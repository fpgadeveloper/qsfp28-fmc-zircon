/* SPDX-License-Identifier: MIT
 *
 * latency.c - latency measurement (zircon_nic 1.3.0), see latency.h
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * What the hardware measures (docs/source/echo_server.md "Latency
 * measurement", DESIGN_SPEC section 11): the MRMAC timestamps the first PCS
 * block of every frame on RX and of the selected frames on TX against one
 * free-running 1588 systimer (2^-8 ns units). zircon_nic subtracts the two
 * and accumulates the delta, in ns, into one of two statistics banks:
 *
 *   bank 0  every hardware UDP echo reply: RX of the request -> TX of the reply
 *   bank 1  every raw (UI0) frame sent with a ZTXT TS_REQ descriptor: RX of
 *           the frame whose rx_ts the descriptor carries -> TX of this frame.
 *           The TCP echo (tcp_echo.c) arms the request's rx_ts, so bank 1 is
 *           the software echo, measured with the same clock and arithmetic.
 *
 * This module only configures the block and reads it: count, sum, sum of
 * squares, min, max and a 64-bin histogram per bank. Percentiles are taken
 * from the histogram and reported as the upper edge of the bin that holds
 * them (at most MAX), so they are upper bounds with the bin width as the
 * resolution.
 */
#include <stdio.h>
#include <string.h>

#include "xiltimer.h"
#include "sleep.h"

#include "lwip/udp.h"
#include "lwip/pbuf.h"
#include "lwip/ip.h"

#include "app_config.h"
#include "console.h"
#include "port.h"
#include "latency.h"
#include "latency_wire.h"

#ifndef COUNTS_PER_SECOND
#define COUNTS_PER_SECOND XPAR_CPU_TIMESTAMP_CLK_FREQ
#endif

static const char *const bank_name[ZIRCON_LAT_NBANKS] = {
	"hardware UDP echo",
	"software TCP echo",
};

/* ------------------------------------------------------------------------ */
/* Helpers                                                                    */
/* ------------------------------------------------------------------------ */
static u64 isqrt64(u64 v)
{
	u64 r = 0, bit = 1ULL << 62;

	while (bit > v)
		bit >>= 2;
	while (bit) {
		if (v >= r + bit) {
			v -= r + bit;
			r = (r >> 1) + bit;
		} else {
			r >>= 1;
		}
		bit >>= 2;
	}
	return r;
}

/* mean and standard deviation in 1/10 ns */
static void mean_stddev(const zircon_lat_bank_t *b, u64 *mean10, u64 *sd10)
{
	double n, mean, var;

	*mean10 = *sd10 = 0;
	if (b->count == 0)
		return;
	n = (double)b->count;
	mean = (double)b->sum_ns / n;
	var = (double)b->sumsq_ns2 / n - mean * mean;
	if (var < 0)
		var = 0;
	*mean10 = (u64)(mean * 10.0 + 0.5);
	*sd10 = isqrt64((u64)(var * 100.0 + 0.5));
}

typedef struct {
	u32 base, width;
	u64 lo[ZIRCON_LAT_NBINS];     /* lower edge of each bin */
} bin_geom_t;

/* The geometry the snapshot of bank b was taken with (the live registers if
 * the snapshot has none) */
static void bin_geom(const port_t *p, const zircon_lat_bank_t *b, bin_geom_t *g)
{
	int i;

	g->base = b->bin_base_ns;
	g->width = b->bin_width_ns;
	if (g->width == 0)
		zircon_lat_get_bins(&p->zircon, &g->base, &g->width);
	for (i = 0; i < ZIRCON_LAT_NBINS; i++)
		g->lo[i] = zircon_lat_bin_lo(i, g->base, g->width);
}

/* Percentile q/10000 (5000 = p50): the upper edge of the bin that holds it,
 * capped at MAX (the overflow bin has no upper edge: MAX) */
static u64 percentile(const zircon_lat_bank_t *b, const bin_geom_t *g, u32 q)
{
	u64 total = 0, target, cum = 0, edge;
	int i;

	for (i = 0; i < ZIRCON_LAT_NBINS; i++)
		total += b->bins[i];
	if (total == 0)
		return 0;
	target = (total * q + 9999) / 10000;
	if (target == 0)
		target = 1;
	for (i = 0; i < ZIRCON_LAT_NBINS; i++) {
		cum += b->bins[i];
		if (cum >= target)
			break;
	}
	if (i >= ZIRCON_LAT_NBINS - 1)
		return b->max_ns;
	edge = g->lo[i + 1];
	return edge < b->max_ns ? edge : b->max_ns;
}

static void fmt_mean(char *buf, int size, u64 v10)
{
	snprintf(buf, size, "%llu.%llu", (unsigned long long)(v10 / 10),
		 (unsigned long long)(v10 % 10));
}

static int snapshot(port_t *p)
{
	if (zircon_lat_snapshot(&p->zircon) != 0) {
		con_printf("Port %d: latency snapshot did not complete (LAT_CTRL 0x%08lx)\r\n",
			   p->n, (unsigned long)zircon_lat_get_ctrl(&p->zircon));
		return -1;
	}
	return 0;
}

/* ------------------------------------------------------------------------ */
/* Bring-up                                                                   */
/* ------------------------------------------------------------------------ */
/* Read the MRMAC 1588 registers twice, 10 ms of A72 time apart; returns the
 * time (ns) the TX / RX timers advanced. TICK_REG also latches the MRMAC
 * statistics: harmless at bring-up (nothing has been counted yet), never done
 * afterwards.
 * The advance is measured on MONITOR_{TX,RX}_1588_SAMPLE_SYSTIMER, not on
 * STAT_{TX,RX}_1588_TOD: on the VCK190 bench (2026-09-24) about half of the
 * TOD read-backs had bit 54 set and ~8 % went backwards (200 TICK+reads per
 * MRMAC), while the SAMPLE registers were monotonic with bit 54 clear in 200
 * of 200 reads. The frame timestamps themselves are not affected (0
 * implausible deltas in 8e8 samples). */
static u64 systimer_probe(port_t *p, mrmac_1588_t *b, u64 *dtx, u64 *drx)
{
	mrmac_1588_t a;
	XTime t0, t1;

	mrmac_tick_only(p->hw.mrmac);
	mrmac_1588_read(p->hw.mrmac, &a);
	XTime_GetTime(&t0);
	usleep(10000);
	mrmac_tick_only(p->hw.mrmac);
	mrmac_1588_read(p->hw.mrmac, b);
	XTime_GetTime(&t1);
	*dtx = ((b->tx_sample - a.tx_sample) & ZIRCON_TS_MASK) >> ZIRCON_TS_FRAC_BITS;
	*drx = ((b->rx_sample - a.rx_sample) & ZIRCON_TS_MASK) >> ZIRCON_TS_FRAC_BITS;
	return (u64)(t1 - t0) * 1000000000ULL / COUNTS_PER_SECOND;
}

void lat_print_1588(port_t *p)
{
	mrmac_1588_t b;
	u64 dt_ns, dtx, drx;

	dt_ns = systimer_probe(p, &b, &dtx, &drx);
	if ((dtx == 0 || drx == 0) && ports[0].hw.gpio_gt) {
		/* the shared ptp_systimer has a sync request on port 0's GPIO */
		con_printf("Port %d: MRMAC 1588 timer not running, requesting a systimer sync\r\n", p->n);
		mrmac_ptp_sync_req(ports[0].hw.gpio_gt);
		dt_ns = systimer_probe(p, &b, &dtx, &drx);
	}
	con_printf("Port %d: 1588 timestamping enabled (2-step), CONFIGURATION_1588_REG 0x%08lx\r\n",
		   p->n, (unsigned long)b.cfg);
	con_printf("Port %d: MRMAC 1588 timer %llu.%09llu s, advanced TX %llu ns RX %llu ns in %llu ns"
		   " of A72 time (systimer samples); increment TX 0x%llx RX 0x%llx\r\n", p->n,
		   (unsigned long long)((b.tx_sample >> 8) / 1000000000ULL),
		   (unsigned long long)((b.tx_sample >> 8) % 1000000000ULL),
		   (unsigned long long)dtx, (unsigned long long)drx, (unsigned long long)dt_ns,
		   (unsigned long long)b.tx_incr, (unsigned long long)b.rx_incr);
	if (dtx == 0 || drx == 0)
		con_printf("Port %d: WARNING: the MRMAC 1588 timer does not advance: latency "
			   "timestamps will be wrong\r\n", p->n);
}

void lat_port_init(port_t *p)
{
	u32 en = ZIRCON_LAT_EN;

	if (!p->has_lat)
		return;
	zircon_lat_set_bins(&p->zircon, LAT_BIN_BASE_NS, LAT_BIN_WIDTH_NS);
	/* the netif accepts descriptors before the hardware sends any, and
	 * falls back to plain frames (rx_ts_missing) while switching */
	if (LAT_RAW_TS_DESC_DEFAULT && p->netif_ok) {
		zircon_netif_set_ts_desc(&p->netif, 1, 1);
		en |= ZIRCON_LAT_RAW_TS_DESC | ZIRCON_LAT_RAW_TX_DESC;
	}
	zircon_lat_set_ctrl(&p->zircon, en);
	zircon_lat_clear(&p->zircon, 3);
	zircon_lat_clear_status(&p->zircon, 0xFFFFFFFF);
	con_printf("Port %d: latency measurement on: bank 0 hardware UDP echo, bank 1 software TCP "
		   "echo%s; histogram %u ns bins from %u ns ('T' to print)\r\n", p->n,
		   (en & ZIRCON_LAT_RAW_TS_DESC) ? "" : " (off: LAT_RAW_TS_DESC_DEFAULT = 0)",
		   (unsigned)LAT_BIN_WIDTH_NS, (unsigned)LAT_BIN_BASE_NS);
}

/* ------------------------------------------------------------------------ */
/* Console report                                                             */
/* ------------------------------------------------------------------------ */
static void print_bank(const port_t *p, int bank, const zircon_lat_bank_t *b, const bin_geom_t *g)
{
	char mean[24], sd[24], range[48];
	u64 mean10, sd10;
	int i;

	(void)p;
	if (b->count == 0) {
		con_printf("bank %d %s: no samples (implausible %lu)\r\n", bank, bank_name[bank],
			   (unsigned long)b->implausible);
		return;
	}
	mean_stddev(b, &mean10, &sd10);
	fmt_mean(mean, sizeof(mean), mean10);
	fmt_mean(sd, sizeof(sd), sd10);
	con_printf("bank %d %s: count %llu min %lu mean %s max %lu stddev %s ns"
		   " | p50 %llu p90 %llu p99 %llu p99.9 %llu ns | implausible %lu last %lu ns\r\n",
		   bank, bank_name[bank], (unsigned long long)b->count,
		   (unsigned long)b->min_ns, mean, (unsigned long)b->max_ns, sd,
		   (unsigned long long)percentile(b, g, 5000),
		   (unsigned long long)percentile(b, g, 9000),
		   (unsigned long long)percentile(b, g, 9900),
		   (unsigned long long)percentile(b, g, 9990),
		   (unsigned long)b->implausible, (unsigned long)b->last_ns);
	con_printf("  %3s  %-22s %12s\r\n", "bin", "ns range", "count");
	for (i = 0; i < ZIRCON_LAT_NBINS; i++) {
		if (b->bins[i] == 0)
			continue;
		if (i == ZIRCON_LAT_NBINS - 1)
			snprintf(range, sizeof(range), ">= %llu", (unsigned long long)g->lo[i]);
		else
			snprintf(range, sizeof(range), "%llu - %llu", (unsigned long long)g->lo[i],
				 (unsigned long long)g->lo[i + 1]);
		con_printf("  %3d  %-22s %12llu\r\n", i, range, (unsigned long long)b->bins[i]);
	}
}

static void report_port(port_t *p)
{
	zircon_lat_bank_t b[ZIRCON_LAT_NBANKS];
	zircon_lat_err_t e;
	bin_geom_t g;
	u32 v = zircon_version(&p->zircon);
	int bank;

	if (!p->ok)
		return;
	if (!p->has_lat) {
		con_printf("Port %d: zircon_nic %d.%d.%d has no latency measurement (needs 1.3.0)\r\n",
			   p->n, (int)ZIRCON_VER_MAJOR(v), (int)ZIRCON_VER_MINOR(v),
			   (int)ZIRCON_VER_PATCH(v));
		return;
	}
	snapshot(p);
	for (bank = 0; bank < ZIRCON_LAT_NBANKS; bank++)
		zircon_lat_read(&p->zircon, bank, &b[bank], 1);
	zircon_lat_read_err(&p->zircon, &e);
	bin_geom(p, &b[0], &g);
	con_printf("LATENCY port %d (LAT_CTRL 0x%08lx LAT_STATUS 0x%08lx%s, stale %lu lost %lu ovf %lu,"
		   " bins %lu ns from %lu ns; RX PCS -> TX PCS of the MRMAC)\r\n", p->n,
		   (unsigned long)zircon_lat_get_ctrl(&p->zircon),
		   (unsigned long)zircon_lat_status(&p->zircon),
		   (mrmac_gt_gpio_in(p->hw.gpio_gt) & MRMAC_GT_IN_PTP_UNDERRUN) ? " PTP_UNDERRUN" : "",
		   (unsigned long)e.stale, (unsigned long)e.lost, (unsigned long)e.ovf,
		   (unsigned long)g.width, (unsigned long)g.base);
	for (bank = 0; bank < ZIRCON_LAT_NBANKS; bank++) {
		bin_geom(p, &b[bank], &g);
		print_bank(p, bank, &b[bank], &g);
	}
}

void lat_clear(port_t *p)
{
	if (!p->ok || !p->has_lat)
		return;
	zircon_lat_clear(&p->zircon, 3);
	zircon_lat_clear_status(&p->zircon, 0xFFFFFFFF);
}

void lat_cmd(const char *s)
{
	int port = -1, clear = 0, p;

	while (*s == ' ')
		s++;
	if (*s >= '0' && *s <= '9') {
		port = *s++ - '0';
		if (*s != ' ' && *s != '\0')
			goto usage;
		while (*s == ' ')
			s++;
	}
	if (*s == 'c') {
		clear = 1;
		s++;
		while (*s == ' ')
			s++;
	}
	if (*s)
		goto usage;
	if (port >= NUM_PORTS || (port >= 0 && !ports[port].ok)) {
		con_printf("no port %d (0..%d)\r\n", port, NUM_PORTS - 1);
		return;
	}
	for (p = 0; p < NUM_PORTS; p++) {
		if (port >= 0 && p != port)
			continue;
		if (clear) {
			if (ports[p].ok && ports[p].has_lat) {
				lat_clear(&ports[p]);
				con_printf("Port %d: latency statistics cleared\r\n", p);
			}
		} else {
			report_port(&ports[p]);
		}
	}
	return;
usage:
	con_printf("usage: T [<port>] [c] Enter (T: print both banks of every port, T c: clear)\r\n");
}

/* ------------------------------------------------------------------------ */
/* Status line                                                                */
/* ------------------------------------------------------------------------ */
int lat_status_summary(port_t *p, char *buf, int size)
{
	zircon_lat_bank_t b;
	bin_geom_t g;
	u64 mean10, sd10;
	int n;

	buf[0] = '\0';
	if (!p->ok || !p->has_lat || zircon_lat_snapshot(&p->zircon) != 0)
		return 0;
	zircon_lat_read(&p->zircon, ZIRCON_LAT_BANK_HW, &b, 1);
	if (b.count == 0)
		return 0;
	bin_geom(p, &b, &g);
	mean_stddev(&b, &mean10, &sd10);
	n = snprintf(buf, size, " | hw lat n %llu min %lu mean %llu p99 %llu max %lu ns",
		     (unsigned long long)b.count, (unsigned long)b.min_ns,
		     (unsigned long long)((mean10 + 5) / 10),
		     (unsigned long long)percentile(&b, &g, 9900), (unsigned long)b.max_ns);
	return n < size ? n : size - 1;
}

/* ------------------------------------------------------------------------ */
/* UDP statistics service                                                     */
/* ------------------------------------------------------------------------ */
static struct udp_pcb *svc_pcb;

static port_t *port_of_netif(const struct netif *n)
{
	int p;

	for (p = 0; p < NUM_PORTS; p++) {
		if (ports[p].netif_ok && &ports[p].netif == n)
			return &ports[p];
	}
	return NULL;
}

static void fill_reply(port_t *p, u8 *out)
{
	lat_wire_hdr_t h;
	lat_wire_bank_t wb;
	zircon_lat_bank_t b[LAT_WIRE_NBANKS];
	bin_geom_t g;
	u32 ctrl;
	int bank, i;

	memset(&h, 0, sizeof(h));
	h.magic = LAT_WIRE_MAGIC;
	h.version = LAT_WIRE_VERSION;
	h.nbanks = LAT_WIRE_NBANKS;
	h.nbins = LAT_WIRE_NBINS;
	h.port = (u8)p->n;
	h.hdr_len = sizeof(h);
	h.zircon_version = zircon_version(&p->zircon);
	h.uptime_ms = now_ms();
	if (!p->has_lat) {
		h.flags = LAT_WIRE_F_NO_LAT;
		memcpy(out, &h, sizeof(h));
		memset(out + sizeof(h), 0, LAT_WIRE_NBANKS * sizeof(lat_wire_bank_t));
		return;
	}
	if (zircon_lat_snapshot(&p->zircon) != 0)
		h.flags |= LAT_WIRE_F_SNAP_FAIL;
	ctrl = zircon_lat_get_ctrl(&p->zircon);
	if (ctrl & ZIRCON_LAT_EN)
		h.flags |= LAT_WIRE_F_EN;
	if (ctrl & ZIRCON_LAT_RAW_TS_DESC)
		h.flags |= LAT_WIRE_F_RAW_TS_DESC;
	for (bank = 0; bank < LAT_WIRE_NBANKS; bank++)
		zircon_lat_read(&p->zircon, bank, &b[bank], 1);
	/* one geometry for both banks in zircon_nic 1.3.0 */
	bin_geom(p, &b[0], &g);
	h.bin_base_ns = g.base;
	h.bin_width_ns = g.width;
	h.lat_status = zircon_lat_status(&p->zircon);
	for (i = 0; i < LAT_WIRE_NBINS; i++)
		h.bin_lo_ns[i] = g.lo[i] > 0xFFFFFFFFULL ? 0xFFFFFFFFu : (u32)g.lo[i];
	memcpy(out, &h, sizeof(h));
	out += sizeof(h);
	for (bank = 0; bank < LAT_WIRE_NBANKS; bank++) {
		wb.count = b[bank].count;
		wb.sum_ns = b[bank].sum_ns;
		wb.sumsq_ns2 = b[bank].sumsq_ns2;
		wb.min_ns = b[bank].min_ns;
		wb.max_ns = b[bank].max_ns;
		wb.implausible = b[bank].implausible;
		wb.last_ns = b[bank].last_ns;
		memcpy(wb.bins, b[bank].bins, sizeof(wb.bins));
		memcpy(out, &wb, sizeof(wb));
		out += sizeof(wb);
	}
}

/* Reply out of the netif the request came in on (the requester is on that
 * port's link, whatever the subnets of the two ports are); data NULL = the
 * statistics of port tp */
static void svc_reply(struct udp_pcb *pcb, const ip_addr_t *addr, u16_t port,
		      struct netif *inp, port_t *tp, const char *text)
{
	u16_t len = text ? (u16_t)strlen(text) : (u16_t)LAT_WIRE_REPLY_LEN;
	struct pbuf *r = pbuf_alloc(PBUF_TRANSPORT, len, PBUF_RAM);

	if (r == NULL)
		return;
	if (text)
		memcpy(r->payload, text, len);
	else
		fill_reply(tp, (u8 *)r->payload);
	if (inp != NULL)
		udp_sendto_if(pcb, r, addr, port, inp);
	else
		udp_sendto(pcb, r, addr, port);
	pbuf_free(r);
}

static void svc_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
		     const ip_addr_t *addr, u16_t port)
{
	char req[16];
	u16_t n;
	port_t *tp;
	const char *s;
	struct netif *inp = ip_current_input_netif();

	(void)arg;
	if (p == NULL)
		return;
	n = pbuf_copy_partial(p, req, sizeof(req) - 1, 0);
	pbuf_free(p);
	while (n && (req[n - 1] == '\n' || req[n - 1] == '\r' || req[n - 1] == ' '))
		n--;
	req[n] = '\0';

	tp = port_of_netif(inp);
	s = NULL;
	if (strncmp(req, "STAT?", 5) == 0)
		s = req + 5;
	else if (strncmp(req, "CLR", 3) == 0)
		s = req + 3;
	if (s != NULL) {
		while (*s == ' ')
			s++;
		if (*s >= '0' && *s <= '9' && s[1] == '\0') {
			int q = *s - '0';

			tp = (q < NUM_PORTS && ports[q].ok) ? &ports[q] : NULL;
		} else if (*s) {
			s = NULL;
		}
	}
	if (s == NULL || tp == NULL || !tp->ok) {
		svc_reply(pcb, addr, port, inp, NULL, "ERR");
		return;
	}
	if (req[0] == 'C') {
		lat_clear(tp);
		svc_reply(pcb, addr, port, inp, NULL, "CLR OK");
		return;
	}
	svc_reply(pcb, addr, port, inp, tp, NULL);
}

int lat_service_start(void)
{
	svc_pcb = udp_new_ip_type(IPADDR_TYPE_V4);
	if (svc_pcb == NULL) {
		con_printf("latency service: out of memory for the PCB\r\n");
		return -1;
	}
	if (udp_bind(svc_pcb, IP_ANY_TYPE, LAT_WIRE_UDP_PORT) != ERR_OK) {
		con_printf("latency service: unable to bind to UDP port %d\r\n", LAT_WIRE_UDP_PORT);
		udp_remove(svc_pcb);
		svc_pcb = NULL;
		return -1;
	}
	udp_recv(svc_pcb, svc_recv, NULL);
	return 0;
}

/* SPDX-License-Identifier: MIT
 *
 * loopback.c - 100G loopback test with the zircon_nic hardware UDP
 *              generator / checker
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * zircon_nic 1.2.0 has, per port, a line-rate UDP generator (payload = 64-bit
 * sequence number + xorshift PRBS seeded from it), a checker that verifies
 * every datagram to CHK_PORT (sequence, payload bits, length) and consumes it
 * in hardware, and 1-second rate meters on the MAC side
 * (docs/DESIGN_SPEC.md section 10). With a QSFP28 cable between port 0 and
 * port 1 this module runs:
 *
 *   'l' cross-port (LB_CROSS): generator p -> cable -> checker of the other
 *       port, in both directions at once (2 x 100G full duplex).
 *       GEN_DST_MAC/IP = the other port's local MAC/IP, GEN_DST_PORT =
 *       GEN_SRC_PORT = CHK_PORT (5001).
 *   'e' echo-through-loopback (LB_ECHO): generator 0 -> cable -> port 1's
 *       hardware UDP echo (UDP 7) -> cable -> checker 0. The echo swaps the
 *       addresses and ports, so the reply's destination port is the request's
 *       source port: GEN_SRC_PORT = CHK_PORT (5001), GEN_DST_PORT = ECHO_PORT (7).
 *
 * With one port (NUM_PORTS = 1) the "other port" is the port itself: a QSFP28
 * loopback plug then runs the same tests.
 *
 * Once a second while a test runs it prints a fixed-column table (per port:
 * link/FEC, generated and checked packets, sequence / bit / length errors,
 * line-rate and payload-rate Gb/s from the hardware meters) and a
 * "LOOPBACK: RUNNING <t> s" line; after LOOPBACK_VERDICT_S seconds of every
 * direction >= LOOPBACK_PASS_CGBPS line rate with zero errors it prints
 * "LOOPBACK: PASS" once, and "LOOPBACK: FAIL <reason>" once if errors or a
 * low rate persist for LOOPBACK_VERDICT_S seconds. The echo mode uses the
 * prefix "LOOPBACK-ECHO:" instead. All output goes through the non-blocking
 * console ring (console.c), so the main loop keeps servicing the DMAs.
 */
#include <stdio.h>
#include <string.h>

#include "sleep.h"
#include "app_config.h"
#include "console.h"
#include "port.h"
#include "loopback.h"

#define LB_TABLE_MS        1000
#define LB_RATE_POLL_MS    200
#define LB_RATE_STALE_MS   2500   /* a meter that stopped ticking reads 0      */
#define LB_WARMUP_S        2      /* first windows include the idle time       */
#define LB_AUTOCHECK_S     3      /* auto-start: traffic must arrive by then   */
#define LB_LINE_RATE_MIN_LEN 726  /* DESIGN_SPEC 10.5: 100G on RX for L >= 726 */

typedef struct {
	u32 last_tx, last_rx, last_seq, last_len;   /* raw 32-bit counters          */
	u64 tx_pkts, rx_pkts, seq_err, len_err;     /* totals since start / clear   */
	u64 bit_err;                                /* 64-bit in hardware           */
	u64 prev_rx_pkts;                           /* at the previous tick         */
} lb_acc_t;

static struct {
	lb_mode_t mode;
	u32 len;
	u32 start_ms;
	u32 last_table_ms, last_rate_ms;
	int good_s, low_s;
	int err_seen;
	u32 first_err_ms;
	int pass_done, fail_done;
	int autostarted;
	int auto_done;
	int all_up;
	u32 all_up_since;
	int gen_on[NUM_PORTS], chk_on[NUM_PORTS];
	int self_port;
	lb_acc_t acc[NUM_PORTS];
} lb;

static inline int peer_of(int p) { return (p + 1) % NUM_PORTS; }

static const char *pfx(void)
{
	return lb.mode == LB_ECHO ? "LOOPBACK-ECHO" : "LOOPBACK";
}

const char *lb_mode_name(lb_mode_t mode)
{
	switch (mode) {
	case LB_CROSS:
		return NUM_PORTS > 1 ? "cross-port" : "self (loopback plug)";
	case LB_ECHO:
		return "echo-through-loopback";
	case LB_SELF:
		return "self (loopback plug)";
	default:
		return "off";
	}
}

void lb_init(void)
{
	memset(&lb, 0, sizeof(lb));
	lb.len = LOOPBACK_LEN;
#if LOOPBACK_AUTOSTART < 0
	lb.auto_done = 1;
#endif
}

lb_mode_t lb_mode(void) { return lb.mode; }
void lb_set_self_port(int port) { lb.self_port = port; }
int lb_self_port(void) { return lb.self_port; }
u32 lb_get_len(void) { return lb.len; }
void lb_cancel_autostart(void) { lb.auto_done = 1; }

/* ------------------------------------------------------------------------ */
/* Counters and rates                                                         */
/* ------------------------------------------------------------------------ */
static void acc_reset(int p)
{
	memset(&lb.acc[p], 0, sizeof(lb.acc[p]));   /* hardware counters were zeroed */
}

static void acc_update(int p)
{
	lb_acc_t *a = &lb.acc[p];
	zircon_genchk_t g;

	if (!ports[p].ok || !ports[p].has_gen)
		return;
	zircon_genchk_read(&ports[p].zircon, &g);
	a->tx_pkts += (u32)(g.gen_tx_pkts - a->last_tx);
	a->rx_pkts += (u32)(g.chk_rx_pkts - a->last_rx);
	a->seq_err += (u32)(g.chk_seq_err - a->last_seq);
	a->len_err += (u32)(g.chk_len_err - a->last_len);
	a->last_tx = g.gen_tx_pkts;
	a->last_rx = g.chk_rx_pkts;
	a->last_seq = g.chk_seq_err;
	a->last_len = g.chk_len_err;
	a->bit_err = g.chk_bit_err;
}

static int rate_fresh(const port_t *p, u32 now)
{
	return p->rate_valid && (u32)(now - p->rate_ms) < LB_RATE_STALE_MS;
}

static u32 tx_line(const port_t *p, u32 now)
{
	return rate_fresh(p, now) ? rate_line_cgbps(p->rate.tx_bytes, p->rate.tx_pkts) : 0;
}

static u32 rx_line(const port_t *p, u32 now)
{
	return rate_fresh(p, now) ? rate_line_cgbps(p->rate.rx_bytes, p->rate.rx_pkts) : 0;
}

static u32 tx_data(const port_t *p, u32 now)
{
	return rate_fresh(p, now) ? rate_frame_cgbps(p->rate.tx_bytes, p->rate.tx_pkts) : 0;
}

static u32 rx_data(const port_t *p, u32 now)
{
	return rate_fresh(p, now) ? rate_frame_cgbps(p->rate.rx_bytes, p->rate.rx_pkts) : 0;
}

/* 1/100 Gb/s -> "99.87" (buf: at least 12 bytes) */
static const char *cg(char *buf, u32 v)
{
	snprintf(buf, 12, "%lu.%02lu", (unsigned long)(v / 100), (unsigned long)(v % 100));
	return buf;
}

int lb_port_involved(int p);

/* Is port p part of the running test (as generator, checker or echo)? */
static int involved(int p)
{
	if (lb.mode == LB_CROSS)
		return 1;
	if (lb.mode == LB_ECHO)
		return p == 0 || p == peer_of(0);
	if (lb.mode == LB_SELF)
		return p == lb.self_port;
	return 0;
}

/* ------------------------------------------------------------------------ */
/* Output                                                                     */
/* ------------------------------------------------------------------------ */
static void print_table_rows(u32 now)
{
	char b1[12], b2[12], b3[12], b4[12];
	int p;

	con_printf("port link FEC            gen TX pkts    chk RX pkts  seq err       bit err"
		   "  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.\r\n");
	for (p = 0; p < NUM_PORTS; p++) {
		port_t *pt = &ports[p];
		lb_acc_t *a = &lb.acc[p];

		if (!pt->ok) {
			con_printf("P%-3d (not present)\r\n", p);
			continue;
		}
		con_printf("P%-3d %-4s %-11s %14llu %14llu %8llu %13llu %8llu %8s %8s %8s %8s\r\n",
			   p, pt->link_up ? "up" : "down",
			   mrmac_fec_name(mrmac_get_fec(pt->hw.mrmac)),
			   (unsigned long long)a->tx_pkts, (unsigned long long)a->rx_pkts,
			   (unsigned long long)a->seq_err, (unsigned long long)a->bit_err,
			   (unsigned long long)a->len_err,
			   cg(b1, tx_line(pt, now)), cg(b2, rx_line(pt, now)),
			   cg(b3, tx_data(pt, now)), cg(b4, rx_data(pt, now)));
	}
}

/* "Port <n>: gen/chk <tx>/<rx> pkts, <e> seq err, <b> bit err, RX <x> Gb/s
 *  (TX <y> Gb/s, <l> len err)" */
static void print_summary(u32 now)
{
	char b1[12], b2[12];
	int p;

	for (p = 0; p < NUM_PORTS; p++) {
		lb_acc_t *a = &lb.acc[p];

		if (!ports[p].ok || !(lb.gen_on[p] || lb.chk_on[p]))
			continue;
		con_printf("Port %d: gen/chk %llu/%llu pkts, %llu seq err, %llu bit err, RX %s Gb/s"
			   " (TX %s Gb/s, %llu len err)\r\n", p,
			   (unsigned long long)a->tx_pkts, (unsigned long long)a->rx_pkts,
			   (unsigned long long)a->seq_err, (unsigned long long)a->bit_err,
			   cg(b1, rx_line(&ports[p], now)), cg(b2, tx_line(&ports[p], now)),
			   (unsigned long long)a->len_err);
	}
}

void lb_print_table(u32 now)
{
	int p;

	for (p = 0; p < NUM_PORTS; p++)
		acc_update(p);
	if (lb.mode == LB_OFF)
		con_printf("LOOPBACK: idle, payload %lu B (counters of the last test; rates = all traffic)\r\n",
			   (unsigned long)lb.len);
	else
		con_printf("%s: RUNNING %lu s (%s, %lu B payload)\r\n", pfx(),
			   (unsigned long)((now - lb.start_ms) / 1000), lb_mode_name(lb.mode),
			   (unsigned long)lb.len);
	print_table_rows(now);
}

/* ------------------------------------------------------------------------ */
/* Start / stop                                                               */
/* ------------------------------------------------------------------------ */
static void hw_stop_all(void)
{
	int p;

	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok || !ports[p].has_gen)
			continue;
		if (zircon_gen_stop(&ports[p].zircon) != 0)
			con_printf("WARNING: Port %d: generator still busy after stop\r\n", p);
	}
	usleep(1000);   /* let the datagrams in flight reach the checkers */
	for (p = 0; p < NUM_PORTS; p++)
		acc_update(p);
	for (p = 0; p < NUM_PORTS; p++) {
		if (ports[p].ok && ports[p].has_gen)
			zircon_chk_enable(&ports[p].zircon, 0);
	}
}

int lb_start(lb_mode_t mode, u32 now, int autostarted)
{
	u8 ip[NUM_PORTS][4];
	int p, q;

	if (mode == LB_OFF)
		return -1;
	if (mode == LB_SELF && (lb.self_port < 0 || lb.self_port >= NUM_PORTS)) {
		con_printf("LOOPBACK: cannot start: no port %d\r\n", lb.self_port);
		return -1;
	}
	for (p = 0; p < NUM_PORTS; p++) {
		if (mode == LB_SELF && p != lb.self_port)
			continue;   /* a self-loop only needs its own port */
		if (!ports[p].ok || !ports[p].has_gen) {
			con_printf("LOOPBACK: cannot start: port %d %s\r\n", p,
				   !ports[p].ok ? "is not present" :
				   "has no hardware UDP generator/checker (zircon_nic < 1.2.0)");
			return -1;
		}
	}
	if (lb.mode != LB_OFF) {
		hw_stop_all();
		lb.mode = LB_OFF;
	}

	/* the checker only claims datagrams addressed to the port's own MAC
	 * AND IPv4 address: every port needs an address (static if no DHCP,
	 * unless the port's address mode is dhcp only) */
	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok)
			continue;
		if (port_ensure_address(&ports[p]) != 0 &&
		    (mode != LB_SELF || p == lb.self_port)) {
			con_printf("LOOPBACK: cannot start: port %d has no IPv4 address "
				   "(type 'i %d static' or 'i %d auto' first)\r\n", p, p, p);
			return -1;
		}
		port_get_ip(&ports[p], ip[p]);
	}

	memset(lb.gen_on, 0, sizeof(lb.gen_on));
	memset(lb.chk_on, 0, sizeof(lb.chk_on));
	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok || !ports[p].has_gen)
			continue;
		zircon_gen_stop(&ports[p].zircon);
		zircon_chk_enable(&ports[p].zircon, 0);
	}
	if (mode == LB_SELF) {
		/* the plug returns the port's own frames: dst = our own MAC / IP */
		p = lb.self_port;
		zircon_gen_config(&ports[p].zircon, ports[p].mac, ip[p],
				  CHK_UDP_PORT, CHK_UDP_PORT, lb.len, 0);
		zircon_chk_config(&ports[p].zircon, CHK_UDP_PORT);
		lb.gen_on[p] = 1;
		lb.chk_on[p] = 1;
	} else if (mode == LB_CROSS) {
		for (p = 0; p < NUM_PORTS; p++) {
			q = peer_of(p);
			zircon_gen_config(&ports[p].zircon, ports[q].mac, ip[q],
					  CHK_UDP_PORT, CHK_UDP_PORT, lb.len, 0);
			zircon_chk_config(&ports[q].zircon, CHK_UDP_PORT);
			lb.gen_on[p] = 1;
			lb.chk_on[q] = 1;
		}
	} else {
		/* the echo reply's destination port = our source port */
		q = peer_of(0);
		zircon_gen_config(&ports[0].zircon, ports[q].mac, ip[q],
				  HW_ECHO_PORT, CHK_UDP_PORT, lb.len, 0);
		zircon_chk_config(&ports[0].zircon, CHK_UDP_PORT);
		lb.gen_on[0] = 1;
		lb.chk_on[0] = 1;
	}
	/* checkers first (enabled + cleared: the first datagram synchronises),
	 * then the generators from sequence number 0 */
	for (p = 0; p < NUM_PORTS; p++) {
		if (lb.chk_on[p]) {
			zircon_chk_enable(&ports[p].zircon, 1);
			zircon_chk_clear(&ports[p].zircon);
		}
		if (lb.gen_on[p])
			zircon_gen_clear(&ports[p].zircon);
		acc_reset(p);
	}
	for (p = 0; p < NUM_PORTS; p++) {
		if (lb.gen_on[p])
			zircon_gen_start(&ports[p].zircon, 1, 0);
	}

	lb.mode = mode;
	lb.start_ms = now;
	lb.last_table_ms = now;
	lb.good_s = lb.low_s = 0;
	lb.err_seen = 0;
	lb.pass_done = lb.fail_done = 0;
	lb.autostarted = autostarted;

	if (mode == LB_SELF)
		con_printf("LOOPBACK: started, self: port %d -> loopback plug -> port %d (UDP %d), "
			   "%lu B payload, continuous\r\n", lb.self_port, lb.self_port, CHK_UDP_PORT,
			   (unsigned long)lb.len);
	else if (mode == LB_CROSS && NUM_PORTS > 1)
		con_printf("LOOPBACK: started, cross-port: port 0 -> port 1 and port 1 -> port 0 "
			   "(UDP %d -> %d), %lu B payload, continuous\r\n",
			   CHK_UDP_PORT, CHK_UDP_PORT, (unsigned long)lb.len);
	else if (mode == LB_CROSS)
		con_printf("LOOPBACK: started, port 0 -> port 0 (loopback plug, UDP %d), "
			   "%lu B payload, continuous\r\n", CHK_UDP_PORT, (unsigned long)lb.len);
	else
		con_printf("LOOPBACK-ECHO: started, port 0 generator -> port %d hardware echo (UDP %d) "
			   "-> port 0 checker (UDP %d), %lu B payload, continuous\r\n",
			   peer_of(0), HW_ECHO_PORT, CHK_UDP_PORT, (unsigned long)lb.len);
	if (lb.len < LB_LINE_RATE_MIN_LEN)
		con_printf("NOTE: payloads below ~%d B cannot reach 100G line rate (packet-rate limit of "
			   "the header path: TX ~16.7 Mpps, RX ~18.75 Mpps)\r\n", LB_LINE_RATE_MIN_LEN);
	return 0;
}

void lb_stop(u32 now, const char *why)
{
	if (lb.mode == LB_OFF)
		return;
	hw_stop_all();
	print_summary(now);
	con_printf("%s: stopped after %lu s%s%s%s\r\n", pfx(),
		   (unsigned long)((now - lb.start_ms) / 1000),
		   why ? " (" : "", why ? why : "", why ? ")" : "");
	lb.mode = LB_OFF;
}

int lb_set_len(u32 len, u32 now)
{
	lb_mode_t m = lb.mode;

	if (len < ZIRCON_GEN_LEN_MIN || len > ZIRCON_GEN_LEN_MAX) {
		con_printf("payload must be %d..%d bytes\r\n", ZIRCON_GEN_LEN_MIN, ZIRCON_GEN_LEN_MAX);
		return -1;
	}
	lb.len = len;
	con_printf("loopback payload: %lu B UDP (%lu B frames)%s\r\n", (unsigned long)len,
		   (unsigned long)(len + ZIRCON_UDP_HDR_BYTES + 4),
		   len < LB_LINE_RATE_MIN_LEN ? " - below ~726 B the packet rate limits the throughput" : "");
	if (m != LB_OFF) {
		lb_stop(now, "payload changed");
		lb_start(m, now, 0);
	}
	return 0;
}

void lb_clear(u32 now)
{
	int p;

	/* the caller pulsed CTRL.STAT_CLR on every port: GEN_TX_* and CHK_* are
	 * 0, the sequence numbers and the checker sync are kept */
	for (p = 0; p < NUM_PORTS; p++)
		acc_reset(p);
	if (lb.mode != LB_OFF) {
		lb.start_ms = now;
		lb.last_table_ms = now;
		lb.good_s = lb.low_s = 0;
		lb.err_seen = 0;
		lb.pass_done = lb.fail_done = 0;
		con_printf("%s: counters cleared, verdict restarted\r\n", pfx());
	}
}

/* ------------------------------------------------------------------------ */
/* Once a second while running                                                */
/* ------------------------------------------------------------------------ */
static void tick(u32 now)
{
	u32 elapsed = (now - lb.start_ms) / 1000;
	u32 min_rate = 0xFFFFFFFFu, r;
	u64 errs = 0, rx_total = 0;
	int link_ok = 1, progress = 1, min_port = 0, min_is_rx = 0;
	int p;

	for (p = 0; p < NUM_PORTS; p++)
		acc_update(p);
	for (p = 0; p < NUM_PORTS; p++) {
		if (!involved(p))
			continue;
		if (!ports[p].link_up)
			link_ok = 0;
		r = tx_line(&ports[p], now);
		if (r < min_rate) {
			min_rate = r;
			min_port = p;
			min_is_rx = 0;
		}
		r = rx_line(&ports[p], now);
		if (r < min_rate) {
			min_rate = r;
			min_port = p;
			min_is_rx = 1;
		}
		if (lb.chk_on[p]) {
			lb_acc_t *a = &lb.acc[p];

			errs += a->seq_err + a->bit_err + a->len_err;
			rx_total += a->rx_pkts;
			if (a->rx_pkts == a->prev_rx_pkts)
				progress = 0;
			a->prev_rx_pkts = a->rx_pkts;
		}
	}

	con_printf("%s: RUNNING %lu s (%s, %lu B payload)\r\n", pfx(), (unsigned long)elapsed,
		   lb_mode_name(lb.mode), (unsigned long)lb.len);
	print_table_rows(now);

	/* auto-started on a guess: stop again if nothing comes back */
	if (lb.autostarted && elapsed >= LB_AUTOCHECK_S && rx_total == 0) {
		lb_stop(now, "auto-start: the checkers received nothing");
		con_printf("LOOPBACK: no loopback traffic seen - port 0 and port 1 do not seem to be "
			   "cabled to each other (type 'l' to run the test anyway)\r\n");
		return;
	}
	if (elapsed < LB_WARMUP_S)
		return;

	if (errs && !lb.err_seen) {
		lb.err_seen = 1;
		lb.first_err_ms = now;
	}
	if (link_ok && min_rate >= LOOPBACK_PASS_CGBPS && errs == 0 && progress)
		lb.good_s++;
	else
		lb.good_s = 0;
	if (!link_ok || min_rate < LOOPBACK_PASS_CGBPS)
		lb.low_s++;
	else
		lb.low_s = 0;

	if (!lb.pass_done && lb.good_s >= LOOPBACK_VERDICT_S) {
		lb.pass_done = 1;
		print_summary(now);
		con_printf("%s: PASS\r\n", pfx());
	}
	if (!lb.fail_done) {
		char b1[12], b2[12];

		if (lb.err_seen && (u32)(now - lb.first_err_ms) >= LOOPBACK_VERDICT_S * 1000u) {
			lb.fail_done = 1;
			print_summary(now);
			con_printf("%s: FAIL errors (%s)\r\n", pfx(),
				   "sequence / bit / length errors counted by the checker");
		} else if (lb.low_s >= LOOPBACK_VERDICT_S) {
			lb.fail_done = 1;
			print_summary(now);
			if (!link_ok)
				con_printf("%s: FAIL link down\r\n", pfx());
			else
				con_printf("%s: FAIL rate: port %d %s %s Gb/s < %s Gb/s line rate for %d s\r\n",
					   pfx(), min_port, min_is_rx ? "RX" : "TX", cg(b1, min_rate),
					   cg(b2, LOOPBACK_PASS_CGBPS), LOOPBACK_VERDICT_S);
		}
	}
}

/* ------------------------------------------------------------------------ */
/* Auto-start                                                                 */
/* ------------------------------------------------------------------------ */
/* Address modes: a port in IP_MODE_STATIC never asks for a lease, so with
 * both ports static the rule is just "both links up for 15 s" (the 3-s
 * no-traffic check still stops a test started on host-cabled ports, and 'l'
 * stops it at any time). A port in IP_MODE_DHCP has no address without a
 * DHCP server - and a port 0 <-> port 1 cable has none - so there is no
 * auto-start while any port is in that mode (re-armed if 'i' changes it). */
static void autostart_poll(u32 now)
{
	int p, all_up = 1, leased = 0, dhcp_only = 0, all_static = 1;

	if (lb.auto_done || lb.mode != LB_OFF)
		return;
	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok || !ports[p].has_gen || !ports[p].link_up)
			all_up = 0;
		if (ports[p].ever_leased)
			leased = 1;
		if (ports[p].ip_mode == IP_MODE_DHCP)
			dhcp_only = 1;
		if (ports[p].ip_mode != IP_MODE_STATIC)
			all_static = 0;
	}
#if LOOPBACK_AUTOSTART == 0
	if (NUM_PORTS < 2 || leased) {
		/* a DHCP server answered: this is not a port 0 <-> port 1 cable */
		lb.auto_done = 1;
		return;
	}
	if (dhcp_only)
		all_up = 0;     /* wait: the 15 s restart once no port is dhcp-only */
#else
	(void)leased;
	(void)all_static;
	(void)dhcp_only;
#endif
	if (!all_up) {
		lb.all_up = 0;
		return;
	}
	if (!lb.all_up) {
		lb.all_up = 1;
		lb.all_up_since = now;
	}
#if LOOPBACK_AUTOSTART == 0
	if ((u32)(now - lb.all_up_since) < LOOPBACK_AUTOSTART_MS)
		return;
	if (all_static)
		con_printf("LOOPBACK: every port has had link for %d s (address mode static): assuming a "
			   "port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)\r\n",
			   LOOPBACK_AUTOSTART_MS / 1000);
	else
		con_printf("LOOPBACK: every port has link and no DHCP server answered in %d s: assuming a "
			   "port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)\r\n",
			   LOOPBACK_AUTOSTART_MS / 1000);
	lb.auto_done = 1;
	lb_start(LB_CROSS, now, 1);
#else
	con_printf("LOOPBACK: LOOPBACK_AUTOSTART is set and every port has link: starting the test\r\n");
	lb.auto_done = 1;
	lb_start(LB_CROSS, now, 0);
#endif
}

void lb_poll(u32 now)
{
	int p;

	if ((u32)(now - lb.last_rate_ms) >= LB_RATE_POLL_MS) {
		lb.last_rate_ms = now;
		for (p = 0; p < NUM_PORTS; p++)
			port_rate_poll(&ports[p], now);
	}
	autostart_poll(now);
	if (lb.mode != LB_OFF && (u32)(now - lb.last_table_ms) >= LB_TABLE_MS) {
		lb.last_table_ms += LB_TABLE_MS;
		if ((u32)(now - lb.last_table_ms) >= LB_TABLE_MS)
			lb.last_table_ms = now;     /* fell behind: resynchronise */
		tick(now);
	}
}

int lb_port_involved(int p)
{
	return lb.mode != LB_OFF && involved(p);
}

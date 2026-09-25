/* SPDX-License-Identifier: MIT
 *
 * port.c - one QSFP28 port of the zircon design (see port.h)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Per port: zircon_nic registers (MAC = APP_MAC_ADDR + port, IPV4 follows
 * lwIP, ECHO_PORT 7, SOCK_LOCAL_PORT 5000, TTL 64, CHK_PORT 5001), the
 * MRMAC/GT bring-up (one-time GT reset through the port's own GT-control
 * GPIO, then the 100G + RS-FEC configuration, re-issued while the link is
 * down, with the FEC fallback), an lwIP netif on the raw path (addressed per
 * the port's address mode: DHCP with a static fallback, static only or DHCP
 * only), the hardware socket demo, and the datapath enable.
 */
#include <string.h>

#include "xparameters.h"
#include "xil_io.h"
#include "xiltimer.h"
#include "sleep.h"

#include "lwip/netif.h"
#include "lwip/ip4_addr.h"
#include "lwip/etharp.h"
#include "netif/ethernet.h"
#if LWIP_DHCP
#include "lwip/dhcp.h"
#endif

#include "app_config.h"
#include "console.h"
#include "latency.h"
#include "port.h"

#ifndef COUNTS_PER_SECOND
#define COUNTS_PER_SECOND XPAR_CPU_TIMESTAMP_CLK_FREQ
#endif

/* IP4_ADDR() with an "a, b, c, d" macro from app_config.h */
#define IP4_ADDR_Q(dst, ...) IP4_ADDR(dst, __VA_ARGS__)

#define IP_MODE_VALID(m) ((m) == IP_MODE_DHCP_THEN_STATIC || (m) == IP_MODE_STATIC || \
			  (m) == IP_MODE_DHCP)
#if !IP_MODE_VALID(IP_MODE_DEFAULT) || !IP_MODE_VALID(IP_MODE_DEFAULT_1)
#error "IP_MODE_DEFAULT / IP_MODE_DEFAULT_1 must be IP_MODE_DHCP_THEN_STATIC, IP_MODE_STATIC or IP_MODE_DHCP"
#endif

/* IP_MODE_DHCP: while no lease arrives, say so every DHCP_NOTE_MS */
#define DHCP_NOTE_MS 30000

/* QSFP sideband GPIO, channel 2 (inputs): b0 ModPrsL, b1 IntL */
#define GPIO2_DATA_OFFSET   0x8
#define QSFP_MODPRSL        (1u << 0)

port_t ports[NUM_PORTS];
mrmac_fec_t fec_mode = APP_FEC_MODE;

static const hw_port_t hw_ports[NUM_PORTS] = HW_PORT_TABLE;
static const u8 base_mac[6] = APP_MAC_ADDR;

/* ------------------------------------------------------------------------ */
/* Time, rates                                                                */
/* ------------------------------------------------------------------------ */
u32 now_ms(void)
{
	XTime t;

	XTime_GetTime(&t);
	return (u32)(t / (COUNTS_PER_SECOND / 1000));
}

/* bits per 1-s window / 10^7 = 1/100 Gb/s */
u32 rate_line_cgbps(u64 bytes, u32 pkts)
{
	return (u32)((8 * (bytes + (u64)ZIRCON_RATE_LINE_OVERHEAD * pkts)) / 10000000ULL);
}

u32 rate_frame_cgbps(u64 bytes, u32 pkts)
{
	u64 hdr = (u64)ZIRCON_UDP_HDR_BYTES * pkts;

	return bytes > hdr ? (u32)((8 * (bytes - hdr)) / 10000000ULL) : 0;
}

/* ------------------------------------------------------------------------ */
/* Addressing                                                                 */
/* ------------------------------------------------------------------------ */
static void print_ip(const char *msg, const ip4_addr_t *ip)
{
	con_printf("%s%d.%d.%d.%d", msg, ip4_addr1(ip), ip4_addr2(ip),
		   ip4_addr3(ip), ip4_addr4(ip));
}

/* "Port <n>: IP a.b.c.d mask m.m.m.m gw g.g.g.g (DHCP|static)" - the same
 * wording as the other Opsero echo servers, parsed by the bench tooling */
static void print_port_address(port_t *p, const char *how)
{
	con_printf("Port %d: ", p->n);
	print_ip("IP ", netif_ip4_addr(&p->netif));
	print_ip(" mask ", netif_ip4_netmask(&p->netif));
	print_ip(" gw ", netif_ip4_gw(&p->netif));
	con_printf(" (%s)\r\n", how);
}

void port_get_ip(const port_t *p, u8 ip[4])
{
	const ip4_addr_t *a = netif_ip4_addr(&p->netif);

	if (!p->netif_ok) {
		memset(ip, 0, 4);
		return;
	}
	ip[0] = ip4_addr1(a);
	ip[1] = ip4_addr2(a);
	ip[2] = ip4_addr3(a);
	ip[3] = ip4_addr4(a);
}

/* Keep the zircon IPV4 register (hardware echo / socket / checker match and
 * source address) in step with lwIP's address */
static void sync_zircon_ip(port_t *p)
{
	u32 v = ip4_addr_get_u32(netif_ip4_addr(&p->netif));
	u8 ip[4];

	if (v == p->programmed_ip)
		return;
	port_get_ip(p, ip);
	zircon_set_ipv4(&p->zircon, v ? ip : NULL);
	p->programmed_ip = v;
}

static void static_address(int n, ip4_addr_t *ip, ip4_addr_t *mask, ip4_addr_t *gw)
{
#if NUM_PORTS > 1
	if (n == 1) {
		IP4_ADDR_Q(ip, STATIC_IP_ADDR_1);
		IP4_ADDR_Q(mask, STATIC_IP_MASK_1);
		IP4_ADDR_Q(gw, STATIC_IP_GW_1);
		return;
	}
#endif
	(void)n;
	IP4_ADDR_Q(ip, STATIC_IP_ADDR);
	IP4_ADDR_Q(mask, STATIC_IP_MASK);
	IP4_ADDR_Q(gw, STATIC_IP_GW);
}

static void set_static_address(port_t *p)
{
	ip4_addr_t ip, mask, gw;

	static_address(p->n, &ip, &mask, &gw);
	netif_set_addr(&p->netif, &ip, &mask, &gw);
	p->addr_state = ADDR_STATIC;
	sync_zircon_ip(p);
	print_port_address(p, "static");
}

/* ---- address modes ---- */
const char *port_ip_mode_name(int mode)
{
	switch (mode) {
	case IP_MODE_STATIC:
		return "static";
	case IP_MODE_DHCP:
		return "dhcp";
	default:
		return "dhcp-then-static";
	}
}

int port_default_ip_mode(int n)
{
#if !LWIP_DHCP
	(void)n;
	return IP_MODE_STATIC;     /* no DHCP client in this lwIP build */
#else
#if NUM_PORTS > 1
	if (n == 1)
		return IP_MODE_DEFAULT_1;
#endif
	(void)n;
	return IP_MODE_DEFAULT;
#endif
}

/* "Port <n>: address mode dhcp-then-static (10 s)" - deliberately not
 * "Port <n>: IP ...", which the bench tooling reads as the address in use */
void port_print_ip_mode(int n, int mode)
{
	switch (mode) {
	case IP_MODE_STATIC:
		con_printf("Port %d: address mode static (no DHCP)\r\n", n);
		break;
	case IP_MODE_DHCP:
		con_printf("Port %d: address mode dhcp (no static fallback)\r\n", n);
		break;
	default:
		con_printf("Port %d: address mode dhcp-then-static (%d s)\r\n", n,
			   (int)(DHCP_TIMEOUT_MS / 1000));
		break;
	}
}

#if LWIP_DHCP
static void stop_dhcp(port_t *p)
{
	/* releases a lease (the address becomes 0.0.0.0) or abandons a
	 * pending request */
	if (p->addr_state == ADDR_DHCP_WAIT || p->addr_state == ADDR_DHCP)
		dhcp_release_and_stop(&p->netif);
}

static void start_dhcp(port_t *p, u32 now)
{
	p->dhcp_start_ms = p->dhcp_note_ms = now;
	if (dhcp_start(&p->netif) == ERR_OK) {
		p->addr_state = ADDR_DHCP_WAIT;
		p->dhcp_failed = 0;
		con_printf("Port %d: DHCP started\r\n", p->n);
	} else if (p->ip_mode == IP_MODE_DHCP) {
		p->addr_state = ADDR_NONE;
		if (!p->dhcp_failed)
			con_printf("Port %d: dhcp_start failed, retrying every %d s\r\n", p->n,
				   (int)(DHCP_TIMEOUT_MS / 1000));
		p->dhcp_failed = 1;
	} else {
		con_printf("Port %d: dhcp_start failed, using static address\r\n", p->n);
		set_static_address(p);
	}
}
#else
static void stop_dhcp(port_t *p)
{
	(void)p;
}
#endif

int port_set_ip_mode(port_t *p, int mode, u32 now)
{
	if (!IP_MODE_VALID(mode))
		return -1;
	if (!p->netif_ok) {
		con_printf("Port %d: no network interface\r\n", p->n);
		return -1;
	}
#if !LWIP_DHCP
	if (mode != IP_MODE_STATIC) {
		con_printf("Port %d: this build has no DHCP client (LWIP_DHCP = 0): static only\r\n", p->n);
		return -1;
	}
#endif
	stop_dhcp(p);
	p->ip_mode = mode;
	p->dhcp_failed = 0;
	port_print_ip_mode(p->n, mode);
	if (mode == IP_MODE_STATIC) {
		set_static_address(p);
		return 0;
	}
#if LWIP_DHCP
	/* no address until a lease arrives (dhcp-then-static: or the fallback) */
	netif_set_addr(&p->netif, IP4_ADDR_ANY4, IP4_ADDR_ANY4, IP4_ADDR_ANY4);
	p->addr_state = ADDR_NONE;
	sync_zircon_ip(p);
	if (netif_is_link_up(&p->netif))
		start_dhcp(p, now);
	else
		con_printf("Port %d: link down, DHCP starts when the link comes up\r\n", p->n);
#else
	(void)now;
#endif
	return 0;
}

void port_print_addressing(port_t *p)
{
	if (!p->ok)
		return;
	port_print_ip_mode(p->n, p->ip_mode);
	if (!p->netif_ok)
		return;
	if (ip4_addr_get_u32(netif_ip4_addr(&p->netif)) != 0)
		print_port_address(p, p->addr_state == ADDR_STATIC ? "static" : "DHCP");
	else if (p->addr_state == ADDR_DHCP_WAIT || p->addr_state == ADDR_DHCP)
		con_printf("Port %d: no IPv4 address yet (DHCP running, %lu s without a lease)\r\n", p->n,
			   (unsigned long)((now_ms() - p->dhcp_start_ms) / 1000));
	else if (p->dhcp_failed)
		con_printf("Port %d: no IPv4 address yet (dhcp_start failed, retrying)\r\n", p->n);
	else
		con_printf("Port %d: no IPv4 address yet (DHCP starts when the link comes up)\r\n", p->n);
}

int port_ensure_address(port_t *p)
{
	if (!p->netif_ok || ip4_addr_get_u32(netif_ip4_addr(&p->netif)) != 0)
		return 0;
	if (p->ip_mode == IP_MODE_DHCP) {
		con_printf("Port %d: no IPv4 address (address mode dhcp, no lease yet)\r\n", p->n);
		return -1;
	}
	stop_dhcp(p);
	con_printf("Port %d: no address yet, using the static one\r\n", p->n);
	set_static_address(p);
	return 0;
}

void port_addr_poll(port_t *p, u32 now)
{
	int link_changed = p->link_changed;
#if LWIP_DHCP
	int link;
#endif

	p->link_changed = 0;
	if (!p->netif_ok)
		return;
#if LWIP_DHCP
	link = netif_is_link_up(&p->netif);
	switch (p->addr_state) {
	case ADDR_NONE:
		if (p->ip_mode == IP_MODE_STATIC)
			set_static_address(p);   /* not reached: static is applied at once */
		else if (link && (!p->dhcp_failed ||
				  (u32)(now - p->dhcp_start_ms) >= DHCP_TIMEOUT_MS))
			start_dhcp(p, now);
		break;
	case ADDR_DHCP_WAIT:
		if (dhcp_supplied_address(&p->netif)) {
			p->addr_state = ADDR_DHCP;
			p->ever_leased = 1;
			sync_zircon_ip(p);
			print_port_address(p, "DHCP");
		} else if (p->ip_mode != IP_MODE_DHCP &&
			   (u32)(now - p->dhcp_start_ms) >= DHCP_TIMEOUT_MS) {
			con_printf("Port %d: no DHCP lease after %d s, falling back to static\r\n",
				   p->n, (int)(DHCP_TIMEOUT_MS / 1000));
			dhcp_release_and_stop(&p->netif);
			set_static_address(p);
		} else {
			if (link_changed && link)
				dhcp_network_changed_link_up(&p->netif);
			/* DHCP only: lwIP keeps retrying by itself; say why there
			 * is no address now and then */
			if (p->ip_mode == IP_MODE_DHCP && link &&
			    (u32)(now - p->dhcp_note_ms) >= DHCP_NOTE_MS) {
				p->dhcp_note_ms = now;
				con_printf("Port %d: no DHCP lease after %lu s (address mode dhcp, no static "
					   "fallback: 'i %d static' or 'i %d auto' to change)\r\n", p->n,
					   (unsigned long)((now - p->dhcp_start_ms) / 1000), p->n, p->n);
			}
		}
		break;
	case ADDR_DHCP:
		if (link_changed && link)
			dhcp_network_changed_link_up(&p->netif);
		if (ip4_addr_get_u32(netif_ip4_addr(&p->netif)) != p->programmed_ip) {
			sync_zircon_ip(p);
			if (p->programmed_ip)
				print_port_address(p, "DHCP");
		}
		break;
	case ADDR_STATIC:
	default:
		break;
	}
#else
	(void)now;
	(void)link_changed;
#endif
}

/* ------------------------------------------------------------------------ */
/* Link                                                                       */
/* ------------------------------------------------------------------------ */
static void print_link_up(port_t *p)
{
	mrmac_state_t st;
	mrmac_fec_t fec = mrmac_get_fec(p->hw.mrmac);

	mrmac_get_state(p->hw.mrmac, &st);
	if (fec == MRMAC_FEC_OFF)
		con_printf("Port %d: link up, 100 Gb/s, FEC off\r\n", p->n);
	else
		con_printf("Port %d: link up, 100 Gb/s, FEC %s (%s, lane lock 0x%x, FEC_CONFIGURATION_REG1 0x%lx)\r\n",
			   p->n, mrmac_fec_name(fec), st.fec_aligned ? "aligned" : "NOT aligned",
			   st.fec_lane_lock, (unsigned long)st.fec_cfg);
}

void port_print_link_diag(port_t *p)
{
	mrmac_state_t st;

	mrmac_get_state(p->hw.mrmac, &st);
	con_printf("Port %d: link down: FEC %s, rx status 0x%08lx, block lock 0x%05lx, "
		   "FEC aligned %d lane lock 0x%x%s%s%s\r\n",
		   p->n, mrmac_fec_name(mrmac_get_fec(p->hw.mrmac)),
		   (unsigned long)st.rx_status, (unsigned long)(st.blk_lock & 0xFFFFF),
		   st.fec_aligned, st.fec_lane_lock,
		   st.local_fault ? ", local fault" : "",
		   st.remote_fault ? ", remote fault" : "",
		   st.hi_ber ? ", hi BER" : "");
}

void port_mac_reinit(port_t *p, mrmac_fec_t fec)
{
	mrmac_port_init(p->hw.mrmac, fec);
	if (fec != MRMAC_FEC_KEEP)
		p->fec_try = fec;
}

void port_link_poll(port_t *p, u32 now)
{
	int up;

	if (!p->ok)
		return;
	up = mrmac_port_link_up(p->hw.mrmac);
	if (up && !p->link_up) {
		print_link_up(p);
		if (p->netif_ok)
			netif_set_link_up(&p->netif);
		p->link_changed = 1;
	} else if (!up && p->link_up) {
		con_printf("Port %d: link down\r\n", p->n);
		if (p->netif_ok)
			netif_set_link_down(&p->netif);
		p->link_changed = 1;
		p->link_down_since_ms = now;
		p->last_retry_ms = now;
		p->last_fec_switch_ms = now;
	}
	p->link_up = up;
	if (up)
		return;

	/* Down: re-issue the MAC reset every LINK_RETRY_MS (the GT does not
	 * re-align on a partner signal that appears after our last reset), and
	 * with FEC_FALLBACK_MS alternate between the chosen FEC mode and FEC off
	 * so that a partner forced to either mode still links. */
	if ((u32)(now - p->last_retry_ms) < LINK_RETRY_MS)
		return;
	p->last_retry_ms = now;
#if FEC_FALLBACK_MS > 0
	if (fec_mode != MRMAC_FEC_KEEP && fec_mode != MRMAC_FEC_OFF &&
	    (u32)(now - p->last_fec_switch_ms) >= FEC_FALLBACK_MS) {
		p->last_fec_switch_ms = now;
		p->fec_try = (p->fec_try == MRMAC_FEC_OFF) ? fec_mode : MRMAC_FEC_OFF;
		con_printf("Port %d: no link after %d s, trying FEC %s\r\n", p->n,
			   (int)((now - p->link_down_since_ms) / 1000), mrmac_fec_name(p->fec_try));
		port_print_link_diag(p);
	}
#else
	if (LINK_DIAG_MS > 0 && (u32)(now - p->last_fec_switch_ms) >= LINK_DIAG_MS) {
		p->last_fec_switch_ms = now;
		con_printf("Port %d: no link for %d s\r\n", p->n,
			   (int)((now - p->link_down_since_ms) / 1000));
		port_print_link_diag(p);
	}
#endif
	port_mac_reinit(p, fec_mode == MRMAC_FEC_KEEP ? MRMAC_FEC_KEEP : p->fec_try);
}

/* ------------------------------------------------------------------------ */
/* Bring-up                                                                   */
/* ------------------------------------------------------------------------ */
int port_hw_init(port_t *p, int n)
{
	u32 v;
	int ok = 1;

	memset(p, 0, sizeof(*p));
	p->n = n;
	p->hw = hw_ports[n];
	memcpy(p->mac, base_mac, 6);
	p->mac[5] = (u8)(base_mac[5] + n);
	p->ip_mode = port_default_ip_mode(n);

	con_printf("Port %d: MAC %02x:%02x:%02x:%02x:%02x:%02x\r\n", n,
		   p->mac[0], p->mac[1], p->mac[2], p->mac[3], p->mac[4], p->mac[5]);

	/* QSFP module presence (ModPrsL, active low), when the GPIO exists */
	if (p->hw.gpio_qsfp) {
		u32 in = Xil_In32(p->hw.gpio_qsfp + GPIO2_DATA_OFFSET);

		con_printf("Port %d: QSFP module %s\r\n", n,
			   (in & QSFP_MODPRSL) ? "NOT present" : "present");
	}

	/* zircon_nic: everything disabled until the datapath is ready */
	if (zircon_init(&p->zircon, p->hw.zircon) != 0) {
		con_printf("ERROR: Port %d: zircon_nic not found at 0x%08lx - port disabled\r\n",
			   n, (unsigned long)p->hw.zircon);
		return -1;
	}
	p->ok = 1;
	v = zircon_version(&p->zircon);
	/* VERSION = major[31:16].minor[15:8].patch[7:0] (0x00010200 = 1.2.0) */
	con_printf("zircon_nic %d.%d.%d at 0x%08lx (port %d)\r\n", (int)ZIRCON_VER_MAJOR(v),
		   (int)ZIRCON_VER_MINOR(v), (int)ZIRCON_VER_PATCH(v), (unsigned long)p->hw.zircon, n);
	if (ZIRCON_VER_MAJOR(v) != 1)
		con_printf("WARNING: zircon_nic major version %d, this application expects 1\r\n",
			   (int)ZIRCON_VER_MAJOR(v));
	else if (v < ZIRCON_VERSION_1_1_0)
		con_printf("NOTE: zircon_nic < 1.1.0: per-path drop counters and packer status read 0\r\n");
	p->has_gen = zircon_has_gen(&p->zircon);
	if (!p->has_gen)
		con_printf("NOTE: Port %d: zircon_nic has no UDP generator/checker (< 1.2.0 or GEN_EN = 0): "
			   "no loopback test\r\n", n);
	p->has_lat = zircon_has_lat(&p->zircon);
	if (!p->has_lat)
		con_printf("NOTE: Port %d: zircon_nic < 1.3.0: no latency measurement\r\n", n);

	zircon_set_mac(&p->zircon, p->mac);
	zircon_set_ipv4(&p->zircon, NULL);
	zircon_set_echo_port(&p->zircon, HW_ECHO_PORT);
	zircon_set_sock_local_port(&p->zircon, SOCK_LOCAL_PORT);
	zircon_set_ttl(&p->zircon, HW_TTL);
	if (p->has_gen) {
		zircon_gen_stop(&p->zircon);
		zircon_chk_enable(&p->zircon, 0);
		zircon_chk_config(&p->zircon, CHK_UDP_PORT);
	}

	/* MRMAC: one-time GT reset (the port's own GT-control GPIO), then
	 * 100G + FEC configuration */
	if (mrmac_gt_reset(p->hw.gpio_gt) != 0) {
		con_printf("Port %d: GT reset-done timeout (no refclk?)\r\n", n);
		ok = 0;
	}
	port_mac_reinit(p, fec_mode);
	if (fec_mode == MRMAC_FEC_KEEP)
		p->fec_try = mrmac_get_fec(p->hw.mrmac);
	con_printf("Port %d: MRMAC at 0x%08lx configured: 100GE, FEC %s (FEC_CONFIGURATION_REG1 0x%08lx), "
		   "RX max frame %lu B\r\n",
		   n, (unsigned long)p->hw.mrmac, mrmac_fec_name(mrmac_get_fec(p->hw.mrmac)),
		   (unsigned long)mrmac_fec_cfg_raw(p->hw.mrmac),
		   (unsigned long)mrmac_rx_max_len(p->hw.mrmac));
	if (p->has_lat)
		lat_print_1588(p);
	p->link_down_since_ms = p->last_retry_ms = p->last_fec_switch_ms = now_ms();
	return ok ? 0 : -1;
}

int port_net_init(port_t *p)
{
	ip4_addr_t ip, mask, gw;
	int ok = 1;

	if (!p->ok)
		return -1;

	/* lwIP on the raw path */
	p->netif_cfg.index = p->n;
	p->netif_cfg.dma_base = p->hw.dma_raw;
	p->netif_cfg.dma_name = p->hw.dma_raw_name;
	memcpy(p->netif_cfg.hwaddr, p->mac, 6);
	/* IP_MODE_STATIC: the static address from the start, link or not (no
	 * DHCP wait); the DHCP modes start without one (port_addr_poll) */
	if (p->ip_mode == IP_MODE_STATIC) {
		static_address(p->n, &ip, &mask, &gw);
	} else {
		ip4_addr_set_zero(&ip);
		ip4_addr_set_zero(&mask);
		ip4_addr_set_zero(&gw);
	}
	if (netif_add(&p->netif, &ip, &mask, &gw, &p->netif_cfg, zircon_netif_init,
		      ethernet_input) == NULL) {
		con_printf("ERROR: Port %d: netif_add failed (raw path DMA)\r\n", p->n);
		ok = 0;
	} else {
		p->netif_ok = 1;
		netif_set_up(&p->netif);
	}
	p->addr_state = p->ip_mode == IP_MODE_STATIC ? ADDR_STATIC : ADDR_NONE;
	if (p->netif_ok && p->ip_mode == IP_MODE_STATIC) {
		sync_zircon_ip(p);
		print_port_address(p, "static");
	}

	/* Hardware socket demo on UI2 */
	p->sock = sock_demo_init(p->n, &p->zircon, p->hw.dma_sock, p->hw.dma_sock_name);
	if (p->sock == NULL) {
		con_printf("WARNING: Port %d: socket DMA init failed, socket demo disabled\r\n", p->n);
		ok = 0;
	}

	/* Latency measurement: bins, banks cleared, RX/TX timestamp
	 * descriptors on the raw path (zircon_nic 1.3.0) */
	lat_port_init(p);

	/* Open the datapath: raw RX/TX, hardware echo, hardware socket */
	zircon_set_ctrl(&p->zircon, ZIRCON_CTRL_RX_EN | ZIRCON_CTRL_TX_EN |
			ZIRCON_CTRL_ECHO_EN | ZIRCON_CTRL_SOCK_EN);
	return ok ? 0 : -1;
}

/* ------------------------------------------------------------------------ */
/* Polling                                                                    */
/* ------------------------------------------------------------------------ */
void port_poll_fast(port_t *p)
{
	if (p->netif_ok)
		zircon_netif_poll(&p->netif);
	sock_demo_poll(p->sock);
}

void port_check(port_t *p)
{
	if (p->netif_ok)
		zircon_netif_check(&p->netif);
	sock_demo_check(p->sock);
}

void port_rate_poll(port_t *p, u32 now)
{
	if (p->ok && zircon_rate_read(&p->zircon, &p->rate_seq, &p->rate)) {
		p->rate_ms = now;
		p->rate_valid = 1;
	}
}

/* ------------------------------------------------------------------------ */
/* Status (phase-1 style line, per port)                                      */
/* ------------------------------------------------------------------------ */
void port_print_status(port_t *p, int force, u32 now)
{
	port_status_snapshot_t s;
	const mrmac_stats_t *ms = &p->mstats;
	char lat[96];
	int changed;

	if (!p->ok)
		return;
	memset(&s, 0, sizeof(s));
	zircon_read_counters(&p->zircon, &s.zc);
	sock_demo_get_stats(p->sock, &s.sd);
	if (p->netif_ok)
		zircon_netif_get_stats(&p->netif, &s.ns);
	s.link_up = p->link_up;

	changed = memcmp(&s, &p->last_status, sizeof(s)) != 0;
	if (!force && !changed && (u32)(now - p->last_status_ms) < STATUS_HEARTBEAT_MS)
		return;
	p->last_status = s;
	p->last_status_ms = now;

	mrmac_tick(p->hw.mrmac, &p->mstats);
	lat_status_summary(p, lat, sizeof(lat));
	con_printf("[%5lu s] P%d link %s FEC %s cw corr %llu uncorr %llu | rx %lu raw %lu echo %lu sock %lu"
		   " | tx %lu raw %lu echo %lu sock %lu | drop fifo %lu bad %lu csum %lu/%lu"
		   " raw %lu sock %lu echo %lu txbig %lu st 0x%lx%s\r\n",
		   (unsigned long)(now / 1000), p->n, p->link_up ? "UP" : "DOWN",
		   mrmac_fec_name(mrmac_get_fec(p->hw.mrmac)),
		   (unsigned long long)ms->fec_corrected_cw, (unsigned long long)ms->fec_uncorrected_cw,
		   (unsigned long)s.zc.rx_frames, (unsigned long)s.zc.rx_raw,
		   (unsigned long)s.zc.rx_echo, (unsigned long)s.zc.rx_sock,
		   (unsigned long)s.zc.tx_frames, (unsigned long)s.zc.tx_raw,
		   (unsigned long)s.zc.tx_echo, (unsigned long)s.zc.tx_sock,
		   (unsigned long)s.zc.rx_fifo_drop, (unsigned long)s.zc.rx_bad_frame,
		   (unsigned long)s.zc.rx_l3_bad_csum, (unsigned long)s.zc.rx_l4_bad_csum,
		   (unsigned long)s.zc.rx_raw_drop, (unsigned long)s.zc.rx_sock_drop,
		   (unsigned long)s.zc.rx_echo_drop, (unsigned long)s.zc.tx_oversize_drop,
		   (unsigned long)s.zc.status, lat);
	if (force || s.ns.rx_err || s.ns.rx_split || s.ns.rx_nobuf || s.ns.tx_busy ||
	    s.ns.dma_err || s.sd.rx_bad_desc || s.sd.tx_busy || s.sd.dma_err ||
	    s.ns.rx_ts_missing || s.ns.rx_ts_len_err) {
		con_printf("          P%d lwip rx %lu (err %lu split %lu nobuf %lu in-err %lu) tx %lu/%lu"
			   " busy %lu dma err %lu | sock bounced %lu/%lu bad desc %lu len err %lu busy %lu"
			   " peer changes %lu dma err %lu\r\n", p->n,
			   (unsigned long)s.ns.rx_frames, (unsigned long)s.ns.rx_err,
			   (unsigned long)s.ns.rx_split, (unsigned long)s.ns.rx_nobuf,
			   (unsigned long)s.ns.rx_input_err, (unsigned long)s.ns.tx_done,
			   (unsigned long)s.ns.tx_queued, (unsigned long)s.ns.tx_busy,
			   (unsigned long)s.ns.dma_err, (unsigned long)s.sd.tx_datagrams,
			   (unsigned long)s.sd.rx_datagrams, (unsigned long)s.sd.rx_bad_desc,
			   (unsigned long)s.sd.rx_len_err, (unsigned long)s.sd.tx_busy,
			   (unsigned long)s.sd.peer_changes, (unsigned long)s.sd.dma_err);
		if (p->has_lat)
			con_printf("          P%d raw timestamp descriptors: rx %lu (missing %lu, length"
				   " mismatch %lu), tx TS_REQ %lu\r\n", p->n,
				   (unsigned long)s.ns.rx_ts_frames, (unsigned long)s.ns.rx_ts_missing,
				   (unsigned long)s.ns.rx_ts_len_err, (unsigned long)s.ns.tx_ts_req);
	}
	if (force)
		con_printf("          P%d MRMAC rx pkts %llu good %llu bad FCS %llu | tx pkts %llu good %llu\r\n",
			   p->n, (unsigned long long)ms->rx_packets,
			   (unsigned long long)ms->rx_good_packets, (unsigned long long)ms->rx_bad_fcs,
			   (unsigned long long)ms->tx_packets, (unsigned long long)ms->tx_good_packets);
}

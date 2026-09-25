/* SPDX-License-Identifier: MIT
 *
 * port.h - one QSFP28 port of the zircon design: MRMAC + GT, zircon_nic,
 *          raw-path lwIP netif (DHCP / static, per-port address mode),
 *          hardware echo and socket
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Every per-port resource lives in a port_t, indexed 0..NUM_PORTS-1; the
 * hardware addresses come from hw_config.h (HW_PORT_TABLE). The Si5328 (GT
 * reference clocks of both ports) is shared and programmed once by main().
 */
#ifndef PORT_H
#define PORT_H

#include "xil_types.h"
#include "lwip/netif.h"

#include "hw_config.h"
#include "mrmac.h"
#include "zircon.h"
#include "zircon_netif.h"
#include "sock_demo.h"

enum addr_state {
	ADDR_NONE = 0,     /* waiting for link          */
	ADDR_DHCP_WAIT,    /* DHCP running, no lease yet */
	ADDR_DHCP,         /* DHCP lease in use          */
	ADDR_STATIC        /* static address in use      */
};

typedef struct {
	zircon_counters_t zc;
	sock_demo_stats_t sd;
	zircon_netif_stats ns;
	int link_up;
} port_status_snapshot_t;

typedef struct port {
	int n;                        /* port number                          */
	hw_port_t hw;                 /* base addresses (hw_config.h)         */
	u8 mac[6];
	int ok;                       /* zircon_nic found, port usable        */
	int has_gen;                  /* zircon_nic has the generator/checker */
	int has_lat;                  /* zircon_nic has latency measurement   */

	zircon_t zircon;
	zircon_netif_config netif_cfg;
	struct netif netif;
	int netif_ok;
	sock_demo_t *sock;

	/* addressing */
	int ip_mode;                  /* IP_MODE_* (app_config.h)              */
	enum addr_state addr_state;
	int ever_leased;              /* a DHCP lease has been obtained        */
	int dhcp_failed;              /* dhcp_start() failed, retry later      */
	u32 dhcp_start_ms;
	u32 dhcp_note_ms;             /* last "still no lease" note (IP_MODE_DHCP) */
	u32 programmed_ip;            /* address last written to zircon IPV4   */

	/* link */
	int link_up;
	int link_changed;             /* since the last addr_poll             */
	mrmac_fec_t fec_try;          /* currently programmed FEC mode        */
	u32 link_down_since_ms, last_retry_ms, last_fec_switch_ms;
	mrmac_stats_t mstats;         /* MRMAC statistics totals              */

	/* periodic status line */
	port_status_snapshot_t last_status;
	u32 last_status_ms;

	/* hardware rate meter: latest 1-s window */
	u32 rate_seq;
	u32 rate_ms;                  /* when the latest window was read       */
	int rate_valid;
	zircon_rate_t rate;
} port_t;

extern port_t ports[NUM_PORTS];
extern mrmac_fec_t fec_mode;      /* the FEC mode programmed on every port */

u32  now_ms(void);

/* Bring-up, in this order: port_hw_init (zircon_nic registers, GT reset,
 * MRMAC 100G/FEC) for every port, lwip_init(), then port_net_init (netif,
 * socket DMA, datapath enable). Both return 0 on success. */
int  port_hw_init(port_t *p, int n);
int  port_net_init(port_t *p);

void port_poll_fast(port_t *p);              /* raw + socket DMA, every loop     */
void port_link_poll(port_t *p, u32 now);     /* link state, MAC re-init          */
void port_addr_poll(port_t *p, u32 now);     /* DHCP / static per address mode   */
void port_check(port_t *p);                  /* DMA error recovery, ~1 Hz        */
void port_rate_poll(port_t *p, u32 now);     /* read a new rate-meter window     */

void port_mac_reinit(port_t *p, mrmac_fec_t fec);
void port_print_status(port_t *p, int force, u32 now);
void port_print_link_diag(port_t *p);
/* Make sure the port has an IPv4 address: in IP_MODE_DHCP_THEN_STATIC stop
 * a pending DHCP and use the static address. Returns -1 if the port has no
 * address and its mode (IP_MODE_DHCP) forbids the static one. */
int  port_ensure_address(port_t *p);

/* Address modes. port_ip_mode_name: "dhcp-then-static", "static", "dhcp".
 * port_default_ip_mode: IP_MODE_DEFAULT (port 1: IP_MODE_DEFAULT_1).
 * port_print_ip_mode prints "Port <n>: address mode <name> (<detail>)". */
const char *port_ip_mode_name(int mode);
int  port_default_ip_mode(int n);
void port_print_ip_mode(int n, int mode);
/* Switch the port to another address mode now (console 'i'): stops DHCP,
 * then applies the static address or restarts DHCP. Returns 0, or -1 if
 * the mode is not available (DHCP modes in a build without LWIP_DHCP). */
int  port_set_ip_mode(port_t *p, int mode, u32 now);
/* Address mode and the address in use (console 's') */
void port_print_addressing(port_t *p);
/* The port's IPv4 address, network order (0.0.0.0 if none) */
void port_get_ip(const port_t *p, u8 ip[4]);

/* Line rate (with FCS, preamble and IPG) and payload-ish frame rate of a
 * rate-meter window in 1/100 Gb/s */
u32  rate_line_cgbps(u64 bytes, u32 pkts);
u32  rate_frame_cgbps(u64 bytes, u32 pkts);   /* bytes minus 42 B of headers */

#endif /* PORT_H */

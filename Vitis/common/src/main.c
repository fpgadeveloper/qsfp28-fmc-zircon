/* SPDX-License-Identifier: MIT
 *
 * main.c - 2x QSFP28 FMC Zircon echo server + 100G loopback test
 *          (VCK190, bare metal)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Both QSFP ports of the Opsero 2x QSFP28 FMC run at 100 Gb/s on a Versal
 * MRMAC each (CAUI-4, RS-FEC) with a zircon_nic block (Taxi Zircon IP stack)
 * between the MAC and the processor. On every port this application brings
 * the link up and offers the three zircon user interfaces (port.c):
 *
 *   UI0 raw path    - lwIP over axi_dma_raw[_1] (zircon_netif.c): DHCP and/or
 *                     a static address (per-port address mode, IP_MODE_DEFAULT
 *                     in app_config.h), ARP, ping, software TCP echo on port 7
 *   UI1 hw echo     - UDP datagrams to port 7 are echoed by the hardware
 *   UI2 hw socket   - UDP datagrams to port 5000 arrive payload-only with a
 *                     descriptor on axi_dma_sock[_1] and are bounced back
 *                     through the socket TX channel (sock_demo.c)
 *
 * plus, with zircon_nic 1.3.0, latency measurement from the MRMAC's IEEE 1588
 * timestamps: hardware UDP echo and software TCP echo, RX PCS to TX PCS
 * (latency.c; console 'T', UDP statistics service on port 5002),
 *
 * and, with the zircon_nic 1.2.0 hardware UDP generator / checker, a 100G
 * loopback test over a QSFP28 cable between port 0 and port 1 (loopback.c):
 * no host NIC needed. It starts by itself when both ports have link and no
 * DHCP server answers (see LOOPBACK_AUTOSTART in app_config.h).
 *
 * Bring-up: VADJ 1.5 V (FMC I/O) -> Si5328 322.265625 MHz on CKOUT1 (port 0,
 * GBTCLK0) and CKOUT2 (port 1, GBTCLK1) -> per port: zircon_nic registers,
 * GT reset, MRMAC 100G/RS-FEC -> lwIP (one netif per port) + DHCP -> services
 * -> poll loop. See app_config.h for the settings.
 *
 * KCU116 (MicroBlaze, HW_MAC_CMAC): the same application on port 0 only,
 * with the UltraScale+ CMAC (Taxi taxi_eth_mac_100g_us behind the
 * zircon_cmac_us shim, RS(528,514) fixed) instead of the MRMAC. Caches are
 * enabled first; VADJ is fixed at 1.8 V by the board (nothing to program);
 * the Si5328 is programmed before the shim releases the GT reset.
 *
 * Everything runs from one polled main loop, including lwIP's timers, which
 * are paced from a free-running 64-bit time base (timebase.h: the Arm
 * generic timer, or axi_timer_1 on MicroBlaze): no interrupts are used.
 * Console output is buffered (console.c) so printing never stalls it.
 *
 * Console: h help, s status, z registers, f cycle FEC, c clear counters,
 * l / e start/stop the loopback tests, p <bytes> payload size,
 * i <port> dhcp|static|auto address mode, T [<port>] [c] latency.
 */
#include <stdio.h>
#include <string.h>
#include <ctype.h>

#include "xparameters.h"
#include "xil_cache.h"
#include "sleep.h"
#include "board.h"

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"   /* tcp_fasttmr / tcp_slowtmr */
#include "lwip/ip4_frag.h"
#include "lwip/etharp.h"
#if LWIP_DHCP
#include "lwip/dhcp.h"
#endif

#include "app_config.h"
#include "hw_config.h"
#include "console.h"
#include "vadj.h"
#include "si5328.h"
#include "port.h"
#include "loopback.h"
#include "latency.h"
#include "latency_wire.h"
#include "tcp_echo.h"
#include "timebase.h"

/* lwIP timer periods (NO_SYS_NO_TIMERS: the application calls them) */
#define TCP_FAST_MS    TCP_FAST_INTERVAL        /* 250 ms */
#define TCP_SLOW_MS    TCP_SLOW_INTERVAL        /* 500 ms */
#define ARP_MS         ARP_TMR_INTERVAL         /* 1 s    */
#define LINK_POLL_MS   500
#define ADDR_POLL_MS   1000

/* ------------------------------------------------------------------------ */
/* Console                                                                    */
/* ------------------------------------------------------------------------ */
static void print_help(void)
{
#if MAC_SUPPORTS_FEC_CHANGE
	con_printf("Keys: h help, s status, z zircon registers, f cycle FEC mode, c clear counters\r\n");
#else
	con_printf("Keys: h help, s status, z zircon registers, c clear counters (FEC fixed: RS(528,514))\r\n");
#endif
#if NUM_PORTS > 1
	con_printf("      l start/stop the loopback test (port 0 <-> port 1 cable: each port's hardware\r\n"
		   "        generator -> the other port's hardware checker, 2 x 100G full duplex)\r\n");
	con_printf("      e start/stop the echo-through-loopback test (port 0 generator -> port 1\r\n"
		   "        hardware UDP echo -> port 0 checker)\r\n");
#else
	con_printf("      l start/stop the loopback test (QSFP28 loopback plug in port 0: hardware\r\n"
		   "        generator -> plug -> hardware checker, 100G; same as L 0)\r\n");
	con_printf("      e start/stop the echo-through-loopback test (loopback plug: port 0 generator\r\n"
		   "        -> plug -> port 0 hardware UDP echo -> plug -> port 0 checker)\r\n");
#endif
	con_printf("      L <port> start/stop the self-loopback test on one port (QSFP28 loopback\r\n"
		   "        plug: the port's generator -> plug -> the same port's checker)\r\n");
	con_printf("      p <bytes> UDP payload of the tests, 8..9000 (now %lu). 100G line rate needs\r\n"
		   "        about 726 B and up: the Zircon header path handles one packet per ~16-18\r\n"
		   "        core cycles (~16.7 Mpps TX, ~18.75 Mpps RX); up to 9000 (jumbo) is fine\r\n",
		   (unsigned long)lb_get_len());
	con_printf("      i <port> dhcp|static|auto  address mode of a port, applied at once (auto =\r\n"
		   "        dhcp-then-static); i alone shows the address mode and address of every port\r\n");
#if defined(HW_MAC_CMAC)
	con_printf("      T [<port>] [c] Enter  latency statistics (zircon_nic 1.3.0): hardware UDP echo\r\n"
		   "        and software TCP echo, MAC-client SOF RX -> TX; T c clears them\r\n");
#else
	con_printf("      T [<port>] [c] Enter  latency statistics (zircon_nic 1.3.0): hardware UDP echo\r\n"
		   "        and software TCP echo, RX PCS -> TX PCS; T c clears them\r\n");
#endif
}

static void print_status_all(u32 now)
{
	int p;

	for (p = 0; p < NUM_PORTS; p++) {
		port_print_status(&ports[p], 1, now);
		if (ports[p].ok && !ports[p].link_up)
			port_print_link_diag(&ports[p]);
		port_print_addressing(&ports[p]);
	}
	lb_print_table(now);
}

static void clear_counters(u32 now)
{
	int p;

	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok)
			continue;
		zircon_clear_stats(&ports[p].zircon);   /* also GEN_TX_* / CHK_* */
		memset(&ports[p].mstats, 0, sizeof(ports[p].mstats));
	}
	con_printf("counters cleared\r\n");
	lb_clear(now);
}

static void toggle_test(lb_mode_t mode, u32 now)
{
	lb_cancel_autostart();
	if (lb_mode() == mode)
		lb_stop(now, "console");
	else
		lb_start(mode, now, 0);
}

/* 'L <port>' Enter: start the self-loopback test on that port, or stop it if
 * it is already running there; 'L' Enter alone stops a running self test */
static void self_loop_cmd(int have_port, u32 port, u32 now)
{
	lb_cancel_autostart();
	if (!have_port) {
		if (lb_mode() == LB_SELF)
			lb_stop(now, "console");
		else
			con_printf("usage: L <port> Enter (port 0..%d)\r\n", NUM_PORTS - 1);
		return;
	}
	if (port >= NUM_PORTS) {
		con_printf("no port %lu (0..%d)\r\n", (unsigned long)port, NUM_PORTS - 1);
		return;
	}
	if (lb_mode() == LB_SELF && lb_self_port() == (int)port) {
		lb_stop(now, "console");
		return;
	}
	lb_set_self_port((int)port);
	lb_start(LB_SELF, now, 0);
}

/* 'i <port> dhcp|static|auto' Enter: switch the port's address mode now;
 * 'i <port>' Enter or 'i' Enter alone: show the address mode(s) */
static void ip_mode_cmd(const char *s, u32 now)
{
	char word[20];
	u32 port = 0;
	int digits = 0, n = 0, mode, p;

	while (*s == ' ')
		s++;
	if (*s == '\0') {
		for (p = 0; p < NUM_PORTS; p++)
			port_print_addressing(&ports[p]);
		return;
	}
	while (*s >= '0' && *s <= '9' && digits < 3) {
		port = port * 10 + (u32)(*s++ - '0');
		digits++;
	}
	if (digits == 0 || (*s != ' ' && *s != '\0'))
		goto usage;
	while (*s == ' ')
		s++;
	while (*s && *s != ' ' && n < (int)sizeof(word) - 1)
		word[n++] = *s++;
	word[n] = '\0';
	while (*s == ' ')
		s++;
	if (*s)
		goto usage;
	if (port >= NUM_PORTS || !ports[port].ok) {
		con_printf("no port %lu (0..%d)\r\n", (unsigned long)port, NUM_PORTS - 1);
		return;
	}
	if (n == 0) {
		port_print_addressing(&ports[port]);
		return;
	}
	if (strcmp(word, "dhcp") == 0)
		mode = IP_MODE_DHCP;
	else if (strcmp(word, "static") == 0)
		mode = IP_MODE_STATIC;
	else if (strcmp(word, "auto") == 0 || strcmp(word, "dhcp-then-static") == 0)
		mode = IP_MODE_DHCP_THEN_STATIC;
	else
		goto usage;
	if (port_set_ip_mode(&ports[port], mode, now) == 0 && lb_port_involved((int)port)) {
		/* The generators were set up with the old address and the port's
		 * checker only claims datagrams to its CURRENT address (zircon IPV4
		 * register), so the running test cannot continue unchanged. With a
		 * static address, restart it at once; otherwise stop it (dhcp: no
		 * address until a lease; auto: DHCP gets its 10 s first). */
		lb_mode_t m = lb_mode();
		char why[48];

		snprintf(why, sizeof(why), "address mode of port %lu changed", (unsigned long)port);
		lb_stop(now, why);
		if (mode == IP_MODE_STATIC)
			lb_start(m, now, 0);
		else
			con_printf("LOOPBACK: start the test again once port %lu has an address "
				   "(%s)\r\n", (unsigned long)port,
				   mode == IP_MODE_DHCP ? "dhcp only: it needs a DHCP lease"
							: "at the latest after the 10 s DHCP wait");
	}
	return;
usage:
	con_printf("usage: i <port> dhcp|static|auto Enter (port 0..%d), or i Enter to show the "
		   "address modes\r\n", NUM_PORTS - 1);
}

/* Single-key commands, plus "p <bytes>", "L <port>" and
 * "i <port> <mode>" terminated by Enter */
static void console_poll(u32 now)
{
	static int in_p;          /* collecting the digits of a 'p' / 'L' command */
	static int in_cmd;        /* 'p', 'L' or 'i' */
	static u32 p_val;
	static int p_digits;
	static char line[32];     /* the text of an 'i' / 'T' command */
	static int line_len;
	int c = con_getc();
	int p;

	if (c < 0)
		return;
	if (in_p && (in_cmd == 'i' || in_cmd == 'T')) {
		if (c == '\r' || c == '\n') {
			con_printf("\r\n");
			in_p = 0;
			line[line_len] = '\0';
			if (in_cmd == 'T')
				lat_cmd(line);
			else
				ip_mode_cmd(line, now);
		} else if ((c == 0x08 || c == 0x7F) && line_len) {
			line_len--;
			con_printf("\b \b");
		} else if (c >= 0x20 && c < 0x7F && line_len < (int)sizeof(line) - 1) {
			line[line_len++] = (char)tolower(c);
			con_printf("%c", c);
		} else if (c < 0x20 || c >= 0x7F) {
			con_printf(" (cancelled)\r\n");
			in_p = 0;
		}
		return;
	}
	if (in_p) {
		if (c >= '0' && c <= '9' && p_digits < 6) {
			p_val = p_val * 10 + (u32)(c - '0');
			p_digits++;
			con_printf("%c", c);
		} else if (c == ' ' && p_digits == 0) {
			/* allow "p 1472" */
		} else if ((c == 0x08 || c == 0x7F) && p_digits) {
			p_val /= 10;
			p_digits--;
			con_printf("\b \b");
		} else if (c == '\r' || c == '\n') {
			con_printf("\r\n");
			in_p = 0;
			if (in_cmd == 'L')
				self_loop_cmd(p_digits != 0, p_val, now);
			else if (p_digits)
				lb_set_len(p_val, now);
			else
				con_printf("loopback payload: %lu B\r\n", (unsigned long)lb_get_len());
		} else {
			con_printf(" (cancelled)\r\n");
			in_p = 0;
		}
		return;
	}
	switch (c) {
	case 'h':
	case '?':
		print_help();
		break;
	case 's':
		print_status_all(now);
		break;
	case 'z':
		for (p = 0; p < NUM_PORTS; p++) {
			if (!ports[p].ok)
				continue;
			con_printf("---- port %d ----\r\n", p);
			zircon_dump(&ports[p].zircon);
		}
		break;
	case 'c':
		clear_counters(now);
		break;
	case 'l':
		toggle_test(LB_CROSS, now);
		break;
	case 'e':
		toggle_test(LB_ECHO, now);
		break;
	case 'p':
	case 'L':
	case 'i':
	case 'T':
		con_printf("%c ", c);
		in_cmd = c;
		in_p = 1;
		p_val = 0;
		p_digits = 0;
		line_len = 0;
		break;
	case 'f':
		if (!mac_supports_fec_change()) {
			con_printf("FEC fixed on this target: RS(528,514) (Taxi " MAC_NAME " wrapper)\r\n");
			break;
		}
		switch (fec_mode) {
		case MAC_FEC_RS528:
			fec_mode = MAC_FEC_OFF;
			break;
		case MAC_FEC_OFF:
			fec_mode = MAC_FEC_RS544;
			break;
		default:
			fec_mode = MAC_FEC_RS528;
			break;
		}
		con_printf("MRMAC FEC mode -> %s, resetting the MACs\r\n", mac_fec_name(fec_mode));
		for (p = 0; p < NUM_PORTS; p++) {
			if (!ports[p].ok)
				continue;
			port_mac_reinit(&ports[p], fec_mode);
			ports[p].link_down_since_ms = ports[p].last_retry_ms =
				ports[p].last_fec_switch_ms = now;
		}
		break;
	default:
		break;
	}
}

/* ------------------------------------------------------------------------ */
/* Main                                                                       */
/* ------------------------------------------------------------------------ */
int main(void)
{
	u32 t0, now, t_fast, t_slow, t_arp, t_link, t_addr, t_status;
#if LWIP_DHCP
	u32 t_dhcp_fine, t_dhcp_coarse;
#endif
	int ok = 1, any_ok = 0, all_up;
	int p;

#ifdef __MICROBLAZE__
	/* The MicroBlaze start-up code leaves the caches off: enable them
	 * before anything else (the lwIP pools, DMA buffers and heap are in
	 * DDR). The D-cache is kept coherent with the AXI DMAs by zdma.c's
	 * flush/invalidate calls and the AXI DMA driver's BD maintenance. */
	Xil_ICacheEnable();
	Xil_DCacheEnable();
#endif
	timebase_init();

	con_printf("\r\n\r\n----- 2x QSFP28 FMC Zircon echo server (%s) -----\r\n", BOARD_NAME);
#if defined(HW_MAC_CMAC)
	con_printf("QSFP ports: %d x 100GbE, UltraScale+ CMAC via Taxi taxi_eth_mac_100g_us (CAUI-4, FEC %s)"
		   " + zircon_nic (Taxi Zircon)\r\n", NUM_PORTS, mac_fec_name(MAC_FEC_RS528));
#else
	con_printf("QSFP ports: %d x 100GbE, Versal MRMAC (CAUI-4, FEC %s) + zircon_nic (Taxi Zircon)\r\n",
		   NUM_PORTS, mac_fec_name(fec_mode));
#endif
	for (p = 0; p < NUM_PORTS; p++)
		port_print_ip_mode(p, port_default_ip_mode(p));

#if !defined(__MICROBLAZE__)
	/* FMC I/Os are LVCMOS15: VADJ = 1.5 V (VCK190 regulator via LPD I2C0) */
	if (vadj_enable(VADJ_1V5) != 0)
		con_printf("WARNING: failed to enable VADJ\r\n");
	else
		con_printf("VADJ enabled (1.5V)\r\n");
	sleep(1);
#else
	/* KCU116: VADJ is fixed at 1.8 V by the board, FMC I/Os are LVCMOS18 */
#endif

	/* GT reference clocks: the FMC's Si5328, free-run 322.265625 MHz on
	 * CKOUT1 (GBTCLK0, port 0) and CKOUT2 (GBTCLK1, port 1): one
	 * programming for both ports (si5328.c enables CKOUT2). It must run
	 * before port_hw_init(): the CMAC shim only releases the GT reset there,
	 * once the refclk exists. */
	if (si5328_init(IIC_CLK_BASEADDR, SI5328_OUT_322M266) != 0) {
		con_printf("ERROR: Si5328 programming failed - no GT refclk\r\n");
		ok = 0;
	} else {
#if defined(HW_MAC_CMAC)
		con_printf("Si5328 programmed: GT refclk 322.265625 MHz (CKOUT1 port 0)\r\n");
#else
		con_printf("Si5328 programmed: GT refclk 322.265625 MHz (CKOUT1 port 0, CKOUT2 port 1)\r\n");
#endif
	}

	/* Per port: zircon_nic registers, GT reset, MAC 100G/FEC */
	for (p = 0; p < NUM_PORTS; p++) {
		if (port_hw_init(&ports[p], p) != 0)
			ok = 0;
		if (ports[p].ok)
			any_ok = 1;
	}
	if (!any_ok) {
		con_printf("ERROR: no zircon_nic found, stopping\r\n");
		con_flush();
		return -1;
	}

	/* lwIP: one netif per port on the raw path */
	lwip_init();
	for (p = 0; p < NUM_PORTS; p++) {
		if (ports[p].ok && port_net_init(&ports[p]) != 0)
			ok = 0;
	}
	for (p = 0; p < NUM_PORTS; p++) {
		if (ports[p].netif_ok) {
			netif_set_default(&ports[p].netif);
			break;
		}
	}

	if (tcp_echo_start(TCP_ECHO_PORT) != 0)
		ok = 0;
	if (lat_service_start() != 0)
		ok = 0;
	con_printf("UDP echo (hardware) on port %d, UDP socket demo (hardware) on port %d, "
		   "TCP echo (software) on port %d, latency statistics on UDP port %d - on every QSFP port\r\n",
		   HW_ECHO_PORT, SOCK_LOCAL_PORT, TCP_ECHO_PORT, LAT_WIRE_UDP_PORT);
	if (!ok)
		con_printf("WARNING: bring-up had errors (see above)\r\n");
	lb_init();
	print_help();

	/* Wait (bounded) for the links before starting the loop */
	con_printf("Waiting for the 100G link%s...\r\n", NUM_PORTS > 1 ? "s" : "");
	t0 = now_ms();
	while ((u32)(now_ms() - t0) < 5000) {
		all_up = 1;
		for (p = 0; p < NUM_PORTS; p++) {
			if (ports[p].ok && !mac_link_up(&ports[p].hw))
				all_up = 0;
		}
		if (all_up)
			break;
		usleep(100000);
	}
	now = now_ms();
	for (p = 0; p < NUM_PORTS; p++) {
		if (!ports[p].ok)
			continue;
		ports[p].link_down_since_ms = ports[p].last_retry_ms =
			ports[p].last_fec_switch_ms = t0;
		port_link_poll(&ports[p], now);
		if (!ports[p].link_up)
			port_print_link_diag(&ports[p]);
		port_addr_poll(&ports[p], now);
	}

	/* From here on printing never blocks the loop */
	con_set_async(1);

	t_fast = t_slow = t_arp = t_link = t_addr = t_status = now;
#if LWIP_DHCP
	t_dhcp_fine = t_dhcp_coarse = now;
#endif

	while (1) {
		now = now_ms();

		for (p = 0; p < NUM_PORTS; p++)
			port_poll_fast(&ports[p]);

		if ((u32)(now - t_fast) >= TCP_FAST_MS) {
			t_fast = now;
			tcp_fasttmr();
		}
		if ((u32)(now - t_slow) >= TCP_SLOW_MS) {
			t_slow = now;
			tcp_slowtmr();
		}
		if ((u32)(now - t_arp) >= ARP_MS) {
			t_arp = now;
			etharp_tmr();
#if IP_REASSEMBLY
			ip_reass_tmr();
#endif
		}
#if LWIP_DHCP
		if ((u32)(now - t_dhcp_fine) >= DHCP_FINE_TIMER_MSECS) {
			t_dhcp_fine = now;
			dhcp_fine_tmr();
		}
		if ((u32)(now - t_dhcp_coarse) >= DHCP_COARSE_TIMER_MSECS) {
			t_dhcp_coarse = now;
			dhcp_coarse_tmr();
		}
#endif
		if ((u32)(now - t_link) >= LINK_POLL_MS) {
			t_link = now;
			for (p = 0; p < NUM_PORTS; p++)
				port_link_poll(&ports[p], now);
		}
		if ((u32)(now - t_addr) >= ADDR_POLL_MS) {
			t_addr = now;
			for (p = 0; p < NUM_PORTS; p++) {
				port_addr_poll(&ports[p], now);
				port_check(&ports[p]);
			}
		}
		lb_poll(now);
		/* phase-1 status lines (on change / heartbeat); while a loopback
		 * test runs its once-a-second table replaces them */
		if ((u32)(now - t_status) >= STATUS_PERIOD_MS) {
			t_status = now;
			if (lb_mode() == LB_OFF) {
				for (p = 0; p < NUM_PORTS; p++)
					port_print_status(&ports[p], 0, now);
			}
		}
		console_poll(now);
		con_poll();
	}

	/* not reached */
	return 0;
}

/* SPDX-License-Identifier: MIT
 *
 * app_config.h - user-configurable settings of the zircon echo_server app
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Everything a user is likely to want to change lives here: addresses, UDP
 * ports, the FEC mode and the console verbosity. Every value can also be
 * overridden from the compiler command line (-DNAME=value).
 */
#ifndef APP_CONFIG_H
#define APP_CONFIG_H

/* ---- Ports -------------------------------------------------------------------
 * NUM_PORTS (1 or 2) defaults to the number of QSFP ports in the XSA (see
 * hw_config.h); -DNUM_PORTS=1 builds a port-0-only application. */

/* ---- Addressing of the 100G ports (one lwIP netif per port, zircon raw path)
 * Every port has an address mode:
 *   IP_MODE_DHCP_THEN_STATIC (default): DHCP as soon as the link is up; if no
 *       lease arrives within DHCP_TIMEOUT_MS the port falls back to its
 *       static address below (the address-less wait is DHCP_TIMEOUT_MS).
 *   IP_MODE_STATIC: no DHCP at all. The static address is applied at start-up,
 *       before the link is even up. Use it when the port is cabled directly
 *       to a host NIC that has no DHCP server (give the host NIC an address in
 *       the same subnet, e.g. 192.168.20.1/24 for port 0).
 *   IP_MODE_DHCP: DHCP only. The client keeps retrying and the port never
 *       takes the static address (it has no address until a lease arrives).
 * IP_MODE_DEFAULT is the mode of every port at start-up; IP_MODE_DEFAULT_1
 * overrides it for port 1. The mode of a port can be changed at run time with
 * the console command "i <port> dhcp|static|auto" (auto = dhcp-then-static).
 * The older switch APP_FORCE_STATIC=1 is still accepted and means
 * IP_MODE_DEFAULT = IP_MODE_STATIC.
 * Give the two ports different subnets: lwIP picks the outgoing port of a
 * software (TCP/ICMP) reply by subnet. */
#define IP_MODE_DHCP_THEN_STATIC  0
#define IP_MODE_STATIC            1
#define IP_MODE_DHCP              2
#ifndef IP_MODE_DEFAULT
#if defined(APP_FORCE_STATIC) && APP_FORCE_STATIC
#define IP_MODE_DEFAULT    IP_MODE_STATIC
#else
#define IP_MODE_DEFAULT    IP_MODE_DHCP_THEN_STATIC
#endif
#endif
#ifndef IP_MODE_DEFAULT_1
#define IP_MODE_DEFAULT_1  IP_MODE_DEFAULT
#endif
#ifndef DHCP_TIMEOUT_MS
#define DHCP_TIMEOUT_MS    10000
#endif
/* Static addresses. The defaults match the subnets that the bench host's
 * 100G NIC serves with NetworkManager "shared" profiles (scripts/fpga_net.sh:
 * the NIC port cabled to QSFP port 0 is 192.168.20.1/24, the one cabled to
 * QSFP port 1 is 192.168.21.1/24, each with a DHCP server), so a port on its
 * static address still reaches that host at .1. On another network give each
 * port any free address on the LAN of its link partner. */
/* Port 0: 192.168.20.2/24, gateway 192.168.20.1 */
#ifndef STATIC_IP_ADDR
#define STATIC_IP_ADDR     192, 168, 20, 2
#endif
#ifndef STATIC_IP_MASK
#define STATIC_IP_MASK     255, 255, 255, 0
#endif
#ifndef STATIC_IP_GW
#define STATIC_IP_GW       192, 168, 20, 1
#endif
/* Port 1: 192.168.21.2/24, gateway 192.168.21.1 */
#ifndef STATIC_IP_ADDR_1
#define STATIC_IP_ADDR_1   192, 168, 21, 2
#endif
#ifndef STATIC_IP_MASK_1
#define STATIC_IP_MASK_1   255, 255, 255, 0
#endif
#ifndef STATIC_IP_GW_1
#define STATIC_IP_GW_1     192, 168, 21, 1
#endif

/* Local MAC address of port 0 (zircon_nic MAC_LO/MAC_HI and lwIP); port n
 * uses this address + n in the last byte (port 1: 00:0a:35:06:21:A1) */
#ifndef APP_MAC_ADDR
#define APP_MAC_ADDR       { 0x00, 0x0a, 0x35, 0x06, 0x21, 0xA0 }
#endif

/* ---- Services -------------------------------------------------------------- */
#define TCP_ECHO_PORT      7      /* software (lwIP) TCP echo                */
#define HW_ECHO_PORT       7      /* hardware UDP echo (zircon ECHO_PORT)    */
#define SOCK_LOCAL_PORT    5000   /* hardware UDP socket (zircon UI2)        */
#define HW_TTL             64     /* TTL of hardware-built IPv4 headers      */
#define CHK_UDP_PORT       5001   /* hardware checker (zircon CHK_PORT)      */
/* UDP 5002: latency statistics service (lwIP), LAT_WIRE_UDP_PORT in
 * latency_wire.h (shared with scripts/zircon_echo_test.py) */

/* ---- Latency measurement (zircon_nic 1.3.0) ----------------------------------
 * The hardware UDP echo is always measured (bank 0). With
 * LAT_RAW_TS_DESC_DEFAULT = 1 the raw path also carries RX timestamps to the
 * software, so the software TCP echo is measured too (bank 1); it costs one
 * 64-byte descriptor per raw frame. LAT_BIN_BASE_NS / LAT_BIN_WIDTH_NS: the
 * histogram (bins 0..47 linear from the base, 48..62 doubling, 63 overflow;
 * the width must be a power of two, the hardware rounds it down); the
 * default covers 0..3 us in 64 ns steps. */
#ifndef LAT_RAW_TS_DESC_DEFAULT
#define LAT_RAW_TS_DESC_DEFAULT 1
#endif
#ifndef LAT_BIN_BASE_NS
#define LAT_BIN_BASE_NS         0
#endif
#ifndef LAT_BIN_WIDTH_NS
#define LAT_BIN_WIDTH_NS        64
#endif

/* ---- Loopback test (hardware UDP generator -> cable -> hardware checker) ----
 * LOOPBACK_AUTOSTART:
 *    0 : auto-detect (default): start the cross-port test ('l') once both
 *        ports have had link for LOOPBACK_AUTOSTART_MS without either getting
 *        a DHCP lease (a port 0 <-> port 1 cable has no DHCP server on it).
 *        A port in IP_MODE_STATIC never asks for a lease, so with both ports
 *        static this is simply "both links up for LOOPBACK_AUTOSTART_MS".
 *        While a port is in IP_MODE_DHCP (no address without a DHCP server)
 *        the test is not auto-started. If the checkers then see no traffic
 *        within 3 s the auto-started test is stopped again; 'l' stops it too
 *    1 : always start it as soon as every port has link
 *   -1 : never; start it from the console
 * LOOPBACK_LEN: UDP payload bytes (8..9000). The Zircon header path handles
 * one packet per ~16-18 core cycles, so 100G line rate needs payloads of
 * about 726 bytes and up (docs/DESIGN_SPEC.md section 10.5).
 * LOOPBACK_PASS_CGBPS: pass threshold, line rate in 1/100 Gb/s per direction.
 * LOOPBACK_VERDICT_S: seconds the rate/error condition must hold. */
#ifndef LOOPBACK_AUTOSTART
#define LOOPBACK_AUTOSTART     0
#endif
#ifndef LOOPBACK_AUTOSTART_MS
#define LOOPBACK_AUTOSTART_MS  15000
#endif
#ifndef LOOPBACK_LEN
#define LOOPBACK_LEN           1472
#endif
#ifndef LOOPBACK_PASS_CGBPS
#define LOOPBACK_PASS_CGBPS    9000
#endif
#ifndef LOOPBACK_VERDICT_S
#define LOOPBACK_VERDICT_S     10
#endif

/* ---- MRMAC FEC ---------------------------------------------------------------
 * MRMAC_FEC_KEEP  : leave FEC_CONFIGURATION_REG1 as the block design set it
 * MRMAC_FEC_OFF   : no FEC (CL82 PCS only)
 * MRMAC_FEC_RS528 : clause 91 RS(528,514) "KR4" - what 100GBASE-CR4/SR4/LR4
 *                   partners (e.g. Intel E810 in FEC auto) expect
 * MRMAC_FEC_RS544 : RS(544,514) "KP4"
 * The design's MRMAC is generated with RS(528,514); writing the same value is
 * harmless. With FEC_FALLBACK_MS non-zero the app alternates between the
 * chosen mode and FEC off every FEC_FALLBACK_MS while the link stays down, so
 * a partner forced to either mode still links. The default is 0 (no
 * automatic fallback): in a port 0 <-> port 1 loopback both ports must stay
 * in RS-FEC, and a port that had fallen back to FEC off while waiting would
 * never link to the other. The FEC mode of both ports can be cycled at
 * runtime by typing 'f' on the console. */
#ifndef APP_FEC_MODE
#define APP_FEC_MODE       MRMAC_FEC_RS528
#endif
#ifndef FEC_FALLBACK_MS
#define FEC_FALLBACK_MS    0
#endif

/* While a port's link is down, its link diagnostic (RX status, block lock,
 * FEC lock, faults) is printed every LINK_DIAG_MS (0 = only once at boot). */
#ifndef LINK_DIAG_MS
#define LINK_DIAG_MS       30000
#endif

/* While the link is down the MRMAC core/serdes reset is re-issued every
 * LINK_RETRY_MS (the GT does not re-align on a partner that appears after
 * the last reset). */
#ifndef LINK_RETRY_MS
#define LINK_RETRY_MS      2000
#endif

/* ---- Console ------------------------------------------------------------------
 * The status line is printed at most once per STATUS_PERIOD_MS, and only when
 * something changed, plus a heartbeat every STATUS_HEARTBEAT_MS. The socket
 * demo prints the descriptor of the first SOCK_VERBOSE_DATAGRAMS datagrams. */
#ifndef STATUS_PERIOD_MS
#define STATUS_PERIOD_MS        1000
#endif
#ifndef STATUS_HEARTBEAT_MS
#define STATUS_HEARTBEAT_MS     30000
#endif
#ifndef SOCK_VERBOSE_DATAGRAMS
#define SOCK_VERBOSE_DATAGRAMS  8
#endif

#endif /* APP_CONFIG_H */

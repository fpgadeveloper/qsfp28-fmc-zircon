/* SPDX-License-Identifier: MIT
 *
 * sock_demo.c - hardware UDP socket demo (zircon UI2, axi_dma_sock)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * zircon_nic implements a connected UDP socket in hardware:
 *   RX: IPv4/UDP datagrams to SOCK_LOCAL_PORT (5000) addressed to the board
 *       arrive on the socket S2MM channel as a 64-byte descriptor
 *       (docs/DESIGN_SPEC.md section 5) followed by the UDP payload only.
 *   TX: whatever software writes to the socket MM2S channel is a UDP payload;
 *       the hardware builds the Ethernet/IPv4/UDP headers (and checksums) from
 *       the SOCK_REMOTE_* / local MAC / IP / SOCK_LOCAL_PORT registers.
 *
 * The demo: the first datagram's descriptor supplies the peer (source MAC,
 * IP, UDP port), which is programmed into SOCK_REMOTE_*; every datagram's
 * payload is then sent straight back through the socket TX channel, so the
 * sender receives its datagram back from <board>:5000. If a datagram arrives
 * from a different peer, the socket is re-connected to that peer (logged), so
 * repeated test runs from new ephemeral ports keep working.
 *
 * One instance per QSFP port; the UART messages carry the port number.
 */
#include <string.h>

#include "console.h"
#include "app_config.h"
#include "hw_config.h"
#include "zdma.h"
#include "zircon.h"
#include "sock_demo.h"

#define SOCK_N_RX       32
#define SOCK_N_TX       32
/* descriptor + the largest payload of a 9000-byte MTU (8972), rounded up to
 * a multiple of 64 */
#define SOCK_BUF_LEN    9088
#define SOCK_RX_BUDGET  16

static u8 rx_bufs[NUM_PORTS][SOCK_N_RX * SOCK_BUF_LEN] __attribute__((aligned(ZDMA_BUF_ALIGN)));
static u8 tx_bufs[NUM_PORTS][SOCK_N_TX * SOCK_BUF_LEN] __attribute__((aligned(ZDMA_BUF_ALIGN)));

struct sock_demo {
	int port;
	zdma_t dma;
	zircon_t *z;
	int ok;
	int peer_valid;
	u8 peer_mac[6];
	u8 peer_ip[4];
	u16 peer_port;
	sock_demo_stats_t st;
};

static sock_demo_t sdemo[NUM_PORTS];

static void print_desc(sock_demo_t *sd, const zircon_sock_desc_t *d, u32 dma_len)
{
	con_printf("Port %d: sock rx #%u len %u (dma %u) from %d.%d.%d.%d:%u "
		   "%02x:%02x:%02x:%02x:%02x:%02x to %d.%d.%d.%d:%u flags 0x%08x\r\n",
		   sd->port, sd->st.rx_datagrams, d->payload_len, dma_len,
		   d->src_ip[0], d->src_ip[1], d->src_ip[2], d->src_ip[3], d->src_port,
		   d->src_mac[0], d->src_mac[1], d->src_mac[2],
		   d->src_mac[3], d->src_mac[4], d->src_mac[5],
		   d->dst_ip[0], d->dst_ip[1], d->dst_ip[2], d->dst_ip[3], d->dst_port,
		   d->flags);
}

static void set_peer(sock_demo_t *sd, const zircon_sock_desc_t *d)
{
	int first = !sd->peer_valid;

	memcpy(sd->peer_mac, d->src_mac, 6);
	memcpy(sd->peer_ip, d->src_ip, 4);
	sd->peer_port = d->src_port;
	sd->peer_valid = 1;
	zircon_set_sock_remote(sd->z, sd->peer_mac, sd->peer_ip, sd->peer_port);
	if (!first)
		sd->st.peer_changes++;
	con_printf("Port %d: sock %s peer %d.%d.%d.%d:%u (%02x:%02x:%02x:%02x:%02x:%02x)\r\n",
		   sd->port, first ? "connected to" : "re-connected to",
		   sd->peer_ip[0], sd->peer_ip[1], sd->peer_ip[2], sd->peer_ip[3], sd->peer_port,
		   sd->peer_mac[0], sd->peer_mac[1], sd->peer_mac[2],
		   sd->peer_mac[3], sd->peer_mac[4], sd->peer_mac[5]);
}

static void rx_datagram(void *arg, u8 *data, u32 len)
{
	sock_demo_t *sd = (sock_demo_t *)arg;
	zircon_sock_desc_t d;
	u32 plen;
	u8 *tx;

	if (len < ZIRCON_SOCK_DESC_LEN || zircon_sock_desc_parse(data, &d) != 0) {
		sd->st.rx_bad_desc++;
		if (sd->st.rx_bad_desc <= 4)
			con_printf("Port %d: sock dropped a %u-byte transfer without a valid descriptor "
				   "(magic 0x%02x%02x%02x%02x)\r\n", sd->port, len,
				   len > 3 ? data[3] : 0, len > 2 ? data[2] : 0,
				   len > 1 ? data[1] : 0, len > 0 ? data[0] : 0);
		return;
	}
	sd->st.rx_datagrams++;
	plen = len - ZIRCON_SOCK_DESC_LEN;
	if (sd->st.rx_datagrams <= SOCK_VERBOSE_DATAGRAMS) {
		print_desc(sd, &d, len);
		if (sd->st.rx_datagrams == SOCK_VERBOSE_DATAGRAMS)
			con_printf("Port %d: sock (further datagrams are only counted)\r\n", sd->port);
	}
	if (d.payload_len != plen) {
		/* trust the DMA length, but count the mismatch */
		sd->st.rx_len_err++;
	}

	if (!sd->peer_valid ||
	    memcmp(sd->peer_mac, d.src_mac, 6) != 0 ||
	    memcmp(sd->peer_ip, d.src_ip, 4) != 0 ||
	    sd->peer_port != d.src_port)
		set_peer(sd, &d);

	if (plen == 0) {
		/* a zero-length DMA transfer is impossible: nothing to bounce */
		sd->st.tx_zero_len++;
		return;
	}
	tx = zdma_tx_buf(&sd->dma);
	if (tx == NULL) {
		sd->st.tx_busy++;
		return;
	}
	memcpy(tx, data + ZIRCON_SOCK_DESC_LEN, plen);
	if (zdma_tx_send(&sd->dma, plen) == 0)
		sd->st.tx_datagrams++;
}

sock_demo_t *sock_demo_init(int port, zircon_t *z, UINTPTR dma_base, const char *dma_name)
{
	sock_demo_t *sd;

	if (port < 0 || port >= NUM_PORTS)
		return NULL;
	sd = &sdemo[port];
	memset(sd, 0, sizeof(*sd));
	sd->port = port;
	sd->z = z;
	if (zdma_init(&sd->dma, dma_name, dma_base,
		      rx_bufs[port], SOCK_N_RX, SOCK_BUF_LEN,
		      tx_bufs[port], SOCK_N_TX, SOCK_BUF_LEN) != 0)
		return NULL;
	sd->ok = 1;
	return sd;
}

void sock_demo_poll(sock_demo_t *sd)
{
	if (sd == NULL || !sd->ok)
		return;
	zdma_tx_reclaim(&sd->dma);
	zdma_rx_poll(&sd->dma, rx_datagram, sd, SOCK_RX_BUDGET);
}

void sock_demo_check(sock_demo_t *sd)
{
	if (sd != NULL && sd->ok)
		zdma_check(&sd->dma);
}

void sock_demo_get_stats(const sock_demo_t *sd, sock_demo_stats_t *s)
{
	if (sd == NULL) {
		memset(s, 0, sizeof(*s));
		return;
	}
	*s = sd->st;
	s->dma_err = sd->dma.dma_err;
}

/* SPDX-License-Identifier: MIT
 *
 * zircon_netif.c - lwIP 2.2 netif over the zircon_nic raw path (UI0, axi_dma_raw)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Port of the ethernet-fmc-taxi-eth taxi_macif.c netif to the zircon design:
 * there is no PHY/MDIO (the 100G link state comes from the MRMAC and is
 * driven by the application with netif_set_link_up/down), and the AXI DMA is
 * 512 bits wide, so frames are exchanged through the zdma module's 64-byte
 * aligned private buffers instead of handing pbuf payloads to the DMA:
 *
 *   RX: S2MM buffer -> copied into a PBUF_POOL pbuf (chain) -> netif->input
 *   TX: pbuf chain -> copied into a bounce buffer (padded to 60 bytes, the
 *       MRMAC appends the FCS) -> one SOF|EOF descriptor
 *
 * One copy per frame keeps the driver independent of the DMA's DRE setting,
 * the pbuf pool geometry and pbuf chaining, and costs little next to lwIP's
 * software checksums. Everything is polled from the main loop.
 *
 * The raw path carries every frame zircon does not handle in hardware (ARP,
 * ICMP, TCP, DHCP, UDP to other ports, ...): the hardware UDP echo and the
 * hardware socket never reach lwIP.
 *
 * Timestamp descriptors (zircon_nic 1.3.0, LAT_CTRL.RAW_TS_DESC; DESIGN_SPEC
 * section 11), both 64 bytes = exactly one 512-bit beat in front of the frame:
 *
 *   RX: with zircon_netif_set_ts_desc(rx = 1) every received transfer starts
 *       with a ZRXT descriptor carrying the frame's MRMAC RX timestamp. It is
 *       stripped here; while netif->input() runs for that frame, the
 *       timestamp is available through zircon_netif_cur_rx_ts() (NO_SYS,
 *       single-threaded: lwIP's callbacks for the frame run inside input()).
 *   TX: after zircon_netif_ts_arm(rx_ts) (the TCP echo does this in its
 *       receive callback), the next TCP segment with payload that leaves
 *       through a netif with tx = 1 is sent behind a ZTXT descriptor with
 *       TS_REQ and the request's rx_ts; the hardware strips it, timestamps the
 *       frame on TX and adds tx_ts - rx_ts to latency bank 1. Then the arm is
 *       dropped. Every other frame is sent without a descriptor.
 */
#include <string.h>

#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "lwip/netif.h"
#include "lwip/ip4_addr.h"
#include "lwip/snmp.h"
#include "lwip/etharp.h"
#include "netif/ethernet.h"

#include "hw_config.h"
#include "zdma.h"
#include "zircon.h"
#include "zircon_netif.h"

#if (LWIP_IPV6)
#error "zircon_netif: IPv4 only"
#endif

#define ZNETIF_N_RX        64
#define ZNETIF_N_TX        64
#define ZNETIF_BUF_LEN     2048     /* >= 64 (descriptor) + 1514 + VLAN tag,
				       multiple of 64                     */
#define ZNETIF_MIN_FRAME   60       /* without FCS                        */
#define ZNETIF_RX_BUDGET   32       /* frames per poll                    */
#define ZNETIF_IFNAME0     'z'
#define ZNETIF_IFNAME1     'n'

#define ZNETIF_MAX_INSTANCES NUM_PORTS

static u8 rx_bufs[ZNETIF_MAX_INSTANCES][ZNETIF_N_RX * ZNETIF_BUF_LEN]
	__attribute__((aligned(ZDMA_BUF_ALIGN)));
static u8 tx_bufs[ZNETIF_MAX_INSTANCES][ZNETIF_N_TX * ZNETIF_BUF_LEN]
	__attribute__((aligned(ZDMA_BUF_ALIGN)));

typedef struct {
	zdma_t dma;
	struct netif *netif;
	const zircon_netif_config *cfg;
	u32 rx_input_err, rx_nobuf, tx_queued;
	int rx_desc, tx_desc;          /* timestamp descriptors in use     */
	u32 rx_ts_frames, rx_ts_missing, rx_ts_len_err, tx_ts_req;
} zircon_netif_t;

static zircon_netif_t znetif[ZNETIF_MAX_INSTANCES];

/* RX timestamp of the frame being delivered right now (valid only inside
 * netif->input()), and the rx_ts armed for the next TCP payload segment */
static struct { int valid; u64 ts; } cur_rx;
static struct { int armed; u64 ts; } tx_arm;

static inline u16 get_le16(const u8 *p) { return (u16)(p[0] | (p[1] << 8)); }
static inline u32 get_le32(const u8 *p)
{
	return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24);
}
static inline u64 get_le64(const u8 *p) { return get_le32(p) | ((u64)get_le32(p + 4) << 32); }
static inline void put_le32(u8 *p, u32 v)
{
	p[0] = (u8)v;
	p[1] = (u8)(v >> 8);
	p[2] = (u8)(v >> 16);
	p[3] = (u8)(v >> 24);
}
static inline void put_le64(u8 *p, u64 v)
{
	put_le32(p, (u32)v);
	put_le32(p + 4, (u32)(v >> 32));
}

/* 1 if the Ethernet frame is an IPv4 TCP segment carrying payload */
static int is_tcp_with_payload(const u8 *f, u32 len)
{
	const u8 *ip = f + 14;
	u32 ihl, tot, doff;

	if (len < 14 + 20 + 20 || f[12] != 0x08 || f[13] != 0x00)
		return 0;
	if ((ip[0] >> 4) != 4 || ip[9] != 6)      /* IP_PROTO_TCP */
		return 0;
	ihl = (ip[0] & 0x0F) * 4u;
	tot = ((u32)ip[2] << 8) | ip[3];
	if (ihl < 20 || len < 14 + ihl + 20)
		return 0;
	doff = (ip[ihl + 12] >> 4) * 4u;
	return tot > ihl + doff;
}

static inline zircon_netif_t *zn_of(struct netif *netif)
{
	return (zircon_netif_t *)netif->state;
}

static err_t low_level_output(struct netif *netif, struct pbuf *p)
{
	zircon_netif_t *z = zn_of(netif);
	u8 *buf, *frame;
	u32 len = p->tot_len;
	u32 off = 0;

	if (len + ZIRCON_RAW_DESC_LEN > ZNETIF_BUF_LEN) {
		LINK_STATS_INC(link.lenerr);
		return ERR_BUF;
	}
	buf = zdma_tx_buf(&z->dma);
	if (buf == NULL) {
		LINK_STATS_INC(link.memerr);
		return ERR_MEM;
	}
	frame = buf;
	if (tx_arm.armed && z->tx_desc) {
		/* armed: only the first TCP segment with payload gets a
		 * descriptor (not an ARP request or a pure ACK sent first) */
		frame = buf + ZIRCON_RAW_DESC_LEN;
		pbuf_copy_partial(p, frame, (u16_t)len, 0);
		if (is_tcp_with_payload(frame, len)) {
			memset(buf, 0, ZIRCON_RAW_DESC_LEN);
			put_le32(buf + ZIRCON_TX_DESC_OFF_MAGIC, ZIRCON_TX_TS_MAGIC);
			buf[ZIRCON_TX_DESC_OFF_FLAGS] = ZIRCON_TX_DESC_TS_REQ;
			put_le64(buf + ZIRCON_TX_DESC_OFF_TS, tx_arm.ts);
			tx_arm.armed = 0;
			z->tx_ts_req++;
			off = ZIRCON_RAW_DESC_LEN;
		} else {
			memmove(buf, frame, len);
			frame = buf;
		}
	} else {
		pbuf_copy_partial(p, frame, (u16_t)len, 0);
	}
	if (len < ZNETIF_MIN_FRAME) {
		memset(frame + len, 0, ZNETIF_MIN_FRAME - len);
		len = ZNETIF_MIN_FRAME;
	}
	if (zdma_tx_send(&z->dma, off + len) != 0) {
		LINK_STATS_INC(link.err);
		return ERR_IF;
	}
	z->tx_queued++;
	MIB2_STATS_NETIF_ADD(netif, ifoutoctets, p->tot_len);
	LINK_STATS_INC(link.xmit);
	return ERR_OK;
}

static void rx_frame(void *arg, u8 *data, u32 len)
{
	zircon_netif_t *z = (zircon_netif_t *)arg;
	struct netif *netif = z->netif;
	struct pbuf *p;

	cur_rx.valid = 0;
	if (z->rx_desc) {
		if (len >= ZIRCON_RAW_DESC_LEN &&
		    get_le32(data + ZIRCON_RX_DESC_OFF_MAGIC) == ZIRCON_RX_TS_MAGIC) {
			u32 flen = get_le16(data + ZIRCON_RX_DESC_OFF_LEN);

			cur_rx.ts = get_le64(data + ZIRCON_RX_DESC_OFF_TS) & ZIRCON_TS_MASK;
			cur_rx.valid = 1;
			data += ZIRCON_RAW_DESC_LEN;
			len -= ZIRCON_RAW_DESC_LEN;
			if (flen != len) {
				z->rx_ts_len_err++;
				if (flen && flen < len)
					len = flen;
			}
			z->rx_ts_frames++;
		} else {
			/* e.g. a frame queued before RAW_TS_DESC was set */
			z->rx_ts_missing++;
		}
		if (len == 0)
			return;
	}

	p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
	if (p == NULL) {
		cur_rx.valid = 0;
		z->rx_nobuf++;
		LINK_STATS_INC(link.memerr);
		LINK_STATS_INC(link.drop);
		return;
	}
	pbuf_take(p, data, (u16_t)len);
	MIB2_STATS_NETIF_ADD(netif, ifinoctets, len);
	LINK_STATS_INC(link.recv);
	if (netif->input(p, netif) != ERR_OK) {
		LINK_STATS_INC(link.drop);
		z->rx_input_err++;
		pbuf_free(p);
	}
	cur_rx.valid = 0;
	/* netif->input() includes lwIP's deferred tcp_output() of the segment's
	 * pcb, i.e. the echo the TCP echo armed a timestamp for: an arm that was
	 * not consumed by now belongs to no frame */
	tx_arm.armed = 0;
}

void zircon_netif_set_ts_desc(struct netif *netif, int rx, int tx)
{
	zircon_netif_t *z = zn_of(netif);

	z->rx_desc = rx;
	z->tx_desc = tx;
}

int zircon_netif_cur_rx_ts(u64 *ts)
{
	if (!cur_rx.valid)
		return 0;
	*ts = cur_rx.ts;
	return 1;
}

void zircon_netif_ts_arm(u64 rx_ts)
{
	tx_arm.ts = rx_ts;
	tx_arm.armed = 1;
}

void zircon_netif_ts_disarm(void)
{
	tx_arm.armed = 0;
}

int zircon_netif_poll(struct netif *netif)
{
	zircon_netif_t *z = zn_of(netif);

	zdma_tx_reclaim(&z->dma);
	return zdma_rx_poll(&z->dma, rx_frame, z, ZNETIF_RX_BUDGET);
}

void zircon_netif_check(struct netif *netif)
{
	zdma_check(&zn_of(netif)->dma);
}

void zircon_netif_get_stats(struct netif *netif, zircon_netif_stats *s)
{
	zircon_netif_t *z = zn_of(netif);

	s->rx_frames = z->dma.rx_frames;
	s->rx_input_err = z->rx_input_err;
	s->rx_nobuf = z->rx_nobuf;
	s->rx_err = z->dma.rx_err;
	s->rx_split = z->dma.rx_split;
	s->tx_queued = z->tx_queued;
	s->tx_done = z->dma.tx_frames;
	s->tx_busy = z->dma.tx_busy;
	s->dma_err = z->dma.dma_err;
	s->rx_ts_frames = z->rx_ts_frames;
	s->rx_ts_missing = z->rx_ts_missing;
	s->rx_ts_len_err = z->rx_ts_len_err;
	s->tx_ts_req = z->tx_ts_req;
}

err_t zircon_netif_init(struct netif *netif)
{
	const zircon_netif_config *cfg = (const zircon_netif_config *)netif->state;
	zircon_netif_t *z;

	LWIP_ASSERT("zircon_netif_init: config", cfg != NULL);
	if (cfg->index < 0 || cfg->index >= ZNETIF_MAX_INSTANCES)
		return ERR_ARG;
	z = &znetif[cfg->index];
	memset(z, 0, sizeof(*z));
	z->cfg = cfg;
	z->netif = netif;
	netif->state = z;

	if (zdma_init(&z->dma, cfg->dma_name ? cfg->dma_name : "axi_dma_raw", cfg->dma_base,
		      rx_bufs[cfg->index], ZNETIF_N_RX, ZNETIF_BUF_LEN,
		      tx_bufs[cfg->index], ZNETIF_N_TX, ZNETIF_BUF_LEN) != 0)
		return ERR_IF;

	netif->name[0] = ZNETIF_IFNAME0;
	netif->name[1] = ZNETIF_IFNAME1;
	netif->output = etharp_output;
	netif->linkoutput = low_level_output;
	netif->hwaddr_len = ETHARP_HWADDR_LEN;
	memcpy(netif->hwaddr, cfg->hwaddr, ETHARP_HWADDR_LEN);
	netif->mtu = 1500;
	netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
	/* ifSpeed is a u32 in MIB-II: saturate (100 Gb/s does not fit) */
	MIB2_INIT_NETIF(netif, snmp_ifType_ethernet_csmacd, 0xFFFFFFFFUL);
	/* link state is driven by the application from the MRMAC status */
	return ERR_OK;
}

/* lwIP LWIP_HOOK_IP4_ROUTE_SRC (see EmbeddedSw/.../lwipopts.h.in): send a
 * packet out of the port that owns its source address, so that two ports in
 * the same subnet each answer on their own link. NULL = normal routing. */
struct netif *zircon_ip4_route_src(const ip4_addr_t *src, const ip4_addr_t *dest)
{
	struct netif *n;

	(void)dest;
	if (src == NULL || ip4_addr_isany(src))
		return NULL;
	NETIF_FOREACH(n) {
		if (netif_is_up(n) && netif_is_link_up(n) &&
		    ip4_addr_get_u32(netif_ip4_addr(n)) == ip4_addr_get_u32(src))
			return n;
	}
	return NULL;
}

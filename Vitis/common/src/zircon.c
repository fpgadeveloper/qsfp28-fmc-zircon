/* SPDX-License-Identifier: MIT
 *
 * zircon.c - zircon_nic register access (docs/DESIGN_SPEC.md sections 3.3, 10, 11)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Byte order conventions of the register file:
 *   MAC_LO  = mac[0] | mac[1] << 8 | mac[2] << 16 | mac[3] << 24
 *             (byte 0 = first byte on the wire in bits 7:0)
 *   MAC_HI  = mac[4] | mac[5] << 8
 *   IPV4    = ip[0] << 24 | ip[1] << 16 | ip[2] << 8 | ip[3]
 *             (192.168.20.2 = 0xC0A81402)
 *   ports   = host-order u16 in bits 15:0
 */
#include <string.h>
#include "xil_io.h"
#include "console.h"
#include "zircon.h"

static inline u32 zrd(const zircon_t *z, u32 off)   { return Xil_In32(z->base + off); }
static inline void zwr(zircon_t *z, u32 off, u32 v) { Xil_Out32(z->base + off, v); }

static u32 mac_lo(const u8 *m) { return m[0] | (m[1] << 8) | (m[2] << 16) | ((u32)m[3] << 24); }
static u32 mac_hi(const u8 *m) { return m[4] | (m[5] << 8); }
static u32 ip_u32(const u8 *ip) { return ((u32)ip[0] << 24) | (ip[1] << 16) | (ip[2] << 8) | ip[3]; }

/* 64-bit counters: reading _LO latches _HI from the same snapshot, so read
 * LO first, then HI (DESIGN_SPEC 3.3) */
static u64 zrd64(const zircon_t *z, u32 lo_off)
{
	u32 lo = zrd(z, lo_off);
	u32 hi = zrd(z, lo_off + 4);

	return ((u64)hi << 32) | lo;
}

int zircon_init(zircon_t *z, UINTPTR base)
{
	u32 id;

	z->base = base;
	z->ctrl = 0;
	z->lat_ctrl = 0;
	id = zrd(z, ZIRCON_REG_ID);
	if (id != ZIRCON_ID_VALUE) {
		con_printf("zircon: bad ID 0x%08x at 0x%08lx (want 0x%08x)\r\n",
			   id, (unsigned long)base, ZIRCON_ID_VALUE);
		return -1;
	}
	zwr(z, ZIRCON_REG_CTRL, 0);
	if (zircon_has_lat(z))
		zwr(z, ZIRCON_REG_LAT_CTRL, 0);
	zwr(z, ZIRCON_REG_STATUS, 0xFFFFFFFF);
	zircon_clear_stats(z);
	return 0;
}

u32 zircon_version(const zircon_t *z)
{
	return zrd(z, ZIRCON_REG_VERSION);
}

void zircon_set_mac(zircon_t *z, const u8 mac[6])
{
	zwr(z, ZIRCON_REG_MAC_LO, mac_lo(mac));
	zwr(z, ZIRCON_REG_MAC_HI, mac_hi(mac));
}

void zircon_set_ipv4(zircon_t *z, const u8 *ip)
{
	zwr(z, ZIRCON_REG_IPV4, ip ? ip_u32(ip) : 0);
}

void zircon_set_echo_port(zircon_t *z, u16 port)
{
	zwr(z, ZIRCON_REG_ECHO_PORT, port);
}

void zircon_set_sock_local_port(zircon_t *z, u16 port)
{
	zwr(z, ZIRCON_REG_SOCK_LOCAL_PORT, port);
}

void zircon_set_sock_remote(zircon_t *z, const u8 mac[6], const u8 ip[4], u16 port)
{
	zwr(z, ZIRCON_REG_SOCK_REMOTE_MAC_LO, mac_lo(mac));
	zwr(z, ZIRCON_REG_SOCK_REMOTE_MAC_HI, mac_hi(mac));
	zwr(z, ZIRCON_REG_SOCK_REMOTE_IP, ip_u32(ip));
	zwr(z, ZIRCON_REG_SOCK_REMOTE_PORT, port);
}

void zircon_set_ttl(zircon_t *z, u8 ttl)
{
	zwr(z, ZIRCON_REG_TTL, ttl);
}

void zircon_set_ctrl(zircon_t *z, u32 ctrl)
{
	z->ctrl = ctrl & ~ZIRCON_CTRL_STAT_CLR;
	zwr(z, ZIRCON_REG_CTRL, z->ctrl);
}

u32 zircon_get_ctrl(const zircon_t *z)
{
	return zrd(z, ZIRCON_REG_CTRL);
}

void zircon_clear_stats(zircon_t *z)
{
	/* STAT_CLR self-clears; keep the enables as they are */
	zwr(z, ZIRCON_REG_CTRL, z->ctrl | ZIRCON_CTRL_STAT_CLR);
}

void zircon_clear_status(zircon_t *z, u32 bits)
{
	zwr(z, ZIRCON_REG_STATUS, bits);
}

void zircon_read_counters(const zircon_t *z, zircon_counters_t *c)
{
	c->rx_frames = zrd(z, ZIRCON_REG_RX_FRAMES);
	c->rx_bad_frame = zrd(z, ZIRCON_REG_RX_BAD_FRAME);
	c->rx_fifo_drop = zrd(z, ZIRCON_REG_RX_FIFO_DROP);
	c->rx_l3_bad_csum = zrd(z, ZIRCON_REG_RX_L3_BAD_CSUM);
	c->rx_l4_bad_csum = zrd(z, ZIRCON_REG_RX_L4_BAD_CSUM);
	c->rx_raw = zrd(z, ZIRCON_REG_RX_RAW);
	c->rx_echo = zrd(z, ZIRCON_REG_RX_ECHO);
	c->rx_sock = zrd(z, ZIRCON_REG_RX_SOCK);
	c->tx_frames = zrd(z, ZIRCON_REG_TX_FRAMES);
	c->tx_raw = zrd(z, ZIRCON_REG_TX_RAW);
	c->tx_echo = zrd(z, ZIRCON_REG_TX_ECHO);
	c->tx_sock = zrd(z, ZIRCON_REG_TX_SOCK);
	c->status = zrd(z, ZIRCON_REG_STATUS);
	/* 1.1.0 drop counters; a 1.0.x core returns 0 for undefined offsets */
	c->rx_raw_drop = zrd(z, ZIRCON_REG_RX_RAW_DROP);
	c->rx_sock_drop = zrd(z, ZIRCON_REG_RX_SOCK_DROP);
	c->rx_echo_drop = zrd(z, ZIRCON_REG_RX_ECHO_DROP);
	c->tx_oversize_drop = zrd(z, ZIRCON_REG_TX_OVERSIZE_DROP);

	c->rx_bytes = zrd64(z, ZIRCON_REG_RX_BYTES_LO);
	c->tx_bytes = zrd64(z, ZIRCON_REG_TX_BYTES_LO);
}

/* ---- 1.2.0 generator / checker / rate meters ------------------------------ */
int zircon_has_gen(const zircon_t *z)
{
	/* GEN_LEN resets to 1472 and reads the written value; a GEN_EN = 0 (or
	 * pre-1.2.0) core reads 0 there */
	return zrd(z, ZIRCON_REG_GEN_LEN) != 0;
}

void zircon_gen_config(zircon_t *z, const u8 dst_mac[6], const u8 dst_ip[4],
		       u16 dst_port, u16 src_port, u32 len, u32 gap)
{
	zwr(z, ZIRCON_REG_GEN_DST_MAC_LO, mac_lo(dst_mac));
	zwr(z, ZIRCON_REG_GEN_DST_MAC_HI, mac_hi(dst_mac));
	zwr(z, ZIRCON_REG_GEN_DST_IP, ip_u32(dst_ip));
	zwr(z, ZIRCON_REG_GEN_DST_PORT, dst_port);
	zwr(z, ZIRCON_REG_GEN_SRC_PORT, src_port);
	zwr(z, ZIRCON_REG_GEN_LEN, len);
	zwr(z, ZIRCON_REG_GEN_GAP, gap);
}

void zircon_gen_start(zircon_t *z, int continuous, u32 count)
{
	u32 mode = continuous ? ZIRCON_GEN_CONT : 0;

	zwr(z, ZIRCON_REG_GEN_COUNT, count);
	/* a run starts on a 0->1 edge of EN; CONT/COUNT are sampled then */
	zwr(z, ZIRCON_REG_GEN_CTRL, mode);
	zwr(z, ZIRCON_REG_GEN_CTRL, mode | ZIRCON_GEN_EN);
}

int zircon_gen_stop(zircon_t *z)
{
	int i;

	zwr(z, ZIRCON_REG_GEN_CTRL, 0);
	/* the datagram in flight completes: at most 9000 B = 141 core cycles
	 * plus the TX path; poll a little */
	for (i = 0; i < 1000; i++) {
		if (!(zrd(z, ZIRCON_REG_GEN_CTRL) & ZIRCON_GEN_BUSY))
			return 0;
	}
	return -1;
}

void zircon_gen_clear(zircon_t *z)
{
	zwr(z, ZIRCON_REG_GEN_CTRL, ZIRCON_GEN_CLR);
	zwr(z, ZIRCON_REG_GEN_CTRL, 0);
}

void zircon_chk_config(zircon_t *z, u16 port)
{
	zwr(z, ZIRCON_REG_CHK_PORT, port);
}

void zircon_chk_enable(zircon_t *z, int en)
{
	zwr(z, ZIRCON_REG_CHK_CTRL, en ? ZIRCON_CHK_EN : 0);
}

void zircon_chk_clear(zircon_t *z)
{
	u32 en = zrd(z, ZIRCON_REG_CHK_CTRL) & ZIRCON_CHK_EN;

	zwr(z, ZIRCON_REG_CHK_CTRL, en | ZIRCON_CHK_CLR);
}

void zircon_genchk_read(const zircon_t *z, zircon_genchk_t *g)
{
	g->gen_ctrl = zrd(z, ZIRCON_REG_GEN_CTRL);
	g->chk_ctrl = zrd(z, ZIRCON_REG_CHK_CTRL);
	g->gen_tx_pkts = zrd(z, ZIRCON_REG_GEN_TX_PKTS);
	g->gen_tx_bytes = zrd64(z, ZIRCON_REG_GEN_TX_BYTES_LO);
	g->chk_rx_pkts = zrd(z, ZIRCON_REG_CHK_RX_PKTS);
	g->chk_rx_bytes = zrd64(z, ZIRCON_REG_CHK_RX_BYTES_LO);
	g->chk_seq_err = zrd(z, ZIRCON_REG_CHK_SEQ_ERR);
	g->chk_bit_err = zrd64(z, ZIRCON_REG_CHK_BIT_ERR_LO);
	g->chk_len_err = zrd(z, ZIRCON_REG_CHK_LEN_ERR);
}

int zircon_rate_read(const zircon_t *z, u32 *last_seq, zircon_rate_t *r)
{
	u32 seq = zrd(z, ZIRCON_REG_RATE_SEQ);    /* latches the window */

	if (seq == *last_seq)
		return 0;
	*last_seq = seq;
	r->seq = seq;
	r->rx_bytes = ((u64)zrd(z, ZIRCON_REG_RX_RATE_BYTES_HI) << 32) |
		      zrd(z, ZIRCON_REG_RX_RATE_BYTES_LO);
	r->rx_pkts = zrd(z, ZIRCON_REG_RX_RATE_PKTS);
	r->tx_bytes = ((u64)zrd(z, ZIRCON_REG_TX_RATE_BYTES_HI) << 32) |
		      zrd(z, ZIRCON_REG_TX_RATE_BYTES_LO);
	r->tx_pkts = zrd(z, ZIRCON_REG_TX_RATE_PKTS);
	return 1;
}

void zircon_dump(const zircon_t *z)
{
	zircon_counters_t c;
	u32 ip = zrd(z, ZIRCON_REG_IPV4);
	u32 mlo = zrd(z, ZIRCON_REG_MAC_LO), mhi = zrd(z, ZIRCON_REG_MAC_HI);
	u32 rip = zrd(z, ZIRCON_REG_SOCK_REMOTE_IP);
	u32 rlo = zrd(z, ZIRCON_REG_SOCK_REMOTE_MAC_LO), rhi = zrd(z, ZIRCON_REG_SOCK_REMOTE_MAC_HI);

	zircon_read_counters(z, &c);
	con_printf("zircon: ID 0x%08x VERSION 0x%08x CTRL 0x%08x STATUS 0x%08x TTL %d\r\n",
		   zrd(z, ZIRCON_REG_ID), zrd(z, ZIRCON_REG_VERSION),
		   zrd(z, ZIRCON_REG_CTRL), c.status, zrd(z, ZIRCON_REG_TTL));
	con_printf("zircon: MAC %02x:%02x:%02x:%02x:%02x:%02x IP %d.%d.%d.%d echo port %d\r\n",
		   mlo & 0xFF, (mlo >> 8) & 0xFF, (mlo >> 16) & 0xFF, mlo >> 24,
		   mhi & 0xFF, (mhi >> 8) & 0xFF,
		   ip >> 24, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF,
		   zrd(z, ZIRCON_REG_ECHO_PORT));
	con_printf("zircon: sock local %d remote %d.%d.%d.%d:%d %02x:%02x:%02x:%02x:%02x:%02x\r\n",
		   zrd(z, ZIRCON_REG_SOCK_LOCAL_PORT),
		   rip >> 24, (rip >> 16) & 0xFF, (rip >> 8) & 0xFF, rip & 0xFF,
		   zrd(z, ZIRCON_REG_SOCK_REMOTE_PORT),
		   rlo & 0xFF, (rlo >> 8) & 0xFF, (rlo >> 16) & 0xFF, rlo >> 24,
		   rhi & 0xFF, (rhi >> 8) & 0xFF);
	con_printf("zircon: rx frames %u bytes %llu | bad %u fifo drop %u l3 csum %u l4 csum %u"
		   " | raw %u echo %u sock %u\r\n",
		   c.rx_frames, (unsigned long long)c.rx_bytes, c.rx_bad_frame, c.rx_fifo_drop,
		   c.rx_l3_bad_csum, c.rx_l4_bad_csum, c.rx_raw, c.rx_echo, c.rx_sock);
	con_printf("zircon: tx frames %u bytes %llu | raw %u echo %u sock %u\r\n",
		   c.tx_frames, (unsigned long long)c.tx_bytes, c.tx_raw, c.tx_echo, c.tx_sock);
	con_printf("zircon: drops raw %u sock %u echo %u tx oversize %u | status 0x%02x%s%s%s%s%s%s\r\n",
		   c.rx_raw_drop, c.rx_sock_drop, c.rx_echo_drop, c.tx_oversize_drop,
		   c.status, (c.status & 0x3F) ? "" : " (clear)",
		   (c.status & ZIRCON_STATUS_RX_FIFO_OVF) ? " RX_FIFO_OVF" : "",
		   (c.status & ZIRCON_STATUS_RX_META_ERR) ? " RX_META_ERR" : "",
		   (c.status & ZIRCON_STATUS_TX_META_ERR) ? " TX_META_ERR" : "",
		   (c.status & ZIRCON_STATUS_RX_PACK_STALL) ? " RX_PACK_STALL" : "",
		   (c.status & ZIRCON_STATUS_RX_PACK_OVF) ? " RX_PACK_OVF" : "");
	if (zircon_has_gen(z)) {
		zircon_genchk_t g;
		u32 dlo = zrd(z, ZIRCON_REG_GEN_DST_MAC_LO), dhi = zrd(z, ZIRCON_REG_GEN_DST_MAC_HI);
		u32 dip = zrd(z, ZIRCON_REG_GEN_DST_IP);

		zircon_genchk_read(z, &g);
		con_printf("zircon: gen ctrl 0x%08x len %u gap %u -> %02x:%02x:%02x:%02x:%02x:%02x"
			   " %u.%u.%u.%u:%u from port %u | tx %u pkts %llu bytes\r\n",
			   (unsigned)g.gen_ctrl, (unsigned)zrd(z, ZIRCON_REG_GEN_LEN),
			   (unsigned)zrd(z, ZIRCON_REG_GEN_GAP),
			   (unsigned)(dlo & 0xFF), (unsigned)((dlo >> 8) & 0xFF),
			   (unsigned)((dlo >> 16) & 0xFF), (unsigned)(dlo >> 24),
			   (unsigned)(dhi & 0xFF), (unsigned)((dhi >> 8) & 0xFF),
			   (unsigned)(dip >> 24), (unsigned)((dip >> 16) & 0xFF),
			   (unsigned)((dip >> 8) & 0xFF), (unsigned)(dip & 0xFF),
			   (unsigned)zrd(z, ZIRCON_REG_GEN_DST_PORT),
			   (unsigned)zrd(z, ZIRCON_REG_GEN_SRC_PORT),
			   (unsigned)g.gen_tx_pkts, (unsigned long long)g.gen_tx_bytes);
		con_printf("zircon: chk ctrl 0x%08x port %u | rx %u pkts %llu bytes | seq err %u"
			   " bit err %llu len err %u\r\n",
			   (unsigned)g.chk_ctrl, (unsigned)zrd(z, ZIRCON_REG_CHK_PORT),
			   (unsigned)g.chk_rx_pkts, (unsigned long long)g.chk_rx_bytes,
			   (unsigned)g.chk_seq_err, (unsigned long long)g.chk_bit_err,
			   (unsigned)g.chk_len_err);
	} else {
		con_printf("zircon: no generator/checker in this core (VERSION < 1.2.0 or GEN_EN = 0)\r\n");
	}
	if (zircon_has_lat(z))
		con_printf("zircon: latency LAT_CTRL 0x%08x LAT_STATUS 0x%08x bins base %u ns width %u ns"
			   " stale %u lost %u ovf %u (T prints the statistics)\r\n",
			   (unsigned)zrd(z, ZIRCON_REG_LAT_CTRL), (unsigned)zrd(z, ZIRCON_REG_LAT_STATUS),
			   (unsigned)zrd(z, ZIRCON_REG_LAT_BIN_BASE),
			   (unsigned)zrd(z, ZIRCON_REG_LAT_BIN_WIDTH),
			   (unsigned)zrd(z, ZIRCON_REG_LAT_STALE_CNT),
			   (unsigned)zrd(z, ZIRCON_REG_LAT_LOST_CNT),
			   (unsigned)zrd(z, ZIRCON_REG_LAT_OVF_CNT));
	else
		con_printf("zircon: no latency measurement in this core (VERSION < 1.3.0)\r\n");
}

/* ---- 1.3.0 latency measurement -------------------------------------------- */
int zircon_has_lat(const zircon_t *z)
{
	u32 v = zircon_version(z);

	return ZIRCON_VER_MAJOR(v) == 1 && v >= ZIRCON_VERSION_1_3_0;
}

void zircon_lat_set_ctrl(zircon_t *z, u32 enables)
{
	z->lat_ctrl = enables & (ZIRCON_LAT_EN | ZIRCON_LAT_RAW_TS_DESC | ZIRCON_LAT_RAW_TX_DESC);
	zwr(z, ZIRCON_REG_LAT_CTRL, z->lat_ctrl);
}

u32 zircon_lat_get_ctrl(const zircon_t *z)
{
	return zrd(z, ZIRCON_REG_LAT_CTRL);
}

u32 zircon_lat_status(const zircon_t *z)
{
	return zrd(z, ZIRCON_REG_LAT_STATUS);
}

void zircon_lat_clear_status(zircon_t *z, u32 bits)
{
	zwr(z, ZIRCON_REG_LAT_STATUS, bits);
}

/* Wait for LAT_CTRL.BUSY to clear (a command takes a few hundred core
 * cycles: a 64-bin sweep per cleared bank, ~300 cycles for a snapshot) */
static int lat_wait(const zircon_t *z)
{
	int i;

	for (i = 0; i < 10000; i++) {
		if (!(zrd(z, ZIRCON_REG_LAT_CTRL) & ZIRCON_LAT_BUSY))
			return 0;
	}
	return -1;
}

int zircon_lat_clear(zircon_t *z, u32 bank_mask)
{
	u32 clr = ((bank_mask & 1) ? ZIRCON_LAT_CLR0 : 0) | ((bank_mask & 2) ? ZIRCON_LAT_CLR1 : 0);

	/* one command at a time; the CLR bits are self-clearing, the enables stay */
	lat_wait(z);
	zwr(z, ZIRCON_REG_LAT_CTRL, z->lat_ctrl | clr);
	return lat_wait(z);
}

void zircon_lat_read_err(const zircon_t *z, zircon_lat_err_t *e)
{
	e->stale = zrd(z, ZIRCON_REG_LAT_STALE_CNT);
	e->lost = zrd(z, ZIRCON_REG_LAT_LOST_CNT);
	e->ovf = zrd(z, ZIRCON_REG_LAT_OVF_CNT);
}

void zircon_lat_set_bins(zircon_t *z, u32 base_ns, u32 width_ns)
{
	zwr(z, ZIRCON_REG_LAT_BIN_BASE, base_ns);
	zwr(z, ZIRCON_REG_LAT_BIN_WIDTH, width_ns);
}

void zircon_lat_get_bins(const zircon_t *z, u32 *base_ns, u32 *width_ns)
{
	*base_ns = zrd(z, ZIRCON_REG_LAT_BIN_BASE);
	*width_ns = zrd(z, ZIRCON_REG_LAT_BIN_WIDTH);
}

int zircon_lat_snapshot(zircon_t *z)
{
	/* the shadow copy may only be read once BUSY has cleared */
	lat_wait(z);
	zwr(z, ZIRCON_REG_LAT_CTRL, z->lat_ctrl | ZIRCON_LAT_SNAP);
	return lat_wait(z);
}

void zircon_lat_read(const zircon_t *z, int bank, zircon_lat_bank_t *b, int with_bins)
{
	u32 base = ZIRCON_LAT_BANK(bank);
	int i;

	b->count = zrd64(z, base + ZIRCON_LAT_COUNT_LO);
	b->sum_ns = zrd64(z, base + ZIRCON_LAT_SUM_LO);
	b->sumsq_ns2 = zrd64(z, base + ZIRCON_LAT_SUMSQ_LO);
	b->min_ns = zrd(z, base + ZIRCON_LAT_MIN);
	b->max_ns = zrd(z, base + ZIRCON_LAT_MAX);
	b->implausible = zrd(z, base + ZIRCON_LAT_IMPLAUSIBLE);
	b->last_ns = zrd(z, base + ZIRCON_LAT_LAST_DELTA);
	b->bin_base_ns = zrd(z, base + ZIRCON_LAT_SNAP_BIN_BASE);
	b->bin_width_ns = zrd(z, base + ZIRCON_LAT_SNAP_BIN_WIDTH);
	if (!with_bins) {
		memset(b->bins, 0, sizeof(b->bins));
		return;
	}
	for (i = 0; i < ZIRCON_LAT_NBINS; i++)
		b->bins[i] = zrd64(z, ZIRCON_LAT_HIST(bank, i));
}

/* Bin geometry: x = delta - base, W = width.
 *   bins 0..47   linear, [i*W, (i+1)*W)        (bin 0 also takes x < 0)
 *   bins 48..62  octaves, [48W*2^(i-48), 48W*2^(i-47))
 *   bin 63       overflow, x >= 48W*2^15 */
u64 zircon_lat_bin_lo(int i, u32 base_ns, u32 width_ns)
{
	u64 w = width_ns;

	if (i <= 0)
		return 0;
	if (i < ZIRCON_LAT_NLINEAR)
		return base_ns + (u64)i * w;
	if (i >= ZIRCON_LAT_NBINS)
		i = ZIRCON_LAT_NBINS - 1;
	return base_ns + ((u64)ZIRCON_LAT_NLINEAR * w << (i - ZIRCON_LAT_NLINEAR));
}

static u16 le16(const u8 *p) { return p[0] | (p[1] << 8); }
static u32 le32(const u8 *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24); }

int zircon_sock_desc_parse(const u8 *b, zircon_sock_desc_t *d)
{
	d->magic = le32(b + 0);
	d->payload_len = le16(b + 4);
	d->src_port = le16(b + 6);
	memcpy(d->src_ip, b + 8, 4);
	memcpy(d->src_mac, b + 12, 6);
	d->dst_port = le16(b + 18);
	memcpy(d->dst_ip, b + 20, 4);
	d->flags = le32(b + 24);
	return d->magic == ZIRCON_SOCK_DESC_MAGIC ? 0 : -1;
}

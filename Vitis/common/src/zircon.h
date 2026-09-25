/* SPDX-License-Identifier: MIT
 *
 * zircon.h - zircon_nic register access (docs/DESIGN_SPEC.md sections 3.3, 10, 11)
 *
 * The ONE place the application learns the zircon_nic register offsets.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef ZIRCON_H
#define ZIRCON_H

#include "xil_types.h"

/* Register offsets (AXI-Lite, 32-bit little-endian) */
#define ZIRCON_REG_ID               0x000
#define ZIRCON_REG_VERSION          0x004
#define ZIRCON_REG_CTRL             0x008
#define ZIRCON_REG_STATUS           0x00C
#define ZIRCON_REG_MAC_LO           0x010
#define ZIRCON_REG_MAC_HI           0x014
#define ZIRCON_REG_IPV4             0x018
#define ZIRCON_REG_ECHO_PORT        0x01C
#define ZIRCON_REG_SOCK_LOCAL_PORT  0x020
#define ZIRCON_REG_SOCK_REMOTE_PORT 0x024
#define ZIRCON_REG_SOCK_REMOTE_IP   0x028
#define ZIRCON_REG_SOCK_REMOTE_MAC_LO 0x02C
#define ZIRCON_REG_SOCK_REMOTE_MAC_HI 0x030
#define ZIRCON_REG_TTL              0x034
#define ZIRCON_REG_RX_FRAMES        0x040
#define ZIRCON_REG_RX_BYTES_LO      0x044
#define ZIRCON_REG_RX_BYTES_HI      0x048
#define ZIRCON_REG_RX_BAD_FRAME     0x04C
#define ZIRCON_REG_RX_FIFO_DROP     0x050
#define ZIRCON_REG_RX_L3_BAD_CSUM   0x054
#define ZIRCON_REG_RX_L4_BAD_CSUM   0x058
#define ZIRCON_REG_RX_RAW           0x05C
#define ZIRCON_REG_RX_ECHO          0x060
#define ZIRCON_REG_RX_SOCK          0x064
#define ZIRCON_REG_TX_FRAMES        0x068
#define ZIRCON_REG_TX_BYTES_LO      0x06C
#define ZIRCON_REG_TX_BYTES_HI      0x070
#define ZIRCON_REG_TX_RAW           0x074
#define ZIRCON_REG_TX_ECHO          0x078
#define ZIRCON_REG_TX_SOCK          0x07C
/* 1.1.0 */
#define ZIRCON_REG_RX_RAW_DROP      0x080
#define ZIRCON_REG_RX_SOCK_DROP     0x084
#define ZIRCON_REG_RX_ECHO_DROP     0x088
#define ZIRCON_REG_TX_OVERSIZE_DROP 0x08C
/* 1.2.0: hardware UDP generator (udp_gen), DESIGN_SPEC section 10.2 */
#define ZIRCON_REG_GEN_CTRL         0x090
#define ZIRCON_REG_GEN_LEN          0x094
#define ZIRCON_REG_GEN_COUNT        0x098
#define ZIRCON_REG_GEN_GAP          0x09C
#define ZIRCON_REG_GEN_DST_MAC_LO   0x0A0
#define ZIRCON_REG_GEN_DST_MAC_HI   0x0A4
#define ZIRCON_REG_GEN_DST_IP       0x0A8
#define ZIRCON_REG_GEN_DST_PORT     0x0AC
#define ZIRCON_REG_GEN_SRC_PORT     0x0B0
#define ZIRCON_REG_GEN_TX_PKTS      0x0B4
#define ZIRCON_REG_GEN_TX_BYTES_LO  0x0B8
#define ZIRCON_REG_GEN_TX_BYTES_HI  0x0BC
/* 1.2.0: hardware UDP checker (udp_chk), section 10.3 */
#define ZIRCON_REG_CHK_CTRL         0x0C0
#define ZIRCON_REG_CHK_PORT         0x0C4
#define ZIRCON_REG_CHK_RX_PKTS      0x0C8
#define ZIRCON_REG_CHK_RX_BYTES_LO  0x0CC
#define ZIRCON_REG_CHK_RX_BYTES_HI  0x0D0
#define ZIRCON_REG_CHK_SEQ_ERR      0x0D4
#define ZIRCON_REG_CHK_BIT_ERR_LO   0x0D8
#define ZIRCON_REG_CHK_BIT_ERR_HI   0x0DC
#define ZIRCON_REG_CHK_LEN_ERR      0x0E0
/* 1.2.0: rate meters (always built), section 10.4. Reading RATE_SEQ latches
 * the six registers below from one 1-second window. */
#define ZIRCON_REG_RATE_SEQ         0x0E4
#define ZIRCON_REG_RX_RATE_BYTES_LO 0x0E8
#define ZIRCON_REG_RX_RATE_BYTES_HI 0x0EC
#define ZIRCON_REG_RX_RATE_PKTS     0x0F0
#define ZIRCON_REG_TX_RATE_BYTES_LO 0x0F4
#define ZIRCON_REG_TX_RATE_BYTES_HI 0x0F8
#define ZIRCON_REG_TX_RATE_PKTS     0x0FC
/* 1.3.0: latency measurement (MRMAC 1588 timestamps), section 11 */
#define ZIRCON_REG_LAT_CTRL         0x100
#define ZIRCON_REG_LAT_STATUS       0x104
#define ZIRCON_REG_LAT_BIN_BASE     0x108   /* ns, lower edge of bin 0          */
#define ZIRCON_REG_LAT_BIN_WIDTH    0x10C   /* ns, width of the linear bins (a
					       power of two, rounded down)      */
#define ZIRCON_REG_LAT_STALE_CNT    0x110   /* TX timestamp tags found stale    */
#define ZIRCON_REG_LAT_LOST_CNT     0x114   /* timestamp requests lost          */
#define ZIRCON_REG_LAT_OVF_CNT      0x118   /* sample FIFO overflows            */
/* Per bank b (0 = hardware UDP echo, 1 = software/raw TX descriptors): the
 * snapshot copy (LAT_CTRL.SNAP), at ZIRCON_LAT_BANK(b) + the offsets below */
#define ZIRCON_LAT_BANK(b)          (0x200 + (b) * 0x40)
#define ZIRCON_LAT_COUNT_LO         0x00
#define ZIRCON_LAT_COUNT_HI         0x04
#define ZIRCON_LAT_SUM_LO           0x08    /* ns                               */
#define ZIRCON_LAT_SUM_HI           0x0C
#define ZIRCON_LAT_SUMSQ_LO         0x10    /* ns^2                             */
#define ZIRCON_LAT_SUMSQ_HI         0x14
#define ZIRCON_LAT_MIN              0x18    /* ns                               */
#define ZIRCON_LAT_MAX              0x1C    /* ns                               */
#define ZIRCON_LAT_IMPLAUSIBLE      0x20    /* deltas rejected as garbage       */
#define ZIRCON_LAT_LAST_DELTA       0x24    /* ns                               */
#define ZIRCON_LAT_SNAP_BIN_BASE    0x28    /* bin geometry at snapshot time    */
#define ZIRCON_LAT_SNAP_BIN_WIDTH   0x2C
/* Histogram of bank b: ZIRCON_LAT_NBINS bins of 8 bytes (LO u32, HI u32 with
 * bits 15:0 used: 48-bit counts) */
#define ZIRCON_LAT_HIST(b, i)       (0x400 + (b) * 0x200 + (i) * 8)

#define ZIRCON_LAT_NBANKS           2
#define ZIRCON_LAT_NBINS            64
#define ZIRCON_LAT_NLINEAR          48      /* bins 0..47 linear                */
#define ZIRCON_LAT_BANK_HW          0       /* hardware UDP echo                */
#define ZIRCON_LAT_BANK_SW          1       /* raw TX descriptor (TCP echo)     */
#define ZIRCON_LAT_BIN_BASE_DEFAULT  0
#define ZIRCON_LAT_BIN_WIDTH_DEFAULT 64

/* LAT_CTRL bits */
#define ZIRCON_LAT_EN               (1u << 0)    /* timestamp + measure            */
#define ZIRCON_LAT_CLR0             (1u << 1)    /* clear bank 0                   */
#define ZIRCON_LAT_CLR1             (1u << 2)    /* clear bank 1                   */
#define ZIRCON_LAT_SNAP             (1u << 3)    /* live -> readable copy (self-clearing) */
#define ZIRCON_LAT_BUSY             (1u << 31)   /* RO: a CLR / SNAP command is running */
#define ZIRCON_LAT_RAW_TS_DESC      (1u << 8)    /* UI0 RX frames carry a ZRXT descriptor */
#define ZIRCON_LAT_RAW_TX_DESC      (1u << 9)    /* UI0 TX: strip / honour ZTXT descriptors */

/* LAT_STATUS bits (sticky, W1C) */
#define ZIRCON_LAT_ST_STALE         (1u << 0)
#define ZIRCON_LAT_ST_LOST          (1u << 1)
#define ZIRCON_LAT_ST_OVF           (1u << 2)

/* MRMAC timestamps: 55 bits in units of 2^-8 ns (zircon_nic carries bits
 * 54:7, so the RX descriptor's value has bits 6:0 = 0) */
#define ZIRCON_TS_FRAC_BITS         8
#define ZIRCON_TS_MASK              ((1ULL << 55) - 1)

/* UI0 (raw path) timestamp descriptors, 64 bytes, little-endian.
 * RX (LAT_CTRL.RAW_TS_DESC = 1): in front of every raw frame
 *   0..3 magic ZRXT, 4..5 frame length, 8..15 rx_ts, 24..27 flags, rest 0
 * TX (optional, per frame): in front of the Ethernet frame; stripped by the
 * hardware, which then timestamps the frame and, with TS_REQ, adds
 * tx_ts - rx_ts to bank 1. A frame that does not start with the magic is
 * sent unchanged.
 *   0..3 magic ZTXT, 6 flags (b0 TS_REQ), 8..15 rx_ts of the request, rest 0 */
#define ZIRCON_RAW_DESC_LEN         64
#define ZIRCON_RX_TS_MAGIC          0x5A525854u   /* "ZRXT" */
#define ZIRCON_TX_TS_MAGIC          0x5A545854u   /* "ZTXT" */
#define ZIRCON_RX_DESC_OFF_MAGIC    0
#define ZIRCON_RX_DESC_OFF_LEN      4
#define ZIRCON_RX_DESC_OFF_TS       8
#define ZIRCON_RX_DESC_OFF_FLAGS    24
#define ZIRCON_TX_DESC_OFF_MAGIC    0
#define ZIRCON_TX_DESC_OFF_FLAGS    6
#define ZIRCON_TX_DESC_OFF_TS       8
#define ZIRCON_TX_DESC_TS_REQ       (1u << 0)

#define ZIRCON_ID_VALUE             0x5A495243u   /* "ZIRC" */
/* VERSION = major[31:16].minor[15:8].patch[7:0] */
#define ZIRCON_VERSION_1_1_0        0x00010100u
#define ZIRCON_VERSION_1_2_0        0x00010200u   /* generator / checker / rate meters */
#define ZIRCON_VERSION_1_3_0        0x00010300u   /* latency measurement */
#define ZIRCON_VER_MAJOR(v)         ((v) >> 16)
#define ZIRCON_VER_MINOR(v)         (((v) >> 8) & 0xFF)
#define ZIRCON_VER_PATCH(v)         ((v) & 0xFF)

/* CTRL bits */
#define ZIRCON_CTRL_RX_EN           (1u << 0)
#define ZIRCON_CTRL_TX_EN           (1u << 1)
#define ZIRCON_CTRL_ECHO_EN         (1u << 2)
#define ZIRCON_CTRL_SOCK_EN         (1u << 3)
#define ZIRCON_CTRL_PROMISC         (1u << 4)
#define ZIRCON_CTRL_STAT_CLR        (1u << 31)

/* STATUS bits (sticky, write-1-to-clear) */
#define ZIRCON_STATUS_RX_FIFO_OVF   (1u << 0)
#define ZIRCON_STATUS_TX_UNDERRUN   (1u << 1)
#define ZIRCON_STATUS_RX_META_ERR   (1u << 2)   /* RO, sticky until reset */
#define ZIRCON_STATUS_TX_META_ERR   (1u << 3)   /* RO, sticky until reset */
#define ZIRCON_STATUS_RX_PACK_STALL (1u << 4)   /* 1.1.0, W1C */
#define ZIRCON_STATUS_RX_PACK_OVF   (1u << 5)   /* 1.1.0, W1C */

/* GEN_CTRL bits */
#define ZIRCON_GEN_EN               (1u << 0)    /* 0->1 edge starts a run        */
#define ZIRCON_GEN_CONT             (1u << 1)    /* continuous (else GEN_COUNT)   */
#define ZIRCON_GEN_CLR              (1u << 2)    /* sequence + GEN_TX_* to 0      */
#define ZIRCON_GEN_BUSY             (1u << 31)   /* RO: a run is in progress      */
/* CHK_CTRL bits */
#define ZIRCON_CHK_EN               (1u << 0)    /* 0->1 edge resynchronises      */
#define ZIRCON_CHK_CLR              (1u << 2)    /* CHK_* to 0 + resynchronise    */
#define ZIRCON_CHK_SYNC             (1u << 31)   /* RO: a datagram was checked    */

#define ZIRCON_GEN_LEN_MIN          8
#define ZIRCON_GEN_LEN_MAX          9000
#define ZIRCON_GEN_LEN_DEFAULT      1472
#define ZIRCON_CHK_PORT_DEFAULT     5001
/* Bytes the rate meters do not see per frame: FCS 4 + preamble/SFD 8 + IPG 12
 * (line rate = 8 * (BYTES + 24 * PKTS) per window) */
#define ZIRCON_RATE_LINE_OVERHEAD   24
/* Ethernet 14 + IPv4 20 + UDP 8 header bytes in front of a generated payload */
#define ZIRCON_UDP_HDR_BYTES        42

/* UI2 RX descriptor (64 bytes, prepended to every socket datagram, LE) */
#define ZIRCON_SOCK_DESC_LEN        64
#define ZIRCON_SOCK_DESC_MAGIC      0x5A534B54u   /* "ZSKT" */

typedef struct {
	u32 magic;          /* 0..3                                        */
	u16 payload_len;    /* 4..5                                        */
	u16 src_port;       /* 6..7                                        */
	u8  src_ip[4];      /* 8..11, network byte order (as on the wire)  */
	u8  src_mac[6];     /* 12..17                                      */
	u16 dst_port;       /* 18..19                                      */
	u8  dst_ip[4];      /* 20..23                                      */
	u32 flags;          /* 24..27, copy of the parser flags            */
} zircon_sock_desc_t;

typedef struct {
	u32 rx_frames, rx_bad_frame, rx_fifo_drop, rx_l3_bad_csum, rx_l4_bad_csum;
	u32 rx_raw, rx_echo, rx_sock;
	u32 tx_frames, tx_raw, tx_echo, tx_sock;
	u32 rx_raw_drop, rx_sock_drop, rx_echo_drop, tx_oversize_drop;  /* 1.1.0 (0 before) */
	u64 rx_bytes, tx_bytes;
	u32 status;
} zircon_counters_t;

/* Generator + checker counters */
typedef struct {
	u32 gen_ctrl, chk_ctrl;
	u32 gen_tx_pkts;
	u64 gen_tx_bytes;
	u32 chk_rx_pkts;
	u64 chk_rx_bytes;
	u32 chk_seq_err;
	u64 chk_bit_err;
	u32 chk_len_err;
} zircon_genchk_t;

/* One rate-meter window (1 s of core clock) */
typedef struct {
	u32 seq;                 /* RATE_SEQ of this sample              */
	u64 rx_bytes, tx_bytes;  /* frame bytes, FCS excluded            */
	u32 rx_pkts, tx_pkts;
} zircon_rate_t;

/* One latency bank (snapshot) */
typedef struct {
	u64 count;
	u64 sum_ns;
	u64 sumsq_ns2;
	u32 min_ns, max_ns;
	u32 implausible;
	u32 last_ns;
	u32 bin_base_ns, bin_width_ns;   /* histogram geometry of this snapshot */
	u64 bins[ZIRCON_LAT_NBINS];
} zircon_lat_bank_t;

/* Latency error counters (0x110..0x118) */
typedef struct {
	u32 stale, lost, ovf;
} zircon_lat_err_t;

typedef struct {
	UINTPTR base;
	u32 ctrl;
	u32 lat_ctrl;       /* LAT_CTRL enables (EN, RAW_TS_DESC)          */
} zircon_t;

/* Check the ID register, zero the counters, program defaults (everything
 * disabled). Returns 0 on success, -1 if the ID does not match. */
int  zircon_init(zircon_t *z, UINTPTR base);
u32  zircon_version(const zircon_t *z);
void zircon_set_mac(zircon_t *z, const u8 mac[6]);
/* ip: 4 bytes in network order (ip[0] = first octet), NULL = 0.0.0.0 */
void zircon_set_ipv4(zircon_t *z, const u8 *ip);
void zircon_set_echo_port(zircon_t *z, u16 port);
void zircon_set_sock_local_port(zircon_t *z, u16 port);
void zircon_set_sock_remote(zircon_t *z, const u8 mac[6], const u8 ip[4], u16 port);
void zircon_set_ttl(zircon_t *z, u8 ttl);
void zircon_set_ctrl(zircon_t *z, u32 ctrl);
u32  zircon_get_ctrl(const zircon_t *z);
void zircon_clear_stats(zircon_t *z);
void zircon_read_counters(const zircon_t *z, zircon_counters_t *c);
void zircon_clear_status(zircon_t *z, u32 bits);
void zircon_dump(const zircon_t *z);
/* ---- 1.2.0 generator / checker / rate meters (DESIGN_SPEC section 10) ---- */
/* 1 if the core has the generator/checker (GEN_EN = 1: GEN_LEN reads non-zero) */
int  zircon_has_gen(const zircon_t *z);
/* Header fields and length of generated datagrams (src MAC/IP = local regs);
 * dst_ip: 4 bytes in network order */
void zircon_gen_config(zircon_t *z, const u8 dst_mac[6], const u8 dst_ip[4],
		       u16 dst_port, u16 src_port, u32 len, u32 gap);
/* Start a run: continuous, or 'count' datagrams */
void zircon_gen_start(zircon_t *z, int continuous, u32 count);
/* Stop (the datagram in flight completes); returns 0 when idle, -1 if still busy */
int  zircon_gen_stop(zircon_t *z);
/* Sequence number and GEN_TX_* to 0 (generator stopped) */
void zircon_gen_clear(zircon_t *z);
void zircon_chk_config(zircon_t *z, u16 port);
void zircon_chk_enable(zircon_t *z, int en);
/* CHK_* to 0 and resynchronise (keeps the enable) */
void zircon_chk_clear(zircon_t *z);
void zircon_genchk_read(const zircon_t *z, zircon_genchk_t *g);
/* Read RATE_SEQ (latching the window); if it differs from *last_seq, read the
 * window into *r, update *last_seq and return 1; else return 0. */
int  zircon_rate_read(const zircon_t *z, u32 *last_seq, zircon_rate_t *r);

/* ---- 1.3.0 latency measurement (DESIGN_SPEC section 11) ---- */
/* 1 if the core has the latency block (VERSION >= 1.3.0) */
int  zircon_has_lat(const zircon_t *z);
/* LAT_CTRL enables: ZIRCON_LAT_EN, ZIRCON_LAT_RAW_TS_DESC, ZIRCON_LAT_RAW_TX_DESC */
void zircon_lat_set_ctrl(zircon_t *z, u32 enables);
u32  zircon_lat_get_ctrl(const zircon_t *z);
u32  zircon_lat_status(const zircon_t *z);
void zircon_lat_clear_status(zircon_t *z, u32 bits);
/* Zero the banks in bank_mask (b0 = bank 0, b1 = bank 1); returns 0, or -1
 * if the command did not complete */
int  zircon_lat_clear(zircon_t *z, u32 bank_mask);
void zircon_lat_read_err(const zircon_t *z, zircon_lat_err_t *e);
/* Histogram geometry (ns) */
void zircon_lat_set_bins(zircon_t *z, u32 base_ns, u32 width_ns);
void zircon_lat_get_bins(const zircon_t *z, u32 *base_ns, u32 *width_ns);
/* Copy the live statistics of both banks to the readable registers
 * (coherent); returns 0, or -1 if SNAP did not complete */
int  zircon_lat_snapshot(zircon_t *z);
/* Read one bank of the last snapshot; with_bins = 0 skips the histogram */
void zircon_lat_read(const zircon_t *z, int bank, zircon_lat_bank_t *b, int with_bins);
/* Lower edge (ns) of histogram bin i for a base/width; the upper edge of bin
 * i < 63 is the lower edge of bin i + 1, bin 63 (overflow) has none. Bin 0
 * also holds every delta below base. */
u64  zircon_lat_bin_lo(int i, u32 base_ns, u32 width_ns);

/* Decode a UI2 RX descriptor; returns 0 if the magic matches, -1 otherwise */
int  zircon_sock_desc_parse(const u8 *buf, zircon_sock_desc_t *d);

#endif /* ZIRCON_H */

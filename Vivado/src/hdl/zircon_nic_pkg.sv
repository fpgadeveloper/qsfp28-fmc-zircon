// SPDX-License-Identifier: MIT
//
// zircon_nic_pkg - shared types and constants of the zircon_nic glue (MIT).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). The Zircon
// metadata byte layout it decodes is defined by the Taxi Zircon sources
// (submodules/taxi/src/zircon/rtl, CERN-OHL-S-2.0); see docs/DESIGN_SPEC.md §4.
//
// Byte-order conventions used throughout the glue (same as the Zircon metadata):
//   * MAC addresses are 48-bit vectors in wire order, first byte on the wire in
//     bits [7:0]  (e.g. 02:0a:35:00:00:01 -> 48'h01_00_00_35_0a_02).
//   * IPv4 addresses are 32-bit vectors in wire order, first octet in bits [7:0]
//     (192.168.10.2 -> 32'h020a_a8c0). The AXI-Lite registers use the opposite
//     (network u32) order; zircon_regs converts.
//   * UDP ports are plain 16-bit numbers.

`resetall
`timescale 1ns / 1ps
`default_nettype none

package zircon_nic_pkg;

    // Zircon parser / deparser flag bits (zircon_ip_rx_parse.sv, zircon_ip_tx_deparse.sv)
    localparam int FLG_VLAN_S     = 1;
    localparam int FLG_VLAN_C     = 2;
    localparam int FLG_IPV4       = 3;
    localparam int FLG_IPV6       = 4;
    localparam int FLG_FRAG       = 5;
    localparam int FLG_ARP        = 6;
    localparam int FLG_ICMP       = 7;
    localparam int FLG_TCP        = 8;
    localparam int FLG_UDP        = 9;
    localparam int FLG_L3_OPT     = 16;
    localparam int FLG_L4_OPT     = 17;
    localparam int FLG_L3_BAD     = 24;
    localparam int FLG_L4_BAD_LEN = 25;
    localparam int FLG_PARSE_DONE = 31;  // RX
    localparam int FLG_EN         = 31;  // TX: build a header

    // Fixed Ethernet(14) + IPv4 without options(20) + UDP(8) header length. The
    // ECHO / SOCK rules exclude VLAN tags and IPv4 options, so this is exact.
    localparam int UDP_HDR_BYTES = 42;

    // Socket RX descriptor magic ("ZSKT", little-endian u32 at byte 0)
    localparam logic [31:0] SOCK_DESC_MAGIC = 32'h5A534B54;

    // Latency measurement (1.3.0, docs/DESIGN_SPEC.md §11)
    // RAW RX descriptor (LAT_CTRL.RAW_RX_DESC) and RAW TX descriptor (LAT_CTRL.RAW_TX_DESC)
    // magics, little-endian u32 at byte 0 of a 64-byte descriptor beat
    localparam logic [31:0] RAW_RX_DESC_MAGIC = 32'h5A525854;   // "ZRXT"
    localparam logic [31:0] RAW_TX_DESC_MAGIC = 32'h5A545854;   // "ZTXT"
    localparam int LAT_TS_W  = 48;       // RX timestamp bits carried: MRMAC ts[54:7] (0.5 ns units)
    localparam int LAT_BANKS = 2;        // statistics banks: 0 = hardware echo, 1 = software (RAW TX descriptor)
    localparam int LAT_DELTA_W = 32;     // latency sample (ns)
    localparam logic [31:0] LAT_MAX_NS = 32'd1_000_000_000;   // deltas >= 1 s are implausible

    // Per-packet TX latency record (tx_meta_builder -> MAC TX): timestamp this
    // frame (want) and account tx_ts - rx_ts to statistics bank `bank`
    typedef struct packed {
        logic                 want;
        logic [1:0]           bank;
        logic [LAT_TS_W-1:0]  rx_ts;     // MRMAC RX timestamp [54:7]
    } lat_rec_t;

    localparam int LAT_REC_W = $bits(lat_rec_t);

    // latency sample (MAC TX -> statistics engine)
    typedef struct packed {
        logic [1:0]             bank;
        logic                   implausible;   // delta >= 1 s (not accumulated)
        logic [LAT_DELTA_W-1:0] delta_ns;
    } lat_sample_t;

    localparam int LAT_SAMPLE_W = $bits(lat_sample_t);

    // tdest of the zircon_ip_tx_buffer inputs
    localparam logic [1:0] TX_DEST_RAW  = 2'd0;
    localparam logic [1:0] TX_DEST_ECHO = 2'd1;
    localparam logic [1:0] TX_DEST_SOCK = 2'd2;
    localparam logic [1:0] TX_DEST_GEN  = 2'd3;   // hardware UDP generator (GEN_EN = 1)

    // Generator payload pattern (docs/DESIGN_SPEC.md §10): eight xorshift64 lanes
    // seeded from the 64-bit sequence number S with x_j(0) = (S ^ PRBS_K[j]) | 2^63
    // and advanced once per 64-byte beat; beat b carries x_j(b+1) in bytes 8j..8j+7
    // (little-endian); payload bytes 0..7 are S (little-endian).
    // PRBS_K[j] = (j + 1) * 0x9E3779B97F4A7C15 mod 2^64.
    localparam logic [63:0] PRBS_K [8] = '{
        64'h9E3779B97F4A7C15, 64'h3C6EF372FE94F82A, 64'hDAA66D2C7DDF743F, 64'h78DDE6E5FD29F054,
        64'h1715609F7C746C69, 64'hB54CDA58FBBEE87E, 64'h538454127B096493, 64'hF1BBCDCBFA53E0A8};

    localparam int GEN_LEN_MIN = 8;       // payload bytes (the sequence number)
    localparam int GEN_LEN_MAX = 9000;

    // xorshift64 (Marsaglia, shifts 13 / 7 / 17)
    function automatic logic [63:0] xs64(input logic [63:0] x);
        logic [63:0] y;
        y = x ^ (x << 13);
        y = y ^ (y >> 7);
        y = y ^ (y << 17);
        return y;
    endfunction

    // lane seed x_j(0) (never 0: bit 63 forced)
    function automatic logic [63:0] prbs_seed(input logic [63:0] s, input int j);
        return (s ^ PRBS_K[j]) | 64'h8000_0000_0000_0000;
    endfunction

    // Compact per-packet record extracted from the 16x64b parser metadata by
    // rx_meta_capture (one FIFO entry per packet instead of 16).
    typedef struct packed {
        logic [15:0] src_port;   // meta bytes 98..99 (u16)
        logic [15:0] dst_port;   // meta bytes 96..97 (u16)
        logic [31:0] src_ip;     // meta bytes 80..83 (wire order)
        logic [31:0] dst_ip;     // meta bytes 64..67 (wire order)
        logic [47:0] src_mac;    // meta bytes 32..37 (wire order)
        logic [47:0] dst_mac;    // meta bytes 24..29 (wire order)
        logic [15:0] pkt_sum;    // meta bytes 6..7: expected len_cksum sum if the L4 checksum is valid
        logic [15:0] plen;       // meta bytes 4..5: L4 payload length (UDP: UDP length - 8)
        logic [31:0] flags;      // meta bytes 0..3
    } rx_hdr_rec_t;

    localparam int RX_HDR_REC_W = $bits(rx_hdr_rec_t);

    // Echo metadata record: the addresses of a received echo request, pushed by
    // rx_dispatch and popped by tx_meta_builder, which swaps them for the reply.
    typedef struct packed {
        logic [LAT_TS_W-1:0] rx_ts;   // MRMAC RX timestamp [54:7] of the request (1.3.0)
        logic [15:0] dst_port;   // rx UDP destination port (= ECHO_PORT)
        logic [15:0] src_port;   // rx UDP source port
        logic [31:0] dst_ip;     // rx destination IPv4 (= local IP)
        logic [31:0] src_ip;     // rx source IPv4
        logic [47:0] dst_mac;    // rx destination MAC (= local MAC)
        logic [47:0] src_mac;    // rx source MAC
    } echo_rec_t;

    localparam int ECHO_REC_W = $bits(echo_rec_t);

    // Configuration delivered from the AXI-Lite domain to the core clock domain
    typedef struct packed {
        logic        stat_clr_toggle;  // toggles on every CTRL.STAT_CLR write
        logic        promisc;          // CTRL.PROMISC (reserved, no effect)
        logic        sock_en;
        logic        echo_en;
        logic        tx_en;
        logic        rx_en;
        logic [7:0]  ttl;
        logic [47:0] local_mac;        // wire order
        logic [31:0] local_ip;         // wire order
        logic [15:0] echo_port;
        logic [15:0] sock_local_port;
        logic [15:0] sock_remote_port;
        logic [31:0] sock_remote_ip;   // wire order
        logic [47:0] sock_remote_mac;  // wire order
        // hardware UDP generator / checker (all zero when GEN_EN = 0)
        logic        gen_en;           // GEN_CTRL b0
        logic        gen_cont;         // GEN_CTRL b1
        logic        gen_clr_toggle;   // toggles on every GEN_CTRL b2 write
        logic [13:0] gen_len;          // GEN_LEN (clamped to 8..9000 by udp_gen)
        logic [31:0] gen_count;
        logic [31:0] gen_gap;
        logic [47:0] gen_dst_mac;      // wire order
        logic [31:0] gen_dst_ip;       // wire order
        logic [15:0] gen_dst_port;
        logic [15:0] gen_src_port;
        logic        chk_en;           // CHK_CTRL b0
        logic        chk_clr_toggle;   // toggles on every CHK_CTRL b2 write
        logic [15:0] chk_port;
        // latency measurement (1.3.0)
        logic        lat_en;           // LAT_CTRL b0: request TX timestamps
        logic        lat_raw_rx_desc;  // LAT_CTRL b8: prepend the ZRXT descriptor to RAW RX frames
        logic        lat_raw_tx_desc;  // LAT_CTRL b9: strip / honour a ZTXT descriptor on UI0 TX frames
        logic        lat_req_toggle;   // toggles on every LAT_CTRL write that carries a command
        logic        lat_snap_toggle;  // LAT_CTRL b3
        logic [LAT_BANKS-1:0] lat_clr_toggle;   // LAT_CTRL b1 (bank 0), b2 (bank 1)
        logic [31:0] lat_base;         // LAT_BIN_BASE (ns), both banks
        logic [4:0]  lat_shift;        // log2 of LAT_BIN_WIDTH (ns), both banks
    } cfg_t;

    localparam int CFG_W = $bits(cfg_t);

    // Counters kept in the core clock domain (see zircon_nic_core)
    typedef struct packed {
        logic [1:0]  err;          // sticky internal errors: [0] RX meta_len overflow, [1] TX meta_len overflow
        logic [31:0] tx_oversize;  // UI TX transfers longer than MAX_TX_BYTES, dropped by tx_len_guard
        logic [31:0] rx_bad;       // frames marked bad after the MAC-side FIFO (terminated by a MAC-side reset)
        logic [31:0] rx_echo_drop; // echo requests dropped: no room in the echo payload / metadata FIFO
        logic [31:0] rx_sock_drop; // SOCK frames dropped by the (drop-when-full) socket RX FIFO
        logic [31:0] rx_raw_drop;  // RAW frames dropped by the (drop-when-full) raw RX FIFO
        logic [31:0] tx_sock;
        logic [31:0] tx_echo;
        logic [31:0] tx_raw;
        logic [31:0] rx_drop;      // frames dropped by rx_dispatch because CTRL.RX_EN=0
        logic [31:0] rx_sock;
        logic [31:0] rx_echo;
        logic [31:0] rx_raw;
        logic [31:0] rx_l4_bad;
        logic [31:0] rx_l3_bad;
        logic [63:0] rx_bytes;
        logic [31:0] rx_frames;
    } core_cnt_t;

    localparam int CORE_CNT_W = $bits(core_cnt_t);

    // Counters kept in the MAC RX clock domain
    typedef struct packed {
        logic [15:0] rx_pack_ovf;   // mrmac_rx_packer overflow events (-> STATUS.RX_PACK_OVF)
        logic [15:0] rx_pack_stall; // mrmac_rx_packer stall cycles    (-> STATUS.RX_PACK_STALL)
        logic [31:0] rx_fifo_drop; // MAC-side FIFO: dropped because full or oversize
        logic [31:0] rx_bad_frame; // MAC-side FIFO: dropped because tuser[0] (MAC error) on the last beat
    } macrx_cnt_t;

    localparam int MACRX_CNT_W = $bits(macrx_cnt_t);

    // Counters kept in the MAC TX clock domain
    typedef struct packed {
        logic [63:0] tx_bytes;
        logic [31:0] tx_frames;
    } mactx_cnt_t;

    localparam int MACTX_CNT_W = $bits(mactx_cnt_t);

    // Latency error counters kept in the MAC TX clock domain (ptp_tx_tagger)
    typedef struct packed {
        logic [31:0] ovf;     // samples lost: statistics FIFO full
        logic [31:0] lost;    // a tag was reused before its timestamp came back
        logic [31:0] stale;   // a timestamp came back with no pending tag (after a reset, or unknown)
    } lat_err_t;

    localparam int LAT_ERR_W = $bits(lat_err_t);

    // Generator / checker counters and rate meters (core clock domain), one
    // snapshot group so each group is coherent in the register domain
    typedef struct packed {
        logic [31:0] tx_rate_pkts;   // rate meter: frames handed to the MAC in the last window
        logic [63:0] tx_rate_bytes;
        logic [31:0] rx_rate_pkts;   // rate meter: frames entering the core in the last window
        logic [63:0] rx_rate_bytes;
        logic [31:0] rate_seq;       // windows completed since reset
        logic [31:0] chk_len_err;
        logic [63:0] chk_bit_err;
        logic [31:0] chk_seq_err;
        logic [63:0] chk_rx_bytes;
        logic [31:0] chk_rx_pkts;
        logic        chk_sync;       // the checker has seen a datagram since enable / clear
        logic [63:0] gen_tx_bytes;
        logic [31:0] gen_tx_pkts;
        logic        gen_busy;
    } ext_cnt_t;

    localparam int EXT_CNT_W = $bits(ext_cnt_t);

    // Ones'-complement equality: 0x0000 and 0xFFFF both represent zero.
    function automatic logic csum_eq(input logic [15:0] a, input logic [15:0] b);
        csum_eq = (a == b) || ((a == 16'h0000 || a == 16'hFFFF) && (b == 16'h0000 || b == 16'hFFFF));
    endfunction

    // Byte-enable mask with the lowest n bits set (n may equal the width)
    function automatic logic [63:0] keep_mask64(input logic [7:0] n);
        keep_mask64 = (n >= 8'd64) ? {64{1'b1}} : ~({64{1'b1}} << n);
    endfunction

endpackage

`resetall

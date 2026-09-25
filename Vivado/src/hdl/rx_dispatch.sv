// SPDX-License-Identifier: MIT
//
// rx_dispatch - per-packet classification and routing of received frames
// (RAW -> UI0, hardware UDP echo -> TX, hardware UDP socket -> UI2, generator
// checker -> udp_chk).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). See
// docs/DESIGN_SPEC.md §3.1 for the rules and §5 for the socket descriptor.
//
// Inputs (all in the core clock domain, all in packet order):
//   s_axis_pkt : the full frame from the store-and-forward packet FIFO (512 b)
//   s_axis_len : zircon_ip_len_cksum record {sum of bytes 14..end, frame length}
//   s_axis_hdr : rx_hdr_rec_t built from the Zircon parser metadata
// A packet is only dispatched when all three heads are valid, so a frame is never
// popped before both of its metadata records exist; the two metadata records are
// popped together, in the cycle the routing decision is committed.
// s_axis_len.tuser[0] is the frame's bad marker forwarded by zircon_ip_len_cksum
// (the MAC-side async FIFO terminates a frame it is reading out with tuser = bad
// when the MAC side is reset): such a frame is dropped and counted (ev_bad,
// RX_BAD_FRAME), never delivered.
// s_axis_len.tuser[48:1] is the frame's MRMAC RX timestamp [54:7] (1.3.0,
// DESIGN_SPEC §11), forwarded the same way: it goes into the echo record of an
// ECHO request and, with cfg_raw_ts_desc (LAT_CTRL.RAW_RX_DESC), into a 64-byte
// ZRXT descriptor beat emitted in front of every RAW frame (DESC state), inside
// the frame, so the drop-when-full RAW FIFO drops descriptor and frame together.
//
// Pipeline per packet:
//   IDLE : wait for the three heads; capture the records plus a peek at the first
//          data beat (UDP checksum field, bytes 40..41)                (1 cycle)
//   PAD  : select the Ethernet padding bytes of a short frame (pad_mask) and
//          evaluate the address / port / flag rules                   (1 cycle)
//   SUM  : sum the padding bytes (pad_sum)                            (1 cycle)
//   ADJ  : UDP checksum check (padding sum subtracted)                (1 cycle)
//   CLS  : classify from the registered results, register the route  (1 cycle)
//   EVAL : commit: pop both metadata records, push the echo record    (1 cycle,
//          stalls only if the echo-metadata FIFO is full)
//   DESC : SOCK (and RAW with cfg_raw_ts_desc) - emit the 64-byte descriptor (1 cycle)
//   FWD  : move the frame at one beat per cycle:
//            RAW  - unchanged
//            DROP - consumed, nothing emitted (CTRL.RX_EN = 0)
//            ECHO/SOCK/CHK - fixed 42-byte strip realigned with a 22-byte carry
//                   register (constant shift: wiring only, no barrel shifter),
//                   trimmed to the UDP payload length so Ethernet padding is
//                   not forwarded; the rest of the frame is drained.
//   FLUSH: emit the carry when the payload tail sits in the last input beat.
// Overhead is 6 cycles per packet (7 for SOCK), well below the ~20 cycles/packet
// of the 32-bit Zircon parser, and large frames stream at 1 beat/cycle.
//
// Rules (hdr = parser record, len = len_cksum record):
//   cand = IPv4 & UDP & !VLAN_S & !VLAN_C & !FRAG & !L3_OPT & !L4_BAD_LEN &
//          PARSE_DONE & dst MAC == local MAC & dst IP == local IP &
//          payload_len != 0 & frame_len >= 42 + payload_len
//   ECHO = cand & dst port == ECHO_PORT & ECHO_EN      (wins if ports are equal)
//   SOCK = cand & dst port == SOCK_LOCAL_PORT & SOCK_EN  (wins over CHK)
//   CHK  = cand & dst port == CHK_PORT & CHK_EN          (1.2.0, udp_chk)
//   L3 ok = !L3_BAD_CKSUM
//   L4 ok = (UDP checksum field == 0) | (hdr.pkt_sum == len.sum - padding sum,
//           ones'-complement arithmetic and equality: 0x0000 == 0xFFFF)
//   ECHO/SOCK/CHK need L3 ok & L4 ok, otherwise the frame goes to RAW (a failed L4
//   check on a rule candidate is counted as RX_L4_BAD_CSUM).
//   CTRL.RX_EN = 0 drops every frame here (so no FIFO ever wedges).
//   ECHO is dropped here (ev_echo_drop, RX_ECHO_DROP) instead of waiting when the
//   echo payload FIFO has no room for the whole payload or the echo-metadata FIFO
//   is full: a stalled TX path then never blocks the RAW / SOCK paths. RAW and
//   SOCK never stall dispatch either: their outputs feed drop-when-full frame
//   FIFOs in zircon_nic_core (review #2, head-of-line blocking). CHK feeds udp_chk,
//   which never back-pressures.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rx_dispatch
    import zircon_nic_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst,

    // configuration (core clock domain)
    input  wire logic         cfg_rx_en,
    input  wire logic         cfg_echo_en,
    input  wire logic         cfg_sock_en,
    input  wire logic [47:0]  cfg_local_mac,   // wire order
    input  wire logic [31:0]  cfg_local_ip,    // wire order
    input  wire logic [15:0]  cfg_echo_port,
    input  wire logic [15:0]  cfg_sock_port,
    input  wire logic         cfg_chk_en,      // tie 0 when the checker is not built
    input  wire logic [15:0]  cfg_chk_port,
    input  wire logic         cfg_raw_ts_desc,  // prepend the ZRXT descriptor to RAW frames (1.3.0)

    // free space of the echo payload FIFO (beats), see the ECHO drop rule
    input  wire logic [15:0]  echo_free_beats,

    // inputs
    taxi_axis_if.snk          s_axis_pkt,
    taxi_axis_if.snk          s_axis_len,
    taxi_axis_if.snk          s_axis_hdr,

    // outputs
    taxi_axis_if.src          m_axis_raw,
    taxi_axis_if.src          m_axis_sock,
    taxi_axis_if.src          m_axis_echo,
    taxi_axis_if.src          m_axis_chk,      // UDP payloads for udp_chk
    taxi_axis_if.src          m_axis_emeta,

    // statistics events (single-cycle pulses)
    output logic              ev_frame,
    output logic [15:0]       ev_frame_len,
    output logic              ev_raw,
    output logic              ev_echo,
    output logic              ev_sock,
    output logic              ev_drop,
    output logic              ev_bad,       // frame marked bad (tuser) on the len record: dropped
    output logic              ev_echo_drop,
    output logic              ev_l3_bad,
    output logic              ev_l4_bad
);

localparam int DATA_W = s_axis_pkt.DATA_W;
localparam int KEEP_W = s_axis_pkt.KEEP_W;
localparam int STRIP = UDP_HDR_BYTES;         // 42
localparam int CARRY = KEEP_W - STRIP;        // 22 bytes carried between beats
localparam int TAIL = KEEP_W - STRIP;         // head-beat bytes 42..63 (padding check)

if (DATA_W != 512 || KEEP_W != 64)
    $fatal(0, "Error: rx_dispatch requires a 512-bit, byte-granular packet stream (instance %m)");

if (s_axis_len.DATA_W != 32)
    $fatal(0, "Error: len interface must be 32 bits (instance %m)");

if (!s_axis_len.USER_EN || s_axis_len.USER_W != 1 + LAT_TS_W)
    $fatal(0, "Error: len interface tuser must be {rx_ts, bad} (instance %m)");

if (s_axis_hdr.DATA_W != RX_HDR_REC_W)
    $fatal(0, "Error: hdr interface width must be %0d (instance %m)", RX_HDR_REC_W);

if (m_axis_emeta.DATA_W != ECHO_REC_W)
    $fatal(0, "Error: emeta interface width must be %0d (instance %m)", ECHO_REC_W);

typedef enum logic [2:0] { R_RAW, R_ECHO, R_SOCK, R_DROP, R_CHK } route_t;
typedef enum logic [3:0] { S_IDLE, S_PAD, S_SUM, S_ADJ, S_CLS, S_EVAL, S_DESC, S_FWD, S_FLUSH } state_t;

state_t state_reg = S_IDLE, state_next;

// ---------------------------------------------------------------------------
// Capture (IDLE) and classification (CLS, from the captured registers)
// ---------------------------------------------------------------------------
rx_hdr_rec_t hdr_in;
assign hdr_in = rx_hdr_rec_t'(s_axis_hdr.tdata);

wire heads_valid = s_axis_pkt.tvalid && s_axis_len.tvalid && s_axis_hdr.tvalid;

// per-packet state captured in IDLE from the three FIFO heads
rx_hdr_rec_t hdr_reg = '0;
logic [15:0] flen_reg = '0;     // frame length (len_cksum)
logic [15:0] lsum_reg = '0;     // ones'-complement sum of frame bytes 14..end (len_cksum)
logic [15:0] csumf_reg = '0;    // UDP checksum field: frame bytes 40..41 (no VLAN, IHL=5)
logic        bad_reg = 1'b0;    // the frame ended with tuser[0] = bad (see RX_BAD_FRAME)
logic [LAT_TS_W-1:0] rx_ts_reg = '0;   // MRMAC RX timestamp [54:7] (len tuser[48:1])
logic        raw_desc_reg = 1'b0;      // RAW frame gets the ZRXT descriptor (CLS)
logic [TAIL*8-1:0] tail_reg = '0;   // head-beat bytes 42..63 (the only place padding can be)
logic [TAIL*8-1:0] tailm_reg = '0;  // the padding bytes of tail_reg (others zeroed)
logic [15:0] padsum_reg = '0;   // ones'-complement sum of the Ethernet padding bytes

// Ethernet padding (review #6). len_cksum sums every byte from offset 14 to the
// end of the frame, padding included, while the parser's pkt_sum only covers the
// UDP datagram, so non-zero padding (legal; some NICs and switches send it) made
// the L4 check of short datagrams fail. Padding exists only in frames of at most
// 64 bytes (single beat): bytes [42 + plen, frame_len) of the head beat. Their
// sum (big-endian 16-bit words aligned to even frame offsets, like len_cksum) is
// subtracted before the compare. Longer frames carrying trailing bytes beyond the
// IP datagram still fail the check and go RAW.
// PAD stage: keep only the padding bytes (tail byte j = frame byte 42 + j)
function automatic logic [TAIL*8-1:0] pad_mask(input logic [TAIL*8-1:0] tail, input logic [15:0] plen,
                                              input logic [15:0] flen);
    pad_mask = '0;
    for (int j = 1; j < TAIL; j++) begin    // byte 42 is never padding (plen >= 1)
        if (flen <= 16'(KEEP_W) && 16'(j) >= plen && 16'(STRIP + j) < flen) begin
            pad_mask[j*8 +: 8] = tail[j*8 +: 8];
        end
    end
endfunction

// SUM stage: ones'-complement sum of the masked bytes (even frame offset = high byte)
function automatic logic [15:0] pad_sum(input logic [TAIL*8-1:0] tailm);
    logic [19:0] acc;
    logic [16:0] f1;
    acc = '0;
    for (int j = 1; j < TAIL; j++) begin
        if (((STRIP + j) % 2) == 0)
            acc = acc + {4'd0, tailm[j*8 +: 8], 8'd0};
        else
            acc = acc + {12'd0, tailm[j*8 +: 8]};
    end
    f1 = 17'(acc[15:0]) + 17'(acc[19:16]);
    return f1[15:0] + 16'(f1[16]);
endfunction

// ones'-complement a - b
function automatic logic [15:0] csum_sub(input logic [15:0] a, input logic [15:0] b);
    logic [15:0] nb;
    logic [16:0] t;
    nb = ~b;                        // 16-bit complement (not widened before inverting)
    t = {1'b0, a} + {1'b0, nb};
    return t[15:0] + {15'd0, t[16]};
endfunction

// PAD stage (registered in parallel with pad_sum): the address/port/flag rules
wire [31:0] f = hdr_reg.flags;
wire cand = f[FLG_IPV4] && f[FLG_UDP] && !f[FLG_VLAN_S] && !f[FLG_VLAN_C] &&
            !f[FLG_FRAG] && !f[FLG_L3_OPT] && !f[FLG_L4_BAD_LEN] && f[FLG_PARSE_DONE] &&
            (hdr_reg.dst_mac == cfg_local_mac) && (hdr_reg.dst_ip == cfg_local_ip) &&
            (hdr_reg.plen != 16'd0) &&
            ({1'b0, flen_reg} >= 17'(STRIP) + {1'b0, hdr_reg.plen});

// room for the echo payload: ceil(plen / 64) beats plus a margin for the beat in
// the output register and the one-cycle lag of the FIFO depth status
localparam int ECHO_MARGIN = 4;

logic        rule_cand_reg = 1'b0;   // cand & (echo, socket or checker port) & L3 ok
logic        port_echo_reg = 1'b0;
logic        port_sock_reg = 1'b0;
logic        l3_bad_ipv4_reg = 1'b0;
logic [16:0] echo_beats_reg = '0;
logic        l4_ok_reg = 1'b0;       // ADJ stage: UDP checksum verified

wire port_echo = cfg_echo_en && (hdr_reg.dst_port == cfg_echo_port);
wire port_sock = cfg_sock_en && (hdr_reg.dst_port == cfg_sock_port);
wire port_chk  = cfg_chk_en && (hdr_reg.dst_port == cfg_chk_port);

// CLS stage
wire echo_room = (echo_beats_reg <= {1'b0, echo_free_beats}) && m_axis_emeta.tready;
wire rule_cand = rule_cand_reg;
wire l4_ok = l4_ok_reg;

route_t cls_route;
logic   cls_echo_drop;
always_comb begin
    cls_echo_drop = 1'b0;
    if (bad_reg || !cfg_rx_en) begin
        cls_route = R_DROP;
    end else if (rule_cand && l4_ok) begin
        cls_route = port_echo_reg ? R_ECHO : (port_sock_reg ? R_SOCK : R_CHK);
        if (port_echo_reg && !echo_room) begin
            cls_route = R_DROP;
            cls_echo_drop = 1'b1;
        end
    end else begin
        cls_route = R_RAW;
    end
end

// registered classification
route_t      route_reg = R_RAW;
logic        l3_bad_reg = 1'b0;
logic        l4_bad_reg = 1'b0;
logic        echo_drop_reg = 1'b0;

// strip engine
logic                 first_reg = 1'b0;   // next input beat is the frame's first
logic [15:0]          rem_reg = '0;       // payload bytes still to emit
logic [CARRY*8-1:0]   carry_reg = '0;     // bytes 42..63 of the previous input beat

// ---------------------------------------------------------------------------
// Output register (one stage, shared by the three output ports)
// ---------------------------------------------------------------------------
logic [DATA_W-1:0] o_data_reg = '0;
logic [KEEP_W-1:0] o_keep_reg = '0;
logic              o_last_reg = 1'b0;
logic              o_valid_reg = 1'b0;
route_t            o_port_reg = R_RAW;

wire o_down_ready = (o_port_reg == R_RAW)  ? m_axis_raw.tready :
                    (o_port_reg == R_SOCK) ? m_axis_sock.tready :
                    (o_port_reg == R_CHK)  ? m_axis_chk.tready :
                                             m_axis_echo.tready;
wire o_free = !o_valid_reg || o_down_ready;

assign m_axis_raw.tdata   = o_data_reg;
assign m_axis_raw.tkeep   = o_keep_reg;
assign m_axis_raw.tstrb   = o_keep_reg;
assign m_axis_raw.tlast   = o_last_reg;
assign m_axis_raw.tid     = '0;
assign m_axis_raw.tdest   = '0;
assign m_axis_raw.tuser   = '0;
assign m_axis_raw.tvalid  = o_valid_reg && (o_port_reg == R_RAW);

assign m_axis_sock.tdata  = o_data_reg;
assign m_axis_sock.tkeep  = o_keep_reg;
assign m_axis_sock.tstrb  = o_keep_reg;
assign m_axis_sock.tlast  = o_last_reg;
assign m_axis_sock.tid    = '0;
assign m_axis_sock.tdest  = '0;
assign m_axis_sock.tuser  = '0;
assign m_axis_sock.tvalid = o_valid_reg && (o_port_reg == R_SOCK);

assign m_axis_echo.tdata  = o_data_reg;
assign m_axis_echo.tkeep  = o_keep_reg;
assign m_axis_echo.tstrb  = o_keep_reg;
assign m_axis_echo.tlast  = o_last_reg;
assign m_axis_echo.tid    = '0;
assign m_axis_echo.tdest  = '0;
assign m_axis_echo.tuser  = '0;
assign m_axis_echo.tvalid = o_valid_reg && (o_port_reg == R_ECHO);

assign m_axis_chk.tdata   = o_data_reg;
assign m_axis_chk.tkeep   = o_keep_reg;
assign m_axis_chk.tstrb   = o_keep_reg;
assign m_axis_chk.tlast   = o_last_reg;
assign m_axis_chk.tid     = '0;
assign m_axis_chk.tdest   = '0;
assign m_axis_chk.tuser   = '0;
assign m_axis_chk.tvalid  = o_valid_reg && (o_port_reg == R_CHK);

// ---------------------------------------------------------------------------
// Echo metadata record (pushed in EVAL)
// ---------------------------------------------------------------------------
echo_rec_t emeta;
always_comb begin
    emeta.dst_port = hdr_reg.dst_port;
    emeta.src_port = hdr_reg.src_port;
    emeta.dst_ip   = hdr_reg.dst_ip;
    emeta.src_ip   = hdr_reg.src_ip;
    emeta.dst_mac  = hdr_reg.dst_mac;
    emeta.src_mac  = hdr_reg.src_mac;
    emeta.rx_ts    = rx_ts_reg;
end

wire commit = (state_reg == S_EVAL) && (route_reg != R_ECHO || m_axis_emeta.tready);

assign m_axis_emeta.tdata  = emeta;
assign m_axis_emeta.tkeep  = '1;
assign m_axis_emeta.tstrb  = '1;
assign m_axis_emeta.tlast  = 1'b1;
assign m_axis_emeta.tid    = '0;
assign m_axis_emeta.tdest  = '0;
assign m_axis_emeta.tuser  = '0;
assign m_axis_emeta.tvalid = (state_reg == S_EVAL) && (route_reg == R_ECHO);

assign s_axis_len.tready = commit;
assign s_axis_hdr.tready = commit;

// ---------------------------------------------------------------------------
// Socket descriptor (docs/DESIGN_SPEC.md §5), little-endian, 64 bytes
// ---------------------------------------------------------------------------
// RAW RX descriptor (1.3.0, §11): magic "ZRXT", frame length, RX timestamp as a
// little-endian u64 in the MRMAC unit (2^-8 ns; bits 6:0 are 0, the core carries
// bits 54:7), parser flags
logic [DATA_W-1:0] desc;
always_comb begin
    desc = '0;
    if (route_reg == R_RAW) begin
        desc[0*8 +: 32]  = RAW_RX_DESC_MAGIC;
        desc[4*8 +: 16]  = flen_reg;
        desc[8*8 +: 64]  = 64'({rx_ts_reg, 7'd0});
        desc[24*8 +: 32] = hdr_reg.flags;
    end else begin
        desc[0*8 +: 32]  = SOCK_DESC_MAGIC;
        desc[4*8 +: 16]  = hdr_reg.plen;
        desc[6*8 +: 16]  = hdr_reg.src_port;
        desc[8*8 +: 32]  = hdr_reg.src_ip;
        desc[12*8 +: 48] = hdr_reg.src_mac;
        desc[18*8 +: 16] = hdr_reg.dst_port;
        desc[20*8 +: 32] = hdr_reg.dst_ip;
        desc[24*8 +: 32] = hdr_reg.flags;
    end
end

// ---------------------------------------------------------------------------
// Datapath control
// ---------------------------------------------------------------------------
logic              in_ready;
logic              load;
logic [DATA_W-1:0] ld_data;
logic [KEEP_W-1:0] ld_keep;
logic              ld_last;

wire in_xfer = s_axis_pkt.tvalid && in_ready;
wire [7:0] rem_beat = (rem_reg >= 16'(KEEP_W)) ? 8'(KEEP_W) : rem_reg[7:0];

assign s_axis_pkt.tready = in_ready;

always_comb begin
    state_next = state_reg;
    in_ready = 1'b0;
    load = 1'b0;
    ld_data = {s_axis_pkt.tdata[STRIP*8-1:0], carry_reg};
    ld_keep = keep_mask64(rem_beat);
    ld_last = rem_reg <= 16'(KEEP_W);

    case (state_reg)
        S_IDLE: begin
            if (heads_valid) begin
                state_next = S_PAD;
            end
        end
        S_PAD: begin
            state_next = S_SUM;
        end
        S_SUM: begin
            state_next = S_ADJ;
        end
        S_ADJ: begin
            state_next = S_CLS;
        end
        S_CLS: begin
            state_next = S_EVAL;
        end
        S_EVAL: begin
            if (commit) begin
                state_next = (route_reg == R_SOCK || (route_reg == R_RAW && raw_desc_reg)) ? S_DESC : S_FWD;
            end
        end
        S_DESC: begin
            ld_data = desc;
            ld_keep = '1;
            ld_last = 1'b0;
            load = o_free;
            if (o_free) begin
                state_next = S_FWD;
            end
        end
        S_FWD: begin
            case (route_reg)
                R_RAW: begin
                    ld_data = s_axis_pkt.tdata;
                    ld_keep = s_axis_pkt.tkeep;
                    ld_last = s_axis_pkt.tlast;
                    in_ready = o_free;
                    load = s_axis_pkt.tvalid && o_free;
                    if (in_xfer && s_axis_pkt.tlast) begin
                        state_next = S_IDLE;
                    end
                end
                R_DROP: begin
                    in_ready = 1'b1;
                    if (in_xfer && s_axis_pkt.tlast) begin
                        state_next = S_IDLE;
                    end
                end
                default: begin
                    // ECHO / SOCK / CHK: strip 42 bytes, emit exactly rem_reg bytes
                    if (first_reg || rem_reg == 16'd0) begin
                        // first beat only fills the carry; after the payload, drain
                        in_ready = 1'b1;
                        if (in_xfer && s_axis_pkt.tlast) begin
                            state_next = (rem_reg != 16'd0) ? S_FLUSH : S_IDLE;
                        end
                    end else begin
                        in_ready = o_free;
                        load = s_axis_pkt.tvalid && o_free;
                        if (in_xfer && s_axis_pkt.tlast) begin
                            state_next = (rem_reg > 16'(KEEP_W)) ? S_FLUSH : S_IDLE;
                        end
                    end
                end
            endcase
        end
        S_FLUSH: begin
            // remaining payload (<= 22 bytes, guaranteed by the length rule) is in the carry
            ld_data = {{(DATA_W-CARRY*8){1'b0}}, carry_reg};
            ld_last = 1'b1;
            load = o_free;
            if (o_free) begin
                state_next = S_IDLE;
            end
        end
        default: begin
            state_next = S_IDLE;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    // output register
    if (load) begin
        o_data_reg  <= ld_data;
        o_keep_reg  <= ld_keep;
        o_last_reg  <= ld_last;
        o_valid_reg <= 1'b1;
        o_port_reg  <= route_reg;
    end else if (o_down_ready) begin
        o_valid_reg <= 1'b0;
    end

    // capture / classification registers
    if (state_reg == S_IDLE) begin
        hdr_reg    <= hdr_in;
        flen_reg   <= s_axis_len.tdata[15:0];
        lsum_reg   <= s_axis_len.tdata[31:16];
        csumf_reg  <= s_axis_pkt.tdata[40*8 +: 16];
        bad_reg    <= s_axis_len.tuser[0];
        rx_ts_reg  <= s_axis_len.tuser[LAT_TS_W:1];
        tail_reg   <= s_axis_pkt.tdata[DATA_W-1 -: TAIL*8];
    end
    if (state_reg == S_PAD) begin
        tailm_reg       <= pad_mask(tail_reg, hdr_reg.plen, flen_reg);
        rule_cand_reg   <= cand && (port_echo || port_sock || port_chk) && !f[FLG_L3_BAD];
        port_echo_reg   <= port_echo;
        port_sock_reg   <= port_sock;
        l3_bad_ipv4_reg <= f[FLG_IPV4] && f[FLG_L3_BAD];
        echo_beats_reg  <= 17'((32'(hdr_reg.plen) + 63) >> 6) + 17'(ECHO_MARGIN);
    end
    if (state_reg == S_SUM) begin
        padsum_reg <= pad_sum(tailm_reg);
    end
    if (state_reg == S_ADJ) begin
        l4_ok_reg <= (csumf_reg == 16'd0) || csum_eq(hdr_reg.pkt_sum, csum_sub(lsum_reg, padsum_reg));
    end
    if (state_reg == S_CLS) begin
        route_reg     <= cls_route;
        raw_desc_reg  <= cfg_raw_ts_desc && cls_route == R_RAW;
        l3_bad_reg    <= !bad_reg && l3_bad_ipv4_reg;
        l4_bad_reg    <= !bad_reg && rule_cand && !l4_ok;
        echo_drop_reg <= !bad_reg && cls_echo_drop;
    end

    // strip engine
    if (commit) begin
        first_reg <= 1'b1;
        rem_reg   <= hdr_reg.plen;
    end
    if (state_reg == S_FWD && in_xfer) begin
        first_reg <= 1'b0;
        carry_reg <= s_axis_pkt.tdata[DATA_W-1 -: CARRY*8];
        if (!first_reg && route_reg != R_RAW) begin
            rem_reg <= (rem_reg > 16'(KEEP_W)) ? rem_reg - 16'(KEEP_W) : 16'd0;
        end
    end
    if (state_reg == S_FLUSH && o_free) begin
        rem_reg <= 16'd0;
    end

    // statistics
    ev_frame     <= commit && !bad_reg;
    ev_frame_len <= flen_reg;
    ev_bad       <= commit && bad_reg;
    ev_raw       <= commit && route_reg == R_RAW;
    ev_echo      <= commit && route_reg == R_ECHO;
    ev_sock      <= commit && route_reg == R_SOCK;
    ev_drop      <= commit && route_reg == R_DROP && !echo_drop_reg && !bad_reg;
    ev_echo_drop <= commit && echo_drop_reg;
    ev_l3_bad    <= commit && l3_bad_reg;
    ev_l4_bad    <= commit && l4_bad_reg;

    if (rst) begin
        state_reg   <= S_IDLE;
        o_valid_reg <= 1'b0;
        first_reg   <= 1'b0;
        rem_reg     <= '0;
        ev_frame    <= 1'b0;
        ev_bad      <= 1'b0;
        ev_raw      <= 1'b0;
        ev_echo     <= 1'b0;
        ev_sock     <= 1'b0;
        ev_drop     <= 1'b0;
        ev_echo_drop <= 1'b0;
        ev_l3_bad   <= 1'b0;
        ev_l4_bad   <= 1'b0;
    end
end

endmodule

`resetall

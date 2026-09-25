// SPDX-License-Identifier: MIT
//
// tx_meta_builder - builds the 16x64-bit Zircon deparser metadata block for every
// packet leaving zircon_ip_tx_buffer.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). The metadata
// layout is defined by zircon_ip_tx_deparse.sv (Taxi, CERN-OHL-S-2.0); see
// docs/DESIGN_SPEC.md §4.
//
// Input s_axis_len carries, per packet and in the order the payloads sit in the
// tx_buffer RAM, the zircon_ip_len_cksum record {payload sum[15:0], length[15:0]}
// and the tdest of the UI the payload came from:
//   tdest 0 (raw UI0)  : flags = 0 (FLG_EN = 0) -> the deparser emits an empty
//                        header and the payload (a complete frame) passes as-is
//   tdest 1 (echo)     : pops the matching echo_rec_t (pushed by rx_dispatch before
//                        the echo payload entered tx_buffer, so it always exists)
//                        and swaps it: dst = rx src, src = rx dst (local MAC / IP /
//                        ECHO_PORT); flags = EN | IPV4 | UDP
//   tdest 2 (socket)   : addresses from the SOCK_* / local registers
//   tdest 3 (generator): dst = GEN_DST_MAC / GEN_DST_IP / GEN_DST_PORT, src = local
//                        MAC / IP, GEN_SRC_PORT (udp_gen, 1.2.0)
// Latency records (1.3.0, docs/DESIGN_SPEC.md §11): for every packet started,
// one lat_rec_t is pushed on m_axis_lrec in packet order: ECHO -> {want =
// cfg_lat_en, bank 0, rx_ts of the request (echo record)}; RAW -> the record
// raw_tx_desc_strip made for the frame (s_axis_rawrec, popped here, want gated by
// cfg_lat_en); SOCK / GEN -> want = 0. zircon_nic_core attaches it to the frame
// leaving the Zircon concat, and ptp_tx_tagger requests the MRMAC timestamp.
// Always 16 beats (the deparser folds the IPv4 checksum in beats 14-15).
// IPv4: TTL from the TTL register, DSCP/ECN 0, identification = a 16-bit counter
// incremented for every hardware-built (echo / socket / generator) packet. The deparser fixes
// IHL = 5 and flags/fragment offset = 0 (DF clear).
//
// UDP checksum workaround (Taxi cc70b27): zircon_ip_tx_deparse accumulates the
// UDP checksum in a 21-bit register l4 = payload_sum + K (K = UDP length + ports +
// once-folded pseudo-header sum) and emits ~(l4[15:0] + l4[20:16]) - a SINGLE
// end-around-carry fold (zircon_ip_tx_deparse.sv:496). When l4[15:0] + l4[20:16]
// carries out of 16 bits the checksum is one too small; it happens for about 1 in
// 2^16 packets whenever K > 0xFFFF (e.g. replies to ephemeral source ports).
// This module therefore computes K itself, T = full ones'-complement fold of
// (payload_sum + K), and passes an adjusted payload_sum' in beat 0 such that the
// deparser's single fold of (payload_sum' + K) yields exactly T. For the few
// (K, T) pairs no payload_sum' can reach (T <= K[20:16] with K[15:0] != 0; odds
// ~1e-9) it passes a value that makes the deparser emit checksum 0x0000, which
// IPv4 UDP defines as "no checksum". TX metadata for raw frames skips this.
//
// Two stages (1.2.0): a prep stage captures the packet's fields and computes the
// checksum adjustment (1 + 4 cycles for hardware-built headers, 1 for raw), then
// hands the finished descriptor to the output stage, which emits the 16 beats
// through a registered output. The prep of packet n+1 overlaps the beats of
// packet n, so the builder sustains 16 cycles per packet (it was 21 in 1.1.0,
// the TX packet-rate limit: see docs/DESIGN_SPEC.md §10).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tx_meta_builder
    import zircon_nic_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst,

    // configuration (core clock domain)
    input  wire logic [47:0]  cfg_local_mac,       // wire order
    input  wire logic [31:0]  cfg_local_ip,        // wire order
    input  wire logic [7:0]   cfg_ttl,
    input  wire logic [15:0]  cfg_sock_local_port,
    input  wire logic [15:0]  cfg_sock_remote_port,
    input  wire logic [31:0]  cfg_sock_remote_ip,  // wire order
    input  wire logic [47:0]  cfg_sock_remote_mac, // wire order
    input  wire logic [47:0]  cfg_gen_dst_mac,     // wire order
    input  wire logic [31:0]  cfg_gen_dst_ip,      // wire order
    input  wire logic [15:0]  cfg_gen_dst_port,
    input  wire logic [15:0]  cfg_gen_src_port,
    input  wire logic         cfg_lat_en,          // LAT_CTRL.EN: request TX timestamps

    taxi_axis_if.snk          s_axis_len,          // {sum, len}, tdest = UI
    taxi_axis_if.snk          s_axis_emeta,        // echo_rec_t
    taxi_axis_if.snk          s_axis_rawrec,       // lat_rec_t per raw packet (raw_tx_desc_strip)
    taxi_axis_if.src          m_axis_lrec,         // lat_rec_t per packet, packet order
    taxi_axis_if.src          m_axis_meta,         // 64-bit, 16 beats per packet

    // statistics events (single-cycle pulses)
    output logic              ev_raw,
    output logic              ev_echo,
    output logic              ev_sock,
    output logic              ev_gen
);

if (s_axis_len.DATA_W != 32 || !s_axis_len.DEST_EN)
    $fatal(0, "Error: len interface must be 32 bits with tdest (instance %m)");

if (s_axis_emeta.DATA_W != ECHO_REC_W)
    $fatal(0, "Error: emeta interface width must be %0d (instance %m)", ECHO_REC_W);

if (m_axis_meta.DATA_W != 64)
    $fatal(0, "Error: metadata interface must be 64 bits (instance %m)");

logic        busy_reg = 1'b0;    // prep stage holds a packet
logic [2:0]  prep_reg = '0;      // >0: computing the checksum adjustment (EN packets)
logic        o_busy_reg = 1'b0;  // output stage is emitting a packet
logic [3:0]  beat_reg = '0;

wire [1:0] len_dest = 2'(s_axis_len.tdest);
wire start = !busy_reg && s_axis_len.tvalid && m_axis_lrec.tready &&
             (len_dest != TX_DEST_ECHO || s_axis_emeta.tvalid) &&
             (len_dest != TX_DEST_RAW || s_axis_rawrec.tvalid);

// per-packet fields
logic [31:0] flags_reg = '0;
logic [31:0] len_sum_reg = '0;
logic [47:0] dst_mac_reg = '0;
logic [47:0] src_mac_reg = '0;
logic [31:0] dst_ip_reg = '0;
logic [31:0] src_ip_reg = '0;
logic [15:0] dst_port_reg = '0;
logic [15:0] src_port_reg = '0;
logic [7:0]  ttl_reg = '0;
logic [15:0] ip_id_reg = '0;
logic [15:0] ip_id_cnt_reg = '0;

// UDP checksum adjustment pipeline (see header comment)
logic [20:0] common_reg = '0;    // UDP length + 17 + IP address words
logic [16:0] ports_reg = '0;
logic [19:0] k_reg = '0;         // K as accumulated by the deparser
logic [15:0] t_reg = '0;         // correct 16-bit ones'-complement sum
logic [15:0] psum_adj_reg = '0;  // payload sum passed to the deparser

wire [15:0] l4len = len_sum_reg[15:0] + 16'd8;

function automatic logic [15:0] csum_adjust(input logic [15:0] t, input logic [19:0] k);
    logic [17:0] a;
    logic [17:0] kh;
    kh = 18'(k[19:16]);
    a = 18'(k[15:0]) + kh;
    if (18'(t) >= a) begin
        csum_adjust = 16'(18'(t) - a);                          // no carries
    end else if (18'(t) >= kh + 18'd1) begin
        csum_adjust = 16'(18'(t) + 18'h0FFFF - a);              // l4[15:0] wraps once
    end else if (18'(t) < kh && a <= 18'h10000 + 18'(t)) begin
        csum_adjust = 16'(18'h10000 + 18'(t) - a);              // the single fold wraps
    end else if (a <= 18'h0FFFF) begin
        csum_adjust = 16'(18'h0FFFF - a);                       // unreachable T: checksum 0
    end else begin
        csum_adjust = 16'(18'h1FFFE - a);
    end
endfunction

// output stage copy of the fields the beats need
logic [31:0] q_flags_reg = '0;
logic [15:0] q_len_reg = '0;
logic [15:0] q_psum_reg = '0;
logic [47:0] q_dst_mac_reg = '0;
logic [47:0] q_src_mac_reg = '0;
logic [31:0] q_dst_ip_reg = '0;
logic [31:0] q_src_ip_reg = '0;
logic [15:0] q_dst_port_reg = '0;
logic [15:0] q_src_port_reg = '0;
logic [7:0]  q_ttl_reg = '0;
logic [15:0] q_ip_id_reg = '0;

// output register
logic [63:0] o_data_reg = '0;
logic        o_last_reg = 1'b0;
logic        o_valid_reg = 1'b0;

assign m_axis_meta.tdata  = o_data_reg;
assign m_axis_meta.tkeep  = '1;
assign m_axis_meta.tstrb  = '1;
assign m_axis_meta.tlast  = o_last_reg;
assign m_axis_meta.tid    = '0;
assign m_axis_meta.tdest  = '0;
assign m_axis_meta.tuser  = '0;
assign m_axis_meta.tvalid = o_valid_reg;

assign s_axis_len.tready   = start;
assign s_axis_emeta.tready = start && len_dest == TX_DEST_ECHO;
assign s_axis_rawrec.tready = start && len_dest == TX_DEST_RAW;

echo_rec_t em;
assign em = echo_rec_t'(s_axis_emeta.tdata);

lat_rec_t rawrec, lrec;
assign rawrec = lat_rec_t'(s_axis_rawrec.tdata);
always_comb begin
    lrec = '0;
    if (len_dest == TX_DEST_ECHO) begin
        lrec.want  = cfg_lat_en;
        lrec.bank  = 2'd0;
        lrec.rx_ts = em.rx_ts;
    end else if (len_dest == TX_DEST_RAW) begin
        lrec.want  = cfg_lat_en && rawrec.want;
        lrec.bank  = rawrec.bank;
        lrec.rx_ts = rawrec.rx_ts;
    end
end

assign m_axis_lrec.tdata  = lrec;
assign m_axis_lrec.tkeep  = '1;
assign m_axis_lrec.tstrb  = '1;
assign m_axis_lrec.tlast  = 1'b1;
assign m_axis_lrec.tid    = '0;
assign m_axis_lrec.tdest  = '0;
assign m_axis_lrec.tuser  = '0;
assign m_axis_lrec.tvalid = start;

wire o_free = !o_valid_reg || m_axis_meta.tready;
wire o_load = o_busy_reg && o_free;
// hand the finished descriptor over when the output stage is idle or loads its last beat
wire handoff = busy_reg && prep_reg == 3'd0 && (!o_busy_reg || (o_load && beat_reg == 4'd15));

// beat contents (docs/DESIGN_SPEC.md §4)
logic [63:0] beat;
always_comb begin
    beat = '0;
    case (beat_reg)
        4'd0:  beat = {q_psum_reg, q_len_reg, q_flags_reg};            // sum, len, flags
        4'd3:  beat = {16'd0, q_dst_mac_reg};                          // bytes 24..29
        4'd4:  beat = {8'h00, 8'h08, q_src_mac_reg};                   // 32..37, ethertype 0x0800 (BE)
        4'd7:  beat = {8'h00, 8'h00, q_ip_id_reg, 8'h00, 8'h00, q_ttl_reg, 8'd17}; // proto 56, TTL 57, ID 60..61, DSCP 63
        4'd8:  beat = {32'd0, q_dst_ip_reg};                           // 64..67
        4'd10: beat = {32'd0, q_src_ip_reg};                           // 80..83
        4'd12: beat = {32'd0, q_src_port_reg, q_dst_port_reg};         // 96..97 dst, 98..99 src
        default: beat = '0;
    endcase
end

always_ff @(posedge clk) begin
    ev_raw  <= 1'b0;
    ev_echo <= 1'b0;
    ev_sock <= 1'b0;
    ev_gen  <= 1'b0;

    if (start) begin
        busy_reg    <= 1'b1;
        prep_reg    <= (len_dest == TX_DEST_RAW) ? 3'd0 : 3'd4;
        len_sum_reg <= s_axis_len.tdata;
        psum_adj_reg <= s_axis_len.tdata[31:16];
        ttl_reg     <= cfg_ttl;
        ip_id_reg   <= ip_id_cnt_reg;
        case (len_dest)
            TX_DEST_ECHO: begin
                flags_reg    <= (32'd1 << FLG_EN) | (32'd1 << FLG_IPV4) | (32'd1 << FLG_UDP);
                dst_mac_reg  <= em.src_mac;
                src_mac_reg  <= em.dst_mac;
                dst_ip_reg   <= em.src_ip;
                src_ip_reg   <= em.dst_ip;
                dst_port_reg <= em.src_port;
                src_port_reg <= em.dst_port;
                ip_id_cnt_reg <= ip_id_cnt_reg + 16'd1;
                ev_echo      <= 1'b1;
            end
            TX_DEST_SOCK: begin
                flags_reg    <= (32'd1 << FLG_EN) | (32'd1 << FLG_IPV4) | (32'd1 << FLG_UDP);
                dst_mac_reg  <= cfg_sock_remote_mac;
                src_mac_reg  <= cfg_local_mac;
                dst_ip_reg   <= cfg_sock_remote_ip;
                src_ip_reg   <= cfg_local_ip;
                dst_port_reg <= cfg_sock_remote_port;
                src_port_reg <= cfg_sock_local_port;
                ip_id_cnt_reg <= ip_id_cnt_reg + 16'd1;
                ev_sock      <= 1'b1;
            end
            TX_DEST_GEN: begin
                flags_reg    <= (32'd1 << FLG_EN) | (32'd1 << FLG_IPV4) | (32'd1 << FLG_UDP);
                dst_mac_reg  <= cfg_gen_dst_mac;
                src_mac_reg  <= cfg_local_mac;
                dst_ip_reg   <= cfg_gen_dst_ip;
                src_ip_reg   <= cfg_local_ip;
                dst_port_reg <= cfg_gen_dst_port;
                src_port_reg <= cfg_gen_src_port;
                ip_id_cnt_reg <= ip_id_cnt_reg + 16'd1;
                ev_gen       <= 1'b1;
            end
            default: begin
                // raw: FLG_EN = 0, everything else zero
                flags_reg    <= '0;
                dst_mac_reg  <= '0;
                src_mac_reg  <= '0;
                dst_ip_reg   <= '0;
                src_ip_reg   <= '0;
                dst_port_reg <= '0;
                src_port_reg <= '0;
                ev_raw       <= 1'b1;
            end
        endcase
    end

    // checksum adjustment pipeline (prep_reg 4 -> 0)
    case (prep_reg)
        3'd4: begin
            common_reg <= 21'(l4len) + 21'd17 +
                          21'({dst_ip_reg[7:0], dst_ip_reg[15:8]}) + 21'({dst_ip_reg[23:16], dst_ip_reg[31:24]}) +
                          21'({src_ip_reg[7:0], src_ip_reg[15:8]}) + 21'({src_ip_reg[23:16], src_ip_reg[31:24]});
            ports_reg  <= 17'(dst_port_reg) + 17'(src_port_reg);
        end
        3'd3: begin
            k_reg <= 20'(l4len) + 20'(ports_reg) + 20'(common_reg[15:0]) + 20'(common_reg[20:16]);
        end
        3'd2: begin
            logic [20:0] s1;
            logic [16:0] f1;
            s1 = 21'(len_sum_reg[31:16]) + 21'(k_reg);
            f1 = 17'(s1[15:0]) + 17'(s1[20:16]);
            t_reg <= f1[15:0] + 16'(f1[16]);
        end
        3'd1: begin
            psum_adj_reg <= csum_adjust(t_reg, k_reg);
        end
        default: ;
    endcase
    if (prep_reg != 3'd0) begin
        prep_reg <= prep_reg - 3'd1;
    end

    // output stage
    if (o_free) begin
        o_valid_reg <= 1'b0;
    end
    if (o_load) begin
        o_data_reg  <= beat;
        o_last_reg  <= beat_reg == 4'd15;
        o_valid_reg <= 1'b1;
        beat_reg    <= beat_reg + 4'd1;
        if (beat_reg == 4'd15) begin
            o_busy_reg <= 1'b0;
        end
    end
    if (handoff) begin
        busy_reg       <= 1'b0;
        o_busy_reg     <= 1'b1;
        beat_reg       <= '0;
        q_flags_reg    <= flags_reg;
        q_len_reg      <= len_sum_reg[15:0];
        q_psum_reg     <= psum_adj_reg;
        q_dst_mac_reg  <= dst_mac_reg;
        q_src_mac_reg  <= src_mac_reg;
        q_dst_ip_reg   <= dst_ip_reg;
        q_src_ip_reg   <= src_ip_reg;
        q_dst_port_reg <= dst_port_reg;
        q_src_port_reg <= src_port_reg;
        q_ttl_reg      <= ttl_reg;
        q_ip_id_reg    <= ip_id_reg;
    end

    if (rst) begin
        busy_reg      <= 1'b0;
        o_busy_reg    <= 1'b0;
        prep_reg      <= '0;
        beat_reg      <= '0;
        o_valid_reg   <= 1'b0;
        ip_id_cnt_reg <= '0;
        ev_raw        <= 1'b0;
        ev_echo       <= 1'b0;
        ev_sock       <= 1'b0;
        ev_gen        <= 1'b0;
    end
end

endmodule

`resetall

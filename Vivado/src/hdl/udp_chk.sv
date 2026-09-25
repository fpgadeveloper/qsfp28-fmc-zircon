// SPDX-License-Identifier: MIT
//
// udp_chk - line-rate checker of udp_gen datagrams (rx_dispatch CHK route).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). See
// docs/DESIGN_SPEC.md §10 for the payload definition and the registers.
//
// Input: the UDP payload of every datagram rx_dispatch routed to the checker
// (42-byte header stripped, trimmed to the UDP length, payload byte 0 in lane 0 of
// the first beat, tkeep contiguous). The checker never back-pressures
// (tready = 1) and takes one beat per cycle.
//
// Per datagram:
//   * payload < 8 bytes (no complete sequence number): CHK_LEN_ERR only.
//   * otherwise: CHK_RX_PKTS += 1, CHK_RX_BYTES += payload bytes; the sequence
//     number S (bytes 0..7, LE) is compared with the expected value: the first
//     datagram after enable / CHK_CTRL.CLR only synchronises; a mismatch counts
//     CHK_SEQ_ERR once and resynchronises; expected := S + 1 in every case.
//   * the PRBS is regenerated from S (udp_gen, zircon_nic_pkg) and CHK_BIT_ERR
//     accumulates popcount(payload XOR pattern) over bytes 8..len-1.
//
// Pipeline (all registered, one beat per cycle):
//   A  input register; lane states x_j <= xs64(seed(S)) on the first beat,
//      xs64(x_j) on the others, so x holds the pattern of the beat in A
//   B  error bits (512, masked by tkeep and the sequence bytes), keep popcounts,
//      sequence compare
//   C  16 x popcount32        D  4 x sum of 4        E  sum of 4 (<= 512)
//   F  64-bit accumulate

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_chk
    import zircon_nic_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic         resync,     // single-cycle: forget the expected sequence number
    input  wire logic         stat_clr,   // single-cycle: counters to 0

    taxi_axis_if.snk          s_axis,     // UDP payloads

    output logic              sync,
    output logic [31:0]       rx_pkts,
    output logic [63:0]       rx_bytes,
    output logic [31:0]       seq_err,
    output logic [63:0]       bit_err,
    output logic [31:0]       len_err
);

localparam int DATA_W = s_axis.DATA_W;
localparam int KEEP_W = s_axis.KEEP_W;

if (DATA_W != 512 || KEEP_W != 64)
    $fatal(0, "Error: udp_chk requires a 512-bit byte-granular stream (instance %m)");

assign s_axis.tready = 1'b1;

function automatic logic [6:0] popcnt32(input logic [31:0] v);
    popcnt32 = '0;
    for (int i = 0; i < 32; i++) popcnt32 = popcnt32 + 7'(v[i]);
endfunction

// ---- stage A ----
logic              in_sof_reg = 1'b1;      // next input beat is a datagram's first
logic              a_valid_reg = 1'b0;
logic [DATA_W-1:0] a_data_reg = '0;
logic [KEEP_W-1:0] a_keep_reg = '0;
logic              a_sof_reg = 1'b0;
logic              a_short_reg = 1'b0;
logic [63:0]       x_reg [8];

wire in_valid = s_axis.tvalid;

always_ff @(posedge clk) begin
    a_valid_reg <= in_valid;
    if (in_valid) begin
        in_sof_reg  <= s_axis.tlast;
        a_data_reg  <= s_axis.tdata;
        a_keep_reg  <= s_axis.tkeep;
        a_sof_reg   <= in_sof_reg;
        a_short_reg <= in_sof_reg && s_axis.tlast && !s_axis.tkeep[7];
        for (int j = 0; j < 8; j++) begin
            x_reg[j] <= in_sof_reg ? xs64(prbs_seed(s_axis.tdata[63:0], j)) : xs64(x_reg[j]);
        end
    end
    if (rst) begin
        in_sof_reg  <= 1'b1;
        a_valid_reg <= 1'b0;
    end
end

// ---- stage B ----
logic [DATA_W-1:0] b_err_reg = '0;
logic [6:0]        b_cnt_lo_reg = '0, b_cnt_hi_reg = '0;
logic              b_pkt_reg = 1'b0;       // first beat of a checked datagram
logic              b_seq_bad_reg = 1'b0;
logic              b_len_err_reg = 1'b0;
logic [63:0]       exp_seq_reg = '0;
logic              sync_reg = 1'b0;

wire a_count = a_valid_reg && !a_short_reg;

always_ff @(posedge clk) begin
    for (int i = 0; i < KEEP_W; i++) begin
        b_err_reg[i*8 +: 8] <= (a_data_reg[i*8 +: 8] ^ x_reg[i/8][(i%8)*8 +: 8]) &
                               {8{a_valid_reg && a_keep_reg[i] && !(a_sof_reg && i < 8)}};
    end
    b_cnt_lo_reg  <= a_count ? popcnt32(a_keep_reg[31:0]) : 7'd0;
    b_cnt_hi_reg  <= a_count ? popcnt32(a_keep_reg[63:32]) : 7'd0;
    b_pkt_reg     <= a_count && a_sof_reg;
    b_len_err_reg <= a_valid_reg && a_short_reg;
    b_seq_bad_reg <= 1'b0;
    if (a_count && a_sof_reg) begin
        b_seq_bad_reg <= sync_reg && (a_data_reg[63:0] != exp_seq_reg);
        exp_seq_reg   <= a_data_reg[63:0] + 64'd1;
        sync_reg      <= 1'b1;
    end
    if (resync) begin
        sync_reg <= 1'b0;
    end
    if (rst) begin
        b_pkt_reg     <= 1'b0;
        b_seq_bad_reg <= 1'b0;
        b_len_err_reg <= 1'b0;
        sync_reg      <= 1'b0;
    end
end

assign sync = sync_reg;

// ---- stages C..F: bit error popcount tree ----
logic [5:0]  c_pc_reg [16];
logic [7:0]  d_sum_reg [4];
logic [9:0]  e_sum_reg = '0;
logic [7:0]  c_bytes_reg = '0;

always_ff @(posedge clk) begin
    for (int k = 0; k < 16; k++) begin
        c_pc_reg[k] <= 6'(popcnt32(b_err_reg[k*32 +: 32]));
    end
    for (int k = 0; k < 4; k++) begin
        d_sum_reg[k] <= 8'(c_pc_reg[4*k]) + 8'(c_pc_reg[4*k+1]) + 8'(c_pc_reg[4*k+2]) + 8'(c_pc_reg[4*k+3]);
    end
    e_sum_reg <= 10'(d_sum_reg[0]) + 10'(d_sum_reg[1]) + 10'(d_sum_reg[2]) + 10'(d_sum_reg[3]);
    c_bytes_reg <= 8'(b_cnt_lo_reg) + 8'(b_cnt_hi_reg);

    // counters
    bit_err  <= bit_err + 64'(e_sum_reg);
    rx_bytes <= rx_bytes + 64'(c_bytes_reg);
    if (b_pkt_reg)     rx_pkts <= rx_pkts + 32'd1;
    if (b_seq_bad_reg) seq_err <= seq_err + 32'd1;
    if (b_len_err_reg) len_err <= len_err + 32'd1;

    if (rst || stat_clr) begin
        bit_err  <= '0;
        rx_bytes <= '0;
        rx_pkts  <= '0;
        seq_err  <= '0;
        len_err  <= '0;
    end
    if (rst) begin
        e_sum_reg   <= '0;
        c_bytes_reg <= '0;
        for (int k = 0; k < 16; k++) c_pc_reg[k] <= '0;
        for (int k = 0; k < 4; k++) d_sum_reg[k] <= '0;
    end
end

endmodule

`resetall

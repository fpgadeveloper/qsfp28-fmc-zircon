// SPDX-License-Identifier: MIT
//
// udp_gen - line-rate UDP payload generator (zircon_ip_tx_buffer input 3).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). See
// docs/DESIGN_SPEC.md §10 for the payload definition and the registers.
//
// Emits UDP *payloads* (512 bit, one beat per cycle while tready is high); the
// Ethernet / IPv4 / UDP headers are built later by tx_meta_builder (tdest 3) from
// the GEN_DST_* / GEN_SRC_PORT and local registers, like the hardware socket.
//
// Payload of the datagram with sequence number S (64 bit, counts from 0 after
// GEN_CTRL.CLR):
//   bytes 0..7            : S, little-endian
//   bytes 8..len-1        : beat b (payload bytes 64b..64b+63), bytes 8j..8j+7 =
//                           x_j(b+1) little-endian, j = 0..7, where
//                           x_j(0) = (S ^ PRBS_K[j]) | 2^63, x_j(n+1) = xs64(x_j(n))
//                           (zircon_nic_pkg; beat 0 bytes 0..7 are replaced by S)
// so the checker regenerates every byte from S alone.
//
// Control (all sampled in the core clock domain):
//   * a run starts when cfg_en is 1 and has been 0 since the previous run
//     (rising edge); cfg_cont and cfg_count are sampled at the start.
//   * continuous run: until cfg_en is cleared; count run: cfg_count packets
//     (0 = nothing), or earlier if cfg_en is cleared.
//   * cfg_en cleared: the packet being emitted is finished (never truncated),
//     then the generator idles (a clean stop).
//   * cfg_gap: that many idle cycles (S_GAP) after each packet's last beat, plus
//     the SEED cycle.
//   * cfg_len: payload bytes, clamped to GEN_LEN_MIN..GEN_LEN_MAX, sampled per packet.
//   * clr (GEN_CTRL.CLR): sequence number and counters to 0; stat_clr
//     (CTRL.STAT_CLR): counters only.
// Cost per packet: ceil(len/64) beats + 1 SEED cycle (+ cfg_gap).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_gen
    import zircon_nic_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic         cfg_en,
    input  wire logic         cfg_cont,
    input  wire logic [13:0]  cfg_len,
    input  wire logic [31:0]  cfg_count,
    input  wire logic [31:0]  cfg_gap,
    input  wire logic         clr,        // single-cycle: sequence + counters
    input  wire logic         stat_clr,   // single-cycle: counters

    taxi_axis_if.src          m_axis,     // payload (tdest set by the instantiating module)

    output logic              busy,
    output logic [31:0]       tx_pkts,
    output logic [63:0]       tx_bytes
);

localparam int DATA_W = m_axis.DATA_W;
localparam int KEEP_W = m_axis.KEEP_W;

if (DATA_W != 512 || KEEP_W != 64)
    $fatal(0, "Error: udp_gen requires a 512-bit byte-granular stream (instance %m)");

typedef enum logic [1:0] { S_IDLE, S_SEED, S_DATA, S_GAP } state_t;

state_t      state_reg = S_IDLE;
logic        armed_reg = 1'b1;       // cfg_en seen low since the last run
logic        cont_reg = 1'b0;
logic [31:0] left_reg = '0;          // packets left in a count run
logic [31:0] gap_reg = '0;
logic [63:0] seq_reg = '0;
logic [13:0] len_reg = '0;           // payload bytes of the current packet
logic [13:0] rem_reg = '0;           // bytes still to emit
logic        first_reg = 1'b0;       // next beat is the packet's first
logic [63:0] x_reg [8];              // lane states: pattern of the next beat

logic [DATA_W-1:0] o_data_reg = '0;
logic [KEEP_W-1:0] o_keep_reg = '0;
logic              o_last_reg = 1'b0;
logic              o_valid_reg = 1'b0;

assign m_axis.tdata  = o_data_reg;
assign m_axis.tkeep  = o_keep_reg;
assign m_axis.tstrb  = o_keep_reg;
assign m_axis.tlast  = o_last_reg;
assign m_axis.tvalid = o_valid_reg;
assign m_axis.tid    = '0;
assign m_axis.tdest  = '0;
assign m_axis.tuser  = '0;

assign busy = state_reg != S_IDLE;

wire o_free = !o_valid_reg || m_axis.tready;
wire load   = state_reg == S_DATA && o_free;
wire last   = rem_reg <= 14'(KEEP_W);

// stop after the current packet (evaluated at a packet end and in the gap)
wire stop = !cfg_en || (!cont_reg && left_reg == 32'd0);

wire [13:0] len_clamped = (cfg_len < 14'(GEN_LEN_MIN)) ? 14'(GEN_LEN_MIN) :
                          (cfg_len > 14'(GEN_LEN_MAX)) ? 14'(GEN_LEN_MAX) : cfg_len;

logic [DATA_W-1:0] beat;
always_comb begin
    for (int j = 0; j < 8; j++) begin
        beat[j*64 +: 64] = x_reg[j];
    end
    if (first_reg) begin
        beat[63:0] = seq_reg;
    end
end

always_ff @(posedge clk) begin
    if (!cfg_en) begin
        armed_reg <= 1'b1;
    end

    if (o_valid_reg && m_axis.tready) begin
        o_valid_reg <= 1'b0;
    end

    case (state_reg)
        S_IDLE: begin
            if (cfg_en && armed_reg) begin
                armed_reg <= 1'b0;
                cont_reg  <= cfg_cont;
                left_reg  <= cfg_count;
                if (cfg_cont || cfg_count != 32'd0) begin
                    state_reg <= S_SEED;
                end
            end
        end
        S_SEED: begin
            for (int j = 0; j < 8; j++) begin
                x_reg[j] <= xs64(prbs_seed(seq_reg, j));
            end
            len_reg   <= len_clamped;
            rem_reg   <= len_clamped;
            first_reg <= 1'b1;
            state_reg <= S_DATA;
        end
        S_DATA: begin
            if (load) begin
                o_data_reg  <= beat;
                o_keep_reg  <= last ? keep_mask64(8'(rem_reg)) : '1;
                o_last_reg  <= last;
                o_valid_reg <= 1'b1;
                first_reg   <= 1'b0;
                rem_reg     <= rem_reg - 14'(KEEP_W);
                for (int j = 0; j < 8; j++) begin
                    x_reg[j] <= xs64(x_reg[j]);
                end
                if (last) begin
                    seq_reg  <= seq_reg + 64'd1;
                    tx_pkts  <= tx_pkts + 32'd1;
                    tx_bytes <= tx_bytes + 64'(len_reg);
                    if (!cont_reg) begin
                        left_reg <= left_reg - 32'd1;
                    end
                    gap_reg <= cfg_gap;
                    if (cfg_gap != 32'd0) begin
                        state_reg <= S_GAP;
                    end else if (!cfg_en || (!cont_reg && left_reg == 32'd1)) begin
                        state_reg <= S_IDLE;
                    end else begin
                        state_reg <= S_SEED;
                    end
                end
            end
        end
        S_GAP: begin
            // gap_reg counts the idle cycles still owed (>= 1 on entry)
            if (stop) begin
                state_reg <= S_IDLE;
            end else if (gap_reg == 32'd1) begin
                state_reg <= S_SEED;
            end
            gap_reg <= gap_reg - 32'd1;
        end
        default: state_reg <= S_IDLE;
    endcase

    if (clr) begin
        seq_reg <= '0;
    end
    if (clr || stat_clr) begin
        tx_pkts  <= '0;
        tx_bytes <= '0;
    end

    if (rst) begin
        state_reg   <= S_IDLE;
        armed_reg   <= 1'b1;
        o_valid_reg <= 1'b0;
        first_reg   <= 1'b0;
        seq_reg     <= '0;
        tx_pkts     <= '0;
        tx_bytes    <= '0;
    end
end

endmodule

`resetall

// SPDX-License-Identifier: MIT
//
// latency_stats - per-bank latency statistics and histograms with a coherent
// snapshot readable over AXI-Lite (1.3.0, docs/DESIGN_SPEC.md §11).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Core clock domain. Consumes lat_sample_t {bank, implausible, delta_ns} and
// keeps, per bank (LAT_BANKS = 2): COUNT (64), SUM (64, ns), SUMSQ (64, ns^2,
// saturating), MIN / MAX / LAST (32, ns), IMPLAUSIBLE (32: samples >= 1 s, not
// accumulated anywhere else) and a 64-bin histogram of 48-bit counters:
//   x = delta - BASE (BASE, SHIFT per bank, W = 2^SHIFT ns), q = x >> SHIFT
//   bin 0..47   q (linear); samples below BASE are counted in bin 0
//   bin 48..62  48*2^k <= q < 48*2^(k+1), bin = 48 + k (doubling from the linear top)
//   bin 63      q >= 48*2^15 (overflow)
// BASE / SHIFT come from LAT_BIN_BASE / LAT_BIN_WIDTH (zircon_regs; one setting for
// both banks in 1.3.0, the ports are per bank). Default BASE 0, W 64 ns: linear
// 0..3.07 us, doubling bins to 100.7 ms, overflow above.
//
// One sample takes 5 cycles (IDLE, P1..P4), far below the TX packet rate.
// Commands (edges of the cfg toggles, which cross from the AXI-Lite domain as
// one coherent word): CLEAR bank b (64-cycle sweep of its bins + scalars) and
// SNAPSHOT (copies every bank's scalars and bins into the shadow RAM, ~300
// cycles). While a command runs, samples wait in the input FIFO, so a snapshot is
// coherent: all its values describe the same set of samples. cmd_ack_toggle then
// takes the value of cmd_req_toggle the command was issued with (LAT_CTRL.BUSY).
// After reset every bank is cleared (the bin RAM has no reset).
//
// Shadow RAM (512 x 32, one BRAM18): written here, read by zircon_regs on
// rd_clk (ui_clk) with one cycle of latency; word address = AXI byte address / 4:
//   0x080 + 16b + w  bank b scalars: w 0 COUNT_LO 1 COUNT_HI 2 SUM_LO 3 SUM_HI
//                    4 SUMSQ_LO 5 SUMSQ_HI 6 MIN 7 MAX 8 IMPLAUSIBLE 9 LAST
//                    10 BIN_BASE 11 BIN_WIDTH (ns; the geometry at snapshot time) 12..15 0
//   0x100 + 128b + 2i (+1)  bank b bin i: LO = [31:0], HI = [47:32]
// Nothing is written there except by a snapshot, and software reads it only
// after LAT_CTRL.BUSY has cleared, so the two clock domains never access the
// same word at the same time (a true dual-clock block RAM, no CDC logic).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module latency_stats
    import zircon_nic_pkg::*;
(
    input  wire logic                         clk,
    input  wire logic                         rst,

    taxi_axis_if.snk                          s_axis_sample,   // lat_sample_t

    input  wire logic [LAT_BANKS-1:0][31:0]   cfg_base,
    input  wire logic [LAT_BANKS-1:0][4:0]    cfg_shift,
    input  wire logic                         cmd_req_toggle,
    input  wire logic                         cmd_snap_toggle,
    input  wire logic [LAT_BANKS-1:0]         cmd_clr_toggle,
    output logic                              cmd_ack_toggle,

    input  wire logic                         rd_clk,
    input  wire logic [8:0]                   rd_addr,         // AXI byte address [10:2]
    output logic [31:0]                       rd_data
);

if (s_axis_sample.DATA_W != LAT_SAMPLE_W)
    $fatal(0, "Error: sample interface width must be %0d (instance %m)", LAT_SAMPLE_W);

if (LAT_BANKS > 2)
    $fatal(0, "Error: the register map has room for 2 banks (instance %m)");

localparam int BW = (LAT_BANKS > 1) ? $clog2(LAT_BANKS) : 1;

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------
typedef enum logic [3:0] { S_CLR, S_IDLE, S_P1, S_P2, S_P3, S_P4, S_CMD, S_SNAP_SC, S_SNAP_BIN, S_ACK } state_t;
state_t state_reg = S_CLR;

logic [63:0] cnt_reg  [LAT_BANKS];
logic [63:0] sum_reg  [LAT_BANKS];
logic [63:0] sq_reg   [LAT_BANKS];
logic [31:0] min_reg  [LAT_BANKS];
logic [31:0] max_reg  [LAT_BANKS];
logic [31:0] imp_reg  [LAT_BANKS];
logic [31:0] last_reg [LAT_BANKS];

// bins: {bank, bin} -> 48-bit counter
logic [47:0] bin_ram [LAT_BANKS*64];
logic [47:0] bin_q_reg = '0;
logic [BW+5:0] bin_raddr;
logic          bin_we;
logic [BW+5:0] bin_waddr;
logic [47:0]   bin_wdata;

initial begin
    for (int i = 0; i < LAT_BANKS*64; i++) bin_ram[i] = '0;
end

always_ff @(posedge clk) begin
    if (bin_we) bin_ram[bin_waddr] <= bin_wdata;
    bin_q_reg <= bin_ram[bin_raddr];
end

// shadow RAM (dual clock)
(* ram_style = "block" *) logic [31:0] sh_ram [512];
logic        sh_we;
logic [8:0]  sh_waddr;
logic [31:0] sh_wdata;

initial begin
    for (int i = 0; i < 512; i++) sh_ram[i] = '0;
end

always_ff @(posedge clk) begin
    if (sh_we) sh_ram[sh_waddr] <= sh_wdata;
end

always_ff @(posedge rd_clk) begin
    rd_data <= sh_ram[rd_addr];
end

// ---------------------------------------------------------------------------
// sample pipeline registers
// ---------------------------------------------------------------------------
lat_sample_t smp_in;
assign smp_in = lat_sample_t'(s_axis_sample.tdata);

logic [BW-1:0] b_reg = '0;
logic [31:0]   d_reg = '0;
logic          neg_reg = 1'b0;
logic [31:0]   x_reg = '0;
logic [31:0]   q_reg = '0;
logic [5:0]    bin_reg = '0;
logic [31:0]   a_reg = '0;          // multiplier input
logic [63:0]   m1_reg = '0, m2_reg = '0;

function automatic logic [5:0] bin_of(input logic neg, input logic [31:0] q);
    logic [3:0] k;
    if (neg) return 6'd0;
    if (q < 32'd48) return 6'(q);
    k = '0;
    for (int j = 1; j <= 15; j++) begin
        if (q >= (32'd48 << j)) k = k + 4'd1;
    end
    return 6'd48 + 6'(k);
endfunction

// commands
logic                 req_seen_reg = 1'b0;
logic                 snap_seen_reg = 1'b0;
logic [LAT_BANKS-1:0] clr_seen_reg = '0;
logic                 req_cur_reg = 1'b0;     // request being served
logic                 do_snap_reg = 1'b0;
logic [LAT_BANKS-1:0] do_clr_reg = '1;        // banks to clear (all after reset)

wire cmd_pending = cmd_req_toggle != req_seen_reg;

// sweep counters
logic [BW-1:0] sw_bank_reg = '0;
logic [6:0]    sw_idx_reg = '0;           // CLR: bin 0..63; SNAP_SC: word 0..15; SNAP_BIN: 0..127
logic          sw_wr_reg = 1'b0;          // SNAP_BIN: bin RAM output valid for sw_prev
logic [6:0]    sw_prev_reg = '0;
logic [BW-1:0] sw_prev_bank_reg = '0;

// scalar word w of bank b
function automatic logic [31:0] scalar_word(input int b, input logic [3:0] w,
                                            input logic [63:0] c, input logic [63:0] s, input logic [63:0] q,
                                            input logic [31:0] mn, input logic [31:0] mx, input logic [31:0] im,
                                            input logic [31:0] ls, input logic [31:0] base, input logic [4:0] sh);
    case (w)
        4'd0:  return c[31:0];
        4'd1:  return c[63:32];
        4'd2:  return s[31:0];
        4'd3:  return s[63:32];
        4'd4:  return q[31:0];
        4'd5:  return q[63:32];
        4'd6:  return mn;
        4'd7:  return mx;
        4'd8:  return im;
        4'd9:  return ls;
        4'd10: return base;
        4'd11: return 32'd1 << sh;
        default: return 32'd0;
    endcase
endfunction

logic [31:0] sc_word;
always_comb begin
    sc_word = '0;
    for (int b = 0; b < LAT_BANKS; b++) begin
        if (sw_bank_reg == BW'(b)) begin
            sc_word = scalar_word(b, sw_idx_reg[3:0], cnt_reg[b], sum_reg[b], sq_reg[b], min_reg[b],
                                  max_reg[b], imp_reg[b], last_reg[b], cfg_base[b], cfg_shift[b]);
        end
    end
end

// bin RAM ports
always_comb begin
    bin_raddr = {b_reg, bin_of(neg_reg, q_reg)};                  // P3
    if (state_reg == S_SNAP_BIN) bin_raddr = {sw_bank_reg, sw_idx_reg[6:1]};
    bin_we    = 1'b0;
    bin_waddr = {b_reg, bin_reg};
    bin_wdata = bin_q_reg + 48'd1;
    if (state_reg == S_P4) begin
        bin_we = 1'b1;
    end
    if (state_reg == S_CLR) begin
        bin_we    = do_clr_reg[sw_bank_reg];
        bin_waddr = {sw_bank_reg, sw_idx_reg[5:0]};
        bin_wdata = '0;
    end
end

// shadow write port
always_comb begin
    sh_we    = 1'b0;
    sh_waddr = 9'h080 + {sw_bank_reg, 4'd0} + 9'(sw_idx_reg[3:0]);
    sh_wdata = sc_word;
    if (state_reg == S_SNAP_SC && !sw_wr_reg) begin
        sh_we = 1'b1;
    end
    if (sw_wr_reg) begin
        sh_we    = 1'b1;
        sh_waddr = 9'h100 + {sw_prev_bank_reg, 7'd0} + 9'(sw_prev_reg);
        sh_wdata = sw_prev_reg[0] ? {16'd0, bin_q_reg[47:32]} : bin_q_reg[31:0];
    end
end

assign s_axis_sample.tready = state_reg == S_IDLE && !cmd_pending;

wire [64:0] sq_sum = {1'b0, sq_reg[b_reg]} + {1'b0, m2_reg};

always_ff @(posedge clk) begin
    // multiplier pipeline (DSP): a -> m1 -> m2
    m1_reg <= a_reg * a_reg;
    m2_reg <= m1_reg;

    sw_wr_reg <= 1'b0;

    case (state_reg)
        S_CLR: begin
            // clear the banks in do_clr_reg, one bin per cycle (all banks in parallel
            // is not possible: one RAM port), 64 cycles per bank
            sw_idx_reg <= sw_idx_reg + 7'd1;
            if (sw_idx_reg[5:0] == 6'd63) begin
                sw_idx_reg <= '0;
                for (int b = 0; b < LAT_BANKS; b++) begin
                    if (sw_bank_reg == BW'(b) && do_clr_reg[b]) begin
                        cnt_reg[b]  <= '0;
                        sum_reg[b]  <= '0;
                        sq_reg[b]   <= '0;
                        min_reg[b]  <= '1;
                        max_reg[b]  <= '0;
                        imp_reg[b]  <= '0;
                        last_reg[b] <= '0;
                    end
                end
                if (sw_bank_reg == BW'(LAT_BANKS - 1)) begin
                    sw_bank_reg <= '0;
                    do_clr_reg  <= '0;
                    state_reg   <= do_snap_reg ? S_SNAP_SC : (req_cur_reg != cmd_ack_toggle ? S_ACK : S_IDLE);
                end else begin
                    sw_bank_reg <= sw_bank_reg + 1'b1;
                end
            end
        end
        S_IDLE: begin
            sw_idx_reg  <= '0;
            sw_bank_reg <= '0;
            if (cmd_pending) begin
                state_reg <= S_CMD;
            end else if (s_axis_sample.tvalid) begin
                b_reg <= BW'(smp_in.bank);
                d_reg <= smp_in.delta_ns;
                a_reg <= smp_in.delta_ns;
                if (smp_in.implausible || smp_in.bank >= 2'(LAT_BANKS)) begin
                    for (int b = 0; b < LAT_BANKS; b++) begin
                        if (smp_in.bank == 2'(b)) imp_reg[b] <= imp_reg[b] + 32'd1;
                    end
                end else begin
                    state_reg <= S_P1;
                end
            end
        end
        S_P1: begin
            {neg_reg, x_reg} <= {1'b0, d_reg} - {1'b0, cfg_base[b_reg]};
            state_reg <= S_P2;
        end
        S_P2: begin
            q_reg <= x_reg >> cfg_shift[b_reg];
            state_reg <= S_P3;
        end
        S_P3: begin
            bin_reg <= bin_of(neg_reg, q_reg);   // RAM read issued with the same address
            state_reg <= S_P4;
        end
        S_P4: begin
            // bin written above (bin_q_reg + 1); scalars
            cnt_reg[b_reg]  <= cnt_reg[b_reg] + 64'd1;
            sum_reg[b_reg]  <= sum_reg[b_reg] + 64'(d_reg);
            sq_reg[b_reg]   <= sq_sum[64] ? '1 : sq_sum[63:0];
            if (d_reg < min_reg[b_reg]) min_reg[b_reg] <= d_reg;
            if (d_reg > max_reg[b_reg]) max_reg[b_reg] <= d_reg;
            last_reg[b_reg] <= d_reg;
            state_reg <= S_IDLE;
        end
        S_CMD: begin
            // latch the command (the cfg word arrived coherently)
            req_seen_reg  <= cmd_req_toggle;
            req_cur_reg   <= cmd_req_toggle;
            snap_seen_reg <= cmd_snap_toggle;
            clr_seen_reg  <= cmd_clr_toggle;
            do_snap_reg   <= cmd_snap_toggle != snap_seen_reg;
            do_clr_reg    <= cmd_clr_toggle ^ clr_seen_reg;
            sw_idx_reg    <= '0;
            sw_bank_reg   <= '0;
            if ((cmd_clr_toggle ^ clr_seen_reg) != '0) begin
                state_reg <= S_CLR;
            end else if (cmd_snap_toggle != snap_seen_reg) begin
                state_reg <= S_SNAP_SC;
            end else begin
                state_reg <= S_ACK;
            end
        end
        S_SNAP_SC: begin
            // scalar words of bank sw_bank_reg (written through sh_* above; the
            // first cycle after the previous bank's bins may still hold that
            // bank's last bin write)
            if (!sw_wr_reg) begin
                sw_idx_reg <= sw_idx_reg + 7'd1;
                if (sw_idx_reg[3:0] == 4'd15) begin
                    sw_idx_reg <= '0;
                    state_reg  <= S_SNAP_BIN;
                end
            end
        end
        S_SNAP_BIN: begin
            // bin RAM read of bin idx/2 this cycle, shadow write next cycle
            sw_wr_reg        <= 1'b1;
            sw_prev_reg      <= sw_idx_reg;
            sw_prev_bank_reg <= sw_bank_reg;
            sw_idx_reg       <= sw_idx_reg + 7'd1;
            if (sw_idx_reg == 7'd127) begin
                sw_idx_reg <= '0;
                if (sw_bank_reg == BW'(LAT_BANKS - 1)) begin
                    sw_bank_reg <= '0;
                    do_snap_reg <= 1'b0;
                    state_reg   <= S_ACK;
                end else begin
                    sw_bank_reg <= sw_bank_reg + 1'b1;
                    state_reg   <= S_SNAP_SC;
                end
            end
        end
        S_ACK: begin
            // the last bin write (sw_wr_reg) completes in this cycle
            cmd_ack_toggle <= req_cur_reg;
            state_reg <= S_IDLE;
        end
        default: state_reg <= S_IDLE;
    endcase

    if (rst) begin
        state_reg      <= S_CLR;
        do_clr_reg     <= '1;
        do_snap_reg    <= 1'b0;
        sw_idx_reg     <= '0;
        sw_bank_reg    <= '0;
        sw_wr_reg      <= 1'b0;
        req_seen_reg   <= 1'b0;
        req_cur_reg    <= 1'b0;
        snap_seen_reg  <= 1'b0;
        clr_seen_reg   <= '0;
        cmd_ack_toggle <= 1'b0;
    end
end

endmodule

`resetall

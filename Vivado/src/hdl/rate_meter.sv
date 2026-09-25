// SPDX-License-Identifier: MIT
//
// rate_meter - RX / TX throughput over fixed windows of the core clock.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). See
// docs/DESIGN_SPEC.md §10.
//
// Inputs are free-running cumulative counters (never cleared by CTRL.STAT_CLR, so
// clearing the statistics never disturbs a measurement): RX = frames / bytes that
// entered the core (the RX_FRAMES / RX_BYTES events), TX = frames / bytes handed to
// the MAC (tx_mac_out, crossed from the MAC TX clock by a coherent snapshot, so the
// TX counts lag by a constant < 100 ns).
// Every WINDOW cycles (1 s at 300 MHz by default) the four deltas since the
// previous window boundary are latched together in one cycle and seq increments,
// so software sees a new sample whenever RATE_SEQ changes.
// Robustness: after reset the window counter waits PRIME cycles and then takes the
// cumulative counters as the reference (the TX snapshot has arrived by then), so the
// first sample covers exactly one window. A cumulative counter that restarted during
// a window (its side was reset, e.g. a MAC TX reset on a link flap) is detected by
// its 64-bit byte count going backwards (it never wraps); the sample then reports
// the counts since that restart instead of a wrapped difference.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rate_meter #(
    parameter int unsigned WINDOW = 300_000_000   // core clock cycles per window
) (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic [31:0]  rx_pkts_cum,
    input  wire logic [63:0]  rx_bytes_cum,
    input  wire logic [31:0]  tx_pkts_cum,
    input  wire logic [63:0]  tx_bytes_cum,

    output logic [31:0]       seq,
    output logic [31:0]       rx_pkts,
    output logic [63:0]       rx_bytes,
    output logic [31:0]       tx_pkts,
    output logic [63:0]       tx_bytes
);

localparam int PRIME = 127;   // > the TX snapshot's latency after reset

if (WINDOW < 16)
    $fatal(0, "Error: rate_meter WINDOW must be >= 16 cycles (instance %m)");

logic [31:0] cnt_reg = '0;
logic        tick_reg = 1'b0;
logic        primed_reg = 1'b0;
logic [6:0]  prime_cnt_reg = '0;

logic [31:0] rx_pkts_prev_reg = '0, tx_pkts_prev_reg = '0;
logic [63:0] rx_bytes_prev_reg = '0, tx_bytes_prev_reg = '0;

always_ff @(posedge clk) begin
    // window counter (registered tick keeps the 32-bit compare off the latch path)
    tick_reg <= primed_reg && cnt_reg == 32'(WINDOW - 2);
    if (primed_reg) begin
        cnt_reg <= (cnt_reg == 32'(WINDOW - 1)) ? 32'd0 : cnt_reg + 32'd1;
    end else begin
        prime_cnt_reg <= prime_cnt_reg + 7'd1;
        if (prime_cnt_reg == 7'(PRIME - 1)) begin
            primed_reg        <= 1'b1;
            rx_pkts_prev_reg  <= rx_pkts_cum;
            rx_bytes_prev_reg <= rx_bytes_cum;
            tx_pkts_prev_reg  <= tx_pkts_cum;
            tx_bytes_prev_reg <= tx_bytes_cum;
        end
    end

    if (tick_reg) begin
        // a counter that went backwards was reset: report its count since then
        if (rx_bytes_cum < rx_bytes_prev_reg) begin
            rx_pkts  <= rx_pkts_cum;
            rx_bytes <= rx_bytes_cum;
        end else begin
            rx_pkts  <= rx_pkts_cum - rx_pkts_prev_reg;
            rx_bytes <= rx_bytes_cum - rx_bytes_prev_reg;
        end
        if (tx_bytes_cum < tx_bytes_prev_reg) begin
            tx_pkts  <= tx_pkts_cum;
            tx_bytes <= tx_bytes_cum;
        end else begin
            tx_pkts  <= tx_pkts_cum - tx_pkts_prev_reg;
            tx_bytes <= tx_bytes_cum - tx_bytes_prev_reg;
        end
        rx_pkts_prev_reg  <= rx_pkts_cum;
        rx_bytes_prev_reg <= rx_bytes_cum;
        tx_pkts_prev_reg  <= tx_pkts_cum;
        tx_bytes_prev_reg <= tx_bytes_cum;
        seq <= seq + 32'd1;
    end

    if (rst) begin
        cnt_reg  <= '0;
        tick_reg <= 1'b0;
        primed_reg    <= 1'b0;
        prime_cnt_reg <= '0;
        seq      <= '0;
        rx_pkts  <= '0;
        rx_bytes <= '0;
        tx_pkts  <= '0;
        tx_bytes <= '0;
    end
end

endmodule

`resetall

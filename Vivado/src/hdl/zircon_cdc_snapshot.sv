// SPDX-License-Identifier: MIT
//
// zircon_cdc_snapshot - coherent transfer of a multi-bit word (a register set or a
// group of counters) from one clock domain to another.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). It instantiates
// taxi_axis_async_fifo from the Taxi library (CERN-OHL-S-2.0, see
// submodules/README.md).
//
// The source domain pushes its current value into a small taxi_axis_async_fifo
// every cycle the FIFO has room; the destination pops every cycle and holds the
// last word. Every word crosses as a whole (it is written into the FIFO RAM in one
// source cycle and read in one destination cycle), so the destination never sees
// a torn value, and the CDC is covered by Taxi's taxi_axis_async_fifo.tcl timing
// constraints (Gray-coded pointers; no hand-written multi-bit synchroniser).
// Latency: about DEPTH destination cycles when the source is the faster clock.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module zircon_cdc_snapshot #(
    parameter int W = 32,
    parameter logic [W-1:0] INIT = '0,
    parameter int DEPTH = 8
) (
    input  wire logic          src_clk,
    input  wire logic          src_rst,
    input  wire logic [W-1:0]  src_data,

    input  wire logic          dst_clk,
    input  wire logic          dst_rst,
    output logic [W-1:0]       dst_data
);

taxi_axis_if #(.DATA_W(W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_src();
taxi_axis_if #(.DATA_W(W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_dst();

assign axis_src.tdata  = src_data;
assign axis_src.tkeep  = '1;
assign axis_src.tstrb  = '1;
assign axis_src.tlast  = 1'b1;
assign axis_src.tid    = '0;
assign axis_src.tdest  = '0;
assign axis_src.tuser  = '0;
assign axis_src.tvalid = 1'b1;

assign axis_dst.tready = 1'b1;

taxi_axis_async_fifo #(
    .DEPTH(DEPTH),
    .FIFO_RAMSTYLE("distributed"),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
fifo_inst (
    .s_clk(src_clk),
    .s_rst(src_rst),
    .s_axis(axis_src),
    .m_clk(dst_clk),
    .m_rst(dst_rst),
    .m_axis(axis_dst),
    .s_pause_req(1'b0),
    .s_pause_ack(),
    .m_pause_req(1'b0),
    .m_pause_ack(),
    .s_status_depth(),
    .s_status_depth_commit(),
    .s_status_overflow(),
    .s_status_bad_frame(),
    .s_status_good_frame(),
    .m_status_depth(),
    .m_status_depth_commit(),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

always_ff @(posedge dst_clk) begin
    if (axis_dst.tvalid) begin
        dst_data <= axis_dst.tdata;
    end
    if (dst_rst) begin
        dst_data <= INIT;
    end
end

endmodule

`resetall

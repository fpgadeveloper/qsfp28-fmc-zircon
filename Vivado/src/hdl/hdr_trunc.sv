// SPDX-License-Identifier: MIT
//
// hdr_trunc - header truncator for the Zircon RX parser branch.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Passes the first TRUNC_BYTES bytes of every frame, forces tlast on the beat
// that carries byte TRUNC_BYTES-1 (masking tkeep beyond it) and silently
// consumes the rest of the frame at full width (one beat per cycle).
//
// Why: zircon_ip_rx_parse is 32 bits wide and consumes the WHOLE frame it is
// given (it idles with tready=1 until tlast). Feeding it only the header keeps the
// per-packet parse cost at ~TRUNC_BYTES/4 + 3 cycles instead of frame_len/4, so the
// lockstep taxi_axis_broadcast in front of it is never throttled by the payload.
//
// Purely combinational datapath (no added latency); state is a beat counter.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module hdr_trunc #(
    parameter int TRUNC_BYTES = 64
) (
    input  wire logic  clk,
    input  wire logic  rst,

    taxi_axis_if.snk   s_axis,
    taxi_axis_if.src   m_axis
);

localparam int KEEP_W = s_axis.KEEP_W;
localparam int TRUNC_BEATS = (TRUNC_BYTES + KEEP_W - 1) / KEEP_W;
localparam int LAST_BYTES  = TRUNC_BYTES - (TRUNC_BEATS - 1) * KEEP_W;
localparam int CNT_W = TRUNC_BEATS > 1 ? $clog2(TRUNC_BEATS) : 1;
localparam logic [KEEP_W-1:0] LAST_MASK = {KEEP_W{1'b1}} >> (KEEP_W - LAST_BYTES);

if (TRUNC_BYTES < 1)
    $fatal(0, "Error: TRUNC_BYTES must be positive (instance %m)");

if (m_axis.DATA_W != s_axis.DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

logic [CNT_W-1:0] beat_reg = '0;
logic drop_reg = 1'b0;   // header done, discarding the remainder of the frame

wire at_limit = beat_reg == CNT_W'(TRUNC_BEATS - 1);

assign m_axis.tdata  = s_axis.tdata;
assign m_axis.tkeep  = at_limit ? (s_axis.tkeep & LAST_MASK) : s_axis.tkeep;
assign m_axis.tstrb  = m_axis.tkeep;
assign m_axis.tlast  = s_axis.tlast || at_limit;
assign m_axis.tid    = s_axis.tid;
assign m_axis.tdest  = s_axis.tdest;
assign m_axis.tuser  = s_axis.tuser;
assign m_axis.tvalid = s_axis.tvalid && !drop_reg;

assign s_axis.tready = drop_reg || m_axis.tready;

always_ff @(posedge clk) begin
    if (s_axis.tvalid && s_axis.tready) begin
        if (s_axis.tlast) begin
            beat_reg <= '0;
            drop_reg <= 1'b0;
        end else if (!drop_reg) begin
            if (at_limit) begin
                drop_reg <= 1'b1;
            end else begin
                beat_reg <= beat_reg + 1'b1;
            end
        end
    end

    if (rst) begin
        beat_reg <= '0;
        drop_reg <= 1'b0;
    end
end

endmodule

`resetall

// SPDX-License-Identifier: MIT
//
// tx_len_guard - drops UI TX transfers longer than MAX_BYTES before they reach
// zircon_ip_tx_buffer (review #7).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// zircon_ip_tx_buffer is a plain FIFO whose length record only appears after a
// whole frame has passed its len_cksum: a transfer of TX_RAM_SIZE bytes or more
// fills it without ever producing metadata and wedges the TX path (and, through
// the shared arbiter, the hardware echo) until reset. This guard is a Taxi frame
// FIFO of FIFO_BEATS beats in store-and-forward mode:
//   * a frame longer than MAX_BYTES but short enough to fit is marked bad on its
//     last beat (a beat counter, see below) and dropped by DROP_BAD_FRAME;
//   * a frame that does not fit at all (> FIFO_BEATS beats) is dropped by
//     DROP_OVERSIZE_FRAME.
// Either drop pulses ev_drop once (TX_OVERSIZE_DROP). Frames of up to
// MAX_BYTES pass unchanged. Being store-and-forward, it also lets tx_buffer's
// arbiter receive UI frames at the core clock rate instead of holding the
// arbiter for a whole frame at the UI clock rate.
//
// Length check without a popcount: with c = number of beats before the last
// one, Q = MAX_BYTES / KEEP_W and R = MAX_BYTES % KEEP_W, a frame is longer
// than MAX_BYTES iff c > Q, or c == Q and the last beat holds more than R bytes
// (tkeep[R] set; UI TX tkeep is contiguous from byte 0, as the AXI DMA MM2S
// produces it).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tx_len_guard #(
    parameter int MAX_BYTES  = 9618,
    parameter int FIFO_BEATS = 256
) (
    input  wire logic  clk,
    input  wire logic  rst,

    taxi_axis_if.snk   s_axis,
    taxi_axis_if.src   m_axis,

    output wire logic  ev_drop
);

localparam int DATA_W = s_axis.DATA_W;
localparam int KEEP_W = s_axis.KEEP_W;
localparam int Q = MAX_BYTES / KEEP_W;
localparam int R = MAX_BYTES % KEEP_W;
localparam int CW = $clog2(Q + 2) + 1;

if (FIFO_BEATS * KEEP_W <= MAX_BYTES)
    $fatal(0, "Error: FIFO_BEATS must hold a MAX_BYTES frame (instance %m)");

taxi_axis_if #(.DATA_W(DATA_W), .KEEP_W(KEEP_W), .USER_EN(1'b1), .USER_W(1)) axis_mark();

logic [CW-1:0] beats_reg = '0;   // beats of the current frame so far (saturating)

wire over = (beats_reg > CW'(Q)) || (beats_reg == CW'(Q) && s_axis.tkeep[R]);

assign axis_mark.tdata  = s_axis.tdata;
assign axis_mark.tkeep  = s_axis.tkeep;
assign axis_mark.tstrb  = s_axis.tstrb;
assign axis_mark.tlast  = s_axis.tlast;
assign axis_mark.tid    = s_axis.tid;
assign axis_mark.tdest  = s_axis.tdest;
assign axis_mark.tuser  = s_axis.tlast && over;
assign axis_mark.tvalid = s_axis.tvalid;
assign s_axis.tready    = axis_mark.tready;

always_ff @(posedge clk) begin
    if (s_axis.tvalid && s_axis.tready) begin
        if (s_axis.tlast) begin
            beats_reg <= '0;
        end else if (beats_reg <= CW'(Q)) begin
            beats_reg <= beats_reg + 1'b1;
        end
    end
    if (rst) beats_reg <= '0;
end

wire logic fifo_overflow, fifo_bad;

taxi_axis_fifo #(
    .DEPTH(FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b1),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_mark),
    .m_axis(m_axis),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(fifo_overflow),
    .status_bad_frame(fifo_bad),
    .status_good_frame()
);

assign ev_drop = fifo_overflow || fifo_bad;

endmodule

`resetall

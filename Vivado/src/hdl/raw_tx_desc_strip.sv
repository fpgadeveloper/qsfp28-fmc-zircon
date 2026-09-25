// SPDX-License-Identifier: MIT
//
// raw_tx_desc_strip - UI0 (raw) TX: strip an optional 64-byte ZTXT latency
// descriptor from the front of a frame and turn it into a per-frame latency
// record (1.3.0, docs/DESIGN_SPEC.md §11).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Placed after tx_len_guard on the raw path, in front of zircon_ip_tx_buffer
// input 0. For EVERY frame it forwards, it pushes exactly one lat_rec_t on
// m_axis_rec (in frame order; tx_meta_builder pops one per raw packet):
//   * enable = 1 and the first beat is a full 64-byte, non-last beat whose
//     bytes 0..3 are the little-endian u32 RAW_TX_DESC_MAGIC ("ZTXT"): the beat is
//     removed; record = {want = byte 6 bit 0 (TS_REQ), bank = 1,
//     rx_ts = bytes 8..15 (LE u64, MRMAC unit 2^-8 ns) bits 54:7}.
//   * otherwise the frame passes untouched; record = {want 0}.
// A transfer that is only a descriptor (magic on a TLAST beat) is not treated as
// one: a descriptor must be followed by the frame.
// The record is pushed with the frame's first forwarded beat. If the record FIFO
// is full the frame waits (back-pressure to UI0), which never deadlocks: records
// are popped by tx_meta_builder for frames already past this module.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module raw_tx_desc_strip
    import zircon_nic_pkg::*;
(
    input  wire logic   clk,
    input  wire logic   rst,

    input  wire logic   enable,         // LAT_CTRL.RAW_TX_DESC

    taxi_axis_if.snk    s_axis,
    taxi_axis_if.src    m_axis,
    taxi_axis_if.src    m_axis_rec      // lat_rec_t, one per forwarded frame
);

localparam int DATA_W = s_axis.DATA_W;
localparam int KEEP_W = s_axis.KEEP_W;

if (DATA_W != 512 || KEEP_W != 64)
    $fatal(0, "Error: raw_tx_desc_strip needs a 512-bit byte-granular stream (instance %m)");

if (m_axis_rec.DATA_W != LAT_REC_W)
    $fatal(0, "Error: record interface width must be %0d (instance %m)", LAT_REC_W);

logic first_reg = 1'b1;      // the next input beat is a frame's first
logic strip_reg = 1'b0;      // current frame had its descriptor removed (first forwarded beat pending)

wire is_desc = enable && first_reg && s_axis.tvalid && !s_axis.tlast && (&s_axis.tkeep) &&
               s_axis.tdata[31:0] == RAW_TX_DESC_MAGIC;

// the record goes out with the first forwarded beat of a frame
wire rec_beat = first_reg || strip_reg;

lat_rec_t rec_in, rec_hold_reg;
always_comb begin
    rec_in.want  = s_axis.tdata[6*8];
    rec_in.bank  = 2'd1;
    rec_in.rx_ts = s_axis.tdata[8*8 + 7 +: LAT_TS_W];
end

lat_rec_t rec_out;
always_comb begin
    if (strip_reg) begin
        rec_out = rec_hold_reg;
    end else begin
        rec_out = '0;
    end
end

wire fwd_ok = m_axis.tready && (!rec_beat || m_axis_rec.tready);

assign s_axis.tready = is_desc ? 1'b1 : fwd_ok;

assign m_axis.tdata  = s_axis.tdata;
assign m_axis.tkeep  = s_axis.tkeep;
assign m_axis.tstrb  = s_axis.tstrb;
assign m_axis.tlast  = s_axis.tlast;
assign m_axis.tid    = s_axis.tid;
assign m_axis.tdest  = s_axis.tdest;
assign m_axis.tuser  = s_axis.tuser;
assign m_axis.tvalid = s_axis.tvalid && !is_desc && (!rec_beat || m_axis_rec.tready);

assign m_axis_rec.tdata  = rec_out;
assign m_axis_rec.tkeep  = '1;
assign m_axis_rec.tstrb  = '1;
assign m_axis_rec.tlast  = 1'b1;
assign m_axis_rec.tid    = '0;
assign m_axis_rec.tdest  = '0;
assign m_axis_rec.tuser  = '0;
assign m_axis_rec.tvalid = s_axis.tvalid && !is_desc && rec_beat && m_axis.tready;

always_ff @(posedge clk) begin
    if (s_axis.tvalid && s_axis.tready) begin
        if (is_desc) begin
            strip_reg    <= 1'b1;
            rec_hold_reg <= rec_in;
            first_reg    <= 1'b0;
        end else begin
            strip_reg <= 1'b0;
            first_reg <= s_axis.tlast;
        end
    end
    if (rst) begin
        first_reg <= 1'b1;
        strip_reg <= 1'b0;
    end
end

endmodule

`resetall

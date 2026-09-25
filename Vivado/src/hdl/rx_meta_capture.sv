// SPDX-License-Identifier: MIT
//
// rx_meta_capture - compacts the 16x64-bit Zircon parser metadata block into one
// rx_hdr_rec_t record per packet.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). The metadata
// layout is defined by zircon_ip_rx_parse.sv (Taxi, CERN-OHL-S-2.0); see
// docs/DESIGN_SPEC.md §4.
//
// The block is consumed at one beat per cycle (16 cycles/packet, faster than the
// parser produces it), and the record is pushed on the block's tlast beat. The
// record FIFO downstream therefore holds one entry per packet, so it can be sized
// in packets (= frames the store-and-forward packet FIFO can hold) rather than in
// 16x as many metadata beats, and rx_dispatch sees the whole record in one cycle.
// If the record FIFO is full the parser is back-pressured (never a loss).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rx_meta_capture
    import zircon_nic_pkg::*;
(
    input  wire logic  clk,
    input  wire logic  rst,

    taxi_axis_if.snk   s_axis_meta,   // 64-bit, 16 beats per packet
    taxi_axis_if.src   m_axis_rec     // rx_hdr_rec_t, one beat per packet
);

if (s_axis_meta.DATA_W != 64)
    $fatal(0, "Error: metadata interface must be 64 bits (instance %m)");

if (m_axis_rec.DATA_W != RX_HDR_REC_W)
    $fatal(0, "Error: record interface width must be %0d (instance %m)", RX_HDR_REC_W);

logic [3:0] beat_reg = '0;
rx_hdr_rec_t rec_reg = '0;

wire [63:0] d = s_axis_meta.tdata;

assign s_axis_meta.tready = !s_axis_meta.tlast || m_axis_rec.tready;

assign m_axis_rec.tdata  = rec_reg;
assign m_axis_rec.tkeep  = '1;
assign m_axis_rec.tstrb  = '1;
assign m_axis_rec.tlast  = 1'b1;
assign m_axis_rec.tid    = '0;
assign m_axis_rec.tdest  = '0;
assign m_axis_rec.tuser  = '0;
assign m_axis_rec.tvalid = s_axis_meta.tvalid && s_axis_meta.tlast;

always_ff @(posedge clk) begin
    if (s_axis_meta.tvalid && s_axis_meta.tready) begin
        beat_reg <= s_axis_meta.tlast ? 4'd0 : beat_reg + 4'd1;

        case (beat_reg)
            4'd0: begin
                rec_reg.flags   <= d[31:0];
                rec_reg.plen    <= d[47:32];
                rec_reg.pkt_sum <= d[63:48];
            end
            4'd3:  rec_reg.dst_mac  <= d[47:0];   // bytes 24..29
            4'd4:  rec_reg.src_mac  <= d[47:0];   // bytes 32..37
            4'd8:  rec_reg.dst_ip   <= d[31:0];   // bytes 64..67
            4'd10: rec_reg.src_ip   <= d[31:0];   // bytes 80..83
            4'd12: begin
                rec_reg.dst_port <= d[15:0];      // bytes 96..97
                rec_reg.src_port <= d[31:16];     // bytes 98..99
            end
            default: ;
        endcase
    end

    if (rst) begin
        beat_reg <= '0;
    end
end

endmodule

`resetall

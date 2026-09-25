// SPDX-License-Identifier: MIT
//
// ptp_tx_tagger - MAC TX side of the latency measurement (mac_tx_clk domain):
// one MRMAC PTP record per transmitted frame, tag allocation, TX timestamp
// lookup and latency computation (1.3.0, docs/DESIGN_SPEC.md §11).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Input s_axis is the frame stream after tx_mac_out; every beat carries
// tuser = {lat_rec_t, bad}. The record rode in-band with the frame from the
// Zircon concat through the MAC TX frame FIFO, so it is dropped exactly with its
// frame (TX_EN = 0 discard, mac_tx reset) and can never be misaligned.
//
//   SOF gate  when a frame's first beat arrives, its PTP record {tag, op} is
//             pushed into a PTP_FIFO_DEPTH-entry FIFO (m_axis_ptp, to the
//             mrmac_tx_axis_adapter) and the beat is released the next cycle, so
//             the record always precedes the frame (one idle cycle per frame
//             on this 512-bit / 390.625 MHz bus, which has 2x the line rate).
//             op = 2'b10 (two-step) when rec.want, else 2'b00 with tag 0.
//   tags      16-bit sequence number per timestamped frame; entry tag[5:0] of a
//             64-entry pending table holds {tag[15:6], bank, rx_ts}. Reusing an
//             entry whose timestamp never came back counts LOST.
//   return    tx_ptp_tstamp_valid_in: look up tag[5:0], check tag[15:6]; a miss
//             (no pending entry, e.g. a frame sent before a mac_tx reset) counts
//             STALE. A hit yields delta = (tx_ts - {rx_ts, 7'b0}) mod 2^55 in
//             2^-8 ns, >> 8 = ns (registered table read + compare,
//             then a 5-stage pipeline); delta >= 1 s is flagged
//             implausible. The sample {bank, implausible, delta_ns} goes to
//             m_axis_sample (an async FIFO to the statistics engine); if that is
//             full the sample is dropped and counted OVF.
//   reset     rst (mac_tx) clears the pending table, the PTP FIFO and the SOF
//             state; the tag sequence number keeps counting so late timestamps
//             of pre-reset frames cannot match a new entry.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ptp_tx_tagger
    import zircon_nic_pkg::*;
#(
    parameter int PTP_FIFO_DEPTH = 16
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          stat_clr,          // clears the error counters

    taxi_axis_if.snk           s_axis,            // frames, tuser = {lat_rec_t, bad}
    taxi_axis_if.src           m_axis,            // frames to the MAC, tuser = 0

    output wire logic [23:0]   m_axis_ptp_tdata,  // {6'd0, tag, op}
    output wire logic          m_axis_ptp_tvalid,
    input  wire logic          m_axis_ptp_tready,

    input  wire logic [54:0]   ts_in,             // MRMAC tx_ptp_tstamp_out
    input  wire logic [15:0]   ts_tag_in,         // MRMAC tx_ptp_tstamp_tag_out
    input  wire logic          ts_valid_in,       // MRMAC tx_ptp_tstamp_valid_out

    taxi_axis_if.src           m_axis_sample,     // lat_sample_t
    output lat_err_t           err_cnt
);

if (s_axis.USER_W != 1 + LAT_REC_W)
    $fatal(0, "Error: s_axis tuser must be {lat_rec_t, bad} (instance %m)");

if (m_axis_sample.DATA_W != LAT_SAMPLE_W)
    $fatal(0, "Error: sample interface width must be %0d (instance %m)", LAT_SAMPLE_W);

localparam logic [1:0] OP_NONE = 2'b00;
localparam logic [1:0] OP_2STEP = 2'b10;

// ---------------------------------------------------------------------------
// PTP record FIFO: LUTRAM, first-word fall-through with one cycle of latency (a
// record written in cycle t is on m_axis_ptp in t + 1, the cycle the frame's
// first beat is released), so the record is never behind its frame
// ---------------------------------------------------------------------------
localparam int PAW = $clog2(PTP_FIFO_DEPTH);

(* ram_style = "distributed" *) logic [23:0] ptp_mem [PTP_FIFO_DEPTH];
logic [PAW:0] ptp_wr_ptr = '0, ptp_rd_ptr = '0;

wire        ptp_full  = (ptp_wr_ptr[PAW-1:0] == ptp_rd_ptr[PAW-1:0]) && (ptp_wr_ptr[PAW] != ptp_rd_ptr[PAW]);
wire        ptp_empty = ptp_wr_ptr == ptp_rd_ptr;
wire [23:0] ptp_wdata;
wire        ptp_wr;

assign m_axis_ptp_tdata  = ptp_mem[ptp_rd_ptr[PAW-1:0]];
assign m_axis_ptp_tvalid = !ptp_empty;

always_ff @(posedge clk) begin
    if (ptp_wr) begin
        ptp_mem[ptp_wr_ptr[PAW-1:0]] <= ptp_wdata;
        ptp_wr_ptr <= ptp_wr_ptr + 1'b1;
    end
    if (m_axis_ptp_tvalid && m_axis_ptp_tready) begin
        ptp_rd_ptr <= ptp_rd_ptr + 1'b1;
    end
    if (rst) begin
        ptp_wr_ptr <= '0;
        ptp_rd_ptr <= '0;
    end
end

// ---------------------------------------------------------------------------
// SOF gate and tag allocation
// ---------------------------------------------------------------------------
lat_rec_t rec;
assign rec = lat_rec_t'(s_axis.tuser[LAT_REC_W:1]);

logic        sof_reg = 1'b1;       // next input beat is a frame's first
logic        pushed_reg = 1'b0;    // the current SOF beat's record has been pushed
logic [15:0] seq_reg = '0;         // next tag

wire gate = !sof_reg || pushed_reg;
wire push = s_axis.tvalid && sof_reg && !pushed_reg && !ptp_full;
wire alloc = push && rec.want;

assign ptp_wdata = {6'd0, rec.want ? seq_reg : 16'd0, rec.want ? OP_2STEP : OP_NONE};
assign ptp_wr    = push;

assign m_axis.tdata  = s_axis.tdata;
assign m_axis.tkeep  = s_axis.tkeep;
assign m_axis.tstrb  = s_axis.tstrb;
assign m_axis.tlast  = s_axis.tlast;
assign m_axis.tid    = '0;
assign m_axis.tdest  = '0;
assign m_axis.tuser  = '0;
assign m_axis.tvalid = s_axis.tvalid && gate;
assign s_axis.tready = m_axis.tready && gate;

// pending table: tag[5:0] -> {tag[15:6], bank, rx_ts}
localparam int PEND_W = 10 + 2 + LAT_TS_W;
(* ram_style = "distributed" *) logic [PEND_W-1:0] pend_ram [64];
logic [63:0] pend_valid = '0;

// ---------------------------------------------------------------------------
// timestamp return
// ---------------------------------------------------------------------------
// stage A: pending-table read of the returned tag (registered); an allocation of
// the same entry in that cycle replaces it, so the old entry is treated as gone
// stage B: tag compare -> hit (clear the entry, start the delta pipeline) or STALE
logic              a_valid_reg = 1'b0;
logic              a_vld_reg = 1'b0;
logic [15:0]       a_tag_reg = '0;
logic [54:0]       a_ts_reg = '0;
logic [PEND_W-1:0] a_ent_reg = '0;

wire [5:0]        r_idx = a_tag_reg[5:0];
wire [PEND_W-1:0] r_ent = a_ent_reg;
wire              r_hit = a_valid_reg && a_vld_reg && r_ent[PEND_W-1 -: 10] == a_tag_reg[15:6];

logic                v1_reg = 1'b0, v2_reg = 1'b0, v3_reg = 1'b0, v4_reg = 1'b0;
logic [1:0]          b1_reg = '0, b2_reg = '0, b3_reg = '0;
logic [54:0]         diff3_reg = '0;
logic [54:0]         tx1_reg = '0;
logic [54:0]         rx1_reg = '0;
logic [28:0]         lo2_reg = '0;          // low 28 bits of the difference + borrow
logic [26:0]         txh2_reg = '0, rxh2_reg = '0;
lat_sample_t         smp_reg = '0;

assign m_axis_sample.tdata  = smp_reg;
assign m_axis_sample.tkeep  = '1;
assign m_axis_sample.tstrb  = '1;
assign m_axis_sample.tlast  = 1'b1;
assign m_axis_sample.tid    = '0;
assign m_axis_sample.tdest  = '0;
assign m_axis_sample.tuser  = '0;
assign m_axis_sample.tvalid = v4_reg;

wire [46:0] ns3 = diff3_reg[54:8];

always_ff @(posedge clk) begin
    // SOF gate
    if (push) begin
        pushed_reg <= 1'b1;
    end
    if (s_axis.tvalid && s_axis.tready) begin
        sof_reg <= s_axis.tlast;
        if (sof_reg) pushed_reg <= 1'b0;
    end

    // stage A
    a_valid_reg <= ts_valid_in;
    a_tag_reg   <= ts_tag_in;
    a_ts_reg    <= ts_in;
    a_ent_reg   <= pend_ram[ts_tag_in[5:0]];
    a_vld_reg   <= pend_valid[ts_tag_in[5:0]] && !(alloc && seq_reg[5:0] == ts_tag_in[5:0]);

    // pending table (stage B): the return is resolved first; an allocation of the
    // same entry in the same cycle wins
    if (r_hit) begin
        pend_valid[r_idx] <= 1'b0;
    end
    if (alloc) begin
        pend_ram[seq_reg[5:0]]   <= {seq_reg[15:6], rec.bank, rec.rx_ts};
        pend_valid[seq_reg[5:0]] <= 1'b1;
        seq_reg <= seq_reg + 16'd1;
        if (pend_valid[seq_reg[5:0]] && !(r_hit && r_idx == seq_reg[5:0])) begin
            err_cnt.lost <= err_cnt.lost + 32'd1;
        end
    end
    if (a_valid_reg && !r_hit) begin
        err_cnt.stale <= err_cnt.stale + 32'd1;
    end

    // latency pipeline
    v1_reg  <= r_hit;
    b1_reg  <= r_ent[LAT_TS_W +: 2];
    tx1_reg <= a_ts_reg;
    rx1_reg <= {r_ent[LAT_TS_W-1:0], 7'd0};

    v2_reg   <= v1_reg;
    b2_reg   <= b1_reg;
    lo2_reg  <= {1'b0, tx1_reg[27:0]} - {1'b0, rx1_reg[27:0]};
    txh2_reg <= tx1_reg[54:28];
    rxh2_reg <= rx1_reg[54:28];

    v3_reg    <= v2_reg;
    b3_reg    <= b2_reg;
    diff3_reg <= {txh2_reg - rxh2_reg - 27'(lo2_reg[28]), lo2_reg[27:0]};

    v4_reg <= v3_reg;
    smp_reg.bank <= b3_reg;
    if (ns3 >= 47'(LAT_MAX_NS)) begin
        smp_reg.implausible <= 1'b1;
        smp_reg.delta_ns    <= '1;
    end else begin
        smp_reg.implausible <= 1'b0;
        smp_reg.delta_ns    <= ns3[LAT_DELTA_W-1:0];
    end
    if (v4_reg && !m_axis_sample.tready) begin
        err_cnt.ovf <= err_cnt.ovf + 32'd1;
    end

    if (rst || stat_clr) begin
        err_cnt <= '0;
    end
    if (rst) begin
        sof_reg    <= 1'b1;
        pushed_reg <= 1'b0;
        pend_valid <= '0;
        a_valid_reg <= 1'b0;
        v1_reg     <= 1'b0;
        v2_reg     <= 1'b0;
        v3_reg     <= 1'b0;
        v4_reg     <= 1'b0;
    end
end

endmodule

`resetall

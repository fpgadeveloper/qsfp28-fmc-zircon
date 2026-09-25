// SPDX-License-Identifier: MIT
//
// tx_mac_out - MAC TX output stage (mac_tx_clk domain): TX enable gate, short-frame
// padding, output register and TX statistics.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
//   * TX enable: sampled at the first beat of every frame. A frame that starts
//     while TX is disabled is consumed and discarded as a whole (never truncated),
//     so nothing upstream wedges while CTRL.TX_EN = 0.
//   * Padding: frames shorter than 60 bytes (e.g. a hardware echo of a 1-byte
//     datagram: 42 + 1 bytes) are zero-padded to 60 bytes; with the FCS appended by
//     the MAC that is the 64-byte Ethernet minimum. At 512 bits a sub-60-byte frame
//     is always a single beat, so this is a per-beat mask.
//   * Output register: a two-entry skid buffer, full throughput, registered tready
//     towards the FIFO and registered outputs towards the MAC.
//   * Statistics: frames and bytes (after padding) accepted by the MAC; the
//     *_free copies are never cleared by stat_clr (rate meter, 1.2.0).
//   * tuser (1.3.0: {lat_rec_t, bad}) is carried through with every beat.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tx_mac_out #(
    parameter int MIN_LEN = 60
) (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic         tx_en,           // synchronised to clk
    input  wire logic         stat_clr,        // single-cycle pulse

    taxi_axis_if.snk          s_axis,
    taxi_axis_if.src          m_axis,

    output logic [31:0]       tx_frames,
    output logic [63:0]       tx_bytes,
    output logic [31:0]       tx_frames_free,
    output logic [63:0]       tx_bytes_free
);

localparam int DATA_W = s_axis.DATA_W;
localparam int KEEP_W = s_axis.KEEP_W;
localparam int USER_W = s_axis.USER_W;
localparam logic [KEEP_W-1:0] MIN_KEEP = {KEEP_W{1'b1}} >> (KEEP_W - MIN_LEN);

if (DATA_W != 512 || KEEP_W != 64 || MIN_LEN > KEEP_W)
    $fatal(0, "Error: tx_mac_out needs a 512-bit byte-granular stream (instance %m)");

// ---- gate + pad (combinational on the FIFO output) ----
logic first_reg = 1'b1;     // next input beat starts a frame
logic drop_reg = 1'b0;      // current frame is being discarded

wire drop = first_reg ? !tx_en : drop_reg;
wire pad  = first_reg && s_axis.tlast;

logic [DATA_W-1:0] p_data;
logic [KEEP_W-1:0] p_keep;
always_comb begin
    p_data = s_axis.tdata;
    p_keep = s_axis.tkeep;
    if (pad) begin
        for (int i = 0; i < KEEP_W; i++) begin
            if (!s_axis.tkeep[i]) p_data[i*8 +: 8] = 8'd0;
        end
        p_keep = s_axis.tkeep | MIN_KEEP;
    end
end

// ---- skid buffer ----
logic [DATA_W-1:0] o_data_reg = '0, t_data_reg = '0;
logic [KEEP_W-1:0] o_keep_reg = '0, t_keep_reg = '0;
logic              o_last_reg = 1'b0, t_last_reg = 1'b0;
logic              o_valid_reg = 1'b0, t_valid_reg = 1'b0;
logic [USER_W-1:0] o_user_reg = '0, t_user_reg = '0;
logic              s_ready_reg = 1'b0;

assign m_axis.tdata  = o_data_reg;
assign m_axis.tkeep  = o_keep_reg;
assign m_axis.tstrb  = o_keep_reg;
assign m_axis.tlast  = o_last_reg;
assign m_axis.tvalid = o_valid_reg;
assign m_axis.tid    = '0;
assign m_axis.tdest  = '0;
assign m_axis.tuser  = o_user_reg;

assign s_axis.tready = s_ready_reg;

wire in_xfer     = s_axis.tvalid && s_ready_reg;
wire s_valid_eff = s_axis.tvalid && !drop;     // beats of a discarded frame are consumed, not stored
wire out_xfer    = o_valid_reg && m_axis.tready;

// skid buffer control (same structure as taxi_axis_register's skid mode)
wire s_ready_early = m_axis.tready || (!t_valid_reg && (!o_valid_reg || !s_valid_eff));
logic o_valid_next, t_valid_next;
logic in_to_out, in_to_tmp, tmp_to_out;

always_comb begin
    o_valid_next = o_valid_reg;
    t_valid_next = t_valid_reg;
    in_to_out = 1'b0;
    in_to_tmp = 1'b0;
    tmp_to_out = 1'b0;
    if (s_ready_reg) begin
        if (m_axis.tready || !o_valid_reg) begin
            o_valid_next = s_valid_eff;
            in_to_out = 1'b1;
        end else begin
            t_valid_next = s_valid_eff;
            in_to_tmp = 1'b1;
        end
    end else if (m_axis.tready) begin
        o_valid_next = t_valid_reg;
        t_valid_next = 1'b0;
        tmp_to_out = 1'b1;
    end
end

// ---- statistics pipeline ----
logic              st_valid_reg = 1'b0;
logic              st_last_reg = 1'b0;
logic [KEEP_W-1:0] st_keep_reg = '0;
logic [6:0]        st_lo_reg = '0, st_hi_reg = '0;
logic              st2_valid_reg = 1'b0, st2_last_reg = 1'b0;

function automatic logic [6:0] popcnt32(input logic [31:0] v);
    popcnt32 = '0;
    for (int i = 0; i < 32; i++) popcnt32 = popcnt32 + 7'(v[i]);
endfunction

always_ff @(posedge clk) begin
    // frame tracking
    if (in_xfer) begin
        first_reg <= s_axis.tlast;
        if (first_reg) begin
            drop_reg <= !tx_en;
        end
    end

    // skid buffer
    s_ready_reg <= s_ready_early;
    o_valid_reg <= o_valid_next;
    t_valid_reg <= t_valid_next;
    if (in_to_out) begin
        o_data_reg <= p_data;
        o_keep_reg <= p_keep;
        o_last_reg <= s_axis.tlast;
        o_user_reg <= s_axis.tuser;
    end else if (tmp_to_out) begin
        o_data_reg <= t_data_reg;
        o_keep_reg <= t_keep_reg;
        o_last_reg <= t_last_reg;
        o_user_reg <= t_user_reg;
    end
    if (in_to_tmp) begin
        t_data_reg <= p_data;
        t_keep_reg <= p_keep;
        t_last_reg <= s_axis.tlast;
        t_user_reg <= s_axis.tuser;
    end

    // statistics: count what the MAC accepts (pipelined popcount)
    st_valid_reg <= out_xfer;
    st_last_reg  <= o_last_reg;
    st_keep_reg  <= o_keep_reg;
    st2_valid_reg <= st_valid_reg;
    st2_last_reg  <= st_last_reg;
    st_lo_reg <= popcnt32(st_keep_reg[31:0]);
    st_hi_reg <= popcnt32(st_keep_reg[63:32]);
    if (st2_valid_reg) begin
        tx_bytes <= tx_bytes + 64'(st_lo_reg) + 64'(st_hi_reg);
        tx_bytes_free <= tx_bytes_free + 64'(st_lo_reg) + 64'(st_hi_reg);
        if (st2_last_reg) begin
            tx_frames <= tx_frames + 32'd1;
            tx_frames_free <= tx_frames_free + 32'd1;
        end
    end

    if (rst || stat_clr) begin
        tx_frames <= '0;
        tx_bytes  <= '0;
    end

    if (rst) begin
        first_reg     <= 1'b1;
        drop_reg      <= 1'b0;
        o_valid_reg   <= 1'b0;
        t_valid_reg   <= 1'b0;
        s_ready_reg   <= 1'b0;
        st_valid_reg  <= 1'b0;
        st2_valid_reg <= 1'b0;
        tx_frames_free <= '0;
        tx_bytes_free  <= '0;
    end
end

endmodule

`resetall

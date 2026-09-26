// SPDX-License-Identifier: MIT
//
// zircon_cmac_us_core - implementation of the zircon_cmac_us module reference
// (zircon_cmac_us.v): UltraScale+ CMAC through Taxi's taxi_eth_mac_100g_us, with the
// MAC-side interface zircon_nic expects and fabric timestamps for its latency
// measurement. Port list and register map: docs/DESIGN_SPEC.md section 6c / 3.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). It instantiates
// taxi_eth_mac_100g_us, taxi_axil_apb_adapter, taxi_sync_reset, taxi_sync_signal and
// the taxi_axis_if / taxi_axil_if / taxi_apb_if interfaces from the Taxi library
// (CERN-OHL-S-2.0, see submodules/README.md), unmodified.
//
// Blocks
//   mac_inst     taxi_eth_mac_100g_us, 4 GTY lanes, PTP_TS_EN = 0 (the wrapper does not
//                drive the CMAC timestamps), RS-FEC on (fixed in the wrapper).
//   timebase     45-bit tick counter on ts_clk; ts55 = {tick, 10'b0} (TS_INCR = 1024:
//                2^-8 ns units, 4 ns per 250 MHz tick; same units as ptp_systimer).
//                ts_gray_sync carries it into tx_clk, rx_clk and ctrl_clk.
//   RX           one register stage after the CMAC: tuser[0] = CMAC error (last beat),
//                tuser[48:1] = ts55[54:7] sampled at the frame's first CMAC beat, on
//                every beat. No back-pressure (m_axis_mac_rx_tready is ignored).
//   TX           s_axis_mac_tx goes straight into the wrapper (taxi_axis_pad -> CMAC).
//                s_axis_tx_ptp records ({tag, op}) wait in a 16-entry FIFO with
//                fall-through: the record may arrive in the same cycle as its frame's
//                first beat. At the first beat's handshake the head record is popped
//                and, for op 2'b10, {ts55, tag} is returned on tx_ptp_tstamp_* one cycle
//                later. No record at SOF: the frame goes untagged, STICKY.PTP_UNDERRUN.
//                tvalid is never gated (the CMAC must not see a mid-frame underflow).
//   s_axi        0x0_0000..0x3_FFFF shim registers, 0x4_0000..0x7_FFFF the wrapper's
//                transceiver APB (taxi_axil_apb_adapter, 32 -> 16 bit, lane n at
//                0x4_0000 + n * 0x1_0000). One transaction at a time.
//   apb filter   between the adapter and the wrapper: (a) a write segment with
//                pstrb == 0 is completed locally and not forwarded (the Taxi GT APB
//                registers ignore pstrb, so a 16-bit write would otherwise also write
//                the neighbouring 16-bit register with the other half of wdata); (b)
//                while CTRL.XCVR_RST is set, and for 32 ctrl_clk cycles after it is
//                cleared, every transfer completes locally with SLVERR / rdata 0 (the
//                wrapper's APB interconnect is held in reset and would never answer).
//
// SIM = 1 (xsim): the wrapper is built with SIM = 1 (no GT / CMAC IP); the testbench
// drives the GT user clocks and the wrapper's internal cmac_axis_tx / cmac_axis_rx
// interfaces hierarchically (as Taxi's own cocotb testbenches do). The CMAC statistics
// outputs do not exist then: RX_GOOD_PKTS counts error-free RX frames, TX_GOOD_PKTS the
// frames accepted by the model, RX_BAD_FCS / RX_HIGH_BER read 0, RX_BLOCK_LOCK =
// RX_STATUS; the clock-frequency window is 1250 ctrl_clk cycles (x100).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module zircon_cmac_us_core #(
    parameter string       FAMILY          = "kintexuplus",
    parameter logic        CFG_LOW_LATENCY = 1'b0,
    parameter logic [3:0]  GT_TX_POLARITY  = 4'b0000,
    parameter logic [3:0]  GT_RX_POLARITY  = 4'b0000,
    parameter int          AXIL_ADDR_W     = 19,
    parameter int          TS_INCR         = 1024,
    parameter logic        SIM             = 1'b0,
    parameter int          CTRL_HZ         = 125000000
) (
    input  wire logic          gt_ref_clk_p,
    input  wire logic          gt_ref_clk_n,
    output wire logic [3:0]    gt_txp,
    output wire logic [3:0]    gt_txn,
    input  wire logic [3:0]    gt_rxp,
    input  wire logic [3:0]    gt_rxn,

    input  wire logic          ctrl_clk,
    input  wire logic          ctrl_aresetn,
    input  wire logic          ts_clk,
    input  wire logic          ts_aresetn,

    output wire logic          tx_clk,
    output wire logic          rx_clk,
    output wire logic          mac_tx_aresetn,
    output wire logic          mac_rx_aresetn,

    output wire logic [511:0]  m_axis_mac_rx_tdata,
    output wire logic [63:0]   m_axis_mac_rx_tkeep,
    output wire logic          m_axis_mac_rx_tvalid,
    input  wire logic          m_axis_mac_rx_tready,
    output wire logic          m_axis_mac_rx_tlast,
    output wire logic [48:0]   m_axis_mac_rx_tuser,

    input  wire logic [511:0]  s_axis_mac_tx_tdata,
    input  wire logic [63:0]   s_axis_mac_tx_tkeep,
    input  wire logic          s_axis_mac_tx_tvalid,
    output wire logic          s_axis_mac_tx_tready,
    input  wire logic          s_axis_mac_tx_tlast,
    input  wire logic [0:0]    s_axis_mac_tx_tuser,

    input  wire logic [23:0]   s_axis_tx_ptp_tdata,
    input  wire logic          s_axis_tx_ptp_tvalid,
    output wire logic          s_axis_tx_ptp_tready,

    output wire logic [54:0]   tx_ptp_tstamp_out,
    output wire logic [15:0]   tx_ptp_tstamp_tag_out,
    output wire logic          tx_ptp_tstamp_valid_out,

    output wire logic          link_up,

    input  wire logic [AXIL_ADDR_W-1:0] s_axi_awaddr,
    input  wire logic [2:0]    s_axi_awprot,
    input  wire logic          s_axi_awvalid,
    output wire logic          s_axi_awready,
    input  wire logic [31:0]   s_axi_wdata,
    input  wire logic [3:0]    s_axi_wstrb,
    input  wire logic          s_axi_wvalid,
    output wire logic          s_axi_wready,
    output wire logic [1:0]    s_axi_bresp,
    output wire logic          s_axi_bvalid,
    input  wire logic          s_axi_bready,
    input  wire logic [AXIL_ADDR_W-1:0] s_axi_araddr,
    input  wire logic [2:0]    s_axi_arprot,
    input  wire logic          s_axi_arvalid,
    output wire logic          s_axi_arready,
    output wire logic [31:0]   s_axi_rdata,
    output wire logic [1:0]    s_axi_rresp,
    output wire logic          s_axi_rvalid,
    input  wire logic          s_axi_rready
);

localparam int TS_SHIFT = $clog2(TS_INCR);
localparam int TICK_W = 55 - TS_SHIFT;
localparam int GT_CNT = 4;
localparam int APB_ADDR_W = 18;
localparam int FREQ_W = 20;
localparam int FREQ_WIN = SIM ? 1250 : CTRL_HZ / 1000;   // ctrl_clk cycles per window
localparam int FREQ_MUL = SIM ? 100 : 1;                 // window counts -> kHz

localparam logic [31:0] REG_ID      = 32'h434D4143;      // "CMAC"
localparam logic [31:0] REG_VERSION = 32'h00010000;

if (TS_INCR != 2**TS_SHIFT || TS_SHIFT < 1 || TS_SHIFT > 16)
    $fatal(0, "Error: TS_INCR must be a power of two between 2 and 65536 (instance %m)");
if (AXIL_ADDR_W != 19)
    $fatal(0, "Error: C_S_AXI_ADDR_WIDTH must be 19 (instance %m)");

// ============================================================================
// ctrl_clk domain: reset, register state
// ============================================================================
logic ctrl_rst_reg = 1'b1;
always_ff @(posedge ctrl_clk) ctrl_rst_reg <= !ctrl_aresetn;
wire ctrl_rst = ctrl_rst_reg;

// CTRL register (reset 0x31)
logic ctrl_xcvr_rst_reg = 1'b1;
logic ctrl_rx_rst_reg   = 1'b0;
logic ctrl_tx_rst_reg   = 1'b0;
logic ctrl_tx_en_reg    = 1'b1;
logic ctrl_rx_en_reg    = 1'b1;

wire xcvr_rst_any = ctrl_xcvr_rst_reg || ctrl_rst;

// ============================================================================
// GT reference clock
// ============================================================================
wire gt_refclk;

if (SIM) begin : refclk
    assign gt_refclk = gt_ref_clk_p;
end else begin : refclk
    IBUFDS_GTE4 ibufds_gte4_refclk_inst (
        .I     (gt_ref_clk_p),
        .IB    (gt_ref_clk_n),
        .CEB   (1'b0),
        .O     (gt_refclk),
        .ODIV2 ()
    );
end

// ============================================================================
// Taxi 100G CMAC wrapper
// ============================================================================
taxi_apb_if #(.ADDR_W(APB_ADDR_W), .DATA_W(16)) apb_adapter();   // adapter -> filter
taxi_apb_if #(.ADDR_W(APB_ADDR_W), .DATA_W(16)) apb_gt();        // filter -> wrapper

taxi_axis_if #(.DATA_W(512), .USER_EN(1), .USER_W(1)) axis_tx();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8)) axis_tx_cpl();
taxi_axis_if #(.DATA_W(512), .USER_EN(1), .USER_W(1)) axis_rx();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(10)) axis_stat();

wire gt_txp_u[GT_CNT];
wire gt_txn_u[GT_CNT];
wire gt_rxp_u[GT_CNT];
wire gt_rxn_u[GT_CNT];

for (genvar n = 0; n < GT_CNT; n = n + 1) begin : lane
    assign gt_txp[n] = gt_txp_u[n];
    assign gt_txn[n] = gt_txn_u[n];
    assign gt_rxp_u[n] = gt_rxp[n];
    assign gt_rxn_u[n] = gt_rxn[n];
end

wire mac_tx_rst_out;
wire mac_rx_rst_out;
wire mac_gtpowergood;
wire mac_rx_status;
wire mac_rx_block_lock;
wire mac_rx_high_ber;
wire mac_stat_tx_pkt_good;
wire mac_stat_rx_pkt_good;
wire mac_stat_rx_err_bad_fcs;

// CMAC ctl_* enables: quasi-static, synchronised into their clock domains
wire cfg_tx_enable_sync;
wire cfg_rx_enable_sync;

taxi_eth_mac_100g_us #(
    .SIM(SIM),
    .VENDOR("XILINX"),
    .FAMILY(FAMILY),
    .GT_CNT(GT_CNT),
    .CFG_LOW_LATENCY(CFG_LOW_LATENCY),
    .GT_TYPE("GTY"),
    .GT_TX_POLARITY(GT_TX_POLARITY),
    .GT_RX_POLARITY(GT_RX_POLARITY),
    .PTP_TS_EN(1'b0),
    .PTP_TD_EN(1'b0),
    .STAT_EN(1'b0)
)
mac_inst (
    .xcvr_ctrl_clk(ctrl_clk),
    .xcvr_ctrl_rst(xcvr_rst_any),
    .s_apb_ctrl(apb_gt),
    .xcvr_gtpowergood_out(mac_gtpowergood),
    .xcvr_gtrefclk00_in(gt_refclk),
    .xcvr_gtrefclk01_in(gt_refclk),
    .xcvr_txp(gt_txp_u),
    .xcvr_txn(gt_txn_u),
    .xcvr_rxp(gt_rxp_u),
    .xcvr_rxn(gt_rxn_u),
    .rx_clk(rx_clk),
    .rx_rst_in(ctrl_rx_rst_reg),
    .rx_rst_out(mac_rx_rst_out),
    .tx_clk(tx_clk),
    .tx_rst_in(ctrl_tx_rst_reg),
    .tx_rst_out(mac_tx_rst_out),
    .s_axis_tx(axis_tx),
    .m_axis_tx_cpl(axis_tx_cpl),
    .m_axis_rx(axis_rx),
    .tx_ptp_ts_out(),
    .tx_ptp_ts_step_out(),
    .tx_ptp_locked(),
    .rx_ptp_ts_out(),
    .rx_ptp_ts_step_out(),
    .rx_ptp_locked(),
    .rx_lfc_req(),
    .rx_pfc_req(),
    .tx_pause_ack(),
    .stat_clk(ctrl_clk),
    .stat_rst(ctrl_rst),
    .m_axis_stat(axis_stat),
    .tx_start_packet(),
    .stat_tx_byte(),
    .stat_tx_pkt_len(),
    .stat_tx_pkt_ucast(),
    .stat_tx_pkt_mcast(),
    .stat_tx_pkt_bcast(),
    .stat_tx_pkt_vlan(),
    .stat_tx_pkt_good(mac_stat_tx_pkt_good),
    .stat_tx_pkt_bad(),
    .stat_tx_pad_frame(),
    .stat_tx_err_oversize(),
    .stat_tx_err_user(),
    .stat_tx_err_underflow(),
    .rx_start_packet(),
    .rx_error_count(),
    .rx_block_lock(mac_rx_block_lock),
    .rx_high_ber(mac_rx_high_ber),
    .rx_status(mac_rx_status),
    .stat_rx_byte(),
    .stat_rx_pkt_len(),
    .stat_rx_pkt_fragment(),
    .stat_rx_pkt_jabber(),
    .stat_rx_pkt_ucast(),
    .stat_rx_pkt_mcast(),
    .stat_rx_pkt_bcast(),
    .stat_rx_pkt_vlan(),
    .stat_rx_pkt_good(mac_stat_rx_pkt_good),
    .stat_rx_pkt_bad(),
    .stat_rx_err_oversize(),
    .stat_rx_err_bad_fcs(mac_stat_rx_err_bad_fcs),
    .stat_rx_err_bad_block(),
    .stat_rx_err_framing(),
    .stat_rx_err_preamble(),
    .stat_tx_mcf(),
    .stat_rx_mcf(),
    .stat_tx_lfc_pkt(),
    .stat_tx_lfc_xon(),
    .stat_tx_lfc_xoff(),
    .stat_tx_lfc_paused(),
    .stat_tx_pfc_pkt(),
    .stat_tx_pfc_xon(),
    .stat_tx_pfc_xoff(),
    .stat_tx_pfc_paused(),
    .stat_rx_lfc_pkt(),
    .stat_rx_lfc_xon(),
    .stat_rx_lfc_xoff(),
    .stat_rx_lfc_paused(),
    .stat_rx_pfc_pkt(),
    .stat_rx_pfc_xon(),
    .stat_rx_pfc_xoff(),
    .stat_rx_pfc_paused(),
    .cfg_tx_enable(cfg_tx_enable_sync),
    .cfg_rx_enable(cfg_rx_enable_sync)
);

assign axis_tx_cpl.tready = 1'b1;
assign axis_stat.tready = 1'b1;
assign axis_rx.tready = 1'b1;

// in SIM the CMAC status / statistics outputs are not driven (no CMAC)
wire rx_status_int    = mac_rx_status;
wire rx_block_lock_int = SIM ? mac_rx_status : mac_rx_block_lock;
wire rx_high_ber_int  = SIM ? 1'b0 : mac_rx_high_ber;

assign link_up = rx_status_int;

taxi_sync_signal #(.WIDTH(1), .N(2)) tx_en_sync_inst (
    .clk(tx_clk), .in(ctrl_tx_en_reg), .out(cfg_tx_enable_sync));
taxi_sync_signal #(.WIDTH(1), .N(2)) rx_en_sync_inst (
    .clk(rx_clk), .in(ctrl_rx_en_reg), .out(cfg_rx_enable_sync));

// ============================================================================
// MAC-side resets (active-high inside, active-low out; async assert, sync release)
// ============================================================================
wire tx_rst;
wire rx_rst;

taxi_sync_reset #(.N(4)) tx_rst_sync_inst (
    .clk(tx_clk), .rst(mac_tx_rst_out || xcvr_rst_any), .out(tx_rst));
taxi_sync_reset #(.N(4)) rx_rst_sync_inst (
    .clk(rx_clk), .rst(mac_rx_rst_out || xcvr_rst_any), .out(rx_rst));

assign mac_tx_aresetn = !tx_rst;
assign mac_rx_aresetn = !rx_rst;

// ============================================================================
// Timebase (ts_clk) and its crossings
// ============================================================================
logic [TICK_W-1:0] tick_reg = '0;

always_ff @(posedge ts_clk) begin
    tick_reg <= tick_reg + 1'b1;
    if (!ts_aresetn) begin
        tick_reg <= '0;
    end
end

wire [TICK_W-1:0] tick_tx;
wire [TICK_W-1:0] tick_rx;
wire [TICK_W-1:0] tick_ctrl;

ts_gray_sync #(.W(TICK_W)) ts_sync_tx_inst (
    .src_clk(ts_clk), .src_bin(tick_reg), .dst_clk(tx_clk), .dst_bin(tick_tx));
ts_gray_sync #(.W(TICK_W)) ts_sync_rx_inst (
    .src_clk(ts_clk), .src_bin(tick_reg), .dst_clk(rx_clk), .dst_bin(tick_rx));
ts_gray_sync #(.W(TICK_W)) ts_sync_ctrl_inst (
    .src_clk(ts_clk), .src_bin(tick_reg), .dst_clk(ctrl_clk), .dst_bin(tick_ctrl));

wire [54:0] ts_tx   = {tick_tx, TS_SHIFT'(0)};
wire [54:0] ts_rx   = {tick_rx, TS_SHIFT'(0)};
wire [54:0] ts_ctrl = {tick_ctrl, TS_SHIFT'(0)};

// ============================================================================
// RX (rx_clk): first-beat timestamp on tuser[48:1] of every beat
// ============================================================================
logic         rx_sof_reg = 1'b1;
logic [47:0]  rx_ts_frame_reg = '0;
logic [511:0] rx_tdata_reg = '0;
logic [63:0]  rx_tkeep_reg = '0;
logic         rx_tvalid_reg = 1'b0;
logic         rx_tlast_reg = 1'b0;
logic [48:0]  rx_tuser_reg = '0;

logic [31:0]  rx_good_cnt_reg = '0;
logic [31:0]  rx_bad_fcs_cnt_reg = '0;
logic [31:0]  rx_err_cnt_reg = '0;

always_ff @(posedge rx_clk) begin
    rx_tvalid_reg <= 1'b0;
    if (axis_rx.tvalid) begin
        rx_tdata_reg  <= axis_rx.tdata;
        rx_tkeep_reg  <= axis_rx.tkeep;
        rx_tlast_reg  <= axis_rx.tlast;
        rx_tvalid_reg <= 1'b1;
        if (rx_sof_reg) begin
            rx_ts_frame_reg <= ts_rx[54:7];
            rx_tuser_reg <= {ts_rx[54:7], axis_rx.tuser[0]};
        end else begin
            rx_tuser_reg <= {rx_ts_frame_reg, axis_rx.tuser[0]};
        end
        rx_sof_reg <= axis_rx.tlast;
        if (axis_rx.tlast && axis_rx.tuser[0]) begin
            rx_err_cnt_reg <= rx_err_cnt_reg + 1;
        end
    end

    if (SIM ? (axis_rx.tvalid && axis_rx.tlast && !axis_rx.tuser[0]) : mac_stat_rx_pkt_good) begin
        rx_good_cnt_reg <= rx_good_cnt_reg + 1;
    end
    if (!SIM && mac_stat_rx_err_bad_fcs) begin
        rx_bad_fcs_cnt_reg <= rx_bad_fcs_cnt_reg + 1;
    end

    if (rx_rst) begin
        rx_sof_reg <= 1'b1;
        rx_tvalid_reg <= 1'b0;
    end
end

assign m_axis_mac_rx_tdata  = rx_tdata_reg;
assign m_axis_mac_rx_tkeep  = rx_tkeep_reg;
assign m_axis_mac_rx_tvalid = rx_tvalid_reg;
assign m_axis_mac_rx_tlast  = rx_tlast_reg;
assign m_axis_mac_rx_tuser  = rx_tuser_reg;

// ============================================================================
// TX (tx_clk): pass-through into the wrapper, PTP record FIFO, SOF timestamp
// ============================================================================
assign axis_tx.tdata  = s_axis_mac_tx_tdata;
assign axis_tx.tkeep  = s_axis_mac_tx_tkeep;
assign axis_tx.tstrb  = s_axis_mac_tx_tkeep;
assign axis_tx.tvalid = s_axis_mac_tx_tvalid;
assign axis_tx.tlast  = s_axis_mac_tx_tlast;
assign axis_tx.tuser  = s_axis_mac_tx_tuser;
assign axis_tx.tid    = '0;
assign axis_tx.tdest  = '0;
assign s_axis_mac_tx_tready = axis_tx.tready;

wire tx_beat = s_axis_mac_tx_tvalid && axis_tx.tready;

logic tx_sof_reg = 1'b1;
wire  tx_sof_beat = tx_beat && tx_sof_reg;

// 16-entry record FIFO {tag[15:0], op[1:0]} with fall-through
localparam int PTP_AW = 4;
(* ram_style = "distributed" *)
logic [17:0] ptp_mem[2**PTP_AW];
logic [PTP_AW:0] ptp_wr_ptr_reg = '0;
logic [PTP_AW:0] ptp_rd_ptr_reg = '0;

wire ptp_empty = ptp_wr_ptr_reg == ptp_rd_ptr_reg;
wire ptp_full  = ptp_wr_ptr_reg == (ptp_rd_ptr_reg ^ {1'b1, {PTP_AW{1'b0}}});
wire [17:0] ptp_head = ptp_empty ? s_axis_tx_ptp_tdata[17:0] : ptp_mem[ptp_rd_ptr_reg[PTP_AW-1:0]];
wire ptp_head_valid = !ptp_empty || s_axis_tx_ptp_tvalid;
wire ptp_pop = tx_sof_beat && ptp_head_valid;
wire ptp_in  = s_axis_tx_ptp_tvalid && !ptp_full;
wire ptp_push = ptp_in && !(ptp_pop && ptp_empty);   // bypassed records are not stored

assign s_axis_tx_ptp_tready = !ptp_full;

logic [54:0] tx_ts_reg = '0;
logic [15:0] tx_tag_reg = '0;
logic        tx_ts_valid_reg = 1'b0;

logic tx_underrun_tgl_reg = 1'b0;
logic tx_recovf_tgl_reg = 1'b0;

logic [31:0] tx_good_cnt_reg = '0;
logic [31:0] tx_frames_cnt_reg = '0;
logic [31:0] tx_ts_ret_cnt_reg = '0;

always_ff @(posedge tx_clk) begin
    tx_ts_valid_reg <= 1'b0;

    if (ptp_push) begin
        ptp_mem[ptp_wr_ptr_reg[PTP_AW-1:0]] <= s_axis_tx_ptp_tdata[17:0];
        ptp_wr_ptr_reg <= ptp_wr_ptr_reg + 1;
    end
    if (ptp_pop && !ptp_empty) begin
        ptp_rd_ptr_reg <= ptp_rd_ptr_reg + 1;
    end

    if (tx_beat) begin
        tx_sof_reg <= s_axis_mac_tx_tlast;
    end

    if (tx_sof_beat) begin
        tx_frames_cnt_reg <= tx_frames_cnt_reg + 1;
        tx_ts_reg <= ts_tx;
        tx_tag_reg <= ptp_head[17:2];
        if (ptp_head_valid) begin
            if (ptp_head[1:0] == 2'b10) begin
                tx_ts_valid_reg <= 1'b1;
                tx_ts_ret_cnt_reg <= tx_ts_ret_cnt_reg + 1;
            end
        end else begin
            tx_underrun_tgl_reg <= !tx_underrun_tgl_reg;
        end
    end

    if (s_axis_tx_ptp_tvalid && ptp_full) begin
        tx_recovf_tgl_reg <= !tx_recovf_tgl_reg;
    end

    if (SIM ? (tx_beat && s_axis_mac_tx_tlast) : mac_stat_tx_pkt_good) begin
        tx_good_cnt_reg <= tx_good_cnt_reg + 1;
    end

    if (tx_rst) begin
        tx_sof_reg <= 1'b1;
        tx_ts_valid_reg <= 1'b0;
        ptp_wr_ptr_reg <= '0;
        ptp_rd_ptr_reg <= '0;
    end
end

assign tx_ptp_tstamp_out       = tx_ts_reg;
assign tx_ptp_tstamp_tag_out   = tx_tag_reg;
assign tx_ptp_tstamp_valid_out = tx_ts_valid_reg;

// ============================================================================
// Clock measurement (tx_clk / rx_clk counted against ctrl_clk)
// ============================================================================
logic [FREQ_W-1:0] tx_fcnt_reg = '0;
logic [FREQ_W-1:0] rx_fcnt_reg = '0;
always_ff @(posedge tx_clk) tx_fcnt_reg <= tx_fcnt_reg + 1'b1;
always_ff @(posedge rx_clk) rx_fcnt_reg <= rx_fcnt_reg + 1'b1;

wire [FREQ_W-1:0] tx_fcnt_ctrl;
wire [FREQ_W-1:0] rx_fcnt_ctrl;

ts_gray_sync #(.W(FREQ_W)) tx_fcnt_sync_inst (
    .src_clk(tx_clk), .src_bin(tx_fcnt_reg), .dst_clk(ctrl_clk), .dst_bin(tx_fcnt_ctrl));
ts_gray_sync #(.W(FREQ_W)) rx_fcnt_sync_inst (
    .src_clk(rx_clk), .src_bin(rx_fcnt_reg), .dst_clk(ctrl_clk), .dst_bin(rx_fcnt_ctrl));

logic [$clog2(FREQ_WIN+1)-1:0] freq_win_reg = '0;
logic [FREQ_W-1:0] tx_fcnt_prev_reg = '0;
logic [FREQ_W-1:0] rx_fcnt_prev_reg = '0;
logic [31:0] tx_khz_reg = '0;
logic [31:0] rx_khz_reg = '0;

always_ff @(posedge ctrl_clk) begin
    freq_win_reg <= freq_win_reg + 1;
    if (freq_win_reg == FREQ_WIN - 1) begin
        freq_win_reg <= '0;
        tx_fcnt_prev_reg <= tx_fcnt_ctrl;
        rx_fcnt_prev_reg <= rx_fcnt_ctrl;
        tx_khz_reg <= 32'(FREQ_W'(tx_fcnt_ctrl - tx_fcnt_prev_reg)) * FREQ_MUL;
        rx_khz_reg <= 32'(FREQ_W'(rx_fcnt_ctrl - rx_fcnt_prev_reg)) * FREQ_MUL;
    end
    if (ctrl_rst) begin
        freq_win_reg <= '0;
        tx_khz_reg <= '0;
        rx_khz_reg <= '0;
    end
end

// ============================================================================
// Status / events / counters into ctrl_clk
// ============================================================================
wire [5:0] status_sync;

taxi_sync_signal #(.WIDTH(6), .N(2)) status_sync_inst (
    .clk(ctrl_clk),
    .in({mac_gtpowergood, mac_rx_rst_out, mac_tx_rst_out, rx_high_ber_int, rx_block_lock_int, rx_status_int}),
    .out(status_sync)
);

wire [1:0] tx_evt_sync;

taxi_sync_signal #(.WIDTH(2), .N(2)) tx_evt_sync_inst (
    .clk(ctrl_clk),
    .in({tx_recovf_tgl_reg, tx_underrun_tgl_reg}),
    .out(tx_evt_sync)
);

wire [95:0] rx_cnt_ctrl;
wire [95:0] tx_cnt_ctrl;

zircon_cdc_snapshot #(.W(96), .DEPTH(8)) rx_cnt_cdc_inst (
    .src_clk(rx_clk), .src_rst(1'b0),
    .src_data({rx_err_cnt_reg, rx_bad_fcs_cnt_reg, rx_good_cnt_reg}),
    .dst_clk(ctrl_clk), .dst_rst(ctrl_rst),
    .dst_data(rx_cnt_ctrl)
);

zircon_cdc_snapshot #(.W(96), .DEPTH(8)) tx_cnt_cdc_inst (
    .src_clk(tx_clk), .src_rst(1'b0),
    .src_data({tx_ts_ret_cnt_reg, tx_frames_cnt_reg, tx_good_cnt_reg}),
    .dst_clk(ctrl_clk), .dst_rst(ctrl_rst),
    .dst_data(tx_cnt_ctrl)
);

logic [1:0] tx_evt_last_reg = '0;
logic       rx_status_last_reg = 1'b0;
logic [2:0] sticky_reg = '0;

// ============================================================================
// APB filter (adapter -> wrapper)
// ============================================================================
logic [4:0] apb_ok_cnt_reg = '0;
wire  apb_ok = &apb_ok_cnt_reg;

always_ff @(posedge ctrl_clk) begin
    if (!apb_ok) begin
        apb_ok_cnt_reg <= apb_ok_cnt_reg + 1;
    end
    if (xcvr_rst_any) begin
        apb_ok_cnt_reg <= '0;
    end
end

logic apb_blk_reg = 1'b0;
logic apb_err_reg = 1'b0;
wire  apb_setup = apb_adapter.psel && !apb_adapter.penable;
wire  apb_err_now = !apb_ok;
wire  apb_blk_now = apb_err_now || (apb_adapter.pwrite && apb_adapter.pstrb == '0);
wire  apb_blk = apb_setup ? apb_blk_now : apb_blk_reg;
wire  apb_err = apb_setup ? apb_err_now : apb_err_reg;

always_ff @(posedge ctrl_clk) begin
    if (apb_setup) begin
        apb_blk_reg <= apb_blk_now;
        apb_err_reg <= apb_err_now;
    end
end

assign apb_gt.paddr   = apb_adapter.paddr;
assign apb_gt.pprot   = apb_adapter.pprot;
assign apb_gt.psel    = apb_adapter.psel && !apb_blk;
assign apb_gt.penable = apb_adapter.penable && !apb_blk;
assign apb_gt.pwrite  = apb_adapter.pwrite;
assign apb_gt.pwdata  = apb_adapter.pwdata;
assign apb_gt.pstrb   = apb_adapter.pstrb;
assign apb_gt.pauser  = '0;
assign apb_gt.pwuser  = '0;

assign apb_adapter.pready  = apb_blk ? 1'b1 : apb_gt.pready;
assign apb_adapter.prdata  = apb_blk ? '0 : apb_gt.prdata;
assign apb_adapter.pslverr = apb_blk ? apb_err : apb_gt.pslverr;
assign apb_adapter.pruser  = '0;
assign apb_adapter.pbuser  = '0;

// ============================================================================
// AXI4-Lite front end: shim registers or the APB adapter, one transaction at a time
// ============================================================================
taxi_axil_if #(.DATA_W(32), .ADDR_W(APB_ADDR_W)) axil_apb();

taxi_axil_apb_adapter apb_adapter_inst (
    .clk(ctrl_clk),
    .rst(ctrl_rst),
    .s_axil_wr(axil_apb),
    .s_axil_rd(axil_apb),
    .m_apb(apb_adapter)
);

typedef enum logic [2:0] {
    AX_IDLE, AX_WR_APB, AX_WR_APB_B, AX_RD_APB, AX_RD_APB_R, AX_RD_LOCAL, AX_WR_RESP, AX_RD_RESP
} ax_state_t;

ax_state_t ax_state_reg = AX_IDLE;

logic [AXIL_ADDR_W-1:0] ax_addr_reg = '0;
logic [31:0] ax_wdata_reg = '0;
logic [3:0]  ax_wstrb_reg = '0;
logic [2:0]  ax_prot_reg = '0;

logic        s_axi_awready_reg = 1'b0;
logic        s_axi_wready_reg = 1'b0;
logic        s_axi_bvalid_reg = 1'b0;
logic [1:0]  s_axi_bresp_reg = 2'b00;
logic        s_axi_arready_reg = 1'b0;
logic        s_axi_rvalid_reg = 1'b0;
logic [1:0]  s_axi_rresp_reg = 2'b00;
logic [31:0] s_axi_rdata_reg = '0;

logic        apb_aw_done_reg = 1'b0;
logic        apb_w_done_reg = 1'b0;

logic [22:0] ts_hi_latch_reg = '0;

assign s_axi_awready = s_axi_awready_reg;
assign s_axi_wready  = s_axi_wready_reg;
assign s_axi_bresp   = s_axi_bresp_reg;
assign s_axi_bvalid  = s_axi_bvalid_reg;
assign s_axi_arready = s_axi_arready_reg;
assign s_axi_rdata   = s_axi_rdata_reg;
assign s_axi_rresp   = s_axi_rresp_reg;
assign s_axi_rvalid  = s_axi_rvalid_reg;

assign axil_apb.awaddr  = ax_addr_reg[APB_ADDR_W-1:0];
assign axil_apb.awprot  = ax_prot_reg;
assign axil_apb.awuser  = '0;
assign axil_apb.awvalid = ax_state_reg == AX_WR_APB && !apb_aw_done_reg;
assign axil_apb.wdata   = ax_wdata_reg;
assign axil_apb.wstrb   = ax_wstrb_reg;
assign axil_apb.wuser   = '0;
assign axil_apb.wvalid  = ax_state_reg == AX_WR_APB && !apb_w_done_reg;
assign axil_apb.bready  = ax_state_reg == AX_WR_APB_B;
assign axil_apb.araddr  = ax_addr_reg[APB_ADDR_W-1:0];
assign axil_apb.arprot  = ax_prot_reg;
assign axil_apb.aruser  = '0;
assign axil_apb.arvalid = ax_state_reg == AX_RD_APB;
assign axil_apb.rready  = ax_state_reg == AX_RD_APB_R;


// local register read mux
logic [31:0] reg_rdata;
always_comb begin
    reg_rdata = '0;
    if (ax_addr_reg[17:8] == '0) begin
        case (ax_addr_reg[7:2])
            6'h00: reg_rdata = REG_ID;
            6'h01: reg_rdata = REG_VERSION;
            6'h02: reg_rdata = {26'd0, ctrl_rx_en_reg, ctrl_tx_en_reg, 1'b0, ctrl_tx_rst_reg, ctrl_rx_rst_reg, ctrl_xcvr_rst_reg};
            6'h03: reg_rdata = {24'd0, rx_khz_reg != 0, tx_khz_reg != 0, status_sync};
            6'h04: reg_rdata = {29'd0, sticky_reg};
            6'h08: reg_rdata = ts_ctrl[31:0];
            6'h09: reg_rdata = {9'd0, ts_hi_latch_reg};
            6'h0A: reg_rdata = TS_INCR;
            6'h0C: reg_rdata = rx_cnt_ctrl[31:0];
            6'h0D: reg_rdata = rx_cnt_ctrl[63:32];
            6'h0E: reg_rdata = rx_cnt_ctrl[95:64];
            6'h0F: reg_rdata = tx_cnt_ctrl[31:0];
            6'h10: reg_rdata = tx_cnt_ctrl[63:32];
            6'h11: reg_rdata = tx_cnt_ctrl[95:64];
            6'h12: reg_rdata = tx_khz_reg;
            6'h13: reg_rdata = rx_khz_reg;
            default: reg_rdata = '0;
        endcase
    end
end

always_ff @(posedge ctrl_clk) begin
    s_axi_awready_reg <= 1'b0;
    s_axi_wready_reg <= 1'b0;
    s_axi_arready_reg <= 1'b0;

    // sticky events
    tx_evt_last_reg <= tx_evt_sync;
    rx_status_last_reg <= status_sync[0];
    if (rx_status_last_reg && !status_sync[0]) sticky_reg[0] <= 1'b1;
    if (tx_evt_sync[0] != tx_evt_last_reg[0]) sticky_reg[1] <= 1'b1;
    if (tx_evt_sync[1] != tx_evt_last_reg[1]) sticky_reg[2] <= 1'b1;

    case (ax_state_reg)
        AX_IDLE: begin
            if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready_reg) begin
                s_axi_awready_reg <= 1'b1;
                s_axi_wready_reg <= 1'b1;
                ax_addr_reg <= s_axi_awaddr;
                ax_prot_reg <= s_axi_awprot;
                ax_wdata_reg <= s_axi_wdata;
                ax_wstrb_reg <= s_axi_wstrb;
                apb_aw_done_reg <= 1'b0;
                apb_w_done_reg <= 1'b0;
                if (s_axi_awaddr[18]) begin
                    ax_state_reg <= AX_WR_APB;
                end else begin
                    // local write (takes effect now; response next state)
                    if (s_axi_awaddr[17:2] == 16'h0002 && s_axi_wstrb[0]) begin
                        ctrl_xcvr_rst_reg <= s_axi_wdata[0];
                        ctrl_rx_rst_reg   <= s_axi_wdata[1];
                        ctrl_tx_rst_reg   <= s_axi_wdata[2];
                        ctrl_tx_en_reg    <= s_axi_wdata[4];
                        ctrl_rx_en_reg    <= s_axi_wdata[5];
                    end
                    if (s_axi_awaddr[17:2] == 16'h0004 && s_axi_wstrb[0]) begin
                        sticky_reg <= sticky_reg & ~s_axi_wdata[2:0];
                    end
                    s_axi_bresp_reg <= 2'b00;
                    s_axi_bvalid_reg <= 1'b1;
                    ax_state_reg <= AX_WR_RESP;
                end
            end else if (s_axi_arvalid && !s_axi_arready_reg) begin
                s_axi_arready_reg <= 1'b1;
                ax_addr_reg <= s_axi_araddr;
                ax_prot_reg <= s_axi_arprot;
                if (s_axi_araddr[18]) begin
                    ax_state_reg <= AX_RD_APB;
                end else begin
                    ax_state_reg <= AX_RD_LOCAL;   // reg_rdata decodes ax_addr_reg
                end
            end
        end
        AX_WR_APB: begin
            if (axil_apb.awready) apb_aw_done_reg <= 1'b1;
            if (axil_apb.wready)  apb_w_done_reg <= 1'b1;
            if ((apb_aw_done_reg || axil_apb.awready) && (apb_w_done_reg || axil_apb.wready)) begin
                ax_state_reg <= AX_WR_APB_B;
            end
        end
        AX_WR_APB_B: begin
            if (axil_apb.bvalid) begin
                s_axi_bresp_reg <= axil_apb.bresp;
                s_axi_bvalid_reg <= 1'b1;
                ax_state_reg <= AX_WR_RESP;
            end
        end
        AX_RD_APB: begin
            if (axil_apb.arready) begin
                ax_state_reg <= AX_RD_APB_R;
            end
        end
        AX_RD_APB_R: begin
            if (axil_apb.rvalid) begin
                s_axi_rdata_reg <= axil_apb.rdata;
                s_axi_rresp_reg <= axil_apb.rresp;
                s_axi_rvalid_reg <= 1'b1;
                ax_state_reg <= AX_RD_RESP;
            end
        end
        AX_RD_LOCAL: begin
            s_axi_rdata_reg <= reg_rdata;
            s_axi_rresp_reg <= 2'b00;
            s_axi_rvalid_reg <= 1'b1;
            if (ax_addr_reg[17:2] == 16'h0008) begin
                ts_hi_latch_reg <= ts_ctrl[54:32];   // TS_NOW_LO read latches TS_NOW_HI
            end
            ax_state_reg <= AX_RD_RESP;
        end
        AX_WR_RESP: begin
            if (s_axi_bready) begin
                s_axi_bvalid_reg <= 1'b0;
                ax_state_reg <= AX_IDLE;
            end
        end
        AX_RD_RESP: begin
            if (s_axi_rready) begin
                s_axi_rvalid_reg <= 1'b0;
                ax_state_reg <= AX_IDLE;
            end
        end
        default: ax_state_reg <= AX_IDLE;
    endcase

    if (ctrl_rst) begin
        ax_state_reg <= AX_IDLE;
        s_axi_awready_reg <= 1'b0;
        s_axi_wready_reg <= 1'b0;
        s_axi_bvalid_reg <= 1'b0;
        s_axi_arready_reg <= 1'b0;
        s_axi_rvalid_reg <= 1'b0;
        ctrl_xcvr_rst_reg <= 1'b1;
        ctrl_rx_rst_reg <= 1'b0;
        ctrl_tx_rst_reg <= 1'b0;
        ctrl_tx_en_reg <= 1'b1;
        ctrl_rx_en_reg <= 1'b1;
        sticky_reg <= '0;
        tx_evt_last_reg <= tx_evt_sync;
        rx_status_last_reg <= 1'b0;
    end
end

endmodule

`resetall

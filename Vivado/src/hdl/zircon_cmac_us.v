// SPDX-License-Identifier: MIT
//
// zircon_cmac_us - block-design module reference: UltraScale+ 100G CMAC (through Taxi's
// taxi_eth_mac_100g_us wrapper) with the MAC-side interface zircon_nic expects:
// 512-bit Taxi-convention AXI-Streams on the CMAC tx_clk / rx_clk, fabric timestamps
// (RX first-beat timestamp on tuser[48:1], TX two-step timestamp return with tag), an
// AXI4-Lite register block and the Taxi transceiver-control APB space.
//
// This thin Verilog shell exists because Vivado requires a Verilog (.v) top for a
// block-design module reference; the implementation is the SystemVerilog module
// zircon_cmac_us_core (zircon_cmac_us_core.sv, MIT), which instantiates the Taxi library
// from submodules/taxi (CERN-OHL-S-2.0, see submodules/README.md).
// Port list and register map: docs/DESIGN_SPEC.md section 6c.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module zircon_cmac_us #(
    parameter FAMILY             = "kintexuplus",
    parameter CFG_LOW_LATENCY    = 0,
    parameter [3:0] GT_TX_POLARITY = 4'b0000,
    parameter [3:0] GT_RX_POLARITY = 4'b0000,
    parameter C_S_AXI_ADDR_WIDTH = 19,
    parameter TS_INCR            = 1024,   // ts55 units per ts_clk cycle (2^-8 ns; 1024 = 4 ns at 250 MHz)
    parameter SIM                = 0
)(
    // ---- GT reference clock (322.265625 MHz, IBUFDS_GTE4 inside) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref_clk CLK_P" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 322265625" *)
    input  wire         gt_ref_clk_clk_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref_clk CLK_N" *)
    input  wire         gt_ref_clk_clk_n,
    // ---- GT serial lanes ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GTX_P" *)
    output wire [3:0]   gt_gtx_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GTX_N" *)
    output wire [3:0]   gt_gtx_n,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GRX_P" *)
    input  wire [3:0]   gt_grx_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GRX_N" *)
    input  wire [3:0]   gt_grx_n,
    // ---- control clock (125 MHz: Taxi xcvr_ctrl_clk, GT free-run/DRP, APB, s_axi) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ctrl_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET ctrl_aresetn" *)
    input  wire         ctrl_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ctrl_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         ctrl_aresetn,
    // ---- timestamp timebase (250 MHz) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ts_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF none, ASSOCIATED_RESET ts_aresetn" *)
    input  wire         ts_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ts_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         ts_aresetn,
    // ---- MAC clocks / resets out ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 322265625, ASSOCIATED_BUSIF s_axis_mac_tx:s_axis_tx_ptp, ASSOCIATED_RESET mac_tx_aresetn" *)
    output wire         tx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_tx_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         mac_tx_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 322265625, ASSOCIATED_BUSIF m_axis_mac_rx, ASSOCIATED_RESET mac_rx_aresetn" *)
    output wire         rx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_rx_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         mac_rx_aresetn,
    // ---- m_axis_mac_rx (rx_clk; 512 b; tuser[0] = CMAC error on last beat,
    //      tuser[48:1] = ts55[54:7] of the frame's first beat, on every beat; no back-pressure) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TDATA" *)
    output wire [511:0] m_axis_mac_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TKEEP" *)
    output wire [63:0]  m_axis_mac_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TVALID" *)
    output wire         m_axis_mac_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TREADY" *)
    input  wire         m_axis_mac_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TLAST" *)
    output wire         m_axis_mac_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_rx TUSER" *)
    output wire [48:0]  m_axis_mac_rx_tuser,
    // ---- s_axis_mac_tx (tx_clk; 512 b; tuser[0] = bad frame) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TDATA" *)
    input  wire [511:0] s_axis_mac_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TKEEP" *)
    input  wire [63:0]  s_axis_mac_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TVALID" *)
    input  wire         s_axis_mac_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TREADY" *)
    output wire         s_axis_mac_tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TLAST" *)
    input  wire         s_axis_mac_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_tx TUSER" *)
    input  wire [0:0]   s_axis_mac_tx_tuser,
    // ---- s_axis_tx_ptp (tx_clk; one record per frame: [1:0] op, [17:2] tag; 16-entry FIFO) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_ptp TDATA" *)
    input  wire [23:0]  s_axis_tx_ptp_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_ptp TVALID" *)
    input  wire         s_axis_tx_ptp_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_ptp TREADY" *)
    output wire         s_axis_tx_ptp_tready,
    // ---- TX timestamp return (tx_clk) ----
    (* X_INTERFACE_IGNORE = "true" *)
    output wire [54:0]  tx_ptp_tstamp_out,
    (* X_INTERFACE_IGNORE = "true" *)
    output wire [15:0]  tx_ptp_tstamp_tag_out,
    (* X_INTERFACE_IGNORE = "true" *)
    output wire         tx_ptp_tstamp_valid_out,
    // ---- status ----
    output wire         link_up,
    // ---- s_axi (AXI4-Lite slave, ctrl_clk; regs at +0x0_0000, GT APB at +0x4_0000) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]   s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire         s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]  s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]   s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire         s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire         s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]   s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire         s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire         s_axi_rready
);

    zircon_cmac_us_core #(
        .FAMILY          (FAMILY),
        .CFG_LOW_LATENCY (CFG_LOW_LATENCY),
        .GT_TX_POLARITY  (GT_TX_POLARITY),
        .GT_RX_POLARITY  (GT_RX_POLARITY),
        .AXIL_ADDR_W     (C_S_AXI_ADDR_WIDTH),
        .TS_INCR         (TS_INCR),
        .SIM             (SIM)
    ) core (
        .gt_ref_clk_p(gt_ref_clk_clk_p), .gt_ref_clk_n(gt_ref_clk_clk_n),
        .gt_txp(gt_gtx_p), .gt_txn(gt_gtx_n), .gt_rxp(gt_grx_p), .gt_rxn(gt_grx_n),
        .ctrl_clk(ctrl_clk), .ctrl_aresetn(ctrl_aresetn),
        .ts_clk(ts_clk), .ts_aresetn(ts_aresetn),
        .tx_clk(tx_clk), .rx_clk(rx_clk),
        .mac_tx_aresetn(mac_tx_aresetn), .mac_rx_aresetn(mac_rx_aresetn),
        .m_axis_mac_rx_tdata(m_axis_mac_rx_tdata),
        .m_axis_mac_rx_tkeep(m_axis_mac_rx_tkeep),
        .m_axis_mac_rx_tvalid(m_axis_mac_rx_tvalid),
        .m_axis_mac_rx_tready(m_axis_mac_rx_tready),
        .m_axis_mac_rx_tlast(m_axis_mac_rx_tlast),
        .m_axis_mac_rx_tuser(m_axis_mac_rx_tuser),
        .s_axis_mac_tx_tdata(s_axis_mac_tx_tdata),
        .s_axis_mac_tx_tkeep(s_axis_mac_tx_tkeep),
        .s_axis_mac_tx_tvalid(s_axis_mac_tx_tvalid),
        .s_axis_mac_tx_tready(s_axis_mac_tx_tready),
        .s_axis_mac_tx_tlast(s_axis_mac_tx_tlast),
        .s_axis_mac_tx_tuser(s_axis_mac_tx_tuser),
        .s_axis_tx_ptp_tdata(s_axis_tx_ptp_tdata),
        .s_axis_tx_ptp_tvalid(s_axis_tx_ptp_tvalid),
        .s_axis_tx_ptp_tready(s_axis_tx_ptp_tready),
        .tx_ptp_tstamp_out(tx_ptp_tstamp_out),
        .tx_ptp_tstamp_tag_out(tx_ptp_tstamp_tag_out),
        .tx_ptp_tstamp_valid_out(tx_ptp_tstamp_valid_out),
        .link_up(link_up),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready)
    );

endmodule

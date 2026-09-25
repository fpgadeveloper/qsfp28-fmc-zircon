// SPDX-License-Identifier: MIT
//
// zircon_nic - block-design module reference: 100G MAC-side AXI-Stream <-> Taxi Zircon
// IP stack <-> raw / hardware-UDP-socket AXI-Streams + AXI-Lite registers.
//
// This thin Verilog shell exists because Vivado requires a Verilog (.v) top for a
// block-design module reference; the implementation is the SystemVerilog module
// zircon_nic_core (zircon_nic_core.sv, MIT), which instantiates the Taxi library and
// Zircon modules from submodules/taxi (CERN-OHL-S-2.0, see submodules/README.md).
// Port list, register map and datapath: docs/DESIGN_SPEC.md.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module zircon_nic #(
    parameter DATA_W         = 512,    // MAC-side, core and UI AXI-Stream width (bits)
    parameter TRUNC_BYTES    = 64,     // header bytes fed to the 32-bit Zircon parser per packet
    parameter RX_FIFO_BEATS  = 512,    // MAC-side RX frame FIFO depth (beats): drop-bad, drop-when-full
    parameter PKT_FIFO_BEATS = 512,    // core store-and-forward RX frame FIFO depth (beats)
    parameter TX_RAM_SIZE    = 32768,  // zircon_ip_tx_buffer payload RAM (bytes)
    parameter TX_FIFO_BEATS  = 512,    // zircon_ip_tx_egress MAC-side frame FIFO depth (beats)
    parameter GEN_EN         = 1,      // hardware UDP generator + checker (1.2.0); 0 = not built, registers read 0
    parameter CORE_HZ        = 300000000, // core clock cycles per rate-meter window (1 s at 300 MHz)
    parameter C_S_AXI_ADDR_WIDTH = 12
)(
    // ---- core clock domain (Zircon + glue) ----
    // The core clock has no bus interface. "ASSOCIATED_BUSIF none" is required:
    // without an ASSOCIATED_BUSIF, IP integrator associates a pin named 'clk'
    // with EVERY interface of the module reference (multiple-clock CRITICAL
    // WARNINGs and FREQ_HZ / CLK_DOMAIN mismatches at validation).
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF none, ASSOCIATED_RESET aresetn" *)
    input  wire                          clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          aresetn,
    // ---- MAC RX domain ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 mac_rx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_mac_rx, ASSOCIATED_RESET mac_rx_aresetn" *)
    input  wire                          mac_rx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_rx_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          mac_rx_aresetn,
    // s_axis_mac_rx (slave AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame, tuser[0] = bad frame / error,
    // tuser[48:1] = the frame's MRMAC RX timestamp bits [54:7] (0.5 ns units; mrmac_rx_packer), used from the last beat)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TDATA" *)
    input  wire [DATA_W-1:0]             s_axis_mac_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TKEEP" *)
    input  wire [DATA_W/8-1:0]           s_axis_mac_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TVALID" *)
    input  wire                          s_axis_mac_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TREADY" *)
    output wire                          s_axis_mac_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TLAST" *)
    input  wire                          s_axis_mac_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_mac_rx TUSER" *)
    input  wire [48:0]                   s_axis_mac_rx_tuser,
    // mrmac_rx_packer status pulses (mac_rx_clk domain): [0] output stalled
    // (tready low), [1] beats dropped -> STATUS b4 RX_PACK_STALL / b5 RX_PACK_OVF
    input  wire [1:0]                    mac_rx_pack_stat,
    // ---- MAC TX domain ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 mac_tx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis_mac_tx:m_axis_tx_ptp, ASSOCIATED_RESET mac_tx_aresetn" *)
    input  wire                          mac_tx_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 mac_tx_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          mac_tx_aresetn,
    // m_axis_mac_tx (master AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame, tuser[0] = bad frame / error)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TDATA" *)
    output wire [DATA_W-1:0]             m_axis_mac_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TKEEP" *)
    output wire [DATA_W/8-1:0]           m_axis_mac_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TVALID" *)
    output wire                          m_axis_mac_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TREADY" *)
    input  wire                          m_axis_mac_tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TLAST" *)
    output wire                          m_axis_mac_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mac_tx TUSER" *)
    output wire [0:0]                    m_axis_mac_tx_tuser,
    // m_axis_tx_ptp (master AXI-Stream, mac_tx_clk, 1.3.0): one record per frame sent on m_axis_mac_tx, in frame
    // order, pushed before the frame's first beat leaves: tdata[1:0] = MRMAC 1588 op (2'b10 two-step timestamp,
    // 2'b00 none), tdata[17:2] = tag, tdata[23:18] = 0. To mrmac_tx_axis_adapter s_axis_ptp. If unused, tie
    // tready to 1 (a full record FIFO holds the TX path).
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_ptp TDATA" *)
    output wire [23:0]                   m_axis_tx_ptp_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_ptp TVALID" *)
    output wire                          m_axis_tx_ptp_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_ptp TREADY" *)
    input  wire                          m_axis_tx_ptp_tready,
    // MRMAC TX timestamp return (mac_tx_clk): tx_ptp_tstamp_out_0 / tx_ptp_tstamp_tag_out_0 / tx_ptp_tstamp_valid_out_0
    (* X_INTERFACE_IGNORE = "true" *)
    input  wire [54:0]                   tx_ptp_tstamp_in,
    (* X_INTERFACE_IGNORE = "true" *)
    input  wire [15:0]                   tx_ptp_tstamp_tag_in,
    (* X_INTERFACE_IGNORE = "true" *)
    input  wire                          tx_ptp_tstamp_valid_in,
    // ---- UI / DMA / AXI-Lite domain ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ui_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axis_raw_rx:s_axis_raw_tx:m_axis_sock_rx:s_axis_sock_tx, ASSOCIATED_RESET ui_aresetn" *)
    input  wire                          ui_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ui_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          ui_aresetn,
    // m_axis_raw_rx (master AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_raw_rx TDATA" *)
    output wire [DATA_W-1:0]             m_axis_raw_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_raw_rx TKEEP" *)
    output wire [DATA_W/8-1:0]           m_axis_raw_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_raw_rx TVALID" *)
    output wire                          m_axis_raw_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_raw_rx TREADY" *)
    input  wire                          m_axis_raw_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_raw_rx TLAST" *)
    output wire                          m_axis_raw_rx_tlast,
    // s_axis_raw_tx (slave AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_raw_tx TDATA" *)
    input  wire [DATA_W-1:0]             s_axis_raw_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_raw_tx TKEEP" *)
    input  wire [DATA_W/8-1:0]           s_axis_raw_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_raw_tx TVALID" *)
    input  wire                          s_axis_raw_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_raw_tx TREADY" *)
    output wire                          s_axis_raw_tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_raw_tx TLAST" *)
    input  wire                          s_axis_raw_tx_tlast,
    // m_axis_sock_rx (master AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_sock_rx TDATA" *)
    output wire [DATA_W-1:0]             m_axis_sock_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_sock_rx TKEEP" *)
    output wire [DATA_W/8-1:0]           m_axis_sock_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_sock_rx TVALID" *)
    output wire                          m_axis_sock_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_sock_rx TREADY" *)
    input  wire                          m_axis_sock_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_sock_rx TLAST" *)
    output wire                          m_axis_sock_rx_tlast,
    // s_axis_sock_tx (slave AXI-Stream, DATA_W bit, Taxi conventions: tkeep byte-valid, tlast per frame)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_sock_tx TDATA" *)
    input  wire [DATA_W-1:0]             s_axis_sock_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_sock_tx TKEEP" *)
    input  wire [DATA_W/8-1:0]           s_axis_sock_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_sock_tx TVALID" *)
    input  wire                          s_axis_sock_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_sock_tx TREADY" *)
    output wire                          s_axis_sock_tx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_sock_tx TLAST" *)
    input  wire                          s_axis_sock_tx_tlast,
    // s_axi (AXI4-Lite slave, 32-bit data, register map in docs/DESIGN_SPEC.md)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]                    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                          s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]                   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]                    s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                          s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                          s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                          s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]                    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                          s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]                   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                          s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                          s_axi_rready
);

    zircon_nic_core #(
        .DATA_W         (DATA_W),
        .TRUNC_BYTES    (TRUNC_BYTES),
        .RX_FIFO_BEATS  (RX_FIFO_BEATS),
        .PKT_FIFO_BEATS (PKT_FIFO_BEATS),
        .TX_RAM_SIZE    (TX_RAM_SIZE),
        .TX_FIFO_BEATS  (TX_FIFO_BEATS),
        .AXIL_ADDR_W    (C_S_AXI_ADDR_WIDTH),
        .GEN_EN         (GEN_EN != 0),
        .CORE_HZ        (CORE_HZ)
    ) core (
        .clk(clk), .aresetn(aresetn),
        .mac_rx_clk(mac_rx_clk), .mac_rx_aresetn(mac_rx_aresetn),
        .s_axis_mac_rx_tdata(s_axis_mac_rx_tdata),
        .s_axis_mac_rx_tkeep(s_axis_mac_rx_tkeep),
        .s_axis_mac_rx_tvalid(s_axis_mac_rx_tvalid),
        .s_axis_mac_rx_tready(s_axis_mac_rx_tready),
        .s_axis_mac_rx_tlast(s_axis_mac_rx_tlast),
        .s_axis_mac_rx_tuser(s_axis_mac_rx_tuser),
        .mac_rx_pack_stat(mac_rx_pack_stat),
        .mac_tx_clk(mac_tx_clk), .mac_tx_aresetn(mac_tx_aresetn),
        .m_axis_mac_tx_tdata(m_axis_mac_tx_tdata),
        .m_axis_mac_tx_tkeep(m_axis_mac_tx_tkeep),
        .m_axis_mac_tx_tvalid(m_axis_mac_tx_tvalid),
        .m_axis_mac_tx_tready(m_axis_mac_tx_tready),
        .m_axis_mac_tx_tlast(m_axis_mac_tx_tlast),
        .m_axis_mac_tx_tuser(m_axis_mac_tx_tuser),
        .m_axis_tx_ptp_tdata(m_axis_tx_ptp_tdata),
        .m_axis_tx_ptp_tvalid(m_axis_tx_ptp_tvalid),
        .m_axis_tx_ptp_tready(m_axis_tx_ptp_tready),
        .tx_ptp_tstamp_in(tx_ptp_tstamp_in),
        .tx_ptp_tstamp_tag_in(tx_ptp_tstamp_tag_in),
        .tx_ptp_tstamp_valid_in(tx_ptp_tstamp_valid_in),
        .ui_clk(ui_clk), .ui_aresetn(ui_aresetn),
        .m_axis_raw_rx_tdata(m_axis_raw_rx_tdata),
        .m_axis_raw_rx_tkeep(m_axis_raw_rx_tkeep),
        .m_axis_raw_rx_tvalid(m_axis_raw_rx_tvalid),
        .m_axis_raw_rx_tready(m_axis_raw_rx_tready),
        .m_axis_raw_rx_tlast(m_axis_raw_rx_tlast),
        .s_axis_raw_tx_tdata(s_axis_raw_tx_tdata),
        .s_axis_raw_tx_tkeep(s_axis_raw_tx_tkeep),
        .s_axis_raw_tx_tvalid(s_axis_raw_tx_tvalid),
        .s_axis_raw_tx_tready(s_axis_raw_tx_tready),
        .s_axis_raw_tx_tlast(s_axis_raw_tx_tlast),
        .m_axis_sock_rx_tdata(m_axis_sock_rx_tdata),
        .m_axis_sock_rx_tkeep(m_axis_sock_rx_tkeep),
        .m_axis_sock_rx_tvalid(m_axis_sock_rx_tvalid),
        .m_axis_sock_rx_tready(m_axis_sock_rx_tready),
        .m_axis_sock_rx_tlast(m_axis_sock_rx_tlast),
        .s_axis_sock_tx_tdata(s_axis_sock_tx_tdata),
        .s_axis_sock_tx_tkeep(s_axis_sock_tx_tkeep),
        .s_axis_sock_tx_tvalid(s_axis_sock_tx_tvalid),
        .s_axis_sock_tx_tready(s_axis_sock_tx_tready),
        .s_axis_sock_tx_tlast(s_axis_sock_tx_tlast),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready)
    );

endmodule

// SPDX-License-Identifier: MIT
//
// zircon_nic_core - 100G MAC-side AXI-Stream <-> Taxi Zircon IP stack <-> raw and
// hardware-UDP-socket AXI-Streams, with a hardware UDP echo and AXI-Lite registers.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root). It instantiates
// modules from the Taxi transport library and its Zircon IP stack
// (submodules/taxi, CERN-OHL-S-2.0, unmodified) - see submodules/README.md.
// Instantiated by zircon_nic.v, the Verilog shell the block design references.
// Contract: docs/DESIGN_SPEC.md §3-§5.
//
// ============================================================================
// RX (MAC -> core)
//   s_axis_mac_rx (mac_rx_clk)
//    -> taxi_axis_async_fifo: frame FIFO, drops frames marked bad (tuser[0] on the
//       last beat), oversize frames and frames arriving while full; never
//       back-pressures the MAC. RX_FIFO_BEATS deep.                    -> clk
//    -> taxi_axis_broadcast (2 outputs, lockstep)
//       [A] zircon_ip_len_cksum (START_OFFSET 14) -> packet FIFO (store and
//           forward, PKT_FIFO_BEATS, never drops) ; {sum,len} -> len FIFO
//       [B] hdr_trunc (first TRUNC_BYTES) -> header FIFO (HDR_FIFO_BEATS)
//           -> taxi_axis_adapter 512->32 -> zircon_ip_rx_parse (HASH_EN 0)
//           -> rx_meta_capture -> record FIFO (one rx_hdr_rec_t per packet)
//    -> rx_dispatch: classify (ECHO / SOCK / CHK / RAW / DROP) and route
//       RAW  -> drop-when-full frame FIFO -> zircon_ip_rx_egress -> m_axis_raw_rx (ui_clk)
//       SOCK -> descriptor + payload -> drop-when-full frame FIFO -> zircon_ip_rx_egress
//               -> m_axis_sock_rx
//       ECHO -> payload -> echo frame FIFO -> tx_buffer input 1 ; addresses -> echo-
//               metadata FIFO (dispatch drops the request when either has no room)
//       CHK  -> payload -> udp_chk (GEN_EN: sequence / PRBS bit-error checker,
//               never back-pressures)
//       so a stalled consumer (DMA ring empty, TX busy) never blocks the other paths
//
// TX (core -> MAC)
//   s_axis_raw_tx  (ui_clk) -> zircon_ip_tx_ingress -> tx_len_guard -> tdest 0 -+
//   echo payload   (clk)    -> echo frame FIFO                     -> tdest 1 -+-> tx_buffer
//   s_axis_sock_tx (ui_clk) -> zircon_ip_tx_ingress -> tx_len_guard -> tdest 2 -+   (N_UI 3/4)
//   udp_gen payloads (clk, GEN_EN)                                 -> tdest 3 -+
//     tx_len_guard: store-and-forward frame FIFO that drops (TX_OVERSIZE_DROP) any
//     transfer longer than MAX_TX_BYTES, which would otherwise wedge tx_buffer
//     {sum,len}+tdest -> len FIFO -> tx_meta_builder -> 16x64b metadata --+
//     payload ------------------------------------------------------------+-> zircon_ip_tx_egress
//   -> (mac_tx_clk, frame FIFO TX_FIFO_BEATS) -> tx_mac_out (TX_EN gate, pad to
//      60 bytes, register) -> ptp_tx_tagger -> m_axis_mac_tx
//     (1.3.0: zircon_ip_tx_egress is instantiated as its parts - deparser, header
//     adapter, concat, MAC-side async frame FIFO - so a per-frame latency record
//     can ride in tuser from the concat output through the frame FIFO.)
//
// Latency measurement (1.3.0, docs/DESIGN_SPEC.md §11)
//   RX: s_axis_mac_rx_tuser[48:1] = MRMAC RX timestamp [54:7] of the frame, carried
//     with the frame through the MAC-side FIFO, broadcast and len_cksum into the
//     len record; rx_dispatch puts it in the echo record and (LAT_CTRL.RAW_RX_DESC)
//     a ZRXT descriptor in front of RAW frames.
//   TX: raw_tx_desc_strip (UI0, LAT_CTRL.RAW_TX_DESC) turns a ZTXT descriptor into
//     a record; tx_meta_builder emits one lat_rec_t per packet (echo: bank 0, raw
//     with TS_REQ: bank 1) into the latency-record FIFO; it is attached to the frame
//     as it leaves the concat (tuser[51:1]), crosses to mac_tx_clk inside the frame
//     FIFO, and ptp_tx_tagger issues the MRMAC {tag, op} record (m_axis_tx_ptp) and
//     turns returned TX timestamps into samples -> async FIFO -> latency_stats
//     (core clock) -> shadow RAM read by zircon_regs.
//
// Sizing / deadlock freedom
//   * zircon_ip_len_cksum's metadata output has no back-pressure, so its FIFOs
//     are sized for the worst case: every packet whose last beat has passed the
//     len_cksum is either in the packet FIFO (RX) / tx_buffer RAM (TX) or in
//     flight, and every packet occupies at least one beat, so at most
//     PKT_FIFO_BEATS (RX) / TX_RAM_SIZE/64 (TX) records are outstanding (+ a few
//     in flight). Both len FIFOs hold twice that. An overflow (which cannot
//     happen) would set STATUS.RX_META_ERR / TX_META_ERR.
//   * The parser output IS back-pressured: when the record FIFO is full the
//     header branch stalls, the lockstep broadcast stalls and the MAC-side FIFO
//     drops whole frames (counted). The record FIFO holds PKT_FIFO_BEATS records
//     so for minimum-size frames the packet FIFO, not the record FIFO, limits.
//   * The packet at the head of the packet FIFO is the oldest packet, so its
//     header record is always the first one the parser produces: no circular wait.
//     PKT_FIFO_BEATS >= RX_FIFO_BEATS guarantees a frame that passed the MAC-side
//     FIFO (which drops oversize frames) fits the packet FIFO completely, so the
//     len record (produced after the last beat) always arrives.
//   * rx_dispatch pops a frame only once its len and header records both exist.
//   * Echo: rx_dispatch pushes the echo record before the payload enters the
//     tx_buffer, and waits if the echo-metadata FIFO is full; tx_meta_builder
//     pops it when the matching len record arrives.
//
// Throughput (core clock 300 MHz, 512 b = 153.6 Gb/s bus)
//   * Data path: one beat per cycle everywhere. The parser branch costs about
//     TRUNC_BYTES/4 + 3 = 19 cycles per packet (it sees at most 64 bytes), so
//     the RX path runs at line rate for frames of ~1 KB and larger and at about
//     15 Mpps for small frames; excess small frames are dropped whole at the
//     MAC-side FIFO (RX_FIFO_DROP). The header FIFO (HDR_FIFO_BEATS truncated
//     headers) absorbs bursts of small frames.
//   * rx_dispatch: 6 cycles overhead per packet (7 for SOCK / RX descriptor) + 1 beat/cycle;
//     with the 16-cycle parser the RX ceiling is 18.75 Mpps.
//   * TX: tx_meta_builder + deparser = 18 cycles/packet (16.7 Mpps; measured
//     16,666,500 pps at <= 512 B payloads on the bench), see DESIGN_SPEC §10.
//   * rate_meter: RX / TX frames and bytes per CORE_HZ-cycle window (1 s).
//
// Clock domain crossings
//   * Data: Taxi async FIFOs (MAC-side RX FIFO, rx_egress x2, tx_ingress x2,
//     tx_egress), constrained by taxi_axis_async_fifo.tcl.
//   * Configuration (ui -> clk) and counter snapshots (mac_rx/clk/mac_tx -> ui):
//     zircon_cdc_snapshot (a small async FIFO carrying the whole word), so every
//     register set / counter group crosses coherently.
//   * CTRL.TX_EN and the STAT_CLR toggle to mac_tx/mac_rx: taxi_sync_signal.
//   * Resets: every *_aresetn is converted to a Taxi-style synchronous
//     active-high reset per domain by taxi_sync_reset.
// ============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module zircon_nic_core
    import zircon_nic_pkg::*;
#(
    parameter int DATA_W         = 512,
    parameter int TRUNC_BYTES    = 64,
    parameter int RX_FIFO_BEATS  = 512,
    parameter int PKT_FIFO_BEATS = 512,
    parameter int TX_RAM_SIZE    = 32768,
    parameter int TX_FIFO_BEATS  = 512,
    parameter int AXIL_ADDR_W    = 12,
    parameter int HDR_FIFO_BEATS = 64,     // truncated headers buffered ahead of the parser
    parameter int UI_FIFO_BEATS  = 64,     // rx_egress / tx_ingress async FIFOs
    parameter int ECHO_META_DEPTH = 256,   // echo records in flight
    parameter int RX_PATH_FIFO_BEATS = 512, // RAW / SOCK / ECHO decoupling frame FIFOs (>= 2 jumbo frames)
    parameter int MAX_TX_BYTES   = 9618,   // longest UI0/UI2 TX transfer accepted (jumbo 9600 + margin)
    parameter int TX_GUARD_BEATS = 256,    // tx_len_guard frame FIFOs (must hold MAX_TX_BYTES)
    parameter bit GEN_EN         = 1'b1,   // hardware UDP generator (tdest 3) + checker (CHK rule)
    parameter int unsigned CORE_HZ = 300_000_000  // core clock cycles per rate-meter window
) (
    // ---- core clock domain ----
    input  wire logic                    clk,
    input  wire logic                    aresetn,

    // ---- MAC RX domain ----
    input  wire logic                    mac_rx_clk,
    input  wire logic                    mac_rx_aresetn,
    input  wire logic [DATA_W-1:0]       s_axis_mac_rx_tdata,
    input  wire logic [DATA_W/8-1:0]     s_axis_mac_rx_tkeep,
    input  wire logic                    s_axis_mac_rx_tvalid,
    output wire logic                    s_axis_mac_rx_tready,
    input  wire logic                    s_axis_mac_rx_tlast,
    input  wire logic [48:0]             s_axis_mac_rx_tuser,  // [0] bad, [48:1] RX timestamp [54:7]
    input  wire logic [1:0]              mac_rx_pack_stat,     // mrmac_rx_packer: [0] stall, [1] overflow

    // ---- MAC TX domain ----
    input  wire logic                    mac_tx_clk,
    input  wire logic                    mac_tx_aresetn,
    output wire logic [DATA_W-1:0]       m_axis_mac_tx_tdata,
    output wire logic [DATA_W/8-1:0]     m_axis_mac_tx_tkeep,
    output wire logic                    m_axis_mac_tx_tvalid,
    input  wire logic                    m_axis_mac_tx_tready,
    output wire logic                    m_axis_mac_tx_tlast,
    output wire logic [0:0]              m_axis_mac_tx_tuser,
    output wire logic [23:0]             m_axis_tx_ptp_tdata,  // {6'd0, tag[15:0], op[1:0]}
    output wire logic                    m_axis_tx_ptp_tvalid,
    input  wire logic                    m_axis_tx_ptp_tready,
    input  wire logic [54:0]             tx_ptp_tstamp_in,
    input  wire logic [15:0]             tx_ptp_tstamp_tag_in,
    input  wire logic                    tx_ptp_tstamp_valid_in,

    // ---- UI / DMA / AXI-Lite domain ----
    input  wire logic                    ui_clk,
    input  wire logic                    ui_aresetn,
    output wire logic [DATA_W-1:0]       m_axis_raw_rx_tdata,
    output wire logic [DATA_W/8-1:0]     m_axis_raw_rx_tkeep,
    output wire logic                    m_axis_raw_rx_tvalid,
    input  wire logic                    m_axis_raw_rx_tready,
    output wire logic                    m_axis_raw_rx_tlast,
    input  wire logic [DATA_W-1:0]       s_axis_raw_tx_tdata,
    input  wire logic [DATA_W/8-1:0]     s_axis_raw_tx_tkeep,
    input  wire logic                    s_axis_raw_tx_tvalid,
    output wire logic                    s_axis_raw_tx_tready,
    input  wire logic                    s_axis_raw_tx_tlast,
    output wire logic [DATA_W-1:0]       m_axis_sock_rx_tdata,
    output wire logic [DATA_W/8-1:0]     m_axis_sock_rx_tkeep,
    output wire logic                    m_axis_sock_rx_tvalid,
    input  wire logic                    m_axis_sock_rx_tready,
    output wire logic                    m_axis_sock_rx_tlast,
    input  wire logic [DATA_W-1:0]       s_axis_sock_tx_tdata,
    input  wire logic [DATA_W/8-1:0]     s_axis_sock_tx_tkeep,
    input  wire logic                    s_axis_sock_tx_tvalid,
    output wire logic                    s_axis_sock_tx_tready,
    input  wire logic                    s_axis_sock_tx_tlast,

    input  wire logic [AXIL_ADDR_W-1:0]  s_axi_awaddr,
    input  wire logic [2:0]              s_axi_awprot,
    input  wire logic                    s_axi_awvalid,
    output wire logic                    s_axi_awready,
    input  wire logic [31:0]             s_axi_wdata,
    input  wire logic [3:0]              s_axi_wstrb,
    input  wire logic                    s_axi_wvalid,
    output wire logic                    s_axi_wready,
    output wire logic [1:0]              s_axi_bresp,
    output wire logic                    s_axi_bvalid,
    input  wire logic                    s_axi_bready,
    input  wire logic [AXIL_ADDR_W-1:0]  s_axi_araddr,
    input  wire logic [2:0]              s_axi_arprot,
    input  wire logic                    s_axi_arvalid,
    output wire logic                    s_axi_arready,
    output wire logic [31:0]             s_axi_rdata,
    output wire logic [1:0]              s_axi_rresp,
    output wire logic                    s_axi_rvalid,
    input  wire logic                    s_axi_rready
);

localparam int KEEP_W = DATA_W / 8;

// ---- configuration checks ----
if (DATA_W != 512)
    $fatal(0, "Error: zircon_nic_core supports DATA_W = 512 only (instance %m)");

if (PKT_FIFO_BEATS < RX_FIFO_BEATS)
    $fatal(0, "Error: PKT_FIFO_BEATS must be >= RX_FIFO_BEATS (a frame accepted by the MAC-side FIFO must fit the packet FIFO) (instance %m)");

if ((PKT_FIFO_BEATS & (PKT_FIFO_BEATS - 1)) != 0 || (RX_FIFO_BEATS & (RX_FIFO_BEATS - 1)) != 0 ||
    (TX_FIFO_BEATS & (TX_FIFO_BEATS - 1)) != 0 || (TX_RAM_SIZE & (TX_RAM_SIZE - 1)) != 0)
    $fatal(0, "Error: FIFO depths must be powers of two (instance %m)");

if (TX_RAM_SIZE < 16384 || TX_FIFO_BEATS * KEEP_W < 16384 || RX_FIFO_BEATS * KEEP_W < 16384)
    $fatal(0, "Error: FIFOs must hold at least 16 KB for 9000-byte jumbo frames (instance %m)");

if (RX_PATH_FIFO_BEATS * KEEP_W < 16384 || (RX_PATH_FIFO_BEATS & (RX_PATH_FIFO_BEATS - 1)) != 0)
    $fatal(0, "Error: RX_PATH_FIFO_BEATS must be a power of two holding >= 16 KB (instance %m)");

if (MAX_TX_BYTES >= TX_RAM_SIZE || TX_GUARD_BEATS * KEEP_W >= TX_RAM_SIZE)
    $fatal(0, "Error: MAX_TX_BYTES and the TX guard FIFO must stay below TX_RAM_SIZE (instance %m)");

if (GEN_EN && TX_RAM_SIZE <= GEN_LEN_MAX)
    $fatal(0, "Error: TX_RAM_SIZE must exceed the largest generator payload (instance %m)");

if (TRUNC_BYTES < 46 || TRUNC_BYTES > 1020)
    $fatal(0, "Error: TRUNC_BYTES must cover Eth+VLAN+IPv4+UDP (>= 46) and be <= 1020 (instance %m)");

// ============================================================================
// Resets: active-low shell inputs -> synchronous active-high per domain
// ============================================================================
wire logic rst, mac_rx_rst, mac_tx_rst, ui_rst;

taxi_sync_reset #(.N(4)) rst_sync_core_inst   (.clk(clk),        .rst(!aresetn),        .out(rst));
taxi_sync_reset #(.N(4)) rst_sync_mac_rx_inst (.clk(mac_rx_clk), .rst(!mac_rx_aresetn), .out(mac_rx_rst));
taxi_sync_reset #(.N(4)) rst_sync_mac_tx_inst (.clk(mac_tx_clk), .rst(!mac_tx_aresetn), .out(mac_tx_rst));
taxi_sync_reset #(.N(4)) rst_sync_ui_inst     (.clk(ui_clk),     .rst(!ui_aresetn),     .out(ui_rst));

// ============================================================================
// Registers (ui_clk) and configuration / statistics CDC
// ============================================================================
cfg_t       cfg_ui;
cfg_t       cfg;             // core clock domain copy
core_cnt_t  core_cnt, core_cnt_ui;
macrx_cnt_t macrx_cnt, macrx_cnt_ui;
mactx_cnt_t mactx_cnt, mactx_cnt_ui;
ext_cnt_t   ext_cnt, ext_cnt_ui;
wire logic [8:0]  lat_rd_addr;
wire logic [31:0] lat_rd_data;
lat_err_t   lat_err, lat_err_ui;
logic       lat_ack_toggle, lat_ack_toggle_ui;

zircon_regs #(
    .AXIL_ADDR_W(AXIL_ADDR_W),
    .GEN_EN(GEN_EN)
)
regs_inst (
    .clk(ui_clk),
    .rst(ui_rst),
    .s_axi_awaddr(s_axi_awaddr),
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
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .cfg(cfg_ui),
    .core_cnt(core_cnt_ui),
    .macrx_cnt(macrx_cnt_ui),
    .mactx_cnt(mactx_cnt_ui),
    .ext_cnt(ext_cnt_ui),
    .lat_err(lat_err_ui),
    .lat_ack_toggle(lat_ack_toggle_ui),
    .lat_rd_addr(lat_rd_addr),
    .lat_rd_data(lat_rd_data)
);

// reset value of the core-side configuration copy = register defaults
localparam cfg_t CFG_INIT = '{echo_port: 16'd7, ttl: 8'd64,
                              gen_len: GEN_EN ? 14'd1472 : 14'd0,
                              chk_port: GEN_EN ? 16'd5001 : 16'd0, default: '0};

zircon_cdc_snapshot #(.W(CFG_W), .INIT(CFG_INIT))
cfg_cdc_inst (
    .src_clk(ui_clk), .src_rst(ui_rst), .src_data(cfg_ui),
    .dst_clk(clk),    .dst_rst(rst),    .dst_data(cfg)
);

zircon_cdc_snapshot #(.W(CORE_CNT_W))
core_cnt_cdc_inst (
    .src_clk(clk),    .src_rst(rst),    .src_data(core_cnt),
    .dst_clk(ui_clk), .dst_rst(ui_rst), .dst_data(core_cnt_ui)
);

zircon_cdc_snapshot #(.W(MACRX_CNT_W))
macrx_cnt_cdc_inst (
    .src_clk(mac_rx_clk), .src_rst(mac_rx_rst), .src_data(macrx_cnt),
    .dst_clk(ui_clk),     .dst_rst(ui_rst),     .dst_data(macrx_cnt_ui)
);

zircon_cdc_snapshot #(.W(MACTX_CNT_W))
mactx_cnt_cdc_inst (
    .src_clk(mac_tx_clk), .src_rst(mac_tx_rst), .src_data(mactx_cnt),
    .dst_clk(ui_clk),     .dst_rst(ui_rst),     .dst_data(mactx_cnt_ui)
);

zircon_cdc_snapshot #(.W(EXT_CNT_W))
ext_cnt_cdc_inst (
    .src_clk(clk),    .src_rst(rst),    .src_data(ext_cnt),
    .dst_clk(ui_clk), .dst_rst(ui_rst), .dst_data(ext_cnt_ui)
);

// STAT_CLR: a toggle in the ui domain; each domain clears on a change
logic clr_toggle_core_reg = 1'b0;
wire  clr_core = cfg.stat_clr_toggle != clr_toggle_core_reg;

always_ff @(posedge clk) begin
    clr_toggle_core_reg <= cfg.stat_clr_toggle;
    if (rst) clr_toggle_core_reg <= 1'b0;
end

// GEN_CTRL.CLR / CHK_CTRL.CLR toggles, CHK_CTRL.EN rising edge (checker resync)
logic gen_clr_toggle_reg = 1'b0, chk_clr_toggle_reg = 1'b0, chk_en_prev_reg = 1'b0;
wire  gen_clr = cfg.gen_clr_toggle != gen_clr_toggle_reg;
wire  chk_clr = cfg.chk_clr_toggle != chk_clr_toggle_reg;
wire  chk_resync = chk_clr || (cfg.chk_en && !chk_en_prev_reg);

always_ff @(posedge clk) begin
    gen_clr_toggle_reg <= cfg.gen_clr_toggle;
    chk_clr_toggle_reg <= cfg.chk_clr_toggle;
    chk_en_prev_reg    <= cfg.chk_en;
    if (rst) begin
        gen_clr_toggle_reg <= 1'b0;
        chk_clr_toggle_reg <= 1'b0;
        chk_en_prev_reg    <= 1'b0;
    end
end

wire logic clr_toggle_mac_rx;
logic      clr_toggle_mac_rx_reg = 1'b0;
wire       clr_mac_rx = clr_toggle_mac_rx != clr_toggle_mac_rx_reg;

taxi_sync_signal #(.WIDTH(1), .N(2))
clr_mac_rx_sync_inst (
    .clk(mac_rx_clk),
    .in(cfg_ui.stat_clr_toggle),
    .out(clr_toggle_mac_rx)
);

always_ff @(posedge mac_rx_clk) begin
    clr_toggle_mac_rx_reg <= clr_toggle_mac_rx;
    if (mac_rx_rst) clr_toggle_mac_rx_reg <= clr_toggle_mac_rx;
end

wire logic [1:0] mac_tx_sync;
logic            clr_toggle_mac_tx_reg = 1'b0;
wire             tx_en_mac_tx = mac_tx_sync[1];
wire             clr_mac_tx = mac_tx_sync[0] != clr_toggle_mac_tx_reg;

taxi_sync_signal #(.WIDTH(2), .N(2))
mac_tx_sync_inst (
    .clk(mac_tx_clk),
    .in({cfg_ui.tx_en, cfg_ui.stat_clr_toggle}),
    .out(mac_tx_sync)
);

always_ff @(posedge mac_tx_clk) begin
    clr_toggle_mac_tx_reg <= mac_tx_sync[0];
    if (mac_tx_rst) clr_toggle_mac_tx_reg <= mac_tx_sync[0];
end

// ============================================================================
// RX: MAC-side frame FIFO (mac_rx_clk -> clk)
// ============================================================================
// tuser = {RX timestamp [54:7], bad} (1 + LAT_TS_W bits)
localparam int RX_USER_W = 1 + LAT_TS_W;
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(RX_USER_W)) axis_mac_rx();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(RX_USER_W)) axis_rx_q();     // MAC-side FIFO output
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(RX_USER_W)) axis_rx_int();   // after the reset gate

assign axis_mac_rx.tdata  = s_axis_mac_rx_tdata;
assign axis_mac_rx.tkeep  = s_axis_mac_rx_tkeep;
assign axis_mac_rx.tstrb  = s_axis_mac_rx_tkeep;
assign axis_mac_rx.tvalid = s_axis_mac_rx_tvalid;
assign axis_mac_rx.tlast  = s_axis_mac_rx_tlast;
assign axis_mac_rx.tuser  = s_axis_mac_rx_tuser;
assign axis_mac_rx.tid    = '0;
assign axis_mac_rx.tdest  = '0;
assign s_axis_mac_rx_tready = axis_mac_rx.tready;

wire logic mac_rx_fifo_overflow;
wire logic mac_rx_fifo_bad_frame;
logic      rx_fifo_m_rst;

taxi_axis_async_fifo #(
    .DEPTH(RX_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .USER_BAD_FRAME_VALUE(1),     // tuser[0] only (bits 48:1 are the timestamp)
    .USER_BAD_FRAME_MASK(1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b1),
    .DROP_WHEN_FULL(1'b1),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
mac_rx_fifo_inst (
    .s_clk(mac_rx_clk),
    .s_rst(mac_rx_rst),
    .s_axis(axis_mac_rx),
    .m_clk(clk),
    .m_rst(rx_fifo_m_rst),
    .m_axis(axis_rx_q),
    .s_pause_req(1'b0),
    .s_pause_ack(),
    .m_pause_req(1'b0),
    .m_pause_ack(),
    .s_status_depth(),
    .s_status_depth_commit(),
    .s_status_overflow(mac_rx_fifo_overflow),
    .s_status_bad_frame(mac_rx_fifo_bad_frame),
    .s_status_good_frame(),
    .m_status_depth(),
    .m_status_depth_commit(),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

// ----------------------------------------------------------------------------
// MAC-side reset handling (review #5)
//   When mac_rx_aresetn asserts (GT RX reset, link flap) while the core runs, the
//   async FIFO's read side ends the frame it is reading out with a terminate beat
//   (tlast, tuser = bad); tuser is carried to rx_dispatch, which drops the frame
//   and counts it in RX_BAD_FRAME. The read side also restarts at pointer 0, but
//   in FRAME_FIFO mode its synchronised commit pointer is only cleared by m_rst
//   (or by a pending pointer-update toggle), so it can keep the pre-reset value and
//   the read side would replay stale RAM contents as frames. So once the output is
//   between frames (the terminate beat, if any, has passed), the output is gated
//   and the read side gets its own m_rst pulse, which also clears the commit
//   pointer (and resets the write side again through the FIFO's own sync).
// ----------------------------------------------------------------------------
wire logic mac_rx_rst_core;

taxi_sync_reset #(.N(4)) rst_sync_mac_rx_core_inst (.clk(clk), .rst(!mac_rx_aresetn), .out(mac_rx_rst_core));

logic       rxq_in_frame = 1'b0;   // the FIFO output is inside a frame
logic       rxq_rst_pend = 1'b0;   // a MAC-side reset happened: m_rst still to be done
logic       rxq_rst_reg = 1'b0;
logic [3:0] rxq_rst_cnt = '0;

wire rxq_gate = rxq_rst_pend && !rxq_in_frame;

assign axis_rx_int.tdata  = axis_rx_q.tdata;
assign axis_rx_int.tkeep  = axis_rx_q.tkeep;
assign axis_rx_int.tstrb  = axis_rx_q.tstrb;
assign axis_rx_int.tlast  = axis_rx_q.tlast;
assign axis_rx_int.tid    = axis_rx_q.tid;
assign axis_rx_int.tdest  = axis_rx_q.tdest;
assign axis_rx_int.tuser  = axis_rx_q.tuser;
assign axis_rx_int.tvalid = axis_rx_q.tvalid && !rxq_gate;
assign axis_rx_q.tready   = axis_rx_int.tready && !rxq_gate;

always_ff @(posedge clk) begin
    if (axis_rx_q.tvalid && axis_rx_q.tready) begin
        rxq_in_frame <= !axis_rx_q.tlast;
    end
    if (mac_rx_rst_core) begin
        rxq_rst_pend <= 1'b1;
    end
    rxq_rst_reg <= rxq_gate;
    if (!rxq_gate) begin
        rxq_rst_cnt <= '1;
    end else if (rxq_rst_cnt != 0) begin
        rxq_rst_cnt <= rxq_rst_cnt - 1;
    end else if (!mac_rx_rst_core) begin
        rxq_rst_pend <= 1'b0;      // reset held >= 16 cycles and the MAC side is out of reset
    end
    if (rst) begin
        rxq_in_frame <= 1'b0;
        rxq_rst_pend <= 1'b0;
        rxq_rst_reg  <= 1'b0;
    end
end

assign rx_fifo_m_rst = rst || rxq_rst_reg;

// MAC RX domain counters
always_ff @(posedge mac_rx_clk) begin
    if (mac_rx_fifo_overflow)  macrx_cnt.rx_fifo_drop <= macrx_cnt.rx_fifo_drop + 32'd1;
    if (mac_rx_fifo_bad_frame) macrx_cnt.rx_bad_frame <= macrx_cnt.rx_bad_frame + 32'd1;
    if (mac_rx_pack_stat[0])   macrx_cnt.rx_pack_stall <= macrx_cnt.rx_pack_stall + 16'd1;
    if (mac_rx_pack_stat[1])   macrx_cnt.rx_pack_ovf   <= macrx_cnt.rx_pack_ovf + 16'd1;
    if (mac_rx_rst || clr_mac_rx) macrx_cnt <= '0;
end

// ============================================================================
// RX: broadcast into the packet branch [A] and the header branch [B]
// ============================================================================
// tuser[0] (bad frame, only set by a terminate beat of the MAC-side FIFO) and
// tuser[48:1] (RX timestamp) are carried on the packet branch into the len record
// (zircon_ip_len_cksum forwards the last beat's tuser on m_axis_meta)
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(RX_USER_W)) axis_rx_bcast[2]();

taxi_axis_broadcast #(
    .M_COUNT(2)
)
rx_bcast_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_int),
    .m_axis(axis_rx_bcast)
);

// ---- [A] length / checksum + store-and-forward packet FIFO ----
taxi_axis_if #(.DATA_W(DATA_W)) axis_rx_pkt_in();
taxi_axis_if #(.DATA_W(DATA_W)) axis_rx_pkt();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(RX_USER_W)) axis_rx_len_in();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(RX_USER_W)) axis_rx_len();

zircon_ip_len_cksum #(
    .START_OFFSET(14)
)
rx_len_cksum_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt(axis_rx_bcast[0]),
    .m_axis_pkt(axis_rx_pkt_in),
    .m_axis_meta(axis_rx_len_in)
);

taxi_axis_fifo #(
    .DEPTH(PKT_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .DROP_OVERSIZE_FRAME(1'b0),   // must never drop: its metadata records exist already
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_pkt_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_pkt_in),
    .m_axis(axis_rx_pkt),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

taxi_axis_fifo #(
    .DEPTH(2 * PKT_FIFO_BEATS * 4),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_len_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_len_in),
    .m_axis(axis_rx_len),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ---- [B] header truncation -> 32-bit Zircon parser -> per-packet record ----
taxi_axis_if #(.DATA_W(DATA_W)) axis_rx_hdr_trunc();
taxi_axis_if #(.DATA_W(DATA_W)) axis_rx_hdr_buf();
taxi_axis_if #(.DATA_W(32)) axis_rx_hdr32();
taxi_axis_if #(.DATA_W(64)) axis_rx_meta();
taxi_axis_if #(.DATA_W(RX_HDR_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_rx_rec_in();
taxi_axis_if #(.DATA_W(RX_HDR_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_rx_rec();

hdr_trunc #(
    .TRUNC_BYTES(TRUNC_BYTES)
)
rx_hdr_trunc_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_bcast[1]),
    .m_axis(axis_rx_hdr_trunc)
);

taxi_axis_fifo #(
    .DEPTH(HDR_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_hdr_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_hdr_trunc),
    .m_axis(axis_rx_hdr_buf),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

taxi_axis_adapter
rx_hdr_adapter_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_hdr_buf),
    .m_axis(axis_rx_hdr32)
);

zircon_ip_rx_parse #(
    .IPV6_EN(1'b1),
    .HASH_EN(1'b0)
)
rx_parse_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt(axis_rx_hdr32),
    .m_axis_meta(axis_rx_meta)
);

rx_meta_capture
rx_meta_capture_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_meta(axis_rx_meta),
    .m_axis_rec(axis_rx_rec_in)
);

taxi_axis_fifo #(
    .DEPTH(PKT_FIFO_BEATS),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_rec_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rx_rec_in),
    .m_axis(axis_rx_rec),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ============================================================================
// RX: dispatch
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_disp_raw();
taxi_axis_if #(.DATA_W(DATA_W)) axis_disp_sock();
taxi_axis_if #(.DATA_W(DATA_W)) axis_disp_echo();
taxi_axis_if #(.DATA_W(DATA_W)) axis_disp_chk();
taxi_axis_if #(.DATA_W(ECHO_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_emeta_in();
taxi_axis_if #(.DATA_W(ECHO_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_emeta();

logic        ev_rx_frame, ev_rx_raw, ev_rx_echo, ev_rx_sock, ev_rx_drop, ev_rx_l3_bad, ev_rx_l4_bad;
logic        ev_rx_echo_drop, ev_rx_bad;
logic [15:0] ev_rx_frame_len;
logic [15:0] echo_free_beats;

rx_dispatch
rx_dispatch_inst (
    .clk(clk),
    .rst(rst),
    .cfg_rx_en(cfg.rx_en),
    .cfg_echo_en(cfg.echo_en),
    .cfg_sock_en(cfg.sock_en),
    .cfg_local_mac(cfg.local_mac),
    .cfg_local_ip(cfg.local_ip),
    .cfg_echo_port(cfg.echo_port),
    .cfg_sock_port(cfg.sock_local_port),
    .cfg_chk_en(GEN_EN && cfg.chk_en),
    .cfg_chk_port(cfg.chk_port),
    .cfg_raw_ts_desc(cfg.lat_raw_rx_desc),
    .echo_free_beats(echo_free_beats),
    .s_axis_pkt(axis_rx_pkt),
    .s_axis_len(axis_rx_len),
    .s_axis_hdr(axis_rx_rec),
    .m_axis_raw(axis_disp_raw),
    .m_axis_sock(axis_disp_sock),
    .m_axis_echo(axis_disp_echo),
    .m_axis_chk(axis_disp_chk),
    .m_axis_emeta(axis_emeta_in),
    .ev_frame(ev_rx_frame),
    .ev_frame_len(ev_rx_frame_len),
    .ev_raw(ev_rx_raw),
    .ev_echo(ev_rx_echo),
    .ev_sock(ev_rx_sock),
    .ev_drop(ev_rx_drop),
    .ev_echo_drop(ev_rx_echo_drop),
    .ev_bad(ev_rx_bad),
    .ev_l3_bad(ev_rx_l3_bad),
    .ev_l4_bad(ev_rx_l4_bad)
);

taxi_axis_fifo #(
    .DEPTH(ECHO_META_DEPTH),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
echo_meta_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_emeta_in),
    .m_axis(axis_emeta),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ============================================================================
// RX: per-path decoupling FIFOs (review #2: no head-of-line blocking)
//   RAW / SOCK: drop-when-full frame FIFOs; a frame that does not fit is dropped
//   whole and counted (RX_RAW_DROP / RX_SOCK_DROP), so a stalled UI consumer
//   (e.g. an AXI DMA S2MM ring with no free descriptor) never stalls dispatch.
//   ECHO: frame FIFO in front of tx_buffer input 1. It never fills: dispatch only
//   routes an echo request when the whole payload fits (echo_free_beats), else it
//   drops it (RX_ECHO_DROP), so a busy TX path never stalls dispatch either.
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_raw_q();
taxi_axis_if #(.DATA_W(DATA_W)) axis_sock_q();
taxi_axis_if #(.DATA_W(DATA_W)) axis_echo_q();

wire logic raw_q_overflow, sock_q_overflow;
wire logic [$clog2(RX_PATH_FIFO_BEATS*KEEP_W):0] echo_q_depth;

taxi_axis_fifo #(
    .DEPTH(RX_PATH_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_raw_q_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_disp_raw),
    .m_axis(axis_raw_q),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(raw_q_overflow),
    .status_bad_frame(),
    .status_good_frame()
);

taxi_axis_fifo #(
    .DEPTH(RX_PATH_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_sock_q_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_disp_sock),
    .m_axis(axis_sock_q),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(sock_q_overflow),
    .status_bad_frame(),
    .status_good_frame()
);

taxi_axis_fifo #(
    .DEPTH(RX_PATH_FIFO_BEATS * KEEP_W),
    .RAM_PIPELINE(2),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .DROP_OVERSIZE_FRAME(1'b0),   // never fills: dispatch checks the room first
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rx_echo_q_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_disp_echo),
    .m_axis(axis_echo_q),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(echo_q_depth),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// free beats of the echo FIFO (status_depth counts bytes in whole beats)
always_ff @(posedge clk) begin
    echo_free_beats <= 16'(RX_PATH_FIFO_BEATS) - 16'(echo_q_depth >> $clog2(KEEP_W));
    if (rst) echo_free_beats <= '0;
end

// ============================================================================
// RX: generator checker (CHK rule, GEN_EN); never back-pressures dispatch
// ============================================================================
logic        chk_sync;
logic [31:0] chk_rx_pkts, chk_seq_err, chk_len_err;
logic [63:0] chk_rx_bytes, chk_bit_err;

if (GEN_EN) begin : chk

    udp_chk
    udp_chk_inst (
        .clk(clk),
        .rst(rst),
        .resync(chk_resync),
        .stat_clr(chk_clr || clr_core),
        .s_axis(axis_disp_chk),
        .sync(chk_sync),
        .rx_pkts(chk_rx_pkts),
        .rx_bytes(chk_rx_bytes),
        .seq_err(chk_seq_err),
        .bit_err(chk_bit_err),
        .len_err(chk_len_err)
    );

end else begin : no_chk

    assign axis_disp_chk.tready = 1'b1;
    assign chk_sync     = 1'b0;
    assign chk_rx_pkts  = '0;
    assign chk_rx_bytes = '0;
    assign chk_seq_err  = '0;
    assign chk_bit_err  = '0;
    assign chk_len_err  = '0;

end

// ============================================================================
// RX: egress CDCs to the UI clock (UI0 raw, UI2 socket)
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_ui_raw_rx();
taxi_axis_if #(.DATA_W(DATA_W)) axis_ui_sock_rx();

zircon_ip_rx_egress #(
    .N_UI(1),
    .UI_RX_FIFO_DEPTH(UI_FIFO_BEATS),
    .UI_RX_FIFO_EB_MODE(1'b1)
)
rx_egress_raw_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt(axis_raw_q),
    .ui_clk(ui_clk),
    .ui_rst(ui_rst),
    .m_axis_ui_rx(axis_ui_raw_rx)
);

zircon_ip_rx_egress #(
    .N_UI(1),
    .UI_RX_FIFO_DEPTH(UI_FIFO_BEATS),
    .UI_RX_FIFO_EB_MODE(1'b1)
)
rx_egress_sock_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt(axis_sock_q),
    .ui_clk(ui_clk),
    .ui_rst(ui_rst),
    .m_axis_ui_rx(axis_ui_sock_rx)
);

assign m_axis_raw_rx_tdata   = axis_ui_raw_rx.tdata;
assign m_axis_raw_rx_tkeep   = axis_ui_raw_rx.tkeep;
assign m_axis_raw_rx_tvalid  = axis_ui_raw_rx.tvalid;
assign m_axis_raw_rx_tlast   = axis_ui_raw_rx.tlast;
assign axis_ui_raw_rx.tready = m_axis_raw_rx_tready;

assign m_axis_sock_rx_tdata   = axis_ui_sock_rx.tdata;
assign m_axis_sock_rx_tkeep   = axis_ui_sock_rx.tkeep;
assign m_axis_sock_rx_tvalid  = axis_ui_sock_rx.tvalid;
assign m_axis_sock_rx_tlast   = axis_ui_sock_rx.tlast;
assign axis_ui_sock_rx.tready = m_axis_sock_rx_tready;

// ============================================================================
// TX: UI ingress CDCs (ui_clk -> clk)
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_ui_raw_tx();
taxi_axis_if #(.DATA_W(DATA_W)) axis_ui_sock_tx();
taxi_axis_if #(.DATA_W(DATA_W)) axis_tx_raw();
taxi_axis_if #(.DATA_W(DATA_W)) axis_tx_sock();
taxi_axis_if #(.DATA_W(8), .LAST_EN(1'b0)) axis_ui_tx_cpl[2]();   // zircon_ip_tx_ingress: declared, never driven

assign axis_ui_raw_tx.tdata  = s_axis_raw_tx_tdata;
assign axis_ui_raw_tx.tkeep  = s_axis_raw_tx_tkeep;
assign axis_ui_raw_tx.tstrb  = s_axis_raw_tx_tkeep;
assign axis_ui_raw_tx.tvalid = s_axis_raw_tx_tvalid;
assign axis_ui_raw_tx.tlast  = s_axis_raw_tx_tlast;
assign axis_ui_raw_tx.tid    = '0;
assign axis_ui_raw_tx.tdest  = '0;
assign axis_ui_raw_tx.tuser  = '0;
assign s_axis_raw_tx_tready  = axis_ui_raw_tx.tready;

assign axis_ui_sock_tx.tdata  = s_axis_sock_tx_tdata;
assign axis_ui_sock_tx.tkeep  = s_axis_sock_tx_tkeep;
assign axis_ui_sock_tx.tstrb  = s_axis_sock_tx_tkeep;
assign axis_ui_sock_tx.tvalid = s_axis_sock_tx_tvalid;
assign axis_ui_sock_tx.tlast  = s_axis_sock_tx_tlast;
assign axis_ui_sock_tx.tid    = '0;
assign axis_ui_sock_tx.tdest  = '0;
assign axis_ui_sock_tx.tuser  = '0;
assign s_axis_sock_tx_tready  = axis_ui_sock_tx.tready;

assign axis_ui_tx_cpl[0].tready = 1'b1;
assign axis_ui_tx_cpl[1].tready = 1'b1;

zircon_ip_tx_ingress #(
    .N_UI(1),
    .UI_TX_FIFO_DEPTH(UI_FIFO_BEATS),
    .UI_TX_FIFO_EB_MODE(1'b1)
)
tx_ingress_raw_inst (
    .clk(clk),
    .rst(rst),
    .ui_clk(ui_clk),
    .ui_rst(ui_rst),
    .s_axis_ui_tx(axis_ui_raw_tx),
    .m_axis_ui_tx_cpl(axis_ui_tx_cpl[0]),
    .m_axis_pkt(axis_tx_raw)
);

zircon_ip_tx_ingress #(
    .N_UI(1),
    .UI_TX_FIFO_DEPTH(UI_FIFO_BEATS),
    .UI_TX_FIFO_EB_MODE(1'b1)
)
tx_ingress_sock_inst (
    .clk(clk),
    .rst(rst),
    .ui_clk(ui_clk),
    .ui_rst(ui_rst),
    .s_axis_ui_tx(axis_ui_sock_tx),
    .m_axis_ui_tx_cpl(axis_ui_tx_cpl[1]),
    .m_axis_pkt(axis_tx_sock)
);

// ============================================================================
// TX: oversize guard on the UI inputs (review #7)
//   zircon_ip_tx_buffer wedges forever on a frame of TX_RAM_SIZE bytes or more
//   (its length record only appears after the whole frame): drop UI transfers
//   longer than MAX_TX_BYTES before they reach it, and count them.
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_tx_raw_g();
taxi_axis_if #(.DATA_W(DATA_W)) axis_tx_sock_g();
wire logic ev_tx_oversize_raw, ev_tx_oversize_sock;

tx_len_guard #(
    .MAX_BYTES(MAX_TX_BYTES),
    .FIFO_BEATS(TX_GUARD_BEATS)
)
tx_guard_raw_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_tx_raw),
    .m_axis(axis_tx_raw_g),
    .ev_drop(ev_tx_oversize_raw)
);

tx_len_guard #(
    .MAX_BYTES(MAX_TX_BYTES),
    .FIFO_BEATS(TX_GUARD_BEATS)
)
tx_guard_sock_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_tx_sock),
    .m_axis(axis_tx_sock_g),
    .ev_drop(ev_tx_oversize_sock)
);

// ============================================================================
// TX: UI0 latency descriptor (1.3.0): strip a ZTXT descriptor, one record per frame
// ============================================================================
taxi_axis_if #(.DATA_W(DATA_W)) axis_tx_raw_s();
taxi_axis_if #(.DATA_W(LAT_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_rawrec_in();
taxi_axis_if #(.DATA_W(LAT_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_rawrec();

raw_tx_desc_strip
raw_tx_desc_strip_inst (
    .clk(clk),
    .rst(rst),
    .enable(cfg.lat_raw_tx_desc),
    .s_axis(axis_tx_raw_g),
    .m_axis(axis_tx_raw_s),
    .m_axis_rec(axis_rawrec_in)
);

// one record per raw frame between the strip and tx_meta_builder: at most
// TX_RAM_SIZE/64 frames sit in tx_buffer; a full FIFO only back-pressures UI0
taxi_axis_fifo #(
    .DEPTH(TX_RAM_SIZE / KEEP_W),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
rawrec_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_rawrec_in),
    .m_axis(axis_rawrec),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ============================================================================
// TX: payload buffer (3 inputs + the generator, tdest = input index)
// ============================================================================
localparam int N_UI = GEN_EN ? 4 : 3;

taxi_axis_if #(.DATA_W(DATA_W), .DEST_EN(1'b1), .DEST_W(2)) axis_tx_ui[N_UI]();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1'b1), .USER_W(1), .ID_EN(1'b1), .ID_W(8)) axis_tx_payload();
taxi_axis_if #(.DATA_W(32), .DEST_EN(1'b1), .DEST_W(2)) axis_tx_len_in();
taxi_axis_if #(.DATA_W(32), .DEST_EN(1'b1), .DEST_W(2)) axis_tx_len();

// input 0: raw (UI0, after the latency descriptor strip)
assign axis_tx_ui[0].tdata  = axis_tx_raw_s.tdata;
assign axis_tx_ui[0].tkeep  = axis_tx_raw_s.tkeep;
assign axis_tx_ui[0].tstrb  = axis_tx_raw_s.tkeep;
assign axis_tx_ui[0].tvalid = axis_tx_raw_s.tvalid;
assign axis_tx_ui[0].tlast  = axis_tx_raw_s.tlast;
assign axis_tx_ui[0].tid    = '0;
assign axis_tx_ui[0].tdest  = TX_DEST_RAW;
assign axis_tx_ui[0].tuser  = '0;
assign axis_tx_raw_s.tready = axis_tx_ui[0].tready;

// input 1: hardware echo (from rx_dispatch via the echo frame FIFO, core clock)
assign axis_tx_ui[1].tdata  = axis_echo_q.tdata;
assign axis_tx_ui[1].tkeep  = axis_echo_q.tkeep;
assign axis_tx_ui[1].tstrb  = axis_echo_q.tkeep;
assign axis_tx_ui[1].tvalid = axis_echo_q.tvalid;
assign axis_tx_ui[1].tlast  = axis_echo_q.tlast;
assign axis_tx_ui[1].tid    = '0;
assign axis_tx_ui[1].tdest  = TX_DEST_ECHO;
assign axis_tx_ui[1].tuser  = '0;
assign axis_echo_q.tready   = axis_tx_ui[1].tready;

// input 2: hardware socket (UI2)
assign axis_tx_ui[2].tdata  = axis_tx_sock_g.tdata;
assign axis_tx_ui[2].tkeep  = axis_tx_sock_g.tkeep;
assign axis_tx_ui[2].tstrb  = axis_tx_sock_g.tkeep;
assign axis_tx_ui[2].tvalid = axis_tx_sock_g.tvalid;
assign axis_tx_ui[2].tlast  = axis_tx_sock_g.tlast;
assign axis_tx_ui[2].tid    = '0;
assign axis_tx_ui[2].tdest  = TX_DEST_SOCK;
assign axis_tx_ui[2].tuser  = '0;
assign axis_tx_sock_g.tready = axis_tx_ui[2].tready;

// input 3: hardware UDP generator (GEN_EN, core clock)
logic        gen_busy;
logic [31:0] gen_tx_pkts;
logic [63:0] gen_tx_bytes;

if (GEN_EN) begin : gen

    taxi_axis_if #(.DATA_W(DATA_W)) axis_gen();

    udp_gen
    udp_gen_inst (
        .clk(clk),
        .rst(rst),
        .cfg_en(cfg.gen_en),
        .cfg_cont(cfg.gen_cont),
        .cfg_len(cfg.gen_len),
        .cfg_count(cfg.gen_count),
        .cfg_gap(cfg.gen_gap),
        .clr(gen_clr),
        .stat_clr(clr_core),
        .m_axis(axis_gen),
        .busy(gen_busy),
        .tx_pkts(gen_tx_pkts),
        .tx_bytes(gen_tx_bytes)
    );

    assign axis_tx_ui[3].tdata  = axis_gen.tdata;
    assign axis_tx_ui[3].tkeep  = axis_gen.tkeep;
    assign axis_tx_ui[3].tstrb  = axis_gen.tkeep;
    assign axis_tx_ui[3].tvalid = axis_gen.tvalid;
    assign axis_tx_ui[3].tlast  = axis_gen.tlast;
    assign axis_tx_ui[3].tid    = '0;
    assign axis_tx_ui[3].tdest  = TX_DEST_GEN;
    assign axis_tx_ui[3].tuser  = '0;
    assign axis_gen.tready      = axis_tx_ui[3].tready;

end else begin : no_gen

    assign gen_busy     = 1'b0;
    assign gen_tx_pkts  = '0;
    assign gen_tx_bytes = '0;

end

zircon_ip_tx_buffer #(
    .N_UI(N_UI),
    .TX_RAM_SIZE(TX_RAM_SIZE)
)
tx_buffer_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt_ui(axis_tx_ui),
    .m_axis_meta_len(axis_tx_len_in),
    .m_axis_pkt(axis_tx_payload)
);

taxi_axis_fifo #(
    .DEPTH(2 * (TX_RAM_SIZE / KEEP_W) * 4),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
tx_len_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_tx_len_in),
    .m_axis(axis_tx_len),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ============================================================================
// TX: metadata builder + Zircon egress (deparser, header/payload concat, MAC FIFO)
// ============================================================================
// MAC-side TX tuser = {lat_rec_t, bad}
localparam int TX_USER_W = 1 + LAT_REC_W;

taxi_axis_if #(.DATA_W(64)) axis_tx_meta();
taxi_axis_if #(.DATA_W(LAT_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_lrec_in();
taxi_axis_if #(.DATA_W(LAT_REC_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_lrec();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1'b1), .USER_W(TX_USER_W)) axis_mac_tx_int();   // frame FIFO output
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1'b1), .USER_W(TX_USER_W)) axis_mac_tx_out();   // tx_mac_out output
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1'b1), .USER_W(1)) axis_mac_tx();

logic ev_tx_raw, ev_tx_echo, ev_tx_sock;
logic [31:0] mactx_frames, mactx_frames_free;
logic [63:0] mactx_bytes, mactx_bytes_free;

tx_meta_builder
tx_meta_builder_inst (
    .clk(clk),
    .rst(rst),
    .cfg_local_mac(cfg.local_mac),
    .cfg_local_ip(cfg.local_ip),
    .cfg_ttl(cfg.ttl),
    .cfg_sock_local_port(cfg.sock_local_port),
    .cfg_sock_remote_port(cfg.sock_remote_port),
    .cfg_sock_remote_ip(cfg.sock_remote_ip),
    .cfg_sock_remote_mac(cfg.sock_remote_mac),
    .cfg_gen_dst_mac(cfg.gen_dst_mac),
    .cfg_gen_dst_ip(cfg.gen_dst_ip),
    .cfg_gen_dst_port(cfg.gen_dst_port),
    .cfg_gen_src_port(cfg.gen_src_port),
    .cfg_lat_en(cfg.lat_en),
    .s_axis_len(axis_tx_len),
    .s_axis_emeta(axis_emeta),
    .s_axis_rawrec(axis_rawrec),
    .m_axis_lrec(axis_lrec_in),
    .m_axis_meta(axis_tx_meta),
    .ev_raw(ev_tx_raw),
    .ev_echo(ev_tx_echo),
    .ev_sock(ev_tx_sock),
    .ev_gen()
);

// latency records in packet order (a few packets between the builder and the
// concat output at most; a full FIFO only stalls the builder)
taxi_axis_fifo #(
    .DEPTH(32),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
lrec_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_lrec_in),
    .m_axis(axis_lrec),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

// ---- Zircon TX egress, as its parts (same modules and parameters as
// zircon_ip_tx_egress with IPV6_EN 1, MAC_TX_FIFO_EB_MODE 1) ----
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8)) axis_tx_hdr32();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8)) axis_tx_parts[2]();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8)) axis_tx_cat();
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(TX_USER_W)) axis_tx_cat_rec();

zircon_ip_tx_deparse #(
    .IPV6_EN(1'b1)
)
tx_deparse_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_meta(axis_tx_meta),
    .m_axis_pkt(axis_tx_hdr32)
);

taxi_axis_adapter
tx_hdr_adapter_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_tx_hdr32),
    .m_axis(axis_tx_parts[0])
);

taxi_axis_tie
tx_payload_tie_inst (
    .s_axis(axis_tx_payload),
    .m_axis(axis_tx_parts[1])
);

taxi_axis_concat #(
    .S_COUNT(2)
)
tx_hdr_concat_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(axis_tx_parts),
    .m_axis(axis_tx_cat)
);

// attach the packet's latency record to every beat of its frame: the deparser
// and concat keep packet order and never drop, so the n-th frame out of the
// concat belongs to the n-th record (pushed when the builder started it, i.e.
// always before the frame exists)
logic     cat_sof_reg = 1'b1;
lat_rec_t cat_rec_reg = '0;
wire      cat_rec_ok = !cat_sof_reg || axis_lrec.tvalid;

assign axis_tx_cat_rec.tdata  = axis_tx_cat.tdata;
assign axis_tx_cat_rec.tkeep  = axis_tx_cat.tkeep;
assign axis_tx_cat_rec.tstrb  = axis_tx_cat.tstrb;
assign axis_tx_cat_rec.tlast  = axis_tx_cat.tlast;
assign axis_tx_cat_rec.tid    = '0;
assign axis_tx_cat_rec.tdest  = '0;
assign axis_tx_cat_rec.tuser  = {cat_sof_reg ? lat_rec_t'(axis_lrec.tdata) : cat_rec_reg, axis_tx_cat.tuser[0]};
assign axis_tx_cat_rec.tvalid = axis_tx_cat.tvalid && cat_rec_ok;
assign axis_tx_cat.tready     = axis_tx_cat_rec.tready && cat_rec_ok;
assign axis_lrec.tready       = axis_tx_cat.tvalid && cat_sof_reg && axis_tx_cat_rec.tready;

always_ff @(posedge clk) begin
    if (axis_tx_cat.tvalid && axis_tx_cat.tready) begin
        cat_sof_reg <= axis_tx_cat.tlast;
        if (cat_sof_reg) cat_rec_reg <= lat_rec_t'(axis_lrec.tdata);
    end
    if (rst) cat_sof_reg <= 1'b1;
end

// MAC-side TX frame FIFO (as in zircon_ip_tx_egress, EB mode), core -> mac_tx_clk
taxi_axis_async_fifo #(
    .DEPTH(DATA_W/8*TX_FIFO_BEATS),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b1),
    .USER_BAD_FRAME_VALUE(1),
    .USER_BAD_FRAME_MASK(1),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
tx_fifo_inst (
    .s_clk(clk),
    .s_rst(rst),
    .s_axis(axis_tx_cat_rec),
    .m_clk(mac_tx_clk),
    .m_rst(mac_tx_rst),
    .m_axis(axis_mac_tx_int),
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

tx_mac_out
tx_mac_out_inst (
    .clk(mac_tx_clk),
    .rst(mac_tx_rst),
    .tx_en(tx_en_mac_tx),
    .stat_clr(clr_mac_tx),
    .s_axis(axis_mac_tx_int),
    .m_axis(axis_mac_tx_out),
    .tx_frames(mactx_frames),
    .tx_bytes(mactx_bytes),
    .tx_frames_free(mactx_frames_free),
    .tx_bytes_free(mactx_bytes_free)
);

// ---- MRMAC PTP tagging and latency samples (mac_tx_clk) ----
taxi_axis_if #(.DATA_W(LAT_SAMPLE_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_lat_smp_tx();
taxi_axis_if #(.DATA_W(LAT_SAMPLE_W), .KEEP_W(1), .KEEP_EN(1'b0), .LAST_EN(1'b0)) axis_lat_smp();

// MRMAC TX timestamp return: one register stage straight off the hard block
// (1.3.0 build: the MRMAC output -> tagger clock-enable path had +0.002 ns)
logic [54:0] ptp_ts_q = '0;
logic [15:0] ptp_tag_q = '0;
logic        ptp_valid_q = 1'b0;

always_ff @(posedge mac_tx_clk) begin
    ptp_ts_q    <= tx_ptp_tstamp_in;
    ptp_tag_q   <= tx_ptp_tstamp_tag_in;
    ptp_valid_q <= tx_ptp_tstamp_valid_in;
    if (mac_tx_rst) ptp_valid_q <= 1'b0;
end

ptp_tx_tagger
ptp_tx_tagger_inst (
    .clk(mac_tx_clk),
    .rst(mac_tx_rst),
    .stat_clr(clr_mac_tx),
    .s_axis(axis_mac_tx_out),
    .m_axis(axis_mac_tx),
    .m_axis_ptp_tdata(m_axis_tx_ptp_tdata),
    .m_axis_ptp_tvalid(m_axis_tx_ptp_tvalid),
    .m_axis_ptp_tready(m_axis_tx_ptp_tready),
    .ts_in(ptp_ts_q),
    .ts_tag_in(ptp_tag_q),
    .ts_valid_in(ptp_valid_q),
    .m_axis_sample(axis_lat_smp_tx),
    .err_cnt(lat_err)
);

zircon_cdc_snapshot #(.W(LAT_ERR_W))
lat_err_cdc_inst (
    .src_clk(mac_tx_clk), .src_rst(mac_tx_rst), .src_data(lat_err),
    .dst_clk(ui_clk),     .dst_rst(ui_rst),     .dst_data(lat_err_ui)
);

// samples -> core clock (a burst of timestamps waits here while a snapshot /
// clear sweep runs)
taxi_axis_async_fifo #(
    .DEPTH(512),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_EN(1'b0),
    .FRAME_FIFO(1'b0),
    .DROP_OVERSIZE_FRAME(1'b0),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b0),
    .MARK_WHEN_FULL(1'b0),
    .PAUSE_EN(1'b0)
)
lat_smp_fifo_inst (
    .s_clk(mac_tx_clk),
    .s_rst(mac_tx_rst),
    .s_axis(axis_lat_smp_tx),
    .m_clk(clk),
    .m_rst(rst),
    .m_axis(axis_lat_smp),
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

// ---- statistics engine (core clock) ----

latency_stats
latency_stats_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_sample(axis_lat_smp),
    .cfg_base({LAT_BANKS{cfg.lat_base}}),
    .cfg_shift({LAT_BANKS{cfg.lat_shift}}),
    .cmd_req_toggle(cfg.lat_req_toggle),
    .cmd_snap_toggle(cfg.lat_snap_toggle),
    .cmd_clr_toggle(cfg.lat_clr_toggle),
    .cmd_ack_toggle(lat_ack_toggle),
    .rd_clk(ui_clk),
    .rd_addr(lat_rd_addr),
    .rd_data(lat_rd_data)
);

taxi_sync_signal #(.WIDTH(1), .N(2))
lat_ack_sync_inst (
    .clk(ui_clk),
    .in(lat_ack_toggle),
    .out(lat_ack_toggle_ui)
);

always_comb begin
    mactx_cnt.tx_frames = mactx_frames;
    mactx_cnt.tx_bytes  = mactx_bytes;
end

assign m_axis_mac_tx_tdata  = axis_mac_tx.tdata;
assign m_axis_mac_tx_tkeep  = axis_mac_tx.tkeep;
assign m_axis_mac_tx_tvalid = axis_mac_tx.tvalid;
assign m_axis_mac_tx_tlast  = axis_mac_tx.tlast;
assign m_axis_mac_tx_tuser  = 1'b0;

assign axis_mac_tx.tready   = m_axis_mac_tx_tready;

// ============================================================================
// Rate meters (always built): free-running RX counts in the core clock, TX counts
// (frames handed to the MAC) crossed from mac_tx_clk as one coherent snapshot
// ============================================================================
logic [31:0] rx_frames_free = '0;
logic [63:0] rx_bytes_free = '0;
logic [95:0] tx_free_core;

always_ff @(posedge clk) begin
    if (ev_rx_frame) begin
        rx_frames_free <= rx_frames_free + 32'd1;
        rx_bytes_free  <= rx_bytes_free + 64'(ev_rx_frame_len);
    end
    if (rst) begin
        rx_frames_free <= '0;
        rx_bytes_free  <= '0;
    end
end

zircon_cdc_snapshot #(.W(96))
tx_free_cdc_inst (
    .src_clk(mac_tx_clk), .src_rst(mac_tx_rst), .src_data({mactx_frames_free, mactx_bytes_free}),
    .dst_clk(clk),        .dst_rst(rst),        .dst_data(tx_free_core)
);

logic [31:0] rate_seq, rate_rx_pkts, rate_tx_pkts;
logic [63:0] rate_rx_bytes, rate_tx_bytes;

rate_meter #(
    .WINDOW(CORE_HZ)
)
rate_meter_inst (
    .clk(clk),
    .rst(rst),
    .rx_pkts_cum(rx_frames_free),
    .rx_bytes_cum(rx_bytes_free),
    .tx_pkts_cum(tx_free_core[95:64]),
    .tx_bytes_cum(tx_free_core[63:0]),
    .seq(rate_seq),
    .rx_pkts(rate_rx_pkts),
    .rx_bytes(rate_rx_bytes),
    .tx_pkts(rate_tx_pkts),
    .tx_bytes(rate_tx_bytes)
);

always_comb begin
    ext_cnt.tx_rate_pkts  = rate_tx_pkts;
    ext_cnt.tx_rate_bytes = rate_tx_bytes;
    ext_cnt.rx_rate_pkts  = rate_rx_pkts;
    ext_cnt.rx_rate_bytes = rate_rx_bytes;
    ext_cnt.rate_seq      = rate_seq;
    ext_cnt.chk_len_err   = chk_len_err;
    ext_cnt.chk_bit_err   = chk_bit_err;
    ext_cnt.chk_seq_err   = chk_seq_err;
    ext_cnt.chk_rx_bytes  = chk_rx_bytes;
    ext_cnt.chk_rx_pkts   = chk_rx_pkts;
    ext_cnt.chk_sync      = chk_sync;
    ext_cnt.gen_tx_bytes  = gen_tx_bytes;
    ext_cnt.gen_tx_pkts   = gen_tx_pkts;
    ext_cnt.gen_busy      = gen_busy;
end

// ============================================================================
// Core clock domain counters and internal error flags
// ============================================================================
always_ff @(posedge clk) begin
    if (ev_rx_frame) begin
        core_cnt.rx_frames <= core_cnt.rx_frames + 32'd1;
        core_cnt.rx_bytes  <= core_cnt.rx_bytes + 64'(ev_rx_frame_len);
    end
    if (ev_rx_l3_bad) core_cnt.rx_l3_bad <= core_cnt.rx_l3_bad + 32'd1;
    if (ev_rx_l4_bad) core_cnt.rx_l4_bad <= core_cnt.rx_l4_bad + 32'd1;
    if (ev_rx_raw)    core_cnt.rx_raw    <= core_cnt.rx_raw + 32'd1;
    if (ev_rx_echo)   core_cnt.rx_echo   <= core_cnt.rx_echo + 32'd1;
    if (ev_rx_sock)   core_cnt.rx_sock   <= core_cnt.rx_sock + 32'd1;
    if (ev_rx_drop)   core_cnt.rx_drop   <= core_cnt.rx_drop + 32'd1;
    if (raw_q_overflow)  core_cnt.rx_raw_drop  <= core_cnt.rx_raw_drop + 32'd1;
    if (sock_q_overflow) core_cnt.rx_sock_drop <= core_cnt.rx_sock_drop + 32'd1;
    if (ev_rx_echo_drop) core_cnt.rx_echo_drop <= core_cnt.rx_echo_drop + 32'd1;
    if (ev_rx_bad)       core_cnt.rx_bad       <= core_cnt.rx_bad + 32'd1;
    core_cnt.tx_oversize <= core_cnt.tx_oversize + 32'(ev_tx_oversize_raw) + 32'(ev_tx_oversize_sock);
    if (ev_tx_raw)    core_cnt.tx_raw    <= core_cnt.tx_raw + 32'd1;
    if (ev_tx_echo)   core_cnt.tx_echo   <= core_cnt.tx_echo + 32'd1;
    if (ev_tx_sock)   core_cnt.tx_sock   <= core_cnt.tx_sock + 32'd1;

    // len_cksum metadata has no back-pressure: flag a (theoretically impossible) loss
    if (axis_rx_len_in.tvalid && !axis_rx_len_in.tready) core_cnt.err[0] <= 1'b1;
    if (axis_tx_len_in.tvalid && !axis_tx_len_in.tready) core_cnt.err[1] <= 1'b1;

    if (rst || clr_core) begin
        core_cnt.rx_frames <= '0;
        core_cnt.rx_bytes  <= '0;
        core_cnt.rx_l3_bad <= '0;
        core_cnt.rx_l4_bad <= '0;
        core_cnt.rx_raw    <= '0;
        core_cnt.rx_echo   <= '0;
        core_cnt.rx_sock   <= '0;
        core_cnt.rx_drop   <= '0;
        core_cnt.rx_raw_drop  <= '0;
        core_cnt.rx_sock_drop <= '0;
        core_cnt.rx_echo_drop <= '0;
        core_cnt.rx_bad       <= '0;
        core_cnt.tx_oversize  <= '0;
        core_cnt.tx_raw    <= '0;
        core_cnt.tx_echo   <= '0;
        core_cnt.tx_sock   <= '0;
    end
    if (rst) begin
        core_cnt.err <= '0;
    end
end

endmodule

`resetall

// SPDX-License-Identifier: MIT
//
// zircon_regs - AXI4-Lite register file of zircon_nic (ui_clk domain).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Register map (byte offsets, 32-bit, docs/DESIGN_SPEC.md §3.3)
//   0x000 ID                RO  0x5A495243 ("ZIRC")
//   0x004 VERSION           RO  0x00010300 (1.3.0)
//   0x008 CTRL              RW  b0 RX_EN, b1 TX_EN, b2 ECHO_EN, b3 SOCK_EN,
//                               b4 PROMISC (reserved), b31 STAT_CLR (W, self-clearing)
//   0x00C STATUS            b0 RX_FIFO_OVF (sticky, W1C), b1 TX_UNDERRUN (always 0:
//                               the MAC-side TX FIFO is a frame FIFO and cannot underrun),
//                               b2 RX_META_ERR, b3 TX_META_ERR (RO, sticky until reset;
//                               internal len_cksum metadata FIFO overflow, must never set),
//                               b4 RX_PACK_STALL, b5 RX_PACK_OVF (sticky, W1C: the
//                               mrmac_rx_packer output was back-pressured / lost beats)
//   0x010 MAC_LO / 0x014 MAC_HI            local MAC, byte 0 (first on wire) in bits 7:0
//   0x018 IPV4                             local IPv4, first octet in bits 31:24
//   0x01C ECHO_PORT (default 7)  0x020 SOCK_LOCAL_PORT  0x024 SOCK_REMOTE_PORT
//   0x028 SOCK_REMOTE_IP  0x02C SOCK_REMOTE_MAC_LO  0x030 SOCK_REMOTE_MAC_HI
//   0x034 TTL (default 64)
//   0x040.. counters, RO, wrap; cleared by CTRL.STAT_CLR:
//   0x040 RX_FRAMES 0x044/0x048 RX_BYTES_LO/HI 0x04C RX_BAD_FRAME 0x050 RX_FIFO_DROP
//   0x054 RX_L3_BAD_CSUM 0x058 RX_L4_BAD_CSUM 0x05C RX_RAW 0x060 RX_ECHO 0x064 RX_SOCK
//   0x068 TX_FRAMES 0x06C/0x070 TX_BYTES_LO/HI 0x074 TX_RAW 0x078 TX_ECHO 0x07C TX_SOCK
//   0x080 RX_RAW_DROP 0x084 RX_SOCK_DROP 0x088 RX_ECHO_DROP 0x08C TX_OVERSIZE_DROP (1.1.0)
// Generator / checker (1.2.0; with GEN_EN = 0 all of 0x090..0x0E0 read 0, writes ignored):
//   0x090 GEN_CTRL    b0 EN, b1 CONT, b2 CLR (W, self-clearing), b31 BUSY (RO)
//   0x094 GEN_LEN (default 1472; used clamped to 8..9000)  0x098 GEN_COUNT  0x09C GEN_GAP
//   0x0A0 GEN_DST_MAC_LO  0x0A4 GEN_DST_MAC_HI  0x0A8 GEN_DST_IP  0x0AC GEN_DST_PORT
//   0x0B0 GEN_SRC_PORT    0x0B4 GEN_TX_PKTS  0x0B8/0x0BC GEN_TX_BYTES_LO/HI
//   0x0C0 CHK_CTRL    b0 EN, b2 CLR (W, self-clearing), b31 SYNC (RO)
//   0x0C4 CHK_PORT (default 5001)  0x0C8 CHK_RX_PKTS  0x0CC/0x0D0 CHK_RX_BYTES_LO/HI
//   0x0D4 CHK_SEQ_ERR  0x0D8/0x0DC CHK_BIT_ERR_LO/HI  0x0E0 CHK_LEN_ERR
// Rate meters (1.2.0, always present): 0x0E4 RATE_SEQ (a read latches the six rate
//   registers below from the same window), 0x0E8/0x0EC RX_RATE_BYTES_LO/HI,
//   0x0F0 RX_RATE_PKTS, 0x0F4/0x0F8 TX_RATE_BYTES_LO/HI, 0x0FC TX_RATE_PKTS
// Latency measurement (1.3.0, docs/DESIGN_SPEC.md §11, docs/source/registers.md):
//   0x100 LAT_CTRL    b0 EN (request TX timestamps), b1 CLR0, b2 CLR1, b3 SNAP (W1,
//                     self-clearing commands), b8 RAW_RX_DESC, b9 RAW_TX_DESC,
//                     b31 BUSY (RO: a command is still running)
//                     (b3 also reads 1 while a command runs)
//   0x104 LAT_STATUS  b0 STALE, b1 LOST, b2 OVF (sticky, W1C; counters below moved)
//   0x108 LAT_BIN_BASE (ns, default 0)  0x10C LAT_BIN_WIDTH (ns, a power of two;
//                     other values are rounded down, 0 -> 1; default 64); both banks
//   0x110 LAT_STALE_CNT  0x114 LAT_LOST_CNT  0x118 LAT_OVF_CNT (RO; cleared by STAT_CLR)
//   0x200..0x7FF      snapshot (latency_stats shadow RAM, read with one extra cycle)
// 64-bit counters: reading _LO latches _HI from the same snapshot, so LO then HI
// is never torn. Undefined offsets read 0, writes to them are ignored.
//
// The counters arrive as coherent snapshots from their own clock domains (see
// zircon_cdc_snapshot); RX_FIFO_DROP is the sum of MAC-side FIFO drops and frames
// dropped by rx_dispatch while CTRL.RX_EN = 0; RX_BAD_FRAME is the sum of MAC-side
// FIFO bad-frame drops and frames rx_dispatch dropped for a bad marker.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module zircon_regs
    import zircon_nic_pkg::*;
#(
    parameter int AXIL_ADDR_W = 12,
    parameter bit GEN_EN = 1'b1          // generator / checker registers present
) (
    input  wire logic                    clk,
    input  wire logic                    rst,

    // AXI4-Lite slave
    input  wire logic [AXIL_ADDR_W-1:0]  s_axi_awaddr,
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
    input  wire logic                    s_axi_arvalid,
    output wire logic                    s_axi_arready,
    output wire logic [31:0]             s_axi_rdata,
    output wire logic [1:0]              s_axi_rresp,
    output wire logic                    s_axi_rvalid,
    input  wire logic                    s_axi_rready,

    // configuration (this clock domain)
    output cfg_t                         cfg,

    // counter snapshots (already in this clock domain)
    input  wire core_cnt_t               core_cnt,
    input  wire macrx_cnt_t              macrx_cnt,
    input  wire mactx_cnt_t              mactx_cnt,
    input  wire ext_cnt_t                ext_cnt,

    // latency measurement (1.3.0)
    input  wire lat_err_t                lat_err,        // MAC TX error counters (snapshot)
    input  wire logic                    lat_ack_toggle, // latency_stats command ack (synchronised)
    output wire logic [8:0]              lat_rd_addr,    // shadow RAM word address (byte addr [10:2])
    input  wire logic [31:0]             lat_rd_data     // shadow RAM data, one cycle after lat_rd_addr
);

localparam logic [31:0] ID_VALUE      = 32'h5A495243;
localparam logic [31:0] VERSION_VALUE = 32'h00010300;   // 1.3.0 (bits 23:16 major, 15:8 minor, 7:0 patch)
localparam logic [4:0]  LAT_SHIFT_DEFAULT = 5'd6;       // 64 ns bins

// floor(log2(v)), 0 for v = 0
function automatic logic [4:0] log2_floor(input logic [31:0] v);
    log2_floor = '0;
    for (int i = 0; i < 32; i++) if (v[i]) log2_floor = 5'(i);
endfunction
localparam logic [15:0] GEN_LEN_DEFAULT  = 16'd1472;
localparam logic [15:0] CHK_PORT_DEFAULT = 16'd5001;

function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw, input logic [3:0] strb);
    for (int i = 0; i < 4; i++) merge[8*i +: 8] = strb[i] ? nw[8*i +: 8] : old[8*i +: 8];
endfunction

function automatic logic [31:0] bswap32(input logic [31:0] v);
    bswap32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction

// ---- registers ----
logic [4:0]  ctrl_reg = '0;
logic        clr_toggle_reg = 1'b0;
logic        rx_ovf_reg = 1'b0;
logic [31:0] mac_lo_reg = '0;
logic [15:0] mac_hi_reg = '0;
logic [31:0] ipv4_reg = '0;
logic [15:0] echo_port_reg = 16'd7;
logic [15:0] sock_local_port_reg = '0;
logic [15:0] sock_remote_port_reg = '0;
logic [31:0] sock_remote_ip_reg = '0;
logic [31:0] sock_remote_mac_lo_reg = '0;
logic [15:0] sock_remote_mac_hi_reg = '0;
logic [7:0]  ttl_reg = 8'd64;

// generator / checker configuration (1.2.0)
logic [1:0]  gen_ctrl_reg = '0;          // b1 CONT, b0 EN
logic        gen_clr_toggle_reg = 1'b0;
logic [15:0] gen_len_reg = GEN_LEN_DEFAULT;
logic [31:0] gen_count_reg = '0;
logic [31:0] gen_gap_reg = '0;
logic [31:0] gen_dst_mac_lo_reg = '0;
logic [15:0] gen_dst_mac_hi_reg = '0;
logic [31:0] gen_dst_ip_reg = '0;
logic [15:0] gen_dst_port_reg = '0;
logic [15:0] gen_src_port_reg = '0;
logic        chk_en_reg = 1'b0;
logic        chk_clr_toggle_reg = 1'b0;
logic [15:0] chk_port_reg = CHK_PORT_DEFAULT;

logic [31:0] gen_tx_bytes_hi_hold_reg = '0;
logic [31:0] chk_rx_bytes_hi_hold_reg = '0;
logic [31:0] chk_bit_err_hi_hold_reg = '0;
logic [63:0] rx_rate_bytes_hold_reg = '0;
logic [31:0] rx_rate_pkts_hold_reg = '0;
logic [63:0] tx_rate_bytes_hold_reg = '0;
logic [31:0] tx_rate_pkts_hold_reg = '0;

logic [31:0] rx_bytes_hi_hold_reg = '0;
logic [31:0] tx_bytes_hi_hold_reg = '0;
logic [31:0] prev_fifo_drop_reg = '0;
logic        pack_stall_reg = 1'b0;
logic        pack_ovf_reg = 1'b0;
logic [15:0] prev_pack_stall_reg = '0;
logic [15:0] prev_pack_ovf_reg = '0;

// latency measurement (1.3.0)
logic        lat_en_reg = 1'b0;
logic        lat_raw_rx_reg = 1'b0;
logic        lat_raw_tx_reg = 1'b0;
logic        lat_req_toggle_reg = 1'b0;
logic        lat_snap_toggle_reg = 1'b0;
logic [LAT_BANKS-1:0] lat_clr_toggle_reg = '0;
logic [31:0] lat_base_reg = '0;
logic [4:0]  lat_shift_reg = LAT_SHIFT_DEFAULT;
logic [2:0]  lat_sticky_reg = '0;          // b0 STALE, b1 LOST, b2 OVF
lat_err_t    prev_lat_err_reg = '0;

always_comb begin
    cfg.stat_clr_toggle  = clr_toggle_reg;
    cfg.promisc          = ctrl_reg[4];
    cfg.sock_en          = ctrl_reg[3];
    cfg.echo_en          = ctrl_reg[2];
    cfg.tx_en            = ctrl_reg[1];
    cfg.rx_en            = ctrl_reg[0];
    cfg.ttl              = ttl_reg;
    cfg.local_mac        = {mac_hi_reg, mac_lo_reg};
    cfg.local_ip         = bswap32(ipv4_reg);
    cfg.echo_port        = echo_port_reg;
    cfg.sock_local_port  = sock_local_port_reg;
    cfg.sock_remote_port = sock_remote_port_reg;
    cfg.sock_remote_ip   = bswap32(sock_remote_ip_reg);
    cfg.sock_remote_mac  = {sock_remote_mac_hi_reg, sock_remote_mac_lo_reg};
    cfg.gen_en           = GEN_EN && gen_ctrl_reg[0];
    cfg.gen_cont         = GEN_EN && gen_ctrl_reg[1];
    cfg.gen_clr_toggle   = GEN_EN && gen_clr_toggle_reg;
    cfg.gen_len          = !GEN_EN ? 14'd0 : (gen_len_reg > 16'(GEN_LEN_MAX)) ? 14'(GEN_LEN_MAX) : 14'(gen_len_reg);
    cfg.gen_count        = GEN_EN ? gen_count_reg : '0;
    cfg.gen_gap          = GEN_EN ? gen_gap_reg : '0;
    cfg.gen_dst_mac      = GEN_EN ? {gen_dst_mac_hi_reg, gen_dst_mac_lo_reg} : '0;
    cfg.gen_dst_ip       = GEN_EN ? bswap32(gen_dst_ip_reg) : '0;
    cfg.gen_dst_port     = GEN_EN ? gen_dst_port_reg : '0;
    cfg.gen_src_port     = GEN_EN ? gen_src_port_reg : '0;
    cfg.chk_en           = GEN_EN && chk_en_reg;
    cfg.chk_clr_toggle   = GEN_EN && chk_clr_toggle_reg;
    cfg.chk_port         = GEN_EN ? chk_port_reg : '0;
    cfg.lat_en           = lat_en_reg;
    cfg.lat_raw_rx_desc  = lat_raw_rx_reg;
    cfg.lat_raw_tx_desc  = lat_raw_tx_reg;
    cfg.lat_req_toggle   = lat_req_toggle_reg;
    cfg.lat_snap_toggle  = lat_snap_toggle_reg;
    cfg.lat_clr_toggle   = lat_clr_toggle_reg;
    cfg.lat_base         = lat_base_reg;
    cfg.lat_shift        = lat_shift_reg;
end

// ---- AXI4-Lite handshakes ----
// A write is accepted when address and data are both valid (single cycle);
// a read is accepted whenever no read response is pending.
logic        b_valid_reg = 1'b0;
logic        r_valid_reg = 1'b0;
logic [31:0] r_data_reg = '0;
logic        r_sh_pend_reg = 1'b0;   // a snapshot-RAM read is waiting for the RAM output

wire do_write = s_axi_awvalid && s_axi_wvalid && !b_valid_reg;
wire do_read  = s_axi_arvalid && !r_valid_reg && !r_sh_pend_reg;

// snapshot region 0x200..0x7FF (word 0x080..0x1FF): latency_stats shadow RAM
wire raddr_sh = s_axi_araddr[11] == 1'b0 && s_axi_araddr[10:9] != 2'b00;
assign lat_rd_addr = s_axi_araddr[10:2];

assign s_axi_awready = do_write;
assign s_axi_wready  = do_write;
assign s_axi_bresp   = 2'b00;
assign s_axi_bvalid  = b_valid_reg;
assign s_axi_arready = do_read;
assign s_axi_rdata   = r_data_reg;
assign s_axi_rresp   = 2'b00;
assign s_axi_rvalid  = r_valid_reg;

wire [9:0] waddr = s_axi_awaddr[11:2];
wire [9:0] raddr = s_axi_araddr[11:2];

if (AXIL_ADDR_W != 12)
    $fatal(0, "Error: AXIL_ADDR_W must be 12 (instance %m)");

wire [31:0] rx_fifo_drop_total = macrx_cnt.rx_fifo_drop + core_cnt.rx_drop;
wire [31:0] rx_bad_total       = macrx_cnt.rx_bad_frame + core_cnt.rx_bad;

always_ff @(posedge clk) begin
    // sticky RX FIFO overflow: the MAC-side drop counter moved (ignoring the
    // transition to 0 caused by STAT_CLR)
    prev_fifo_drop_reg <= macrx_cnt.rx_fifo_drop;
    if (macrx_cnt.rx_fifo_drop != prev_fifo_drop_reg && macrx_cnt.rx_fifo_drop != 32'd0) begin
        rx_ovf_reg <= 1'b1;
    end
    // sticky mrmac_rx_packer status, same scheme
    prev_pack_stall_reg <= macrx_cnt.rx_pack_stall;
    prev_pack_ovf_reg   <= macrx_cnt.rx_pack_ovf;
    if (macrx_cnt.rx_pack_stall != prev_pack_stall_reg && macrx_cnt.rx_pack_stall != 16'd0) begin
        pack_stall_reg <= 1'b1;
    end
    if (macrx_cnt.rx_pack_ovf != prev_pack_ovf_reg && macrx_cnt.rx_pack_ovf != 16'd0) begin
        pack_ovf_reg <= 1'b1;
    end
    // sticky latency errors, same scheme
    prev_lat_err_reg <= lat_err;
    if (lat_err.stale != prev_lat_err_reg.stale && lat_err.stale != 32'd0) lat_sticky_reg[0] <= 1'b1;
    if (lat_err.lost  != prev_lat_err_reg.lost  && lat_err.lost  != 32'd0) lat_sticky_reg[1] <= 1'b1;
    if (lat_err.ovf   != prev_lat_err_reg.ovf   && lat_err.ovf   != 32'd0) lat_sticky_reg[2] <= 1'b1;

    // write
    if (s_axi_bvalid && s_axi_bready) begin
        b_valid_reg <= 1'b0;
    end
    if (do_write) begin
        b_valid_reg <= 1'b1;
        case (waddr)
            10'h002: begin // CTRL
                if (s_axi_wstrb[0]) ctrl_reg <= s_axi_wdata[4:0];
                if (s_axi_wstrb[3] && s_axi_wdata[31]) clr_toggle_reg <= !clr_toggle_reg;
            end
            10'h003: begin // STATUS (W1C)
                if (s_axi_wstrb[0] && s_axi_wdata[0]) rx_ovf_reg <= 1'b0;
                if (s_axi_wstrb[0] && s_axi_wdata[4]) pack_stall_reg <= 1'b0;
                if (s_axi_wstrb[0] && s_axi_wdata[5]) pack_ovf_reg <= 1'b0;
            end
            10'h004: mac_lo_reg             <= merge(mac_lo_reg, s_axi_wdata, s_axi_wstrb);
            10'h005: mac_hi_reg             <= 16'(merge({16'd0, mac_hi_reg}, s_axi_wdata, s_axi_wstrb));
            10'h006: ipv4_reg               <= merge(ipv4_reg, s_axi_wdata, s_axi_wstrb);
            10'h007: echo_port_reg          <= 16'(merge({16'd0, echo_port_reg}, s_axi_wdata, s_axi_wstrb));
            10'h008: sock_local_port_reg    <= 16'(merge({16'd0, sock_local_port_reg}, s_axi_wdata, s_axi_wstrb));
            10'h009: sock_remote_port_reg   <= 16'(merge({16'd0, sock_remote_port_reg}, s_axi_wdata, s_axi_wstrb));
            10'h00A: sock_remote_ip_reg     <= merge(sock_remote_ip_reg, s_axi_wdata, s_axi_wstrb);
            10'h00B: sock_remote_mac_lo_reg <= merge(sock_remote_mac_lo_reg, s_axi_wdata, s_axi_wstrb);
            10'h00C: sock_remote_mac_hi_reg <= 16'(merge({16'd0, sock_remote_mac_hi_reg}, s_axi_wdata, s_axi_wstrb));
            10'h00D: ttl_reg                <= 8'(merge({24'd0, ttl_reg}, s_axi_wdata, s_axi_wstrb));
            // generator / checker
            10'h024: begin // GEN_CTRL
                if (s_axi_wstrb[0]) gen_ctrl_reg <= s_axi_wdata[1:0];
                if (s_axi_wstrb[0] && s_axi_wdata[2]) gen_clr_toggle_reg <= !gen_clr_toggle_reg;
            end
            10'h025: gen_len_reg        <= 16'(merge({16'd0, gen_len_reg}, s_axi_wdata, s_axi_wstrb));
            10'h026: gen_count_reg      <= merge(gen_count_reg, s_axi_wdata, s_axi_wstrb);
            10'h027: gen_gap_reg        <= merge(gen_gap_reg, s_axi_wdata, s_axi_wstrb);
            10'h028: gen_dst_mac_lo_reg <= merge(gen_dst_mac_lo_reg, s_axi_wdata, s_axi_wstrb);
            10'h029: gen_dst_mac_hi_reg <= 16'(merge({16'd0, gen_dst_mac_hi_reg}, s_axi_wdata, s_axi_wstrb));
            10'h02A: gen_dst_ip_reg     <= merge(gen_dst_ip_reg, s_axi_wdata, s_axi_wstrb);
            10'h02B: gen_dst_port_reg   <= 16'(merge({16'd0, gen_dst_port_reg}, s_axi_wdata, s_axi_wstrb));
            10'h02C: gen_src_port_reg   <= 16'(merge({16'd0, gen_src_port_reg}, s_axi_wdata, s_axi_wstrb));
            10'h030: begin // CHK_CTRL
                if (s_axi_wstrb[0]) chk_en_reg <= s_axi_wdata[0];
                if (s_axi_wstrb[0] && s_axi_wdata[2]) chk_clr_toggle_reg <= !chk_clr_toggle_reg;
            end
            10'h031: chk_port_reg       <= 16'(merge({16'd0, chk_port_reg}, s_axi_wdata, s_axi_wstrb));
            // latency measurement
            10'h040: begin // LAT_CTRL
                if (s_axi_wstrb[0]) begin
                    lat_en_reg <= s_axi_wdata[0];
                    if (s_axi_wdata[1]) lat_clr_toggle_reg[0] <= !lat_clr_toggle_reg[0];
                    if (s_axi_wdata[2] && LAT_BANKS > 1) lat_clr_toggle_reg[LAT_BANKS-1] <= !lat_clr_toggle_reg[LAT_BANKS-1];
                    if (s_axi_wdata[3]) lat_snap_toggle_reg <= !lat_snap_toggle_reg;
                    if (|s_axi_wdata[3:1]) lat_req_toggle_reg <= !lat_req_toggle_reg;
                end
                if (s_axi_wstrb[1]) begin
                    lat_raw_rx_reg <= s_axi_wdata[8];
                    lat_raw_tx_reg <= s_axi_wdata[9];
                end
            end
            10'h041: begin // LAT_STATUS (W1C)
                if (s_axi_wstrb[0]) lat_sticky_reg <= lat_sticky_reg & ~s_axi_wdata[2:0];
            end
            10'h042: lat_base_reg  <= merge(lat_base_reg, s_axi_wdata, s_axi_wstrb);
            10'h043: lat_shift_reg <= log2_floor(merge(32'd1 << lat_shift_reg, s_axi_wdata, s_axi_wstrb));
            default: ;
        endcase
    end

    // read
    if (s_axi_rvalid && s_axi_rready) begin
        r_valid_reg <= 1'b0;
    end
    if (r_sh_pend_reg) begin
        r_sh_pend_reg <= 1'b0;
        r_valid_reg   <= 1'b1;
        r_data_reg    <= lat_rd_data;
    end
    if (do_read && raddr_sh) begin
        r_sh_pend_reg <= 1'b1;
    end
    if (do_read && !raddr_sh) begin
        r_valid_reg <= 1'b1;
        case (raddr)
            10'h000: r_data_reg <= ID_VALUE;
            10'h001: r_data_reg <= VERSION_VALUE;
            10'h002: r_data_reg <= {27'd0, ctrl_reg};
            10'h003: r_data_reg <= {26'd0, pack_ovf_reg, pack_stall_reg, core_cnt.err, 1'b0, rx_ovf_reg};
            10'h004: r_data_reg <= mac_lo_reg;
            10'h005: r_data_reg <= {16'd0, mac_hi_reg};
            10'h006: r_data_reg <= ipv4_reg;
            10'h007: r_data_reg <= {16'd0, echo_port_reg};
            10'h008: r_data_reg <= {16'd0, sock_local_port_reg};
            10'h009: r_data_reg <= {16'd0, sock_remote_port_reg};
            10'h00A: r_data_reg <= sock_remote_ip_reg;
            10'h00B: r_data_reg <= sock_remote_mac_lo_reg;
            10'h00C: r_data_reg <= {16'd0, sock_remote_mac_hi_reg};
            10'h00D: r_data_reg <= {24'd0, ttl_reg};
            10'h010: r_data_reg <= core_cnt.rx_frames;
            10'h011: begin
                r_data_reg <= core_cnt.rx_bytes[31:0];
                rx_bytes_hi_hold_reg <= core_cnt.rx_bytes[63:32];
            end
            10'h012: r_data_reg <= rx_bytes_hi_hold_reg;
            10'h013: r_data_reg <= rx_bad_total;
            10'h014: r_data_reg <= rx_fifo_drop_total;
            10'h015: r_data_reg <= core_cnt.rx_l3_bad;
            10'h016: r_data_reg <= core_cnt.rx_l4_bad;
            10'h017: r_data_reg <= core_cnt.rx_raw;
            10'h018: r_data_reg <= core_cnt.rx_echo;
            10'h019: r_data_reg <= core_cnt.rx_sock;
            10'h01A: r_data_reg <= mactx_cnt.tx_frames;
            10'h01B: begin
                r_data_reg <= mactx_cnt.tx_bytes[31:0];
                tx_bytes_hi_hold_reg <= mactx_cnt.tx_bytes[63:32];
            end
            10'h01C: r_data_reg <= tx_bytes_hi_hold_reg;
            10'h01D: r_data_reg <= core_cnt.tx_raw;
            10'h01E: r_data_reg <= core_cnt.tx_echo;
            10'h01F: r_data_reg <= core_cnt.tx_sock;
            10'h020: r_data_reg <= core_cnt.rx_raw_drop;
            10'h021: r_data_reg <= core_cnt.rx_sock_drop;
            10'h022: r_data_reg <= core_cnt.rx_echo_drop;
            10'h023: r_data_reg <= core_cnt.tx_oversize;
            // generator / checker (GEN_EN = 0: read 0, see below)
            10'h024: r_data_reg <= {ext_cnt.gen_busy, 29'd0, gen_ctrl_reg};
            10'h025: r_data_reg <= {16'd0, gen_len_reg};
            10'h026: r_data_reg <= gen_count_reg;
            10'h027: r_data_reg <= gen_gap_reg;
            10'h028: r_data_reg <= gen_dst_mac_lo_reg;
            10'h029: r_data_reg <= {16'd0, gen_dst_mac_hi_reg};
            10'h02A: r_data_reg <= gen_dst_ip_reg;
            10'h02B: r_data_reg <= {16'd0, gen_dst_port_reg};
            10'h02C: r_data_reg <= {16'd0, gen_src_port_reg};
            10'h02D: r_data_reg <= ext_cnt.gen_tx_pkts;
            10'h02E: begin
                r_data_reg <= ext_cnt.gen_tx_bytes[31:0];
                gen_tx_bytes_hi_hold_reg <= ext_cnt.gen_tx_bytes[63:32];
            end
            10'h02F: r_data_reg <= gen_tx_bytes_hi_hold_reg;
            10'h030: r_data_reg <= {ext_cnt.chk_sync, 30'd0, chk_en_reg};
            10'h031: r_data_reg <= {16'd0, chk_port_reg};
            10'h032: r_data_reg <= ext_cnt.chk_rx_pkts;
            10'h033: begin
                r_data_reg <= ext_cnt.chk_rx_bytes[31:0];
                chk_rx_bytes_hi_hold_reg <= ext_cnt.chk_rx_bytes[63:32];
            end
            10'h034: r_data_reg <= chk_rx_bytes_hi_hold_reg;
            10'h035: r_data_reg <= ext_cnt.chk_seq_err;
            10'h036: begin
                r_data_reg <= ext_cnt.chk_bit_err[31:0];
                chk_bit_err_hi_hold_reg <= ext_cnt.chk_bit_err[63:32];
            end
            10'h037: r_data_reg <= chk_bit_err_hi_hold_reg;
            10'h038: r_data_reg <= ext_cnt.chk_len_err;
            // rate meters: reading RATE_SEQ latches the whole window
            10'h039: begin
                r_data_reg <= ext_cnt.rate_seq;
                rx_rate_bytes_hold_reg <= ext_cnt.rx_rate_bytes;
                rx_rate_pkts_hold_reg  <= ext_cnt.rx_rate_pkts;
                tx_rate_bytes_hold_reg <= ext_cnt.tx_rate_bytes;
                tx_rate_pkts_hold_reg  <= ext_cnt.tx_rate_pkts;
            end
            10'h03A: r_data_reg <= rx_rate_bytes_hold_reg[31:0];
            10'h03B: r_data_reg <= rx_rate_bytes_hold_reg[63:32];
            10'h03C: r_data_reg <= rx_rate_pkts_hold_reg;
            10'h03D: r_data_reg <= tx_rate_bytes_hold_reg[31:0];
            10'h03E: r_data_reg <= tx_rate_bytes_hold_reg[63:32];
            10'h03F: r_data_reg <= tx_rate_pkts_hold_reg;
            // latency measurement
            10'h040: r_data_reg <= {lat_req_toggle_reg != lat_ack_toggle, 21'd0, lat_raw_tx_reg, lat_raw_rx_reg,
                                    4'd0, lat_req_toggle_reg != lat_ack_toggle, 2'd0, lat_en_reg};
            10'h041: r_data_reg <= {29'd0, lat_sticky_reg};
            10'h042: r_data_reg <= lat_base_reg;
            10'h043: r_data_reg <= 32'd1 << lat_shift_reg;
            10'h044: r_data_reg <= lat_err.stale;
            10'h045: r_data_reg <= lat_err.lost;
            10'h046: r_data_reg <= lat_err.ovf;
            default: r_data_reg <= 32'd0;
        endcase
        if (!GEN_EN && raddr >= 10'h024 && raddr <= 10'h038) begin
            r_data_reg <= 32'd0;
        end
    end

    if (rst) begin
        b_valid_reg            <= 1'b0;
        r_valid_reg            <= 1'b0;
        ctrl_reg               <= '0;
        clr_toggle_reg         <= 1'b0;
        rx_ovf_reg             <= 1'b0;
        mac_lo_reg             <= '0;
        mac_hi_reg             <= '0;
        ipv4_reg               <= '0;
        echo_port_reg          <= 16'd7;
        sock_local_port_reg    <= '0;
        sock_remote_port_reg   <= '0;
        sock_remote_ip_reg     <= '0;
        sock_remote_mac_lo_reg <= '0;
        sock_remote_mac_hi_reg <= '0;
        ttl_reg                <= 8'd64;
        rx_bytes_hi_hold_reg   <= '0;
        tx_bytes_hi_hold_reg   <= '0;
        prev_fifo_drop_reg     <= '0;
        pack_stall_reg         <= 1'b0;
        pack_ovf_reg           <= 1'b0;
        prev_pack_stall_reg    <= '0;
        prev_pack_ovf_reg      <= '0;
        gen_ctrl_reg           <= '0;
        gen_clr_toggle_reg     <= 1'b0;
        gen_len_reg            <= GEN_LEN_DEFAULT;
        gen_count_reg          <= '0;
        gen_gap_reg            <= '0;
        gen_dst_mac_lo_reg     <= '0;
        gen_dst_mac_hi_reg     <= '0;
        gen_dst_ip_reg         <= '0;
        gen_dst_port_reg       <= '0;
        gen_src_port_reg       <= '0;
        chk_en_reg             <= 1'b0;
        chk_clr_toggle_reg     <= 1'b0;
        chk_port_reg           <= CHK_PORT_DEFAULT;
        gen_tx_bytes_hi_hold_reg <= '0;
        chk_rx_bytes_hi_hold_reg <= '0;
        chk_bit_err_hi_hold_reg  <= '0;
        rx_rate_bytes_hold_reg <= '0;
        rx_rate_pkts_hold_reg  <= '0;
        tx_rate_bytes_hold_reg <= '0;
        tx_rate_pkts_hold_reg  <= '0;
        r_sh_pend_reg          <= 1'b0;
        lat_en_reg             <= 1'b0;
        lat_raw_rx_reg         <= 1'b0;
        lat_raw_tx_reg         <= 1'b0;
        lat_req_toggle_reg     <= 1'b0;
        lat_snap_toggle_reg    <= 1'b0;
        lat_clr_toggle_reg     <= '0;
        lat_base_reg           <= '0;
        lat_shift_reg          <= LAT_SHIFT_DEFAULT;
        lat_sticky_reg         <= '0;
        prev_lat_err_reg       <= '0;
    end
end

endmodule

`resetall

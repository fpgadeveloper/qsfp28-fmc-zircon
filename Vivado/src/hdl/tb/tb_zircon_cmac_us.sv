// SPDX-License-Identifier: MIT
//
// tb_zircon_cmac_us - xsim testbench of the KCU116 CMAC shim zircon_cmac_us (Verilog
// shell + zircon_cmac_us_core) built around Taxi's taxi_eth_mac_100g_us with SIM = 1,
// plus one integration run with zircon_nic behind it.
//
// Taxi's SIM mode removes the GT and CMAC IP but does NOT loop TX to RX: the GT user
// clocks (gt_txoutclk / gt_rxoutclk of every lane) and the CMAC client interfaces
// (cmac_axis_tx / cmac_axis_rx inside the wrapper) are left for the testbench to
// drive, as Taxi's own cocotb testbenches do. This TB forces them hierarchically and
// models the CMAC: TX tready (always / random / 100 Gb/s shaped), an optional TX -> RX
// loop with a fixed delay across the two unrelated clocks, and injected RX frames.
//
//   101 registers_and_xcvr_reset  ID / VERSION / CTRL 0x31 / TS_INCR / STICKY defaults,
//        mac_*_aresetn low and GT APB answering SLVERR while XCVR_RST is set; release
//        -> TX_RST_OUT / RX_RST_OUT clear, RX_STATUS, link_up, mac_*_aresetn high
//   102 apb_round_trip  AXI-Lite -> taxi_axil_apb_adapter -> the wrapper's own GT APB
//        registers: 32-bit and 16-bit (both halves) accesses, lane address split, a
//        16-bit write does not disturb the neighbouring 16-bit register
//   103 ts_now_and_clk_khz  TS_NOW advances at 1 ns/ns (LO latches HI); TX_CLK_KHZ /
//        RX_CLK_KHZ match the model clocks
//   104 rx_timestamp  injected RX frames (1..40 beats, error flags, mid-frame gaps):
//        data unchanged, tuser[48:1] on every beat equal to the first-beat timestamp,
//        timestamp vs true arrival time within the ts_gray_sync window, counters
//   105 tx_tag_return  op 2'b10 records (queued ahead, same cycle as SOF, several
//        frames ahead), op 0 records, random CMAC tready: one return per op-2 frame,
//        one cycle after the SOF handshake, right tag, timestamp vs true SOF time;
//        none for op 0; counters
//   106 ptp_underrun  a frame without a record goes out untagged, STICKY.PTP_UNDERRUN
//        set, W1C clears it; the frame data is intact
//   107 loop_delta  TX -> RX loop (unrelated clocks, three different RX periods /
//        phases): |(RX ts - TX ts) - true delay| <= 8 ns for every frame
//   108 gray_sync  (monitors over the whole run) ts_gray_sync outputs in tx_clk,
//        rx_clk and ctrl_clk monotonic, +0/+1 (+2 or 3 in ctrl_clk) per cycle, and the
//        lag spread (max - min) <= 8 ns in each domain and across tx and rx together
//   109 rx_tx_reset  CTRL.RX_RST: mac_rx_aresetn low, STICKY.LINK_LOST; CTRL.TX_RST:
//        mac_tx_aresetn low; recovery
//   110 nic_gen_to_chk  zircon_nic + shim, mac_tx_clk != mac_rx_clk, CMAC TX shaped to
//        100 Gb/s, looped: 200 generated 1472-byte datagrams checked, no errors /
//        drops, no PTP underrun (records reach the shim in time), no timestamps
//   111 nic_echo_latency  20 UDP echo requests with LAT_CTRL.EN: bank 0 COUNT 20,
//        MIN / MAX within 8 ns of the true RX-first-beat -> TX-SOF delays, LAT_STATUS 0
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).

`timescale 1ns / 1ps
`default_nettype none

module tb_zircon_cmac_us;

`define MAC dut.core.mac_inst

typedef byte unsigned bytes_t[$];

// ---------------------------------------------------------------------------
// Clocks and resets
// ---------------------------------------------------------------------------
logic ctrl_clk = 1'b0, ts_clk = 1'b0, core_clk = 1'b0, ui_clk = 1'b0;
logic gtx_clk = 1'b0, grx_clk = 1'b0;
real  tx_half = 1.5515;     // 3.1030 ns (322.27 MHz - 300 ppm)
real  rx_half = 1.5506;     // 3.1012 ns (322.45 MHz)

always #4.0    ctrl_clk = ~ctrl_clk;   // 125 MHz
always #2.0    ts_clk = ~ts_clk;       // 250 MHz
always #1.6667 core_clk = ~core_clk;   // 300 MHz
always #5.0    ui_clk = ~ui_clk;       // 100 MHz
initial begin #0.37; forever #(tx_half) gtx_clk = ~gtx_clk; end
initial begin #1.13; forever #(rx_half) grx_clk = ~grx_clk; end

logic ctrl_aresetn = 1'b0, ts_aresetn = 1'b0, core_aresetn = 1'b0, ui_aresetn = 1'b0;

int test_errors = 0, total_pass = 0, total_fail = 0;

task automatic finish_test(int id, string name);
    if (test_errors == 0) begin
        $display("PASS: test %0d %s", id, name);
        total_pass++;
    end else begin
        $display("FAIL: test %0d %s (%0d errors)", id, name, test_errors);
        total_fail++;
    end
    test_errors = 0;
endtask

function automatic bit bytes_eq(const ref bytes_t a, const ref bytes_t b);
    if (a.size() != b.size()) return 0;
    foreach (a[i]) if (a[i] != b[i]) return 0;
    return 1;
endfunction

task automatic err(string msg);
    $display("  ERROR [%0t] %s", $realtime, msg);
    test_errors++;
endtask

// ---------------------------------------------------------------------------
// DUT: zircon_cmac_us (SIM = 1) and zircon_nic
// ---------------------------------------------------------------------------
// shim AXI-Lite
logic [18:0] sa_awaddr = '0, sa_araddr = '0;
logic        sa_awvalid = 1'b0, sa_wvalid = 1'b0, sa_bready = 1'b0, sa_arvalid = 1'b0, sa_rready = 1'b0;
logic [31:0] sa_wdata = '0;
logic [3:0]  sa_wstrb = '0;
wire         sa_awready, sa_wready, sa_bvalid, sa_arready, sa_rvalid;
wire  [1:0]  sa_bresp, sa_rresp;
wire  [31:0] sa_rdata;

// shim MAC side
wire         tx_clk, rx_clk, mac_tx_aresetn, mac_rx_aresetn, link_up;
wire [511:0] rx_tdata;
wire [63:0]  rx_tkeep;
wire         rx_tvalid, rx_tlast;
wire [48:0]  rx_tuser;
wire [511:0] tx_tdata;
wire [63:0]  tx_tkeep;
wire         tx_tvalid, tx_tready, tx_tlast;
wire [0:0]   tx_tuser;
wire [23:0]  ptp_tdata;
wire         ptp_tvalid, ptp_tready;
wire [54:0]  ts_out;
wire [15:0]  ts_tag_out;
wire         ts_valid_out;
wire [3:0]   gtx_p, gtx_n;

// testbench TX sources (sel_nic = 0) or zircon_nic (sel_nic = 1)
bit          sel_nic = 1'b0;
logic [511:0] tb_tx_tdata = '0;
logic [63:0]  tb_tx_tkeep = '0;
logic         tb_tx_tvalid = 1'b0, tb_tx_tlast = 1'b0;
logic [23:0]  tb_ptp_tdata = '0;
logic         tb_ptp_tvalid = 1'b0;

wire [511:0] z_tx_tdata;
wire [63:0]  z_tx_tkeep;
wire         z_tx_tvalid, z_tx_tlast;
wire [0:0]   z_tx_tuser;
wire [23:0]  z_ptp_tdata;
wire         z_ptp_tvalid;

assign tx_tdata   = sel_nic ? z_tx_tdata   : tb_tx_tdata;
assign tx_tkeep   = sel_nic ? z_tx_tkeep   : tb_tx_tkeep;
assign tx_tvalid  = sel_nic ? z_tx_tvalid  : tb_tx_tvalid;
assign tx_tlast   = sel_nic ? z_tx_tlast   : tb_tx_tlast;
assign tx_tuser   = sel_nic ? z_tx_tuser   : 1'b0;
assign ptp_tdata  = sel_nic ? z_ptp_tdata  : tb_ptp_tdata;
assign ptp_tvalid = sel_nic ? z_ptp_tvalid : tb_ptp_tvalid;

zircon_cmac_us #(
    .FAMILY("kintexuplus"),
    .CFG_LOW_LATENCY(0),
    .C_S_AXI_ADDR_WIDTH(19),
    .TS_INCR(1024),
    .SIM(1)
) dut (
    .gt_ref_clk_clk_p(1'b0), .gt_ref_clk_clk_n(1'b1),
    .gt_gtx_p(gtx_p), .gt_gtx_n(gtx_n), .gt_grx_p(4'b0000), .gt_grx_n(4'b1111),
    .ctrl_clk(ctrl_clk), .ctrl_aresetn(ctrl_aresetn),
    .ts_clk(ts_clk), .ts_aresetn(ts_aresetn),
    .tx_clk(tx_clk), .mac_tx_aresetn(mac_tx_aresetn),
    .rx_clk(rx_clk), .mac_rx_aresetn(mac_rx_aresetn),
    .m_axis_mac_rx_tdata(rx_tdata), .m_axis_mac_rx_tkeep(rx_tkeep), .m_axis_mac_rx_tvalid(rx_tvalid),
    .m_axis_mac_rx_tready(1'b1), .m_axis_mac_rx_tlast(rx_tlast), .m_axis_mac_rx_tuser(rx_tuser),
    .s_axis_mac_tx_tdata(tx_tdata), .s_axis_mac_tx_tkeep(tx_tkeep), .s_axis_mac_tx_tvalid(tx_tvalid),
    .s_axis_mac_tx_tready(tx_tready), .s_axis_mac_tx_tlast(tx_tlast), .s_axis_mac_tx_tuser(tx_tuser),
    .s_axis_tx_ptp_tdata(ptp_tdata), .s_axis_tx_ptp_tvalid(ptp_tvalid), .s_axis_tx_ptp_tready(ptp_tready),
    .tx_ptp_tstamp_out(ts_out), .tx_ptp_tstamp_tag_out(ts_tag_out), .tx_ptp_tstamp_valid_out(ts_valid_out),
    .link_up(link_up),
    .s_axi_awaddr(sa_awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(sa_awvalid), .s_axi_awready(sa_awready),
    .s_axi_wdata(sa_wdata), .s_axi_wstrb(sa_wstrb), .s_axi_wvalid(sa_wvalid), .s_axi_wready(sa_wready),
    .s_axi_bresp(sa_bresp), .s_axi_bvalid(sa_bvalid), .s_axi_bready(sa_bready),
    .s_axi_araddr(sa_araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(sa_arvalid), .s_axi_arready(sa_arready),
    .s_axi_rdata(sa_rdata), .s_axi_rresp(sa_rresp), .s_axi_rvalid(sa_rvalid), .s_axi_rready(sa_rready)
);

// zircon_nic AXI-Lite (ui_clk)
logic [11:0] za_awaddr = '0, za_araddr = '0;
logic        za_awvalid = 1'b0, za_wvalid = 1'b0, za_arvalid = 1'b0;
logic [31:0] za_wdata = '0;
wire         za_awready, za_wready, za_bvalid, za_arready, za_rvalid;
wire  [1:0]  za_bresp, za_rresp;
wire  [31:0] za_rdata;

zircon_nic #(
    .GEN_EN(1),
    .CORE_HZ(20000)
) nic (
    .clk(core_clk), .aresetn(core_aresetn),
    .mac_rx_clk(rx_clk), .mac_rx_aresetn(mac_rx_aresetn),
    .s_axis_mac_rx_tdata(rx_tdata), .s_axis_mac_rx_tkeep(rx_tkeep),
    .s_axis_mac_rx_tvalid(rx_tvalid), .s_axis_mac_rx_tready(),
    .s_axis_mac_rx_tlast(rx_tlast), .s_axis_mac_rx_tuser(rx_tuser),
    .mac_rx_pack_stat(2'b00),
    .mac_tx_clk(tx_clk), .mac_tx_aresetn(mac_tx_aresetn),
    .m_axis_mac_tx_tdata(z_tx_tdata), .m_axis_mac_tx_tkeep(z_tx_tkeep),
    .m_axis_mac_tx_tvalid(z_tx_tvalid), .m_axis_mac_tx_tready(sel_nic && tx_tready),
    .m_axis_mac_tx_tlast(z_tx_tlast), .m_axis_mac_tx_tuser(z_tx_tuser),
    .m_axis_tx_ptp_tdata(z_ptp_tdata), .m_axis_tx_ptp_tvalid(z_ptp_tvalid),
    .m_axis_tx_ptp_tready(sel_nic && ptp_tready),
    .tx_ptp_tstamp_in(ts_out), .tx_ptp_tstamp_tag_in(ts_tag_out),
    .tx_ptp_tstamp_valid_in(sel_nic && ts_valid_out),
    .ui_clk(ui_clk), .ui_aresetn(ui_aresetn),
    .m_axis_raw_rx_tdata(), .m_axis_raw_rx_tkeep(), .m_axis_raw_rx_tvalid(),
    .m_axis_raw_rx_tready(1'b1), .m_axis_raw_rx_tlast(),
    .s_axis_raw_tx_tdata('0), .s_axis_raw_tx_tkeep('0), .s_axis_raw_tx_tvalid(1'b0),
    .s_axis_raw_tx_tready(), .s_axis_raw_tx_tlast(1'b0),
    .m_axis_sock_rx_tdata(), .m_axis_sock_rx_tkeep(), .m_axis_sock_rx_tvalid(),
    .m_axis_sock_rx_tready(1'b1), .m_axis_sock_rx_tlast(),
    .s_axis_sock_tx_tdata('0), .s_axis_sock_tx_tkeep('0), .s_axis_sock_tx_tvalid(1'b0),
    .s_axis_sock_tx_tready(), .s_axis_sock_tx_tlast(1'b0),
    .s_axi_awaddr(za_awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(za_awvalid),
    .s_axi_awready(za_awready), .s_axi_wdata(za_wdata), .s_axi_wstrb(4'hF),
    .s_axi_wvalid(za_wvalid), .s_axi_wready(za_wready), .s_axi_bresp(za_bresp),
    .s_axi_bvalid(za_bvalid), .s_axi_bready(1'b1), .s_axi_araddr(za_araddr),
    .s_axi_arprot(3'b000), .s_axi_arvalid(za_arvalid), .s_axi_arready(za_arready),
    .s_axi_rdata(za_rdata), .s_axi_rresp(za_rresp), .s_axi_rvalid(za_rvalid),
    .s_axi_rready(1'b1)
);

// ---------------------------------------------------------------------------
// CMAC model: GT user clocks and the wrapper's CMAC client interfaces (SIM = 1)
// ---------------------------------------------------------------------------
logic         m_tx_tready = 1'b1;
logic [511:0] m_rx_tdata = '0;
logic [63:0]  m_rx_tkeep = '0;
logic         m_rx_tvalid = 1'b0, m_rx_tlast = 1'b0;
logic [0:0]   m_rx_tuser = '0;

initial begin
    force `MAC.ch[0].ch_inst.gt.gt_inst.gt_txoutclk = gtx_clk;
    force `MAC.ch[1].ch_inst.gt.gt_inst.gt_txoutclk = gtx_clk;
    force `MAC.ch[2].ch_inst.gt.gt_inst.gt_txoutclk = gtx_clk;
    force `MAC.ch[3].ch_inst.gt.gt_inst.gt_txoutclk = gtx_clk;
    force `MAC.ch[0].ch_inst.gt.gt_inst.gt_rxoutclk = grx_clk;
    force `MAC.ch[1].ch_inst.gt.gt_inst.gt_rxoutclk = grx_clk;
    force `MAC.ch[2].ch_inst.gt.gt_inst.gt_rxoutclk = grx_clk;
    force `MAC.ch[3].ch_inst.gt.gt_inst.gt_rxoutclk = grx_clk;
    force `MAC.cmac.cmac_axis_tx.tready = m_tx_tready;
    force `MAC.cmac.cmac_axis_rx.tdata  = m_rx_tdata;
    force `MAC.cmac.cmac_axis_rx.tkeep  = m_rx_tkeep;
    force `MAC.cmac.cmac_axis_rx.tvalid = m_rx_tvalid;
    force `MAC.cmac.cmac_axis_rx.tlast  = m_rx_tlast;
    force `MAC.cmac.cmac_axis_rx.tuser  = m_rx_tuser;
end

wire [511:0] c_tx_tdata  = `MAC.cmac.cmac_axis_tx.tdata;
wire [63:0]  c_tx_tkeep  = `MAC.cmac.cmac_axis_tx.tkeep;
wire         c_tx_tvalid = `MAC.cmac.cmac_axis_tx.tvalid;
wire         c_tx_tlast  = `MAC.cmac.cmac_axis_tx.tlast;
wire [0:0]   c_tx_tuser  = `MAC.cmac.cmac_axis_tx.tuser;

// ---- TX side of the model ----
int     tx_ready_mode = 0;      // 0 always ready, 1 random 70 %, 2 100 Gb/s shaped
bit     loop_en = 1'b0;
real    loop_delay = 200.3;     // ns from the CMAC TX last beat to RX release
bytes_t cmac_tx_q[$];           // frames that left the wrapper (non-loop tests)
bit     cmac_tx_err_q[$];
int     cmac_tx_frames = 0;

typedef struct {
    bytes_t d;
    bit     err;
    real    rel;       // not before this time
    int     gaps;      // idle rx cycles inserted after every beat of the frame (0 none)
} rxf_t;

rxf_t rx_q[$];         // frames waiting to be driven on cmac_axis_rx
rxf_t rx_exp_q[$];     // frames expected on the shim's m_axis_mac_rx (in order)

initial begin
    bytes_t cur;
    real credit = 0.0;
    forever begin
        @(posedge gtx_clk);
        if (c_tx_tvalid && m_tx_tready) begin
            int nb = 0;
            for (int i = 0; i < 64; i++) begin
                if (c_tx_tkeep[i]) begin
                    cur.push_back(c_tx_tdata[i*8 +: 8]);
                    nb++;
                end
            end
            credit -= nb;
            if (c_tx_tlast) begin
                credit -= 20.0;      // preamble + IFG
                cmac_tx_frames++;
                if (loop_en) begin
                    rxf_t f;
                    f.d = cur;
                    f.err = c_tx_tuser[0];
                    f.rel = $realtime + loop_delay;
                    f.gaps = 0;
                    rx_q.push_back(f);
                end else begin
                    cmac_tx_q.push_back(cur);
                    cmac_tx_err_q.push_back(c_tx_tuser[0]);
                end
                cur = {};
            end
        end
        case (tx_ready_mode)
            0: m_tx_tready <= 1'b1;
            1: m_tx_tready <= ($urandom % 10) < 7;
            default: begin
                // 100 Gb/s: 12.5 GB/s / 322.2656 MHz = 38.79 bytes per tx_clk cycle
                credit += 38.79;
                if (credit > 128.0) credit = 128.0;
                m_tx_tready <= credit >= 64.0;
            end
        endcase
    end
end

// ---- RX side of the model ----
real rx_first_t_q[$];      // true time (rx_clk edge) the wrapper sampled each frame's first beat
bit  m_rx_sof = 1'b1;

initial begin
    rxf_t cur;
    int   pos = 0;
    bit   active = 0;
    int   gap = 0;
    forever begin
        @(posedge grx_clk);
        // monitor (pre-edge values = what the wrapper samples at this edge)
        if (m_rx_tvalid) begin
            if (m_rx_sof) rx_first_t_q.push_back($realtime);
            m_rx_sof = m_rx_tlast;
        end
        // driver
        if (gap > 0) begin
            gap--;
            m_rx_tvalid <= 1'b0;
            continue;
        end
        if (!active && rx_q.size() > 0 && rx_q[0].rel <= $realtime) begin
            cur = rx_q.pop_front();
            rx_exp_q.push_back(cur);
            pos = 0;
            active = 1;
        end
        if (active) begin
            logic [511:0] d = '0;
            logic [63:0]  k = '0;
            for (int i = 0; i < 64 && pos + i < cur.d.size(); i++) begin
                d[i*8 +: 8] = cur.d[pos + i];
                k[i] = 1'b1;
            end
            pos += 64;
            m_rx_tdata  <= d;
            m_rx_tkeep  <= k;
            m_rx_tvalid <= 1'b1;
            m_rx_tlast  <= pos >= cur.d.size();
            m_rx_tuser  <= (pos >= cur.d.size()) ? cur.err : 1'b0;
            if (pos >= cur.d.size()) active = 0;
            gap = cur.gaps;
        end else begin
            m_rx_tvalid <= 1'b0;
            m_rx_tlast  <= 1'b0;
            m_rx_tuser  <= '0;
        end
    end
end

// ---------------------------------------------------------------------------
// Timebase truth: tick value v appeared in the ts_clk counter at t_of(v)
// ---------------------------------------------------------------------------
real t_tick1 = -1.0;
longint unsigned tick_prev = 0;

always @(dut.core.tick_reg) begin
    if (dut.core.tick_reg == 1 && t_tick1 < 0) t_tick1 = $realtime;
    if (t_tick1 >= 0 && dut.core.tick_reg != tick_prev + 1 && dut.core.tick_reg != 0)
        err($sformatf("tick counter jumped %0d -> %0d", tick_prev, dut.core.tick_reg));
    tick_prev = dut.core.tick_reg;
end

function automatic real t_of(longint unsigned v);
    return t_tick1 + (real'(v) - 1.0) * 4.0;
endfunction

// ---------------------------------------------------------------------------
// ts_gray_sync monitors (test 108): lag = sample time - time the value appeared
// ---------------------------------------------------------------------------
real lag_min[3] = '{1.0e9, 1.0e9, 1.0e9};
real lag_max[3] = '{-1.0e9, -1.0e9, -1.0e9};
int  gray_errors = 0;
longint unsigned gprev[3] = '{0, 0, 0};
int  gsamples[3] = '{0, 0, 0};
bit  gcont[3] = '{0, 0, 0};      // previous cycle was sampled too (no reset gap)

task automatic gray_sample(int dom, longint unsigned v, int max_step);
    real lag;
    if (t_tick1 < 0 || v < 4) return;
    if (gcont[dom]) begin
        if (v < gprev[dom] || v - gprev[dom] > max_step) begin
            if (gray_errors < 10)
                $display("  ERROR [%0t] ts_gray_sync domain %0d: %0d -> %0d", $realtime, dom, gprev[dom], v);
            gray_errors++;
        end
    end
    gprev[dom] = v;
    gcont[dom] = 1;
    gsamples[dom]++;
    lag = $realtime - t_of(v);
    if (lag < lag_min[dom]) lag_min[dom] = lag;
    if (lag > lag_max[dom]) lag_max[dom] = lag;
endtask

// sampled while the domain's reset is released (a reset gap restarts the step check)
always @(posedge gtx_clk)  if (mac_tx_aresetn) gray_sample(0, dut.core.tick_tx, 1);   else gcont[0] = 0;
always @(posedge grx_clk)  if (mac_rx_aresetn) gray_sample(1, dut.core.tick_rx, 1);   else gcont[1] = 0;
always @(posedge ctrl_clk) if (ctrl_aresetn)   gray_sample(2, dut.core.tick_ctrl, 3); else gcont[2] = 0;

// ---------------------------------------------------------------------------
// RX checker on the shim output (rx_clk)
// ---------------------------------------------------------------------------
real rx_ev_lag_min = 1.0e9, rx_ev_lag_max = -1.0e9;
int  rx_frames_seen = 0;
logic [54:0] last_rx_ts = '0;
real last_rx_t = 0.0;
int  rx_seen_since = 0;          // frames since the last reset of this counter

initial begin
    bytes_t cur;
    logic [47:0] fts = '0;
    bit sof = 1;
    forever begin
        @(posedge grx_clk);
        if (rx_tvalid) begin
            if (sof) begin
                real t, lag;
                fts = rx_tuser[48:1];
                if (rx_first_t_q.size() == 0) begin
                    err("RX frame at the shim output without a model first beat");
                    t = $realtime;
                end else begin
                    t = rx_first_t_q.pop_front();
                end
                lag = t - t_of({fts, 7'b0} >> 10);
                if (lag < rx_ev_lag_min) rx_ev_lag_min = lag;
                if (lag > rx_ev_lag_max) rx_ev_lag_max = lag;
                last_rx_ts = {fts, 7'b0};
                last_rx_t = t;
            end else if (rx_tuser[48:1] != fts) begin
                err($sformatf("RX tuser[48:1] %h changed within the frame (first beat %h)", rx_tuser[48:1], fts));
            end
            if (!rx_tlast && rx_tuser[0]) err("RX tuser[0] set on a non-last beat");
            for (int i = 0; i < 64; i++) if (rx_tkeep[i]) cur.push_back(rx_tdata[i*8 +: 8]);
            sof = rx_tlast;
            if (rx_tlast) begin
                rxf_t e;
                if (rx_exp_q.size() == 0) begin
                    err("unexpected RX frame at the shim output");
                end else begin
                    e = rx_exp_q.pop_front();
                    if (!bytes_eq(e.d, cur)) err($sformatf("RX frame data mismatch (%0d bytes, expected %0d)", cur.size(), e.d.size()));
                    if (rx_tuser[0] != e.err) err($sformatf("RX error flag %0d, expected %0d", rx_tuser[0], e.err));
                end
                rx_frames_seen++;
                rx_seen_since++;
                cur = {};
            end
        end
        if (!mac_rx_aresetn) sof = 1;
    end
end

// ---------------------------------------------------------------------------
// TX checker at the shim input (tx_clk): records, SOF, timestamp returns
// ---------------------------------------------------------------------------
logic [23:0] rec_model_q[$];
int  tx_sof_count = 0, tx_ret_count = 0, tx_ret_expected = 0, tx_underruns = 0;
real tx_ev_lag_min = 1.0e9, tx_ev_lag_max = -1.0e9;
logic [54:0] last_tx_ts = '0;
real last_tx_t = 0.0;
real tx_sof_t_q[$];            // SOF handshake times of all frames (integration: echo replies)

initial begin
    bit   sof = 1;
    bit   pend = 0;
    logic [15:0] pend_tag = '0;
    real  pend_t = 0.0;
    forever begin
        @(posedge gtx_clk);
        // return expected from the previous edge
        if (pend) begin
            if (!ts_valid_out) begin
                err($sformatf("no TX timestamp one cycle after the SOF of tag %04x", pend_tag));
            end else begin
                real lag;
                if (ts_tag_out != pend_tag) err($sformatf("TX timestamp tag %04x, expected %04x", ts_tag_out, pend_tag));
                if (ts_out[9:0] != 0) err("TX timestamp bits [9:0] not zero");
                lag = pend_t - t_of(ts_out >> 10);
                if (lag < tx_ev_lag_min) tx_ev_lag_min = lag;
                if (lag > tx_ev_lag_max) tx_ev_lag_max = lag;
                last_tx_ts = ts_out;
                last_tx_t = pend_t;
                tx_ret_count++;
            end
            pend = 0;
        end else if (ts_valid_out) begin
            err($sformatf("unexpected TX timestamp (tag %04x)", ts_tag_out));
        end
        if (!mac_tx_aresetn) begin
            sof = 1;
            rec_model_q = {};
            continue;
        end
        if (ptp_tvalid && ptp_tready) rec_model_q.push_back(ptp_tdata);
        if (tx_tvalid && tx_tready) begin
            if (sof) begin
                tx_sof_count++;
                tx_sof_t_q.push_back($realtime);
                if (rec_model_q.size() == 0) begin
                    tx_underruns++;
                end else begin
                    logic [23:0] r = rec_model_q.pop_front();
                    if (r[1:0] == 2'b10) begin
                        pend = 1;
                        pend_tag = r[17:2];
                        pend_t = $realtime;
                        tx_ret_expected++;
                    end
                end
            end
            sof = tx_tlast;
        end
    end
end

// ---------------------------------------------------------------------------
// AXI-Lite masters
// ---------------------------------------------------------------------------
logic [1:0] last_resp;

task automatic shim_wr(input logic [18:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF,
                       input logic [1:0] exp_resp = 2'b00);
    @(posedge ctrl_clk);
    sa_awaddr <= a; sa_wdata <= d; sa_wstrb <= s;
    sa_awvalid <= 1'b1; sa_wvalid <= 1'b1;
    do @(posedge ctrl_clk); while (!(sa_awready && sa_wready));
    sa_awvalid <= 1'b0; sa_wvalid <= 1'b0;
    sa_bready <= 1'b1;
    do @(posedge ctrl_clk); while (!sa_bvalid);
    sa_bready <= 1'b0;
    last_resp = sa_bresp;
    if (sa_bresp != exp_resp) err($sformatf("shim write 0x%05x: BRESP %0d, expected %0d", a, sa_bresp, exp_resp));
endtask

task automatic shim_rd(input logic [18:0] a, output logic [31:0] d, input logic [1:0] exp_resp = 2'b00);
    @(posedge ctrl_clk);
    sa_araddr <= a;
    sa_arvalid <= 1'b1;
    do @(posedge ctrl_clk); while (!sa_arready);
    sa_arvalid <= 1'b0;
    sa_rready <= 1'b1;
    do @(posedge ctrl_clk); while (!sa_rvalid);
    sa_rready <= 1'b0;
    d = sa_rdata;
    last_resp = sa_rresp;
    if (sa_rresp != exp_resp) err($sformatf("shim read 0x%05x: RRESP %0d, expected %0d", a, sa_rresp, exp_resp));
endtask

task automatic shim_chk(input logic [18:0] a, input logic [31:0] e, input logic [31:0] m = 32'hFFFFFFFF);
    logic [31:0] d;
    shim_rd(a, d);
    if ((d & m) != (e & m)) err($sformatf("shim reg 0x%05x = %08x, expected %08x (mask %08x)", a, d, e, m));
endtask

task automatic nic_wr(input logic [11:0] a, input logic [31:0] d);
    @(posedge ui_clk);
    za_awaddr <= a; za_wdata <= d;
    za_awvalid <= 1'b1; za_wvalid <= 1'b1;
    do @(posedge ui_clk); while (!(za_awready && za_wready));
    za_awvalid <= 1'b0; za_wvalid <= 1'b0;
    while (!za_bvalid) @(posedge ui_clk);
    if (za_bresp != 2'b00) err($sformatf("nic write 0x%03x: BRESP %0d", a, za_bresp));
endtask

task automatic nic_rd(input logic [11:0] a, output logic [31:0] d);
    @(posedge ui_clk);
    za_araddr <= a;
    za_arvalid <= 1'b1;
    do @(posedge ui_clk); while (!za_arready);
    za_arvalid <= 1'b0;
    do @(posedge ui_clk); while (!za_rvalid);
    d = za_rdata;
    if (za_rresp != 2'b00) err($sformatf("nic read 0x%03x: RRESP %0d", a, za_rresp));
endtask

task automatic nic_chk(input logic [11:0] a, input logic [31:0] e, input logic [31:0] m = 32'hFFFFFFFF);
    logic [31:0] d;
    nic_rd(a, d);
    if ((d & m) != (e & m)) err($sformatf("nic reg 0x%03x = %08x, expected %08x", a, d, e));
endtask

task automatic shim_wait(input logic [18:0] a, input logic [31:0] e, input logic [31:0] m, input real tmo_ns);
    logic [31:0] d;
    real t0 = $realtime;
    do begin
        shim_rd(a, d);
        if ((d & m) == (e & m)) return;
    end while ($realtime - t0 < tmo_ns);
    err($sformatf("timeout waiting for shim reg 0x%05x & %08x == %08x (last %08x)", a, m, e, d));
endtask

task automatic nic_wait(input logic [11:0] a, input logic [31:0] e, input logic [31:0] m, input real tmo_ns);
    logic [31:0] d;
    real t0 = $realtime;
    do begin
        nic_rd(a, d);
        if ((d & m) == (e & m)) return;
    end while ($realtime - t0 < tmo_ns);
    err($sformatf("timeout waiting for nic reg 0x%03x & %08x == %08x (last %08x)", a, m, e, d));
endtask

// ---------------------------------------------------------------------------
// TB TX drivers (sel_nic = 0); called right after a posedge of tx_clk
// ---------------------------------------------------------------------------
task automatic drive_rec(input logic [23:0] r);
    tb_ptp_tdata <= r;
    tb_ptp_tvalid <= 1'b1;
    do @(posedge gtx_clk); while (!(tb_ptp_tvalid && ptp_tready));
    tb_ptp_tvalid <= 1'b0;
endtask

task automatic drive_data(input bytes_t f);
    int pos = 0;
    while (pos < f.size()) begin
        logic [511:0] d = '0;
        logic [63:0]  k = '0;
        for (int i = 0; i < 64 && pos + i < f.size(); i++) begin
            d[i*8 +: 8] = f[pos + i];
            k[i] = 1'b1;
        end
        pos += 64;
        tb_tx_tdata <= d;
        tb_tx_tkeep <= k;
        tb_tx_tlast <= pos >= f.size();
        tb_tx_tvalid <= 1'b1;
        do @(posedge gtx_clk); while (!(tb_tx_tvalid && tx_tready));
    end
    tb_tx_tvalid <= 1'b0;
    tb_tx_tlast <= 1'b0;
endtask

// rec_mode: 0 record first (queued), 1 record in the SOF cycle, 2 no record
task automatic send_frame(input bytes_t f, input int rec_mode, input logic [1:0] op, input logic [15:0] tag);
    logic [23:0] r = {6'd0, tag, op};
    @(posedge gtx_clk);
    case (rec_mode)
        0: begin drive_rec(r); drive_data(f); end
        1: fork drive_rec(r); drive_data(f); join
        default: drive_data(f);
    endcase
endtask

function automatic bytes_t rand_frame(int len, int seed);
    bytes_t f;
    int s = seed;
    for (int i = 0; i < len; i++) f.push_back(8'($urandom(s + i * 7919)));
    return f;
endfunction

task automatic wait_tx_idle(input real tmo_ns);
    real t0 = $realtime;
    while ($realtime - t0 < tmo_ns && (rx_q.size() > 0 || m_rx_tvalid || tb_tx_tvalid)) @(posedge ui_clk);
    repeat (40) @(posedge ui_clk);
endtask

// ---------------------------------------------------------------------------
// Frame builders for the zircon_nic tests
// ---------------------------------------------------------------------------
localparam logic [47:0] LOCAL_MAC = 48'h020a355a4901;
localparam logic [31:0] LOCAL_IP  = 32'hC0A80A02;
localparam logic [47:0] HOST_MAC  = 48'h3cfdfea1b2c3;
localparam logic [31:0] HOST_IP   = 32'hC0A80A01;

function automatic bytes_t udp_frame(logic [15:0] sport, logic [15:0] dport, int plen, int seed);
    bytes_t f;
    bytes_t pl;
    int ulen = 8 + plen, ilen = 20 + ulen;
    logic [31:0] s;
    for (int i = 0; i < plen; i++) pl.push_back(8'((seed * 31 + i * 17) ^ (i >> 3)));
    for (int i = 5; i >= 0; i--) f.push_back(LOCAL_MAC[i*8 +: 8]);
    for (int i = 5; i >= 0; i--) f.push_back(HOST_MAC[i*8 +: 8]);
    f.push_back(8'h08); f.push_back(8'h00);
    // IPv4 header
    f.push_back(8'h45); f.push_back(8'h00); f.push_back(8'(ilen >> 8)); f.push_back(8'(ilen));
    f.push_back(8'(seed >> 8)); f.push_back(8'(seed)); f.push_back(8'h40); f.push_back(8'h00);
    f.push_back(8'd64); f.push_back(8'd17); f.push_back(8'h00); f.push_back(8'h00);
    for (int i = 3; i >= 0; i--) f.push_back(HOST_IP[i*8 +: 8]);
    for (int i = 3; i >= 0; i--) f.push_back(LOCAL_IP[i*8 +: 8]);
    s = 0;
    for (int i = 14; i < 34; i += 2) s += {f[i], f[i+1]};
    while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
    f[24] = 8'(~s >> 8); f[25] = 8'(~s);
    // UDP
    f.push_back(8'(sport >> 8)); f.push_back(8'(sport));
    f.push_back(8'(dport >> 8)); f.push_back(8'(dport));
    f.push_back(8'(ulen >> 8)); f.push_back(8'(ulen));
    f.push_back(8'h00); f.push_back(8'h00);
    foreach (pl[i]) f.push_back(pl[i]);
    s = HOST_IP[31:16] + HOST_IP[15:0] + LOCAL_IP[31:16] + LOCAL_IP[15:0] + 17 + ulen;
    for (int i = 34; i < f.size(); i += 2) s += {f[i], (i + 1 < f.size()) ? f[i+1] : 8'h00};
    while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
    s = ~s & 16'hFFFF;
    if (s == 0) s = 16'hFFFF;
    f[40] = 8'(s >> 8); f[41] = 8'(s);
    while (f.size() < 60) f.push_back(8'h00);
    return f;
endfunction

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
localparam logic [18:0] R_ID = 19'h00000, R_VERSION = 19'h00004, R_CTRL = 19'h00008, R_STATUS = 19'h0000C,
    R_STICKY = 19'h00010, R_TS_LO = 19'h00020, R_TS_HI = 19'h00024, R_TS_INCR = 19'h00028,
    R_RX_GOOD = 19'h00030, R_RX_BAD_FCS = 19'h00034, R_RX_ERR = 19'h00038, R_TX_GOOD = 19'h0003C,
    R_TX_FRAMES = 19'h00040, R_TX_TS_RET = 19'h00044, R_TX_KHZ = 19'h00048, R_RX_KHZ = 19'h0004C;

initial begin
    logic [31:0] d, d2, lo1, hi1, lo2, hi2;
    logic [31:0] c_rx_good, c_rx_err, c_tx_frames, c_tx_ret, c_tx_good;
    int n_err_frames;
    real t_a, t_b;

    #100;
    ctrl_aresetn = 1'b1;
    ts_aresetn = 1'b1;
    core_aresetn = 1'b1;
    ui_aresetn = 1'b1;
    repeat (20) @(posedge ctrl_clk);

    // ======================================================================
    // 101 registers and XCVR_RST
    // ======================================================================
    shim_chk(R_ID, 32'h434D4143);
    shim_chk(R_VERSION, 32'h00010000);
    shim_chk(R_CTRL, 32'h00000031);
    shim_chk(R_TS_INCR, 32'd1024);
    shim_chk(R_STICKY, 32'h0);
    shim_chk(19'h00100, 32'h0);                 // undefined offset reads 0
    shim_chk(R_STATUS, 32'h38, 32'h3F);          // GTPOWERGOOD, RX_RST_OUT, TX_RST_OUT; no RX_STATUS
    if (mac_tx_aresetn !== 1'b0 || mac_rx_aresetn !== 1'b0) err("mac_*_aresetn not low while XCVR_RST");
    shim_rd(19'h41014, d, 2'b10);                // GT APB while XCVR_RST: SLVERR
    if (d !== 32'h0) err($sformatf("GT APB read during XCVR_RST returned %08x", d));
    shim_wr(19'h41014, 32'h0, 4'hF, 2'b10);
    shim_wr(R_CTRL, 32'h30);                     // release XCVR_RST
    shim_wait(R_STATUS, 32'h01, 32'h19, 20000.0); // RX_STATUS, no TX/RX_RST_OUT
    repeat (20) @(posedge ctrl_clk);
    if (mac_tx_aresetn !== 1'b1 || mac_rx_aresetn !== 1'b1) err("mac_*_aresetn not high after release");
    if (link_up !== 1'b1) err("link_up low after release");
    shim_chk(R_STATUS, 32'h23, 32'h3F);          // RX_STATUS, BLOCK_LOCK (SIM), GTPOWERGOOD
    finish_test(101, "registers_and_xcvr_reset");

    // ======================================================================
    // 102 APB round trip (lane n at 0x4_0000 + n * 0x1_0000)
    // ======================================================================
    shim_chk(19'h51010, 32'h0010_0000);          // lane 1: 0x1012 TXDIFFCTRL 16 | 0x1010 polarity 0
    shim_chk(19'h51014, 32'h0000_0040);          // lane 1: 0x1016 precursor 0 | 0x1014 maincursor 64
    shim_wr(19'h51014, 32'hAAAA_0033, 4'h3);     // 16-bit write of 0x1014 only
    shim_chk(19'h51014, 32'h0000_0033);
    shim_wr(19'h51016, 32'h0005_5555, 4'hC);     // 16-bit write of 0x1016 only
    shim_chk(19'h51014, 32'h0005_0033);
    shim_rd(19'h51016, d);                       // 16-bit read of the upper half
    if (d[31:16] != 16'h0005) err($sformatf("16-bit read of 0x1016 = %04x", d[31:16]));
    shim_wr(19'h51014, 32'h0003_0040);           // 32-bit write, both halves
    shim_chk(19'h51014, 32'h0003_0040);
    shim_chk(19'h61014, 32'h0000_0040);          // lane 2 untouched
    shim_chk(19'h41014, 32'h0000_0040);          // lane 0 untouched
    shim_wr(19'h72004, 32'h0000_0002, 4'h3);     // lane 3 RX loopback
    shim_chk(19'h72004, 32'h0000_0002, 32'h0000_0007);
    shim_wr(19'h72004, 32'h0000_0000, 4'h3);
    shim_chk(19'h72000, 32'h0000_0E00, 32'h0000_0E00);   // lane 3 RX reset-done bits 9..11
    shim_chk(R_ID, 32'h434D4143);                // local registers not aliased by the APB space
    finish_test(102, "apb_round_trip");

    // ======================================================================
    // 103 TS_NOW and the clock measurement
    // ======================================================================
    shim_rd(R_TS_LO, lo1); shim_rd(R_TS_HI, hi1);
    t_a = $realtime;
    #2000;
    shim_rd(R_TS_LO, lo2); shim_rd(R_TS_HI, hi2);
    t_b = $realtime;
    begin
        longint unsigned a = {hi1, lo1}, b = {hi2, lo2};
        real dns = real'(b - a) / 256.0;
        if (b <= a) err("TS_NOW did not advance");
        if (dns < (t_b - t_a) - 20.0 || dns > (t_b - t_a) + 20.0)
            err($sformatf("TS_NOW advanced %0.1f ns in %0.1f ns", dns, t_b - t_a));
        if (a[9:0] != 0) err("TS_NOW bits [9:0] not zero");
    end
    #25000;    // two 10 us windows (SIM)
    shim_rd(R_TX_KHZ, d);
    if (d < 32'd320000 || d > 32'd324500) err($sformatf("TX_CLK_KHZ %0d (model 322266)", d));
    else $display("  TX_CLK_KHZ %0d (model %0.0f)", d, 1.0e6 / (2.0 * tx_half));
    shim_rd(R_RX_KHZ, d);
    if (d < 32'd320000 || d > 32'd324500) err($sformatf("RX_CLK_KHZ %0d (model 322451)", d));
    else $display("  RX_CLK_KHZ %0d (model %0.0f)", d, 1.0e6 / (2.0 * rx_half));
    shim_chk(R_STATUS, 32'hE3, 32'hFF);          // + TX_CLK_ALIVE, RX_CLK_ALIVE
    finish_test(103, "ts_now_and_clk_khz");

    // ======================================================================
    // 104 RX timestamp on every beat
    // ======================================================================
    shim_rd(R_RX_GOOD, c_rx_good);
    shim_rd(R_RX_ERR, c_rx_err);
    rx_seen_since = 0;
    n_err_frames = 0;
    for (int i = 0; i < 60; i++) begin
        rxf_t f;
        int len = (i % 3 == 0) ? 60 + (i * 37) % 64 : 60 + ($urandom(i) % 2500);
        f.d = rand_frame(len, 1000 + i);
        f.err = (i % 7 == 3);
        f.rel = 0.0;
        f.gaps = (i % 5 == 1) ? 1 + i % 3 : 0;
        if (f.err) n_err_frames++;
        rx_q.push_back(f);
    end
    begin
        real t0 = $realtime;
        while ((rx_q.size() > 0 || rx_exp_q.size() > 0) && $realtime - t0 < 100000.0) @(posedge ui_clk);
    end
    repeat (50) @(posedge ctrl_clk);
    if (rx_seen_since != 60) err($sformatf("%0d of 60 RX frames seen", rx_seen_since));
    shim_rd(R_RX_GOOD, d);
    if (d - c_rx_good != 60 - n_err_frames) err($sformatf("RX_GOOD_PKTS +%0d, expected +%0d", d - c_rx_good, 60 - n_err_frames));
    shim_rd(R_RX_ERR, d);
    if (d - c_rx_err != n_err_frames) err($sformatf("RX_ERR_FRAMES +%0d, expected +%0d", d - c_rx_err, n_err_frames));
    shim_chk(R_RX_BAD_FCS, 32'h0);
    $display("  RX event lag %0.2f .. %0.2f ns (spread %0.2f)", rx_ev_lag_min, rx_ev_lag_max, rx_ev_lag_max - rx_ev_lag_min);
    if (rx_ev_lag_max - rx_ev_lag_min > 8.0) err("RX timestamp lag spread > 8 ns");
    finish_test(104, "rx_timestamp");

    // ======================================================================
    // 105 TX tag return
    // ======================================================================
    shim_rd(R_TX_FRAMES, c_tx_frames);
    shim_rd(R_TX_TS_RET, c_tx_ret);
    shim_rd(R_TX_GOOD, c_tx_good);
    tx_ready_mode = 1;
    begin
        int ret0 = tx_ret_count, exp0 = tx_ret_expected, sof0 = tx_sof_count, und0 = tx_underruns;
        int n_op2 = 0;
        // (a) one frame at a time, record queued first / in the SOF cycle; op 2 and op 0
        for (int i = 0; i < 40; i++) begin
            logic [1:0] op = (i % 4 == 2) ? 2'b00 : 2'b10;
            if (op == 2'b10) n_op2++;
            send_frame(rand_frame(40 + (i * 97) % 1600, 2000 + i), i % 2, op, 16'h1000 + i);
        end
        // (b) several records ahead of their frames
        @(posedge gtx_clk);
        for (int i = 0; i < 12; i++) drive_rec({6'd0, 16'h2000 + 16'(i), (i % 3 == 1) ? 2'b00 : 2'b10});
        for (int i = 0; i < 12; i++) begin
            if (i % 3 != 1) n_op2++;
            drive_data(rand_frame(64 * (1 + i % 4), 3000 + i));
        end
        // (c) back-to-back frames, record in each SOF cycle
        for (int i = 0; i < 20; i++) begin
            n_op2++;
            fork
                drive_rec({6'd0, 16'h3000 + 16'(i), 2'b10});
                drive_data(rand_frame(60 + i * 13, 4000 + i));
            join
        end
        repeat (20) @(posedge gtx_clk);
        if (tx_ret_count - ret0 != n_op2) err($sformatf("%0d timestamps returned, expected %0d", tx_ret_count - ret0, n_op2));
        if (tx_ret_expected - exp0 != n_op2) err($sformatf("model expected %0d, plan %0d", tx_ret_expected - exp0, n_op2));
        if (tx_underruns != und0) err("unexpected PTP underrun");
        repeat (50) @(posedge ctrl_clk);
        shim_rd(R_TX_FRAMES, d);
        if (d - c_tx_frames != 72) err($sformatf("TX_FRAMES +%0d, expected +72", d - c_tx_frames));
        shim_rd(R_TX_TS_RET, d);
        if (d - c_tx_ret != n_op2) err($sformatf("TX_TS_RET +%0d, expected +%0d", d - c_tx_ret, n_op2));
        shim_rd(R_TX_GOOD, d);
        if (d - c_tx_good != 72) err($sformatf("TX_GOOD_PKTS +%0d, expected +72", d - c_tx_good));
        shim_chk(R_STICKY, 32'h0);
        if (cmac_tx_q.size() != 72) err($sformatf("%0d frames at the CMAC model, expected 72", cmac_tx_q.size()));
        foreach (cmac_tx_err_q[i]) if (cmac_tx_err_q[i]) err("CMAC model saw a frame with tuser error (underflow)");
        cmac_tx_q = {};
        cmac_tx_err_q = {};
    end
    $display("  TX event lag %0.2f .. %0.2f ns (spread %0.2f)", tx_ev_lag_min, tx_ev_lag_max, tx_ev_lag_max - tx_ev_lag_min);
    if (tx_ev_lag_max - tx_ev_lag_min > 8.0) err("TX timestamp lag spread > 8 ns");
    tx_ready_mode = 0;
    finish_test(105, "tx_tag_return");

    // ======================================================================
    // 106 PTP underrun
    // ======================================================================
    begin
        int und0 = tx_underruns, ret0 = tx_ret_count;
        bytes_t f = rand_frame(300, 5000);
        send_frame(f, 2, 2'b00, 16'h0);
        repeat (20) @(posedge gtx_clk);
        if (tx_underruns - und0 != 1) err("model did not see the underrun");
        if (tx_ret_count != ret0) err("timestamp returned for an untagged frame");
        repeat (20) @(posedge ctrl_clk);
        shim_chk(R_STICKY, 32'h2);
        shim_wr(R_STICKY, 32'h2);
        shim_chk(R_STICKY, 32'h0);
        if (cmac_tx_q.size() != 1) err("underrun frame missing at the CMAC model");
        else begin
            bytes_t g = cmac_tx_q[0];
            if (!bytes_eq(g, f)) err("underrun frame data mismatch");
        end
        cmac_tx_q = {};
        cmac_tx_err_q = {};
        // the next frame with a record is tagged normally
        send_frame(rand_frame(200, 5001), 0, 2'b10, 16'h4444);
        repeat (20) @(posedge gtx_clk);
        if (tx_ret_count != ret0 + 1) err("frame after the underrun not tagged");
        cmac_tx_q = {};
        cmac_tx_err_q = {};
    end
    finish_test(106, "ptp_underrun");

    // ======================================================================
    // 107 TX -> RX loop, delta vs true delay
    // ======================================================================
    begin
        real err_min = 1.0e9, err_max = -1.0e9;
        loop_en = 1;
        for (int ph = 0; ph < 3; ph++) begin
            if (ph == 1) rx_half = 1.54995;    // 3.0999 ns
            if (ph == 2) rx_half = 1.55255;    // 3.1051 ns
            repeat (7 + ph * 3) @(posedge ts_clk);
            for (int i = 0; i < 40; i++) begin
                int seen0 = rx_frames_seen, ret0 = tx_ret_count;
                real rep, tru, e;
                loop_delay = 150.0 + 13.7 * i + 0.37 * ph;
                send_frame(rand_frame(60 + (i * 211) % 3000, 6000 + 100 * ph + i), i % 2, 2'b10, 16'h5000 + 16'(ph * 64 + i));
                begin
                    real t0 = $realtime;
                    while ((rx_frames_seen == seen0 || tx_ret_count == ret0) && $realtime - t0 < 20000.0) @(posedge grx_clk);
                end
                if (rx_frames_seen == seen0 || tx_ret_count == ret0) begin
                    err("loop frame or its timestamp missing");
                    continue;
                end
                rep = real'(last_rx_ts - last_tx_ts) / 256.0;
                tru = last_rx_t - last_tx_t;
                e = rep - tru;
                if (e < err_min) err_min = e;
                if (e > err_max) err_max = e;
                if (e > 8.0 || e < -8.0) err($sformatf("loop delta %0.2f ns, true %0.2f ns", rep, tru));
            end
        end
        loop_en = 0;
        rx_half = 1.5506;
        $display("  loop delta error %0.2f .. %0.2f ns", err_min, err_max);
    end
    finish_test(107, "loop_delta");

    // ======================================================================
    // 109 RX / TX reset from CTRL
    // ======================================================================
    shim_wr(R_STICKY, 32'h7);
    shim_wr(R_CTRL, 32'h32);                     // RX_RST
    repeat (40) @(posedge ctrl_clk);
    if (mac_rx_aresetn !== 1'b0) err("mac_rx_aresetn not low with CTRL.RX_RST");
    if (mac_tx_aresetn !== 1'b1) err("mac_tx_aresetn low with CTRL.RX_RST only");
    shim_chk(R_STICKY, 32'h1, 32'h1);            // LINK_LOST
    shim_wr(R_CTRL, 32'h34);                     // TX_RST, RX released
    repeat (40) @(posedge ctrl_clk);
    if (mac_tx_aresetn !== 1'b0) err("mac_tx_aresetn not low with CTRL.TX_RST");
    shim_wr(R_CTRL, 32'h30);
    shim_wait(R_STATUS, 32'h01, 32'h19, 20000.0);
    repeat (20) @(posedge ctrl_clk);
    if (mac_tx_aresetn !== 1'b1 || mac_rx_aresetn !== 1'b1) err("mac_*_aresetn not high after the CTRL resets");
    shim_wr(R_STICKY, 32'h7);
    shim_chk(R_STICKY, 32'h0);
    // traffic still flows after the resets
    begin
        int ret0 = tx_ret_count;
        send_frame(rand_frame(500, 7000), 0, 2'b10, 16'h7777);
        repeat (20) @(posedge gtx_clk);
        if (tx_ret_count != ret0 + 1) err("no timestamp after the CTRL resets");
        cmac_tx_q = {};
        cmac_tx_err_q = {};
    end
    finish_test(109, "rx_tx_reset");

    // ======================================================================
    // 110 zircon_nic + shim: generator -> checker through the looped CMAC model
    // ======================================================================
    begin
        logic [31:0] f0, r0, s0;
        int und0 = tx_underruns;
        shim_rd(R_TX_FRAMES, f0);
        shim_rd(R_TX_TS_RET, r0);
        repeat (10) @(posedge gtx_clk);
        sel_nic = 1;
        tx_ready_mode = 2;
        loop_en = 1;
        loop_delay = 300.0;
        nic_chk(12'h000, 32'h5A495243);
        nic_wr(12'h010, 32'h5A350A02);           // MAC_LO 02:0a:35:5a
        nic_wr(12'h014, 32'h00000149);           // MAC_HI 49:01
        nic_wr(12'h018, LOCAL_IP);
        nic_wr(12'h01C, 32'd7);
        nic_wr(12'h034, 32'd64);
        nic_wr(12'h008, 32'h8000000F);           // RX|TX|ECHO|SOCK + STAT_CLR
        #1000;
        nic_wr(12'h00C, 32'h3F);
        nic_wr(12'h090, 32'h0);                  // GEN_CTRL
        nic_wr(12'h0A0, 32'h5A350A02);           // GEN_DST_MAC = own MAC
        nic_wr(12'h0A4, 32'h00000149);
        nic_wr(12'h0A8, LOCAL_IP);
        nic_wr(12'h0AC, 32'd5001);               // CHK_PORT
        nic_wr(12'h0B0, 32'd5002);
        nic_wr(12'h094, 32'd1472);
        nic_wr(12'h098, 32'd200);
        nic_wr(12'h09C, 32'd0);
        nic_wr(12'h090, 32'h4);                  // GEN CLR
        nic_wr(12'h0C0, 32'h5);                  // CHK EN | CLR
        #500;
        nic_wr(12'h090, 32'h1);                  // GEN EN
        nic_wait(12'h0C8, 32'd200, 32'hFFFFFFFF, 400000.0);
        #3000;
        nic_chk(12'h0B4, 32'd200);               // GEN_TX_PKTS
        nic_chk(12'h0B8, 32'd200 * 1472);
        nic_chk(12'h0CC, 32'd200 * 1472);        // CHK_RX_BYTES_LO
        nic_chk(12'h0D4, 32'd0);                 // CHK_SEQ_ERR
        nic_chk(12'h0D8, 32'd0);                 // CHK_BIT_ERR
        nic_chk(12'h0E0, 32'd0);                 // CHK_LEN_ERR
        nic_chk(12'h040, 32'd200);               // RX_FRAMES
        nic_chk(12'h04C, 32'd0);                 // RX_BAD_FRAME
        nic_chk(12'h050, 32'd0);                 // RX_FIFO_DROP
        nic_chk(12'h068, 32'd200);               // TX_FRAMES
        nic_chk(12'h00C, 32'h0);                 // STATUS
        nic_chk(12'h0C0, 32'h80000001);          // CHK EN | SYNC
        repeat (50) @(posedge ctrl_clk);
        shim_rd(R_TX_FRAMES, d);
        if (d - f0 != 200) err($sformatf("shim TX_FRAMES +%0d, expected +200", d - f0));
        shim_rd(R_TX_TS_RET, d);
        if (d != r0) err("shim returned timestamps for generator frames");
        shim_chk(R_STICKY, 32'h0);               // no PTP underrun / record overflow
        if (tx_underruns != und0) err("model saw a PTP underrun");
        $display("  gen->chk: 200 x 1472 B, tx_clk %0.4f ns, rx_clk %0.4f ns, CMAC TX shaped to 100 Gb/s",
                 2.0 * tx_half, 2.0 * rx_half);
    end
    finish_test(110, "nic_gen_to_chk");

    // ======================================================================
    // 111 zircon_nic echo latency with the shim's timestamps
    // ======================================================================
    begin
        real tru_min = 1.0e9, tru_max = -1.0e9;
        logic [31:0] cnt, mn, mx, st;
        loop_en = 0;
        tx_ready_mode = 0;
        nic_wr(12'h100, 32'h7);                  // LAT EN | CLR0 | CLR1
        nic_wait(12'h100, 32'h0, 32'h80000008, 20000.0);
        nic_wr(12'h104, 32'h7);
        tx_sof_t_q = {};
        for (int i = 0; i < 20; i++) begin
            rxf_t f;
            real t_req, t_rep;
            int sof0 = tx_sof_count, ret0 = tx_ret_count;
            f.d = udp_frame(16'd40000 + 16'(i), 16'd7, 18 + i * 71, i);
            f.err = 0;
            f.rel = 0.0;
            f.gaps = 0;
            rx_q.push_back(f);
            begin
                real t0 = $realtime;
                while ((tx_sof_count == sof0 || tx_ret_count == ret0) && $realtime - t0 < 50000.0) @(posedge gtx_clk);
            end
            if (tx_sof_count == sof0 || tx_ret_count == ret0) begin
                err($sformatf("echo %0d: no reply / timestamp", i));
                continue;
            end
            t_req = last_rx_t;
            t_rep = last_tx_t;
            if (t_rep - t_req < tru_min) tru_min = t_rep - t_req;
            if (t_rep - t_req > tru_max) tru_max = t_rep - t_req;
            repeat (10) @(posedge gtx_clk);
        end
        cmac_tx_q = {};
        cmac_tx_err_q = {};
        #2000;
        nic_wr(12'h100, 32'h9);                  // EN | SNAP
        nic_wait(12'h100, 32'h0, 32'h80000008, 20000.0);
        nic_rd(12'h200, cnt);
        nic_rd(12'h218, mn);
        nic_rd(12'h21C, mx);
        nic_rd(12'h104, st);
        $display("  echo latency: COUNT %0d, MIN %0d ns, MAX %0d ns; true %0.2f .. %0.2f ns", cnt, mn, mx, tru_min, tru_max);
        if (cnt != 20) err($sformatf("bank 0 COUNT %0d, expected 20", cnt));
        if (real'(mn) < tru_min - 8.0 || real'(mn) > tru_min + 8.0) err("bank 0 MIN not within 8 ns of the true minimum");
        if (real'(mx) < tru_max - 8.0 || real'(mx) > tru_max + 8.0) err("bank 0 MAX not within 8 ns of the true maximum");
        if (st != 0) err($sformatf("LAT_STATUS %08x", st));
        nic_chk(12'h060, 32'd20);                // RX_ECHO
        shim_chk(R_STICKY, 32'h0);
    end
    finish_test(111, "nic_echo_latency");

    // ======================================================================
    // 108 ts_gray_sync over the whole run
    // ======================================================================
    begin
        string nm[3] = '{"tx_clk", "rx_clk", "ctrl_clk"};
        for (int k = 0; k < 3; k++) begin
            $display("  ts_gray_sync %s: %0d samples, lag %0.2f .. %0.2f ns (spread %0.2f)",
                     nm[k], gsamples[k], lag_min[k], lag_max[k], lag_max[k] - lag_min[k]);
            if (gsamples[k] < 1000) err($sformatf("too few gray samples in %s", nm[k]));
            if (lag_max[k] - lag_min[k] > 8.0) err($sformatf("%s lag spread > 8 ns", nm[k]));
        end
        if ((lag_max[0] > lag_max[1] ? lag_max[0] : lag_max[1]) - (lag_min[0] < lag_min[1] ? lag_min[0] : lag_min[1]) > 8.0)
            err("tx/rx combined lag spread > 8 ns");
        if (gray_errors != 0) err($sformatf("%0d monotonicity / step errors", gray_errors));
    end
    finish_test(108, "gray_sync");

    $display("SUMMARY: %0d passed, %0d failed", total_pass, total_fail);
    if (total_fail == 0) $display("ALL TESTS PASSED");
    else $display("TESTS FAILED");
    $finish;
end

initial begin
    #3000000;
    $display("TESTS FAILED: global timeout");
    $finish;
end

endmodule

`resetall

// SPDX-License-Identifier: MIT
//
// tb_zircon_nic - xsim testbench of the zircon_nic block-design shell.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// Drives the MAC RX stream (512 b, 390.625 MHz), the UI0/UI2 TX streams and the
// AXI-Lite port (100 MHz), sinks MAC TX / UI0 RX / UI2 RX, and executes the command
// script written by gen_vectors.py (see that file for the command set). Every
// received frame is compared byte-exactly with the next expected frame of its
// port. Prints "PASS: test <n> <name>" / "FAIL: ..." per test and
// "ALL TESTS PASSED" / "TESTS FAILED" at the end.
//
// 1.3.0 latency measurement: an MRMAC PTP model - a free-running 55-bit timer
// (2^-8 ns units, +1024 per 4 ns ts_clk cycle); the MAC RX driver puts the timer
// value at each frame's first beat on tuser[48:1] (bits 54:7); the MAC TX monitor
// pops one m_axis_tx_ptp record per frame at its first beat (it must already be
// there), and for op = 2 returns the timer value at that SOF with the tag after a
// PTPDELAY-cycle delay. Expected latency samples are paired with tagged frames
// by the UDP ports in frame bytes 34..37 and accumulated into a per-bank model
// that LATCHK compares exactly with a register snapshot.
//
// Plusargs: +vectors=<file> (default vectors.txt)
// Parameters (xelab -generic_top): GEN_EN (generator / checker built, default 1),
// CORE_HZ (rate-meter window in core cycles, shortened to 20000 = 66.7 us here).

`timescale 1ns / 1ps
`default_nettype none

module tb_zircon_nic #(
    parameter int GEN_EN  = 1,
    parameter int CORE_HZ = 20000
);

localparam int DATA_W = 512;
localparam int KEEP_W = 64;

// ---------------------------------------------------------------------------
// Clocks and resets
// ---------------------------------------------------------------------------
logic clk = 1'b0, mac_rx_clk = 1'b0, mac_tx_clk = 1'b0, ui_clk = 1'b0;
logic aresetn = 1'b0, mac_rx_aresetn = 1'b0, mac_tx_aresetn = 1'b0, ui_aresetn = 1'b0;

always #1.6667 clk = ~clk;          // 300 MHz core
always #1.28   mac_rx_clk = ~mac_rx_clk;   // 390.625 MHz
always #1.28   mac_tx_clk = ~mac_tx_clk;
always #5.0    ui_clk = ~ui_clk;    // 100 MHz

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
logic [DATA_W-1:0] mac_rx_tdata = '0;
logic [KEEP_W-1:0] mac_rx_tkeep = '0;
logic              mac_rx_tvalid = 1'b0, mac_rx_tlast = 1'b0;
logic [48:0]       mac_rx_tuser = '0;
logic [1:0]        pack_stat = '0;
wire               mac_rx_tready;

wire  [DATA_W-1:0] mac_tx_tdata;
wire  [KEEP_W-1:0] mac_tx_tkeep;
wire               mac_tx_tvalid, mac_tx_tlast;
wire  [0:0]        mac_tx_tuser;
logic              mac_tx_tready = 1'b1;

wire  [23:0]       ptp_tdata;
wire               ptp_tvalid;
logic              ptp_tready = 1'b1;
logic [54:0]       ptp_ts_in = '0;
logic [15:0]       ptp_tag_in = '0;
logic              ptp_ts_valid_in = 1'b0;

wire  [DATA_W-1:0] raw_rx_tdata;
wire  [KEEP_W-1:0] raw_rx_tkeep;
wire               raw_rx_tvalid, raw_rx_tlast;
logic              raw_rx_tready = 1'b1;

logic [DATA_W-1:0] raw_tx_tdata = '0;
logic [KEEP_W-1:0] raw_tx_tkeep = '0;
logic              raw_tx_tvalid = 1'b0, raw_tx_tlast = 1'b0;
wire               raw_tx_tready;

wire  [DATA_W-1:0] sock_rx_tdata;
wire  [KEEP_W-1:0] sock_rx_tkeep;
wire               sock_rx_tvalid, sock_rx_tlast;
logic              sock_rx_tready = 1'b1;

logic [DATA_W-1:0] sock_tx_tdata = '0;
logic [KEEP_W-1:0] sock_tx_tkeep = '0;
logic              sock_tx_tvalid = 1'b0, sock_tx_tlast = 1'b0;
wire               sock_tx_tready;

logic [11:0] s_axi_awaddr = '0, s_axi_araddr = '0;
logic        s_axi_awvalid = 1'b0, s_axi_wvalid = 1'b0, s_axi_bready = 1'b1;
logic        s_axi_arvalid = 1'b0, s_axi_rready = 1'b1;
logic [31:0] s_axi_wdata = '0;
logic [3:0]  s_axi_wstrb = '0;
wire         s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
wire  [1:0]  s_axi_bresp, s_axi_rresp;
wire  [31:0] s_axi_rdata;

zircon_nic #(
    .GEN_EN(GEN_EN),
    .CORE_HZ(CORE_HZ)
) dut (
    .clk(clk), .aresetn(aresetn),
    .mac_rx_clk(mac_rx_clk), .mac_rx_aresetn(mac_rx_aresetn),
    .s_axis_mac_rx_tdata(mac_rx_tdata), .s_axis_mac_rx_tkeep(mac_rx_tkeep),
    .s_axis_mac_rx_tvalid(mac_rx_tvalid), .s_axis_mac_rx_tready(mac_rx_tready),
    .s_axis_mac_rx_tlast(mac_rx_tlast), .s_axis_mac_rx_tuser(mac_rx_tuser),
    .mac_rx_pack_stat(pack_stat),
    .mac_tx_clk(mac_tx_clk), .mac_tx_aresetn(mac_tx_aresetn),
    .m_axis_mac_tx_tdata(mac_tx_tdata), .m_axis_mac_tx_tkeep(mac_tx_tkeep),
    .m_axis_mac_tx_tvalid(mac_tx_tvalid), .m_axis_mac_tx_tready(mac_tx_tready),
    .m_axis_mac_tx_tlast(mac_tx_tlast), .m_axis_mac_tx_tuser(mac_tx_tuser),
    .m_axis_tx_ptp_tdata(ptp_tdata), .m_axis_tx_ptp_tvalid(ptp_tvalid), .m_axis_tx_ptp_tready(ptp_tready),
    .tx_ptp_tstamp_in(ptp_ts_in), .tx_ptp_tstamp_tag_in(ptp_tag_in), .tx_ptp_tstamp_valid_in(ptp_ts_valid_in),
    .ui_clk(ui_clk), .ui_aresetn(ui_aresetn),
    .m_axis_raw_rx_tdata(raw_rx_tdata), .m_axis_raw_rx_tkeep(raw_rx_tkeep),
    .m_axis_raw_rx_tvalid(raw_rx_tvalid), .m_axis_raw_rx_tready(raw_rx_tready),
    .m_axis_raw_rx_tlast(raw_rx_tlast),
    .s_axis_raw_tx_tdata(raw_tx_tdata), .s_axis_raw_tx_tkeep(raw_tx_tkeep),
    .s_axis_raw_tx_tvalid(raw_tx_tvalid), .s_axis_raw_tx_tready(raw_tx_tready),
    .s_axis_raw_tx_tlast(raw_tx_tlast),
    .m_axis_sock_rx_tdata(sock_rx_tdata), .m_axis_sock_rx_tkeep(sock_rx_tkeep),
    .m_axis_sock_rx_tvalid(sock_rx_tvalid), .m_axis_sock_rx_tready(sock_rx_tready),
    .m_axis_sock_rx_tlast(sock_rx_tlast),
    .s_axis_sock_tx_tdata(sock_tx_tdata), .s_axis_sock_tx_tkeep(sock_tx_tkeep),
    .s_axis_sock_tx_tvalid(sock_tx_tvalid), .s_axis_sock_tx_tready(sock_tx_tready),
    .s_axis_sock_tx_tlast(sock_tx_tlast),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
    .s_axi_arprot(3'b000), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready)
);

// ---------------------------------------------------------------------------
// Frame types / bookkeeping
// ---------------------------------------------------------------------------
typedef byte unsigned bytes_t[$];

typedef struct {
    bytes_t d;
    bit     bad;
} txf_t;

txf_t   mac_rx_q[$];      // frames to send on MAC RX
bytes_t raw_tx_q[$];      // frames to send on UI0 TX
bytes_t sock_tx_q[$];     // frames to send on UI2 TX

// ports: 0 = MAC TX, 1 = UI0 RX, 2 = UI2 RX
bytes_t exp_q[3][$];
bytes_t cand_q[3][$];
bytes_t got_sub_q[3][$];
bit     subseq_mode[3] = '{0, 0, 0};
bit     hold[3] = '{0, 0, 0};
bit     randready = 0;
int     frames_seen[3] = '{0, 0, 0};

bit     collect[3] = '{0, 0, 0};   // frames only counted (COLLECT), not compared
int     collect_cnt[3] = '{0, 0, 0};
bit     loopback = 0;                // MAC TX frames are sent back on MAC RX (LOOPBACK)
bit     mac_tx_shape = 0;            // MAC TX tready shaped to 100G line rate (MACSHAPE)
bit     mac_rx_shape = 0;            // MAC RX source shaped to 100G line rate (RXSHAPE)
realtime tx_ts_q[$];                 // MAC TX frame completion times (current test)
realtime rx_commit_ts_q[$];          // rx_dispatch commit times of good frames (RXRATEINFO)
int     tx_len_q[$];                 // and their lengths

int     test_errors = 0;
int     total_fail = 0;
int     total_pass = 0;
string  test_name = "";
int     test_id = -1;
realtime last_rx_activity = 0;

function automatic string port_name(int p);
    return p == 0 ? "MAC" : (p == 1 ? "UI0" : "UI2");
endfunction

function automatic int port_index(string s);
    if (s == "MAC") return 0;
    if (s == "UI0") return 1;
    if (s == "UI2") return 2;
    $fatal(1, "bad port name %s", s);
    return -1;
endfunction

function automatic byte unsigned hexval(byte c);
    if (c >= "0" && c <= "9") return c - "0";
    if (c >= "a" && c <= "f") return c - "a" + 10;
    if (c >= "A" && c <= "F") return c - "A" + 10;
    $fatal(1, "bad hex char %0d", c);
    return 0;
endfunction

function automatic bytes_t hex2bytes(string h);
    bytes_t q;
    for (int i = 0; i + 1 < h.len(); i += 2) begin
        byte unsigned hi, lo;
        hi = hexval(h[i]);
        lo = hexval(h[i+1]);
        q.push_back(byte'((hi << 4) | lo));
    end
    return q;
endfunction

function automatic void split(string s, ref string toks[$]);
    int start = -1;
    toks.delete();
    for (int i = 0; i <= s.len(); i++) begin
        bit ws = (i == s.len()) || s[i] == " " || s[i] == "\n" || s[i] == 8'h0D || s[i] == "\t";
        if (ws) begin
            if (start >= 0) toks.push_back(s.substr(start, i - 1));
            start = -1;
        end else if (start < 0) begin
            start = i;
        end
    end
endfunction

// fast hex token extraction for long frame lines: returns the substring after
// the first n space-separated tokens
function automatic string tail_after(string s, int n);
    int cnt = 0;
    int i = 0;
    while (i < s.len() && cnt < n) begin
        if (s[i] == " ") cnt++;
        i++;
    end
    // strip trailing newline
    begin
        int e = s.len() - 1;
        while (e >= i && (s[e] == "\n" || s[e] == 8'h0D || s[e] == " ")) e--;
        return s.substr(i, e);
    end
endfunction

function automatic bit bytes_eq(const ref bytes_t a, const ref bytes_t b);
    if (a.size() != b.size()) return 0;
    foreach (a[i]) if (a[i] != b[i]) return 0;
    return 1;
endfunction

task automatic report_mismatch(int p, const ref bytes_t got, const ref bytes_t exp);
    int first = -1;
    int n = got.size() < exp.size() ? got.size() : exp.size();
    for (int i = 0; i < n; i++) begin
        if (got[i] != exp[i]) begin
            first = i;
            break;
        end
    end
    $display("  ERROR [%0t] %s frame %0d mismatch: got %0d bytes, expected %0d bytes, first difference at byte %0d",
             $realtime, port_name(p), frames_seen[p], got.size(), exp.size(), first);
    if (first >= 0) begin
        int lo = first - 4 < 0 ? 0 : first - 4;
        int hi = first + 12;
        string sg = "", se = "";
        for (int i = lo; i < hi; i++) begin
            if (i < got.size()) sg = {sg, $sformatf("%02x", got[i])}; else sg = {sg, "--"};
            if (i < exp.size()) se = {se, $sformatf("%02x", exp[i])}; else se = {se, "--"};
        end
        $display("    got [%0d..]: %s", lo, sg);
        $display("    exp [%0d..]: %s", lo, se);
    end
endtask

// ---------------------------------------------------------------------------
// MRMAC PTP model and latency bookkeeping (1.3.0)
// ---------------------------------------------------------------------------
localparam logic [54:0] TS_MASK = '1;
localparam logic [54:0] TS_LOW7 = 55'h7F;

logic ts_clk = 1'b0;
always #2.0 ts_clk = ~ts_clk;      // 250 MHz MRMAC timestamp clock

logic [54:0] ptp_timer = 55'h0000_1234_5600_0000;
always @(posedge ts_clk) ptp_timer <= ptp_timer + 55'd1024;   // 4 ns in 2^-8 ns units

typedef struct {
    int          bank;
    logic [54:0] rx_ts;
    realtime     t_rx;      // sim time of the RX SOF (< 0: no time check)
} lat_exp_t;

lat_exp_t    lat_exp_map[int];         // key: UDP {src port, dst port} of the TX frame
longint      lat_model[2][$];          // expected samples per bank (ns; -1 = implausible)
bit          lat_echo_mode = 0;        // RX echo requests create bank-0 expectations
bit          rxdesc_mode = 0;          // UI0 frames start with a ZRXT descriptor
logic [54:0] rxdesc_ts_q[$];           // RX timestamps of the frames sent in rxdesc_mode
logic [23:0] ptp_rec_q[$];             // m_axis_tx_ptp records received, not yet used
bit          tx_sof = 1;
int          ptp_frames = 0, ptp_tagged = 0;
int          ptp_dly_min = 4, ptp_dly_max = 24;
longint      tx_cycle = 0;
int          ptp_ready_mode = 1;       // 1 always ready, 0 held, 2 random

typedef struct {
    logic [54:0] ts;
    logic [15:0] tag;
    longint      due;
} ptp_ret_t;
ptp_ret_t    ptp_ret_q[$];

function automatic int port_key(logic [15:0] sport, logic [15:0] dport);
    return int'({sport, dport});
endfunction

// big-endian u16 at byte i of a byte queue (xsim mis-handles {q[i], q[i+1]})
function automatic logic [15:0] be16(const ref bytes_t q, input int i);
    logic [15:0] v;
    v[15:8] = q[i];
    v[7:0]  = q[i + 1];
    return v;
endfunction

// an RX frame's first beat is being presented with timestamp ts
function automatic void rx_frame_started(const ref bytes_t d, input logic [54:0] ts);
    if (rxdesc_mode) rxdesc_ts_q.push_back(ts);
    if (lat_echo_mode && d.size() >= 38) begin
        // echo request from sport -> reply carries {sport 7 (ECHO_PORT), dport = request sport}
        lat_exp_t e;
        logic [15:0] req_sport;
        logic [15:0] req_dport;
        req_sport = be16(d, 34);
        req_dport = be16(d, 36);
        e.bank = 0;
        e.rx_ts = ts;
        e.t_rx = $realtime;
        lat_exp_map[port_key(req_dport, req_sport)] = e;
    end
endfunction

function automatic longint lat_delta(logic [54:0] tx, logic [54:0] rx);
    logic [54:0] d;
    d = tx - (rx & ~TS_LOW7);
    return longint'(d >> 8);
endfunction

// SOFs waiting for their record (PTPREADY 0 / 2 only: the TB's MAC sink does
// not model the adapter's SOF wait, so a record may come after its frame)
typedef struct {
    logic [DATA_W-1:0] d0;
    logic [54:0]       ts;
} sof_t;
sof_t sof_wait_q[$];

// first beat of a MAC TX frame accepted
task automatic ptp_on_sof(logic [DATA_W-1:0] d0);
    if (ptp_rec_q.size() == 0) begin
        if (ptp_ready_mode != 1) begin
            sof_t w;
            w.d0 = d0;
            w.ts = ptp_timer;
            sof_wait_q.push_back(w);
        end else begin
            $display("  ERROR [%0t] MAC TX frame without a PTP record (m_axis_tx_ptp)", $realtime);
            test_errors++;
        end
        return;
    end
    ptp_process(ptp_rec_q.pop_front(), d0, ptp_timer);
endtask

// a PTP record received (m_axis_tx_ptp)
task automatic ptp_on_rec(logic [23:0] rec);
    if (sof_wait_q.size() > 0) begin
        sof_t w = sof_wait_q.pop_front();
        ptp_process(rec, w.d0, w.ts);
    end else begin
        ptp_rec_q.push_back(rec);
    end
endtask

// pair a record with its frame (first beat d0, PTP timer at its SOF ts_sof)
task automatic ptp_process(logic [23:0] rec, logic [DATA_W-1:0] d0, logic [54:0] ts_sof);
    logic [1:0]  op;
    logic [15:0] tag;
    op  = rec[1:0];
    tag = rec[17:2];
    ptp_frames++;
    if (rec[23:18] != 0 || op == 2'b01 || op == 2'b11 || (op == 2'b00 && tag != 0)) begin
        $display("  ERROR [%0t] bad PTP record %06x", $realtime, rec);
        test_errors++;
    end
    if (op == 2'b10) begin
        ptp_ret_t r;
        int key;
        ptp_tagged++;
        r.ts  = ts_sof;
        r.tag = tag;
        r.due = tx_cycle + ptp_dly_min + ($urandom % (ptp_dly_max - ptp_dly_min + 1));
        if (ptp_ret_q.size() > 0 && ptp_ret_q[$].due >= r.due) r.due = ptp_ret_q[$].due + 1;
        ptp_ret_q.push_back(r);
        key = port_key({d0[34*8 +: 8], d0[35*8 +: 8]}, {d0[36*8 +: 8], d0[37*8 +: 8]});
        if (!lat_exp_map.exists(key)) begin
            $display("  ERROR [%0t] timestamped MAC TX frame with no expectation (ports %08x)", $realtime, key);
            test_errors++;
        end else begin
            lat_exp_t e = lat_exp_map[key];
            longint dl = lat_delta(r.ts, e.rx_ts);
            lat_exp_map.delete(key);
            if (dl >= 64'd1_000_000_000) dl = -1;
            lat_model[e.bank].push_back(dl);
            if (e.t_rx >= 0) begin
                // the timer is sampled at both SOFs: the delta must match the sim time
                // difference to within the 4 ns timer step (+ the 0.5 ns RX truncation)
                real dt = $realtime - e.t_rx - (real'(ptp_timer - ts_sof) / 256.0);
                if (real'(dl) < dt - 5.0 || real'(dl) > dt + 5.0) begin
                    $display("  ERROR [%0t] latency %0d ns does not match the SOF time difference %0.1f ns", $realtime, dl, dt);
                    test_errors++;
                end
            end
        end
    end
endtask

// UI0 frame in rxdesc_mode: check and strip the 64-byte ZRXT descriptor
task automatic rx_desc_check(ref bytes_t f);
    logic [54:0] exp_ts, got_ts;
    logic [31:0] magic;
    int len;
    if (f.size() < 65) begin
        $display("  ERROR [%0t] UI0 frame of %0d bytes has no RX descriptor", $realtime, f.size());
        test_errors++;
        return;
    end
    if (rxdesc_ts_q.size() == 0) begin
        $display("  ERROR [%0t] UI0 descriptor with no RX frame timestamp recorded", $realtime);
        test_errors++;
        return;
    end
    exp_ts = rxdesc_ts_q.pop_front() & ~TS_LOW7;
    got_ts = '0;
    for (int i = 0; i < 7; i++) got_ts[i*8 +: 8] = f[8 + i];
    begin
        logic [15:0] w0, w1, w2;
        w0 = be16(f, 0);
        w1 = be16(f, 2);
        w2 = be16(f, 4);
        len = int'({w2[7:0], w2[15:8]});
        magic = {w1[7:0], w1[15:8], w0[7:0], w0[15:8]};
    end
    if (magic != 32'h5A525854 || len != f.size() - 64 || got_ts != exp_ts ||
        f[15] != 0 || f[6] != 0 || f[7] != 0) begin
        $display("  ERROR [%0t] RX descriptor: magic %02x%02x%02x%02x len %0d (frame %0d) ts %h (expected %h)",
                 $realtime, f[3], f[2], f[1], f[0], len, f.size() - 64, got_ts, exp_ts);
        test_errors++;
    end
    for (int i = 16; i < 64; i++) begin
        if ((i < 24 || i >= 28) && f[i] != 0) begin
            $display("  ERROR [%0t] RX descriptor byte %0d = %02x (expected 0)", $realtime, i, f[i]);
            test_errors++;
            break;
        end
    end
    f = f[64:$];
endtask

// TX timestamp return (MRMAC tx_ptp_tstamp_*), held while the MAC TX side is in reset
always @(posedge mac_tx_clk) begin
    tx_cycle++;
    ptp_ts_valid_in <= 1'b0;
    if (mac_tx_aresetn && ptp_ret_q.size() > 0 && ptp_ret_q[0].due <= tx_cycle) begin
        ptp_ret_t r = ptp_ret_q.pop_front();
        ptp_ts_in       <= r.ts;
        ptp_tag_in      <= r.tag;
        ptp_ts_valid_in <= 1'b1;
    end else begin
        ptp_ts_in  <= 55'({$urandom, $urandom});
        ptp_tag_in <= 16'($urandom);
    end
    ptp_tready <= (ptp_ready_mode == 1) || (ptp_ready_mode == 2 && ($urandom % 3 != 0));
end

task automatic frame_received(int p, bytes_t f);
    txf_t lb;
    frames_seen[p]++;
    last_rx_activity = $realtime;
    if (p == 0) begin
        tx_ts_q.push_back($realtime);
        tx_len_q.push_back(f.size());
    end
    if (p == 1 && rxdesc_mode) begin
        rx_desc_check(f);
    end
    if (p == 0 && loopback) begin
        lb.d = f;
        lb.bad = 1'b0;
        mac_rx_q.push_back(lb);
        collect_cnt[p]++;
        return;
    end
    if (collect[p]) begin
        collect_cnt[p]++;
        return;
    end
    if (subseq_mode[p]) begin
        got_sub_q[p].push_back(f);
        return;
    end
    if (exp_q[p].size() == 0) begin
        $display("  ERROR [%0t] unexpected frame on %s (%0d bytes)", $realtime, port_name(p), f.size());
        test_errors++;
        return;
    end
    begin
        bytes_t e = exp_q[p].pop_front();
        if (!bytes_eq(f, e)) begin
            report_mismatch(p, f, e);
            test_errors++;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Sinks
// ---------------------------------------------------------------------------
bytes_t cur_frame[3];

task automatic sink_beat(int p, logic [DATA_W-1:0] d, logic [KEEP_W-1:0] k, logic last);
    bit gap = 0;
    for (int i = 0; i < KEEP_W; i++) begin
        if (k[i]) begin
            if (gap) begin
                $display("  ERROR [%0t] %s: non-contiguous tkeep %h", $realtime, port_name(p), k);
                test_errors++;
            end
            cur_frame[p].push_back(d[i*8 +: 8]);
        end else begin
            gap = 1;
        end
    end
    if (!last && k != '1) begin
        $display("  ERROR [%0t] %s: partial tkeep %h on a non-last beat", $realtime, port_name(p), k);
        test_errors++;
    end
    if (last) begin
        frame_received(p, cur_frame[p]);
        cur_frame[p] = {};
    end
endtask

// MACSHAPE: a token bucket of 32 bytes per 390.625 MHz cycle = 100 Gb/s; every
// frame also costs 24 bytes (FCS + preamble + IPG), like a 100GBASE-R MAC
int mac_tx_credit = 0;

always @(posedge mac_tx_clk) begin
    // PTP records first: a record handshaken in the SOF cycle itself still counts
    // as present (the real path has the width converter in between)
    if (ptp_tvalid && ptp_tready) begin
        ptp_on_rec(ptp_tdata);
    end
    if (!mac_tx_aresetn) begin
        ptp_rec_q.delete();
        sof_wait_q.delete();
        tx_sof = 1;
        cur_frame[0] = {};
    end else if (mac_tx_tvalid && mac_tx_tready) begin
        if (tx_sof) ptp_on_sof(mac_tx_tdata);
        tx_sof = mac_tx_tlast;
    end
    if (mac_tx_tvalid && mac_tx_tready) begin
        sink_beat(0, mac_tx_tdata, mac_tx_tkeep, mac_tx_tlast);
        mac_tx_credit -= $countones(mac_tx_tkeep) + (mac_tx_tlast ? 24 : 0);
    end
    if (mac_tx_tvalid && mac_tx_tuser[0]) begin
        $display("  ERROR [%0t] MAC TX tuser set", $realtime);
        test_errors++;
    end
    if (mac_tx_shape) begin
        mac_tx_credit += 32;
        if (mac_tx_credit > 64) mac_tx_credit = 64;
    end else begin
        mac_tx_credit = 0;
    end
    mac_tx_tready <= !hold[0] && (!randready || ($urandom % 4 != 0)) && (!mac_tx_shape || mac_tx_credit > 0);
end

always @(posedge ui_clk) begin
    if (raw_rx_tvalid && raw_rx_tready) sink_beat(1, raw_rx_tdata, raw_rx_tkeep, raw_rx_tlast);
    if (sock_rx_tvalid && sock_rx_tready) sink_beat(2, sock_rx_tdata, sock_rx_tkeep, sock_rx_tlast);
    raw_rx_tready  <= !hold[1] && (!randready || ($urandom % 4 != 0));
    sock_rx_tready <= !hold[2] && (!randready || ($urandom % 3 != 0));
end

// RX packet rate probe: rx_dispatch's per-frame commit event (white-box, core clock)
always @(posedge clk) begin
    if (dut.core.ev_rx_frame) rx_commit_ts_q.push_back($realtime);
end

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------
// MAC RX: frames back to back, one beat per cycle (the MAC has no back-pressure)
int rx_gap = 0;           // idle cycles after every MAC RX frame (RXGAP command)

initial begin
    txf_t cur;
    int   pos;
    logic [54:0] cur_rx_ts;
    bit   active = 0;
    int   gap_cnt = 0;
    int   credit = 0;
    forever begin
        @(posedge mac_rx_clk);
        if (mac_rx_tvalid && !mac_rx_tready) begin
            $display("  ERROR [%0t] MAC RX tready low (the MAC cannot be back-pressured)", $realtime);
            test_errors++;
        end
        // RXSHAPE: 100G line rate (32 bytes per cycle, 24 bytes per frame overhead)
        if (mac_rx_shape) begin
            credit += 32;
            if (credit > 64) credit = 64;
            if (credit <= 0) begin
                mac_rx_tvalid <= 1'b0;
                mac_rx_tlast  <= 1'b0;
                mac_rx_tuser  <= '0;
                continue;
            end
        end else begin
            credit = 0;
        end
        if (gap_cnt > 0) begin
            gap_cnt--;
            mac_rx_tvalid <= 1'b0;
            mac_rx_tlast  <= 1'b0;
            mac_rx_tuser  <= '0;
            continue;
        end
        if (!active && mac_rx_q.size() > 0) begin
            cur = mac_rx_q.pop_front();
            pos = 0;
            active = 1;
            cur_rx_ts = ptp_timer;       // MRMAC: timestamp of the frame's first beat
            rx_frame_started(cur.d, cur_rx_ts);
        end
        if (active) begin
            logic [DATA_W-1:0] d = '0;
            logic [KEEP_W-1:0] k = '0;
            for (int i = 0; i < KEEP_W && pos + i < cur.d.size(); i++) begin
                d[i*8 +: 8] = cur.d[pos + i];
                k[i] = 1'b1;
            end
            pos += KEEP_W;
            if (mac_rx_shape) credit -= $countones(k) + (pos >= cur.d.size() ? 24 : 0);
            mac_rx_tdata  <= d;
            mac_rx_tkeep  <= k;
            mac_rx_tvalid <= 1'b1;
            mac_rx_tlast  <= pos >= cur.d.size();
            mac_rx_tuser  <= {cur_rx_ts[54:7], (pos >= cur.d.size()) ? cur.bad : 1'b0};
            if (pos >= cur.d.size()) begin
                active = 0;
                gap_cnt = rx_gap;
            end
        end else begin
            mac_rx_tvalid <= 1'b0;
            mac_rx_tlast  <= 1'b0;
            mac_rx_tuser  <= '0;
        end
    end
end

// UI TX sources (respect tready; random gaps when randready)
task automatic ui_source(int which);
    bytes_t cur;
    int     pos;
    bit     active = 0;
    forever begin
        @(posedge ui_clk);
        // handshake of the beat presented in the previous cycle
        if (which == 0 ? (raw_tx_tvalid && raw_tx_tready) : (sock_tx_tvalid && sock_tx_tready)) begin
            if (which == 0) raw_tx_tvalid <= 1'b0; else sock_tx_tvalid <= 1'b0;
            if (pos >= cur.size()) active = 0;
        end else if (which == 0 ? raw_tx_tvalid : sock_tx_tvalid) begin
            continue;   // hold the beat
        end
        if (!active) begin
            if (which == 0 && raw_tx_q.size() > 0) begin cur = raw_tx_q.pop_front(); pos = 0; active = 1; end
            if (which == 1 && sock_tx_q.size() > 0) begin cur = sock_tx_q.pop_front(); pos = 0; active = 1; end
        end
        if (active && (!randready || ($urandom % 5 != 0))) begin
            logic [DATA_W-1:0] d = '0;
            logic [KEEP_W-1:0] k = '0;
            for (int i = 0; i < KEEP_W && pos + i < cur.size(); i++) begin
                d[i*8 +: 8] = cur[pos + i];
                k[i] = 1'b1;
            end
            pos += KEEP_W;
            if (which == 0) begin
                raw_tx_tdata <= d; raw_tx_tkeep <= k; raw_tx_tlast <= pos >= cur.size(); raw_tx_tvalid <= 1'b1;
            end else begin
                sock_tx_tdata <= d; sock_tx_tkeep <= k; sock_tx_tlast <= pos >= cur.size(); sock_tx_tvalid <= 1'b1;
            end
        end
    end
endtask

initial ui_source(0);
initial ui_source(1);

function automatic bit inputs_idle();
    return mac_rx_q.size() == 0 && raw_tx_q.size() == 0 && sock_tx_q.size() == 0 &&
           !mac_rx_tvalid && !raw_tx_tvalid && !sock_tx_tvalid;
endfunction

// ---------------------------------------------------------------------------
// AXI-Lite master
// ---------------------------------------------------------------------------
task automatic axil_write(input logic [11:0] addr, input logic [31:0] data);
    @(posedge ui_clk);
    s_axi_awaddr  <= addr;
    s_axi_awvalid <= 1'b1;
    s_axi_wdata   <= data;
    s_axi_wstrb   <= 4'hF;
    s_axi_wvalid  <= 1'b1;
    do @(posedge ui_clk); while (!(s_axi_awready && s_axi_wready));
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    while (!s_axi_bvalid) @(posedge ui_clk);
    if (s_axi_bresp != 2'b00) begin
        $display("  ERROR AXI-Lite write 0x%03x: BRESP %0d", addr, s_axi_bresp);
        test_errors++;
    end
endtask

task automatic axil_read(input logic [11:0] addr, output logic [31:0] data);
    @(posedge ui_clk);
    s_axi_araddr  <= addr;
    s_axi_arvalid <= 1'b1;
    do @(posedge ui_clk); while (!s_axi_arready);
    s_axi_arvalid <= 1'b0;
    do @(posedge ui_clk); while (!s_axi_rvalid);
    data = s_axi_rdata;
    if (s_axi_rresp != 2'b00) begin
        $display("  ERROR AXI-Lite read 0x%03x: RRESP %0d", addr, s_axi_rresp);
        test_errors++;
    end
endtask

// ---------------------------------------------------------------------------
// Checks used by the script
// ---------------------------------------------------------------------------
task automatic drain();
    realtime t0 = $realtime;
    // inputs sent and every expected frame received (or 2 ms timeout)
    while (!(inputs_idle() && exp_q[0].size() == 0 && exp_q[1].size() == 0 && exp_q[2].size() == 0) &&
           $realtime - t0 < 2000000.0) begin
        @(posedge ui_clk);
    end
    // subsequence mode: wait until the port has been quiet for 20 us
    if (subseq_mode[0] || subseq_mode[1] || subseq_mode[2]) begin
        last_rx_activity = $realtime;
        while ($realtime - last_rx_activity < 20000.0 && $realtime - t0 < 2000000.0) @(posedge ui_clk);
    end
    // settle: catch late/unexpected frames and let the counter snapshots cross over
    #3000;
    for (int p = 0; p < 3; p++) begin
        if (exp_q[p].size() != 0) begin
            $display("  ERROR [%0t] %s: %0d expected frame(s) never arrived", $realtime, port_name(p), exp_q[p].size());
            test_errors++;
            exp_q[p].delete();
        end
    end
endtask

// sum of the drop counters named by toks[first..]
task automatic read_drops(const ref string toks[$], input int first, output logic [31:0] drops, output string names);
    logic [31:0] v;
    drops = 0;
    names = "";
    for (int i = first; i < toks.size(); i++) begin
        axil_read(12'(toks[i].atohex()), v);
        drops += v;
        names = {names, $sformatf(" 0x%03x=%0d", 12'(toks[i].atohex()), v)};
    end
endtask

task automatic subchk(int p, const ref string toks[$]);
    logic [31:0] drops;
    string names;
    int ci = 0;
    int ok = 1;
    int matched = 0;
    read_drops(toks, 2, drops, names);
    for (int g = 0; g < got_sub_q[p].size(); g++) begin
        bytes_t gf = got_sub_q[p][g];
        while (ci < cand_q[p].size()) begin
            bytes_t cf = cand_q[p][ci];
            if (bytes_eq(gf, cf)) break;
            ci++;
        end
        if (ci >= cand_q[p].size()) begin
            $display("  ERROR %s: received frame %0d is not an in-order subsequence of the sent frames", port_name(p), g);
            ok = 0;
            break;
        end
        matched++;
        ci++;
    end
    $display("  subsequence check %s: sent %0d, received %0d (%0d matched in order), drop counters%s",
             port_name(p), cand_q[p].size(), got_sub_q[p].size(), matched, names);
    if (matched != got_sub_q[p].size()) ok = 0;
    if (!ok) test_errors++;
    if (got_sub_q[p].size() + drops != cand_q[p].size()) begin
        $display("  ERROR %s: received + dropped (%0d) != sent (%0d)", port_name(p), got_sub_q[p].size() + drops, cand_q[p].size());
        test_errors++;
    end
    if (drops == 0) begin
        $display("  ERROR %s: expected an overrun (drops > 0)", port_name(p));
        test_errors++;
    end
    got_sub_q[p].delete();
    cand_q[p].delete();
endtask

// PREFIX: the frames received in subsequence mode must be exactly the first n
// candidates (n >= 1), and every register listed must read n
task automatic prefix_chk(int p, const ref string toks[$]);
    int n = got_sub_q[p].size();
    logic [31:0] v;
    if (n == 0) begin
        $display("  ERROR %s: no frame received", port_name(p));
        test_errors++;
    end
    if (n > cand_q[p].size()) begin
        $display("  ERROR %s: %0d frames received, only %0d candidates", port_name(p), n, cand_q[p].size());
        test_errors++;
        n = cand_q[p].size();
    end
    for (int i = 0; i < n; i++) begin
        bytes_t gf = got_sub_q[p][i];
        bytes_t cf = cand_q[p][i];
        if (!bytes_eq(gf, cf)) begin
            frames_seen[p] = i;
            report_mismatch(p, gf, cf);
            test_errors++;
            break;
        end
    end
    $display("  prefix check %s: %0d frames, all equal to the first candidates", port_name(p), got_sub_q[p].size());
    for (int i = 2; i < toks.size(); i++) begin
        axil_read(12'(toks[i].atohex()), v);
        if (v != 32'(got_sub_q[p].size())) begin
            $display("  ERROR register 0x%03x = %0d, expected %0d", 12'(toks[i].atohex()), v, got_sub_q[p].size());
            test_errors++;
        end
    end
    got_sub_q[p].delete();
    cand_q[p].delete();
endtask

// WAITCHG: poll a register until it changes; the change must be +1
task automatic wait_change(logic [11:0] a);
    logic [31:0] v0, v;
    realtime t0 = $realtime;
    axil_read(a, v0);
    do axil_read(a, v); while (v == v0 && $realtime - t0 < 2000000.0);
    if (v != v0 + 32'd1) begin
        $display("  ERROR [%0t] register 0x%03x went from %0d to %0d (expected +1)", $realtime, a, v0, v);
        test_errors++;
    end
endtask

// WAITREG: poll a register until (value & mask) == exp (2 ms timeout)
task automatic wait_reg(logic [11:0] a, logic [31:0] e, logic [31:0] m);
    logic [31:0] v;
    realtime t0 = $realtime;
    do axil_read(a, v); while ((v & m) != (e & m) && $realtime - t0 < 2000000.0);
    if ((v & m) != (e & m)) begin
        $display("  ERROR [%0t] timeout waiting for register 0x%03x = 0x%08x (mask 0x%08x), last 0x%08x", $realtime, a, e, m, v);
        test_errors++;
    end
endtask

// RATEINFO: MAC TX throughput of the frames of this test, skipping the first
// `skip` frames (pipeline fill); informational
task automatic rate_info(string label, int skip);
    int n = tx_ts_q.size();
    if (n < skip + 3) begin
        $display("  RATE %s: only %0d MAC TX frames", label, n);
        return;
    end
    begin
        realtime span = tx_ts_q[n-1] - tx_ts_q[skip];
        longint bytes = 0;
        real ns_per, gbps_line, gbps_frame;
        for (int i = skip + 1; i < n; i++) bytes += tx_len_q[i];
        ns_per = span / (n - 1 - skip);
        gbps_frame = 8.0 * bytes / span;
        gbps_line = 8.0 * (bytes + 24.0 * (n - 1 - skip)) / span;
        $display("  RATE %s: %0d frames, %0.2f ns/frame = %0.2f core cycles/frame, %0.2f Mpps, %0.2f Gb/s frames, %0.2f Gb/s line",
                 label, n - 1 - skip, ns_per, ns_per / 3.3334, 1000.0 / ns_per, gbps_frame, gbps_line);
    end
endtask

// count-only variant (frames whose bytes are not predictable, e.g. echo replies
// with a shared IPv4 ID counter): received + drop counters == sent, drops > 0
task automatic rxcnt(int p, int n_sent, const ref string toks[$]);
    logic [31:0] drops;
    string names;
    read_drops(toks, 3, drops, names);
    $display("  count check %s: sent %0d, received %0d, drop counters%s",
             port_name(p), n_sent, got_sub_q[p].size(), names);
    if (got_sub_q[p].size() + drops != n_sent) begin
        $display("  ERROR %s: received + dropped (%0d) != sent (%0d)", port_name(p), got_sub_q[p].size() + drops, n_sent);
        test_errors++;
    end
    if (drops == 0) begin
        $display("  ERROR %s: expected drops (> 0)", port_name(p));
        test_errors++;
    end
    got_sub_q[p].delete();
endtask

// ---------------------------------------------------------------------------
// Latency checks (1.3.0)
// ---------------------------------------------------------------------------
localparam logic [11:0] R_LAT_CTRL = 12'h100;

task automatic lat_cmd(logic [31:0] cmd);
    logic [31:0] v;
    realtime t0;
    axil_read(R_LAT_CTRL, v);
    axil_write(R_LAT_CTRL, (v & 32'h0000_0301) | cmd);
    t0 = $realtime;
    do axil_read(R_LAT_CTRL, v); while (v[31] && $realtime - t0 < 1000000.0);
    if (v[31]) begin
        $display("  ERROR [%0t] LAT_CTRL.BUSY stuck", $realtime);
        test_errors++;
    end
endtask

typedef struct {
    longint unsigned cnt, sum, sq;
    longint unsigned mn, mx, imp, last, base, width;
    int              shift;
    longint unsigned hbin[64];
} lat_regs_t;

task automatic lat_read(int b, output lat_regs_t r);
    logic [31:0] w[12];
    logic [31:0] lo, hi;
    for (int i = 0; i < 12; i++) axil_read(12'(12'h200 + b * 12'h40 + i * 4), w[i]);
    r.cnt = {w[1], w[0]};
    r.sum = {w[3], w[2]};
    r.sq  = {w[5], w[4]};
    r.mn = w[6]; r.mx = w[7]; r.imp = w[8]; r.last = w[9]; r.base = w[10]; r.width = w[11];
    r.shift = 0;
    for (int i = 0; i < 32; i++) if (w[11][i]) r.shift = i;
    if (w[11] == 0 || (w[11] & (w[11] - 1)) != 0) begin
        $display("  ERROR bank %0d: snapshot BIN_WIDTH %0d is not a power of two", b, w[11]);
        test_errors++;
    end
    for (int i = 0; i < 64; i++) begin
        axil_read(12'(12'h400 + b * 12'h200 + i * 8), lo);
        axil_read(12'(12'h400 + b * 12'h200 + i * 8 + 4), hi);
        if (hi[31:16] != 0) begin
            $display("  ERROR bin HI word upper half not 0 (bank %0d bin %0d)", b, i);
            test_errors++;
        end
        r.hbin[i] = {hi[15:0], lo};
    end
endtask

function automatic int lat_bin(longint d, longint unsigned base, int shift);
    longint unsigned q;
    int k;
    if (d < longint'(base)) return 0;
    q = longint'(d - longint'(base)) >> shift;
    if (q < 48) return int'(q);
    k = 0;
    for (int j = 1; j <= 15; j++) if (q >= (longint'(48) << j)) k++;
    return 48 + k;
endfunction

// snapshot bank b and compare it exactly with the model
task automatic lat_check(int b);
    lat_regs_t r;
    longint unsigned e_cnt = 0, e_sum = 0, e_imp = 0, e_mn = 32'hFFFFFFFF, e_mx = 0, e_last = 0;
    logic [64:0] e_sq = 0;
    longint unsigned e_bins[64];
    longint unsigned bsum = 0;
    int nerr = 0;
    realtime t0 = $realtime;
    while (ptp_ret_q.size() > 0 && $realtime - t0 < 1000000.0) @(posedge ui_clk);
    #3000;   // samples cross to the statistics engine
    lat_cmd(32'h8);
    lat_read(b, r);
    foreach (e_bins[i]) e_bins[i] = 0;
    for (int i = 0; i < lat_model[b].size(); i++) begin
        longint d = lat_model[b][i];
        if (d < 0) begin
            e_imp++;
        end else begin
            e_cnt++;
            e_sum += d;
            e_sq = e_sq + 65'(d * d);
            if (e_sq[64]) e_sq = {1'b0, 64'hFFFF_FFFF_FFFF_FFFF};
            if (d < e_mn) e_mn = d;
            if (d > e_mx) e_mx = d;
            e_last = d;
            e_bins[lat_bin(d, r.base, r.shift)]++;
        end
    end
    if (r.cnt != e_cnt || r.sum != e_sum || r.sq != e_sq[63:0] || r.mn != e_mn || r.mx != e_mx ||
        r.imp != e_imp || r.last != e_last) begin
        $display("  ERROR bank %0d: count %0d/%0d sum %0d/%0d sumsq %0d/%0d min %0d/%0d max %0d/%0d implausible %0d/%0d last %0d/%0d (got/expected)",
                 b, r.cnt, e_cnt, r.sum, e_sum, r.sq, e_sq[63:0], r.mn, e_mn, r.mx, e_mx, r.imp, e_imp, r.last, e_last);
        test_errors++;
    end
    for (int i = 0; i < 64; i++) begin
        bsum += r.hbin[i];
        if (r.hbin[i] != e_bins[i]) begin
            if (nerr++ < 4) $display("  ERROR bank %0d bin %0d = %0d, expected %0d", b, i, r.hbin[i], e_bins[i]);
            test_errors++;
        end
    end
    if (bsum != r.cnt) begin
        $display("  ERROR bank %0d: histogram sum %0d != count %0d", b, bsum, r.cnt);
        test_errors++;
    end
    if (r.cnt > 0 && !(r.mn * r.cnt <= r.sum && r.sum <= r.mx * r.cnt)) begin
        $display("  ERROR bank %0d: mean outside [min, max]", b);
        test_errors++;
    end
    begin
        string bl = "";
        for (int i = 0; i < 64; i++) if (r.hbin[i] != 0) bl = {bl, $sformatf(" %0d:%0d", i, r.hbin[i])};
        $display("  LAT bank %0d: %0d samples, min %0d mean %0.1f max %0d ns, implausible %0d, W=%0d ns base %0d, hbin%s",
                 b, r.cnt, r.cnt ? r.mn : 0, r.cnt ? real'(r.sum) / real'(r.cnt) : 0.0, r.mx, r.imp,
                 r.width, r.base, bl);
    end
endtask

// repeated snapshots while samples arrive: each one internally consistent
task automatic lat_cohere(int b, int n);
    lat_regs_t r;
    longint unsigned prev = 0, first = 0;
    for (int k = 0; k < n; k++) begin
        longint unsigned bsum = 0;
        lat_cmd(32'h8);
        lat_read(b, r);
        foreach (r.hbin[i]) bsum += r.hbin[i];
        if (bsum != r.cnt || r.cnt < prev || (r.cnt > 0 && (r.mn > r.mx || r.last < r.mn || r.last > r.mx))) begin
            $display("  ERROR snapshot %0d of bank %0d incoherent: count %0d (previous %0d) histogram sum %0d min %0d max %0d last %0d",
                     k, b, r.cnt, prev, bsum, r.mn, r.mx, r.last);
            test_errors++;
        end
        if (k == 0) first = r.cnt;
        prev = r.cnt;
    end
    $display("  coherence: %0d snapshots of bank %0d while sampling, count %0d -> %0d", n, b, first, prev);
    if (prev == first) begin
        $display("  ERROR no samples arrived during the snapshots");
        test_errors++;
    end
endtask

// ---------------------------------------------------------------------------
// Script interpreter
// ---------------------------------------------------------------------------
initial begin
    string vec_file;
    int    fd;
    string line;
    string toks[$];
    logic [31:0] rdata;

    if (!$value$plusargs("vectors=%s", vec_file)) vec_file = "vectors.txt";
    fd = $fopen(vec_file, "r");
    if (fd == 0) $fatal(1, "cannot open %s", vec_file);

    // reset
    #100;
    aresetn = 1'b1; mac_rx_aresetn = 1'b1; mac_tx_aresetn = 1'b1; ui_aresetn = 1'b1;
    #500;

    while ($fgets(line, fd)) begin
        string cmd;
        if (line.len() == 0) continue;
        // commands with a long hex argument are split without tokenising the hex
        if (line.len() > 3 && line.substr(0, 2) == "RX ") begin
            txf_t f;
            f.bad = line[3] == "1";
            f.d = hex2bytes(tail_after(line, 2));
            mac_rx_q.push_back(f);
            continue;
        end
        if (line.len() > 6 && line.substr(0, 5) == "TXRAW ") begin
            raw_tx_q.push_back(hex2bytes(tail_after(line, 1)));
            continue;
        end
        if (line.len() > 7 && line.substr(0, 6) == "TXRAWD ") begin
            // TXRAWD <mode> <hex>: UI0 frame behind a ZTXT descriptor; mode 0: TS_REQ 0,
            // 1: TS_REQ 1 (bank-1 expectation), 2: TS_REQ 1 with rx_ts 2 s old
            // (implausible), 3: TS_REQ 1 but no expectation (LAT_CTRL.EN = 0)
            bytes_t fr = hex2bytes(tail_after(line, 2));
            bytes_t d;
            int mode = line[7] - "0";
            logic [54:0] rts = (ptp_timer | 55'($urandom % 128));
            if (mode == 2) rts = ptp_timer - 55'd512_000_000_000;
            d = {8'h54, 8'h58, 8'h54, 8'h5A, 8'h00, 8'h00, 8'(mode != 0), 8'h00};
            for (int i = 0; i < 8; i++) d.push_back(8'(64'(rts) >> (8 * i)));
            while (d.size() < 64) d.push_back(8'h00);
            if (mode == 1 || mode == 2) begin
                lat_exp_t e;
                e.bank = 1;
                e.rx_ts = rts;
                e.t_rx = -1.0;
                lat_exp_map[port_key(be16(fr, 34), be16(fr, 36))] = e;
            end
            raw_tx_q.push_back({d, fr});
            continue;
        end
        if (line.len() > 7 && line.substr(0, 6) == "TXSOCK ") begin
            sock_tx_q.push_back(hex2bytes(tail_after(line, 1)));
            continue;
        end
        if (line.len() > 4 && line.substr(0, 3) == "EXP ") begin
            exp_q[port_index(line.substr(4, 6))].push_back(hex2bytes(tail_after(line, 2)));
            continue;
        end
        if (line.len() > 5 && line.substr(0, 4) == "CAND ") begin
            cand_q[port_index(line.substr(5, 7))].push_back(hex2bytes(tail_after(line, 2)));
            continue;
        end
        split(line, toks);
        if (toks.size() == 0) continue;
        cmd = toks[0];
        if (cmd == "TEST") begin
            string c0;
            int n_scan;
            n_scan = $sscanf(line, "%s %d %s", c0, test_id, test_name);
            test_errors = 0;
            ptp_frames = 0;
            ptp_tagged = 0;
            tx_ts_q.delete();
            tx_len_q.delete();
            rx_commit_ts_q.delete();
            $display("[%0t] ---- test %0d %s", $realtime, test_id, test_name);
        end else if (cmd == "END") begin
            if (test_errors == 0) begin
                $display("PASS: test %0d %s", test_id, test_name);
                total_pass++;
            end else begin
                $display("FAIL: test %0d %s (%0d errors)", test_id, test_name, test_errors);
                total_fail++;
            end
        end else if (cmd == "WR") begin
            axil_write(12'(toks[1].atohex()), 32'(toks[2].atohex()));
        end else if (cmd == "RD") begin
            logic [31:0] e, m;
            logic [11:0] a;
            a = 12'(toks[1].atohex());
            e = 32'(toks[2].atohex());
            m = toks.size() > 3 ? 32'(toks[3].atohex()) : 32'hFFFFFFFF;
            axil_read(a, rdata);
            if ((rdata & m) != (e & m)) begin
                $display("  ERROR [%0t] register 0x%03x = 0x%08x, expected 0x%08x (mask 0x%08x)", $realtime, a, rdata, e, m);
                test_errors++;
            end
        end else if (cmd == "HOLD") begin
            hold[port_index(toks[1])] = toks[2] == "1";
        end else if (cmd == "PACKSTAT") begin
            @(posedge mac_rx_clk);
            pack_stat <= 2'(toks[1].atohex());
            @(posedge mac_rx_clk);
            pack_stat <= 2'b00;
        end else if (cmd == "RXGAP") begin
            rx_gap = toks[1].atoi();
        end else if (cmd == "RANDREADY") begin
            randready = toks[1] == "1";
        end else if (cmd == "SUBSEQ") begin
            subseq_mode[port_index(toks[1])] = toks[2] == "1";
        end else if (cmd == "SUBCHK") begin
            subchk(port_index(toks[1]), toks);
        end else if (cmd == "PREFIX") begin
            prefix_chk(port_index(toks[1]), toks);
        end else if (cmd == "COLLECT") begin
            collect[port_index(toks[1])] = toks[2] == "1";
            collect_cnt[port_index(toks[1])] = 0;
        end else if (cmd == "CNTEQ") begin
            int p = port_index(toks[1]);
            if (collect_cnt[p] != toks[2].atoi()) begin
                $display("  ERROR %s: %0d frames collected, expected %0d", port_name(p), collect_cnt[p], toks[2].atoi());
                test_errors++;
            end
        end else if (cmd == "LOOPBACK") begin
            loopback = toks[1] == "1";
            collect_cnt[0] = 0;
        end else if (cmd == "MACSHAPE") begin
            mac_tx_shape = toks[1] == "1";
        end else if (cmd == "RXSHAPE") begin
            mac_rx_shape = toks[1] == "1";
        end else if (cmd == "WAITCHG") begin
            wait_change(12'(toks[1].atohex()));
        end else if (cmd == "WAITREG") begin
            wait_reg(12'(toks[1].atohex()), 32'(toks[2].atohex()),
                     toks.size() > 3 ? 32'(toks[3].atohex()) : 32'hFFFFFFFF);
        end else if (cmd == "RDEQ") begin
            // RDEQ <a> <b> [min]: registers a and b equal (and >= min)
            logic [31:0] va, vb;
            axil_read(12'(toks[1].atohex()), va);
            axil_read(12'(toks[2].atohex()), vb);
            if (va != vb || (toks.size() > 3 && va < 32'(toks[3].atoi()))) begin
                $display("  ERROR [%0t] register 0x%s = %0d, 0x%s = %0d (expected equal%s)", $realtime,
                         toks[1], va, toks[2], vb, toks.size() > 3 ? {", >= ", toks[3]} : "");
                test_errors++;
            end else begin
                $display("  0x%s = 0x%s = %0d", toks[1], toks[2], va);
            end
        end else if (cmd == "TXGAPMIN") begin
            // consecutive MAC TX frames of this test at least <ns> apart
            real mn = 1.0e12;
            for (int i = 1; i < tx_ts_q.size(); i++) begin
                if (tx_ts_q[i] - tx_ts_q[i-1] < mn) mn = tx_ts_q[i] - tx_ts_q[i-1];
            end
            $display("  MAC TX: %0d frames, smallest spacing %0.1f ns (>= %s ns required)", tx_ts_q.size(), mn, toks[1]);
            if (tx_ts_q.size() < 2 || mn < real'(toks[1].atoi())) test_errors++;
        end else if (cmd == "TSCLR") begin
            tx_ts_q.delete();
            tx_len_q.delete();
            rx_commit_ts_q.delete();
        end else if (cmd == "RXRATEINFO") begin
            // RX frames committed by rx_dispatch: rate over the middle half (informational)
            int n = rx_commit_ts_q.size();
            if (n < 8) begin
                $display("  RXRATE %s: only %0d frames", toks[1], n);
            end else begin
                realtime span = rx_commit_ts_q[3*n/4] - rx_commit_ts_q[n/4];
                real ns_per = span / (3*n/4 - n/4);
                $display("  RXRATE %s: %0d frames, %0.2f ns/frame = %0.2f core cycles/frame, %0.2f Mpps",
                         toks[1], n, ns_per, ns_per / 3.3334, 1000.0 / ns_per);
            end
        end else if (cmd == "RATEINFO") begin
            rate_info(toks[1], toks.size() > 2 ? toks[2].atoi() : 4);
        end else if (cmd == "RDSUM") begin
            logic [31:0] v, sum;
            sum = 0;
            for (int i = 2; i < toks.size(); i++) begin
                axil_read(12'(toks[i].atohex()), v);
                sum += v;
            end
            if (sum != 32'(toks[1].atoi())) begin
                $display("  ERROR [%0t] registers %s.. add up to %0d, expected %s", $realtime, toks[2], sum, toks[1]);
                test_errors++;
            end
        end else if (cmd == "SHOWREG") begin
            // SHOWREG <label> <addr>...: print register values (informational)
            string msg;
            logic [31:0] v;
            msg = $sformatf("  %s:", toks[1]);
            for (int i = 2; i < toks.size(); i++) begin
                axil_read(12'(toks[i].atohex()), v);
                msg = {msg, $sformatf(" 0x%s=%0d", toks[i], v)};
            end
            $display("%s", msg);
        end else if (cmd == "RXCNT") begin
            rxcnt(port_index(toks[1]), toks[2].atoi(), toks);
        end else if (cmd == "CHKEMPTY") begin
            int p = port_index(toks[1]);
            if (exp_q[p].size() != 0) begin
                $display("  ERROR [%0t] %s: %0d expected frame(s) not received yet", $realtime, port_name(p), exp_q[p].size());
                test_errors++;
            end
        end else if (cmd == "RSTMACRX") begin
            mac_rx_aresetn = toks[1] == "1";
        end else if (cmd == "RSTMACTX") begin
            mac_tx_aresetn = toks[1] == "1";
        end else if (cmd == "WAITRX") begin
            while (!inputs_idle()) @(posedge ui_clk);
        end else if (cmd == "WAIT") begin
            #(toks[1].atoi() * 1.0ns);
        end else if (cmd == "DRAIN") begin
            drain();
            if (ptp_rec_q.size() != 0 || sof_wait_q.size() != 0) begin
                $display("  ERROR [%0t] %0d PTP record(s) without a MAC TX frame, %0d frame(s) without a record",
                         $realtime, ptp_rec_q.size(), sof_wait_q.size());
                test_errors++;
                ptp_rec_q.delete();
                sof_wait_q.delete();
            end
        end else if (cmd == "LATECHO") begin
            lat_echo_mode = toks[1] == "1";
        end else if (cmd == "RXDESC") begin
            rxdesc_mode = toks[1] == "1";
            rxdesc_ts_q.delete();
        end else if (cmd == "LATCHK") begin
            lat_check(toks[1].atoi());
        end else if (cmd == "LATCLR") begin
            lat_cmd(32'h1 << (1 + toks[1].atoi()));
            lat_model[toks[1].atoi()].delete();
        end else if (cmd == "LATFLUSH") begin
            lat_exp_map.delete();
            lat_model[0].delete();
            lat_model[1].delete();
        end else if (cmd == "LATCOHERE") begin
            lat_cohere(toks[1].atoi(), toks[2].atoi());
        end else if (cmd == "LATCNT") begin
            if (ptp_rec_q.size() != 0 || sof_wait_q.size() != 0) begin
                $display("  ERROR %0d PTP record(s) without a MAC TX frame, %0d frame(s) without a record",
                         ptp_rec_q.size(), sof_wait_q.size());
                test_errors++;
            end
            // LATCNT <frames> <tagged>: PTP records used by MAC TX frames in this test
            if (ptp_frames != toks[1].atoi() || ptp_tagged != toks[2].atoi()) begin
                $display("  ERROR PTP records: %0d frames / %0d timestamped, expected %s / %s",
                         ptp_frames, ptp_tagged, toks[1], toks[2]);
                test_errors++;
            end else begin
                $display("  PTP records: %0d frames, %0d timestamped (op 2), one per frame in order", ptp_frames, ptp_tagged);
            end
            if (lat_exp_map.size() != 0) begin
                $display("  ERROR %0d expected timestamped frame(s) never sent", lat_exp_map.size());
                test_errors++;
            end
        end else if (cmd == "PTPTIMER") begin
            logic [63:0] tv;
            int n_tv;
            n_tv = $sscanf(toks[1], "%h", tv);
            @(posedge ts_clk);
            ptp_timer = 55'(tv);
        end else if (cmd == "PTPDELAY") begin
            ptp_dly_min = toks[1].atoi();
            ptp_dly_max = toks[2].atoi();
        end else if (cmd == "PTPREADY") begin
            ptp_ready_mode = toks[1].atoi();
        end else if (cmd == "FINISH") begin
            break;
        end else begin
            $fatal(1, "unknown command: %s", line);
        end
    end
    $fclose(fd);

    $display("SUMMARY: %0d passed, %0d failed", total_pass, total_fail);
    if (total_fail == 0 && total_pass > 0) begin
        $display("ALL TESTS PASSED");
    end else begin
        $display("TESTS FAILED");
    end
    $finish;
end

// global watchdog
initial begin
    #100ms;
    $display("TESTS FAILED: global timeout");
    $finish;
end

endmodule

`default_nettype wire

// SPDX-License-Identifier: MIT
//
// tb_mrmac_rx_packer - xsim unit testbench of mrmac_rx_packer (MRMAC 100G RX
// client, 48 bytes/beat, no back-pressure -> 512-bit AXIS for zircon_nic).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
// The MRMAC model drives one beat per cycle with NO idle cycles unless a test
// asks for them (harsher than the real 100G line rate) and random garbage on
// every port while tvalid is low. Every output frame is checked byte for byte
// and tuser[0] must be the frame's MRMAC error flag on the TLAST beat, 0 on
// every other beat. Tests (PASS/FAIL lines in the tb_zircon_nic format):
//   13 rx_packer_directed          lengths 1..200, 48-byte multiples up to 9024,
//                                  A(tlast) - B(single beat) - C with no idle
//                                  cycles, errored frames in between
//   14 rx_packer_random            6000 random frames 1..9000 B, 20% errored,
//                                  back to back, occasional idle/garbage cycles
//   20 rx_packer_backpressure      (a) short random tready drops: nothing lost,
//                                  STALL reported; (b) tready held low for long
//                                  stretches: the FIFO overflows, OVF reported,
//                                  and every frame delivered with tuser[0] = 0
//                                  is intact (all damaged frames are marked bad)
// 1.3.0: every frame gets a random 55-bit rx_ptp_tstamp on its first client
// beat (garbage on all other beats and idle cycles); every output beat must
// carry tuser[48:1] = that frame's ts[54:7] (RX_TS_BEAT = 0).

`timescale 1ns / 1ps
`default_nettype none

module tb_mrmac_rx_packer;

logic clk = 1'b0;
logic aresetn = 1'b0;
always #1.28 clk = ~clk;   // 390.625 MHz

logic [63:0] tdata [6];
logic [10:0] tkeep_user [6];
logic        rx_tlast = 1'b0;
logic        rx_tvalid = 1'b0;
logic [54:0] rx_ts = '0;

initial begin
    for (int i = 0; i < 6; i++) begin
        tdata[i] = '0;
        tkeep_user[i] = '0;
    end
end

wire [511:0] m_tdata;
wire [63:0]  m_tkeep;
wire [48:0]  m_tuser;
wire         m_tlast, m_tvalid;
logic        m_tready = 1'b1;
wire [1:0]   stat;

mrmac_rx_packer #(.FIFO_DEPTH(16)) dut (
    .aclk(clk), .aresetn(aresetn),
    .rx_axis_tdata0(tdata[0]), .rx_axis_tdata1(tdata[1]), .rx_axis_tdata2(tdata[2]),
    .rx_axis_tdata3(tdata[3]), .rx_axis_tdata4(tdata[4]), .rx_axis_tdata5(tdata[5]),
    .rx_axis_tkeep_user0(tkeep_user[0]), .rx_axis_tkeep_user1(tkeep_user[1]),
    .rx_axis_tkeep_user2(tkeep_user[2]), .rx_axis_tkeep_user3(tkeep_user[3]),
    .rx_axis_tkeep_user4(tkeep_user[4]), .rx_axis_tkeep_user5(tkeep_user[5]),
    .rx_axis_tlast(rx_tlast), .rx_axis_tvalid(rx_tvalid), .rx_ptp_tstamp(rx_ts),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tuser(m_tuser),
    .m_axis_tlast(m_tlast), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
    .stat(stat)
);

// ---------------------------------------------------------------------------
// Bookkeeping
// ---------------------------------------------------------------------------
typedef byte unsigned bytes_t[$];
typedef struct {
    bytes_t d;
    bit     err;
    logic [54:0] ts;
} frm_t;

frm_t   exp_q[$];
int     test_errors = 0;
int     total_pass = 0, total_fail = 0;
int     n_out = 0, n_out_bad = 0;
int     n_stall = 0, n_ovf = 0;
bit     lossy = 0;          // overflow expected: match good frames by sequence number
int     lossy_next = 0;     // lowest sequence number a good frame may still carry
bytes_t cur;
bytes_t sent_by_seq[int];
bit     sent_err_by_seq[int];
logic [54:0] sent_ts_by_seq[int];
logic [47:0] cur_ts;         // tuser[48:1] of the first output beat of the current frame
logic [54:0] exp_ts_q[$];    // timestamps of the frames in exp_q
bit          ts_changed;

always @(posedge clk) begin
    if (stat[0]) n_stall++;
    if (stat[1]) n_ovf++;
end

function automatic bit bytes_eq(const ref bytes_t a, const ref bytes_t b);
    if (a.size() != b.size()) return 0;
    foreach (a[i]) if (a[i] != b[i]) return 0;
    return 1;
endfunction

task automatic check_frame(const ref bytes_t got, input bit bad);
    frm_t   e;
    bytes_t sd;
    int     seq;
    if (lossy) begin
        if (bad) return;            // damaged or errored: zircon_nic drops it
        if (got.size() < 8) begin
            $display("  ERROR [%0t] good frame of %0d bytes in lossy mode", $realtime, got.size());
            test_errors++;
            return;
        end
        seq = {got[3], got[2], got[1], got[0]};
        if (!sent_by_seq.exists(seq) || seq < lossy_next) begin
            $display("  ERROR [%0t] good frame with unknown / out-of-order sequence %0d", $realtime, seq);
            test_errors++;
            return;
        end
        if (cur_ts != sent_ts_by_seq[seq][54:7]) begin
            $display("  ERROR [%0t] frame %0d: timestamp %h, expected %h", $realtime, seq, cur_ts, sent_ts_by_seq[seq][54:7]);
            test_errors++;
        end
        lossy_next = seq + 1;
        if (sent_err_by_seq[seq]) begin
            $display("  ERROR [%0t] frame %0d was sent errored but delivered good", $realtime, seq);
            test_errors++;
        end
        sd = sent_by_seq[seq];
        if (!bytes_eq(got, sd)) begin
            $display("  ERROR [%0t] frame %0d delivered good but damaged (%0d bytes, sent %0d)",
                     $realtime, seq, got.size(), sd.size());
            test_errors++;
        end
        return;
    end
    if (exp_q.size() == 0) begin
        $display("  ERROR [%0t] unexpected frame (%0d bytes)", $realtime, got.size());
        test_errors++;
        return;
    end
    e = exp_q.pop_front();
    void'(exp_ts_q.pop_front());
    if (!bytes_eq(got, e.d)) begin
        if (test_errors < 20)
            $display("  ERROR [%0t] frame %0d: got %0d bytes, expected %0d (or data differs)",
                     $realtime, n_out, got.size(), e.d.size());
        test_errors++;
    end
    if (bad != e.err) begin
        if (test_errors < 20)
            $display("  ERROR [%0t] frame %0d (%0d bytes): bad-frame flag %0d, expected %0d",
                     $realtime, n_out, e.d.size(), bad, e.err);
        test_errors++;
    end
endtask

always @(posedge clk) begin
    if (m_tvalid && m_tready) begin
        automatic bit gap = 0;
        for (int i = 0; i < 64; i++) begin
            if (m_tkeep[i]) begin
                if (gap) begin
                    $display("  ERROR [%0t] non-contiguous tkeep %h", $realtime, m_tkeep);
                    test_errors++;
                end
                cur.push_back(m_tdata[i*8 +: 8]);
            end else begin
                gap = 1;
            end
        end
        if (!m_tlast && m_tkeep != '1) begin
            $display("  ERROR [%0t] partial tkeep on a non-last beat", $realtime);
            test_errors++;
        end
        if (m_tkeep == '0) begin
            $display("  ERROR [%0t] empty beat", $realtime);
            test_errors++;
        end
        if (!m_tlast && m_tuser[0]) begin
            $display("  ERROR [%0t] tuser[0] set on a non-last beat", $realtime);
            test_errors++;
        end
        // timestamp: identical on every beat of a frame and equal to the frame's
        // (in the lossy phase a frame that lost its TLAST beat merges with the
        // next one and changes timestamp; it is always delivered bad)
        if (cur.size() <= 64) begin
            cur_ts = m_tuser[48:1];
            ts_changed = 0;
        end else if (m_tuser[48:1] != cur_ts) begin
            ts_changed = 1;
        end
        if (m_tlast && ts_changed && !m_tuser[0]) begin
            $display("  ERROR [%0t] timestamp changed inside a good frame (%h -> %h)", $realtime, cur_ts, m_tuser[48:1]);
            test_errors++;
        end
        if (!lossy && exp_ts_q.size() > 0) begin
            automatic logic [54:0] ets = exp_ts_q[0];
            automatic logic [47:0] gts = m_tuser[48:1];
            if (gts !== ets[54:7]) begin
                if (test_errors < 20)
                    $display("  ERROR [%0t] frame %0d: timestamp %h, expected %h", $realtime, n_out, gts, ets[54:7]);
                test_errors++;
            end
        end
        if (m_tlast) begin
            check_frame(cur, m_tuser[0]);
            n_out++;
            if (m_tuser[0]) n_out_bad++;
            cur = {};
        end
    end
end

// ---------------------------------------------------------------------------
// MRMAC client model
// ---------------------------------------------------------------------------
task automatic drive_idle();
    rx_tvalid <= 1'b0;
    for (int l = 0; l < 6; l++) begin
        tdata[l]      <= {$urandom, $urandom};
        tkeep_user[l] <= 11'($urandom);
    end
    rx_tlast <= $urandom % 2;
    rx_ts    <= {$urandom, $urandom};
    @(posedge clk);
endtask

task automatic send_frame(bytes_t d, bit err, int gap_pct = 0, int seqn = -1);
    int pos = 0;
    frm_t e;
    e.d = d;
    e.err = err;
    e.ts = {$urandom, $urandom};
    if (seqn >= 0) sent_ts_by_seq[seqn] = e.ts;
    if (!lossy) begin
        exp_q.push_back(e);
        exp_ts_q.push_back(e.ts);
    end
    while (pos < d.size()) begin
        int n = (d.size() - pos) > 48 ? 48 : (d.size() - pos);
        bit last = (pos + 48) >= d.size();
        if (gap_pct > 0 && ($urandom % 100) < gap_pct) begin
            drive_idle();
            continue;
        end
        for (int l = 0; l < 6; l++) begin
            logic [63:0] w = {$urandom, $urandom};
            logic [7:0]  k = '0;
            for (int b = 0; b < 8; b++) begin
                if (l*8 + b < n) begin
                    w[b*8 +: 8] = d[pos + l*8 + b];
                    k[b] = 1'b1;
                end
            end
            tdata[l] <= w;
            // Err is only meaningful with tlast; mid-frame control words are undefined
            tkeep_user[l] <= last ? {2'b00, err, k} : 11'($urandom);
        end
        rx_tlast  <= last;
        rx_tvalid <= 1'b1;
        rx_ts     <= (pos == 0) ? e.ts : 55'({$urandom, $urandom});
        @(posedge clk);
        pos += 48;
    end
endtask

function automatic bytes_t mkframe(int n, int seed);
    bytes_t d;
    for (int i = 0; i < n; i++) d.push_back(byte'((i * 7 + seed * 13 + (i >> 8)) & 8'hFF));
    // sequence number in the first 4 bytes (lossy-mode matching)
    for (int i = 0; i < 4 && i < n; i++) d[i] = byte'(seed >> (8 * i));
    return d;
endfunction

task automatic finish_test(int id, string name);
    repeat (100) drive_idle();
    if (exp_q.size() != 0) begin
        $display("  ERROR %0d expected frame(s) never arrived", exp_q.size());
        test_errors++;
        exp_q.delete();
        exp_ts_q.delete();
    end
    if (test_errors == 0) begin
        $display("PASS: test %0d %s", id, name);
        total_pass++;
    end else begin
        $display("FAIL: test %0d %s (%0d errors)", id, name, test_errors);
        total_fail++;
    end
    test_errors = 0;
endtask

initial begin
    automatic int seq = 0;
    process::self().srandom(20260924);
    repeat (8) @(posedge clk);
    aresetn <= 1'b1;
    repeat (8) @(posedge clk);

    // ---- test 13 ----
    $display("[%0t] ---- test 13 rx_packer_directed", $realtime);
    for (int n = 1; n <= 200; n++) begin
        send_frame(mkframe(n, seq), (n % 7) == 3);
        seq++;
    end
    for (int k = 1; k <= 188; k += (k < 8 ? 1 : 17)) begin
        send_frame(mkframe(48 * k, seq), 1'b0); seq++;
        send_frame(mkframe(48 * k, seq), 1'b1); seq++;
    end
    // A (multi-beat, ends on any residue) - B (single beat) - C, no idle cycles
    for (int a = 49; a <= 240; a++) begin
        send_frame(mkframe(a, seq), (a % 5) == 0); seq++;
        send_frame(mkframe(1 + (a % 48), seq), (a % 3) == 0); seq++;
        send_frame(mkframe(60 + (a % 100), seq), 1'b0); seq++;
    end
    // runs of single-beat frames after a "full + flush" frame end
    for (int a = 0; a < 16; a++) begin
        send_frame(mkframe(96 + 16 + a, seq), 1'b0); seq++;     // r = 48 + tail > 64
        for (int b = 0; b < 10; b++) begin
            send_frame(mkframe(1 + ((a * 10 + b) % 48), seq), 1'b0); seq++;
        end
    end
    finish_test(13, "rx_packer_directed");

    // ---- test 14 ----
    $display("[%0t] ---- test 14 rx_packer_random", $realtime);
    for (int i = 0; i < 6000; i++) begin
        automatic int r = $urandom % 100;
        automatic int n = (r < 30) ? 1 + $urandom % 48 :
                (r < 60) ? 49 + $urandom % 150 :
                (r < 85) ? 60 + $urandom % 1455 :
                (r < 95) ? 1 + $urandom % 9000 :
                           48 * (1 + $urandom % 187);
        send_frame(mkframe(n, seq), ($urandom % 5) == 0, ($urandom % 8 == 0) ? 5 : 0);
        seq++;
        if ($urandom % 10 == 0) drive_idle();
    end
    finish_test(14, "rx_packer_random");
    if (n_stall != 0 || n_ovf != 0) begin
        $display("  ERROR stall/overflow reported with tready always high (%0d/%0d)", n_stall, n_ovf);
        total_fail++;
    end

    // ---- test 20 ----
    $display("[%0t] ---- test 20 rx_packer_backpressure", $realtime);
    // (a) short tready drops, well inside the FIFO: lossless
    fork
        begin
            for (int i = 0; i < 1500; i++) begin
                send_frame(mkframe(1 + $urandom % 1600, seq), ($urandom % 5) == 0);
                seq++;
                // keep the average output rate below one beat per cycle so the
                // short tready drops can be caught up (back-to-back 1-beat frames
                // produce one output per input cycle and could never catch up)
                repeat ($urandom % 3) drive_idle();
            end
            drive_idle();
        end
        begin
            for (int c = 0; c < 400000; c++) begin
                @(posedge clk);
                // drop tready for 1..3 cycles about every 40 cycles
                if ($urandom % 40 == 0) begin
                    m_tready <= 1'b0;
                    repeat (1 + $urandom % 3) @(posedge clk);
                    m_tready <= 1'b1;
                end
                if (exp_q.size() == 0 && !rx_tvalid) break;
            end
            m_tready <= 1'b1;
        end
    join
    wait (exp_q.size() == 0);
    m_tready <= 1'b1;
    repeat (50) drive_idle();
    if (n_stall == 0) begin
        $display("  ERROR no STALL reported under back-pressure");
        test_errors++;
    end
    if (n_ovf != 0) begin
        $display("  ERROR overflow reported for short tready drops (%0d)", n_ovf);
        test_errors++;
    end
    // (b) long tready-low stretches: overflow, damaged frames must be marked bad
    lossy = 1;
    lossy_next = seq;
    n_out_bad = 0;
    fork
        begin
            for (int i = 0; i < 3000; i++) begin
                automatic int n = 8 + $urandom % 700;
                automatic bytes_t d = mkframe(n, seq);
                automatic bit e = ($urandom % 10) == 0;
                sent_by_seq[seq] = d;
                sent_err_by_seq[seq] = e;
                send_frame(d, e, 0, seq);
                seq++;
            end
            drive_idle();
        end
        begin
            forever begin
                @(posedge clk);
                if ($urandom % 200 == 0) begin
                    m_tready <= 1'b0;
                    repeat (5 + $urandom % 60) @(posedge clk);
                    m_tready <= 1'b1;
                end
            end
        end
    join_any
    disable fork;
    m_tready <= 1'b1;
    repeat (100) drive_idle();
    $display("  lossy phase: %0d frames out, %0d marked bad, overflow events %0d", n_out, n_out_bad, n_ovf);
    if (n_ovf == 0) begin
        $display("  ERROR no overflow reported although tready was held low");
        test_errors++;
    end
    lossy = 0;
    // (c) recovery: lossless again
    for (int i = 0; i < 200; i++) begin
        send_frame(mkframe(1 + $urandom % 500, seq), 1'b0);
        seq++;
    end
    finish_test(20, "rx_packer_backpressure");

    $display("SUMMARY: %0d passed, %0d failed", total_pass, total_fail);
    if (total_fail == 0 && total_pass > 0)
        $display("ALL TESTS PASSED");
    else
        $display("TESTS FAILED");
    $finish;
end

initial begin
    #50ms;
    $display("TESTS FAILED: global timeout");
    $finish;
end

endmodule

`default_nettype wire

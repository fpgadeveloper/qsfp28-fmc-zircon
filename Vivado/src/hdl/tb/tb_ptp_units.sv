// SPDX-License-Identifier: MIT
//
// tb_ptp_units - xsim unit testbench of the 1.3.0 PTP helpers:
//   23 tx_adapter_ptp_sideband  mrmac_tx_axis_adapter s_axis_ptp: every frame's
//        {op, tag} is driven from the cycle its first beat is presented until
//        its TLAST beat is accepted, 0 between frames; records that arrive
//        n_before the frame, a few cycles after its first beat (the frame waits,
//        never inside a frame) or never (underrun after SOF_WAIT: op 0, sticky
//        ptp_underrun, the frame still goes out) - with random source gaps and
//        MRMAC tready; data passes unchanged; aresetn mid-frame recovers
//   24 ptp_systimer              +INCR per ts_clk cycle, periodic st_sync
//        (mode 1), a pulse per sync_req rising edge, one pulse (mode 0),
//        st_overwrite / st_adjust levels
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).

`timescale 1ns / 1ps
`default_nettype none

module tb_ptp_units;

localparam int SOF_WAIT = 8;

logic clk = 1'b0;
always #1.28 clk = ~clk;
logic aresetn = 1'b0;

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

// ---------------------------------------------------------------------------
// mrmac_tx_axis_adapter
// ---------------------------------------------------------------------------
logic [383:0] s_tdata = '0;
logic [47:0]  s_tkeep = '0;
logic         s_tlast = 1'b0, s_tvalid = 1'b0;
wire          s_tready;
logic [23:0]  p_tdata = '0;
logic         p_tvalid = 1'b0;
wire          p_tready;
wire [63:0]   td [6];
wire [10:0]   tk [6];
wire          m_tlast, m_tvalid;
logic         m_tready = 1'b1;
wire [1:0]    op;
wire [15:0]   tag;
wire          underrun;

mrmac_tx_axis_adapter #(.SOF_WAIT(SOF_WAIT)) adapter (
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tlast(s_tlast),
    .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .s_axis_ptp_tdata(p_tdata), .s_axis_ptp_tvalid(p_tvalid), .s_axis_ptp_tready(p_tready),
    .tx_axis_tdata0(td[0]), .tx_axis_tdata1(td[1]), .tx_axis_tdata2(td[2]),
    .tx_axis_tdata3(td[3]), .tx_axis_tdata4(td[4]), .tx_axis_tdata5(td[5]),
    .tx_axis_tkeep_user0(tk[0]), .tx_axis_tkeep_user1(tk[1]), .tx_axis_tkeep_user2(tk[2]),
    .tx_axis_tkeep_user3(tk[3]), .tx_axis_tkeep_user4(tk[4]), .tx_axis_tkeep_user5(tk[5]),
    .tx_axis_tlast(m_tlast), .tx_axis_tvalid(m_tvalid), .tx_axis_tready(m_tready),
    .tx_ptp_1588op_in(op), .tx_ptp_tag_field_in(tag), .ptp_underrun(underrun),
    .aclk(clk), .aresetn(aresetn)
);

// frame plan: per frame its beats, record and how the record arrives
typedef enum int { EARLY, LATE, MISSING } rmode_t;
typedef struct {
    int          beats;
    logic [17:0] rec;         // {tag, op}
    rmode_t      mode;
    int          late;        // LATE: cycles after the first beat is presented
} plan_t;

plan_t   plan[$];
int      n_frames = 0;
int      src_frame = 0;       // frame index the source is presenting / about to present
longint  sof_present_t[int];  // cycle count at which frame i's first beat was presented
int      mon_frame = 0, mon_pos = 0;   // MRMAC side monitor position
bit      mon_in = 0;
longint  cyc = 0;
bit      src_random = 1;
bit      rdy_random = 1;
int      exp_missing = 0;

always @(posedge clk) cyc++;

// data source (AXIS-compliant: tvalid held until the handshake)
logic [383:0] beat_data [int][int];
int  pos = 0;          // source beat within frame src_frame
int  ptp_i = 0;        // next record to send
bit  hold_all = 0;     // freeze both sources (reset scenario)
initial begin
    forever begin
        @(posedge clk);
        if (hold_all) continue;
        if (s_tvalid && s_tready) begin
            s_tvalid <= 1'b0;
            if (s_tlast) begin
                src_frame++;
                pos = 0;
            end else begin
                pos++;
            end
        end else if (s_tvalid) begin
            continue;
        end
        if (src_frame < plan.size() && aresetn && (!src_random || $urandom % 4 != 0)) begin
            logic [383:0] d;
            for (int i = 0; i < 12; i++) d[i*32 +: 32] = $urandom;
            beat_data[src_frame][pos] = d;
            s_tdata  <= d;
            s_tkeep  <= (pos == plan[src_frame].beats - 1) ? 48'h0000_FFFF_FFFF : '1;
            s_tlast  <= pos == plan[src_frame].beats - 1;
            s_tvalid <= 1'b1;
            if (pos == 0 && !sof_present_t.exists(src_frame)) sof_present_t[src_frame] = cyc + 1;
        end
    end
end

// PTP record source: in frame order. A missing record is skipped only once its
// frame has started at the MRMAC side, so the next record cannot be taken for it.
initial begin
    forever begin
        @(posedge clk);
        if (hold_all) continue;
        if (p_tvalid && p_tready) begin
            p_tvalid <= 1'b0;
            ptp_i++;
        end else if (p_tvalid) begin
            continue;
        end
        while (ptp_i < plan.size() && plan[ptp_i].mode == MISSING && (mon_frame > ptp_i || (mon_frame == ptp_i && mon_in))) ptp_i++;
        if (ptp_i < plan.size() && plan[ptp_i].mode != MISSING) begin
            bit go = (plan[ptp_i].mode == EARLY && (ptp_i == 0 || src_frame >= ptp_i - 1)) ||
                     (plan[ptp_i].mode == LATE && sof_present_t.exists(ptp_i) && cyc >= sof_present_t[ptp_i] + plan[ptp_i].late);
            if (go) begin
                p_tdata  <= {6'd0, plan[ptp_i].rec};
                p_tvalid <= 1'b1;
            end
        end
    end
end


always @(posedge clk) begin
    m_tready <= !rdy_random || ($urandom % 3 != 0);
    if (!aresetn) begin
        mon_in = 0;
        mon_pos = 0;
    end else begin
        logic [17:0] e;
        e = (mon_frame < plan.size() && plan[mon_frame].mode != MISSING) ? plan[mon_frame].rec : 18'd0;
        if (m_tvalid || mon_in) begin
            if ({tag, op} != e) begin
                if (test_errors < 10)
                    $display("  ERROR [%0t] frame %0d beat %0d: op/tag %h, expected %h", $realtime, mon_frame, mon_pos, {tag, op}, e);
                test_errors++;
            end
        end else if (op != 0 || tag != 0) begin
            $display("  ERROR [%0t] op/tag %h between frames", $realtime, {tag, op});
            test_errors++;
        end
        if (m_tvalid && m_tready) begin
            logic [383:0] d = {td[5], td[4], td[3], td[2], td[1], td[0]};
            if (!beat_data.exists(mon_frame) || !beat_data[mon_frame].exists(mon_pos) || d != beat_data[mon_frame][mon_pos]) begin
                $display("  ERROR [%0t] frame %0d beat %0d data mismatch", $realtime, mon_frame, mon_pos);
                test_errors++;
            end
            if (mon_pos == 0 && plan[mon_frame].mode == LATE && cyc < sof_present_t[mon_frame] + plan[mon_frame].late) begin
                $display("  ERROR [%0t] frame %0d left n_before its late record", $realtime, mon_frame);
                test_errors++;
            end
            mon_in = !m_tlast;
            if (m_tlast) begin
                mon_frame++;
                mon_pos = 0;
            end else begin
                mon_pos++;
            end
        end
    end
end

task automatic add_frames(int n, int pct_late, int pct_missing);
    for (int k = 0; k < n; k++) begin
        plan_t p;
        int r = $urandom % 100;
        p.beats = 1 + $urandom % 6;
        p.rec = {16'(plan.size() * 7 + 1), ($urandom % 2) ? 2'b10 : 2'b00};
        p.mode = (r < pct_missing) ? MISSING : (r < pct_missing + pct_late) ? LATE : EARLY;
        p.late = 1 + $urandom % (SOF_WAIT - 2);
        if (p.mode == MISSING) exp_missing++;
        plan.push_back(p);
    end
endtask

// ---------------------------------------------------------------------------
// ptp_systimer
// ---------------------------------------------------------------------------
logic ts_clk = 1'b0;
always #2.0 ts_clk = ~ts_clk;
logic ts_aresetn = 1'b0;
logic sync_req = 1'b0;

wire [54:0] st1_timer, st1_tx, st1_rx, st0_timer;
wire        st1_sync, st1_rsync, st1_ow, st0_sync;
wire [31:0] st1_adj;
wire [1:0]  st1_adj_t;
wire        st1_adj_v;

ptp_systimer #(.SYNC_MODE(1), .SYNC_PERIOD(50)) systimer1 (
    .ts_clk(ts_clk), .ts_aresetn(ts_aresetn), .sync_req(sync_req),
    .systimer(st1_timer), .ctl_tx_ptp_systemtimer(st1_tx), .ctl_rx_ptp_systemtimer(st1_rx),
    .ctl_tx_ptp_st_sync(st1_sync), .ctl_rx_ptp_st_sync(st1_rsync),
    .ctl_tx_ptp_st_overwrite(st1_ow), .ctl_rx_ptp_st_overwrite(),
    .ctl_tx_ptp_st_adjust(st1_adj), .ctl_rx_ptp_st_adjust(),
    .ctl_tx_ptp_st_adjust_type(st1_adj_t), .ctl_rx_ptp_st_adjust_type(),
    .ctl_tx_ptp_st_adjust_vld(st1_adj_v), .ctl_rx_ptp_st_adjust_vld()
);

ptp_systimer #(.SYNC_MODE(0), .SYNC_DELAY(20)) systimer0 (
    .ts_clk(ts_clk), .ts_aresetn(ts_aresetn), .sync_req(1'b0),
    .systimer(st0_timer), .ctl_tx_ptp_systemtimer(), .ctl_rx_ptp_systemtimer(),
    .ctl_tx_ptp_st_sync(st0_sync), .ctl_rx_ptp_st_sync(),
    .ctl_tx_ptp_st_overwrite(), .ctl_rx_ptp_st_overwrite(),
    .ctl_tx_ptp_st_adjust(), .ctl_rx_ptp_st_adjust(),
    .ctl_tx_ptp_st_adjust_type(), .ctl_rx_ptp_st_adjust_type(),
    .ctl_tx_ptp_st_adjust_vld(), .ctl_rx_ptp_st_adjust_vld()
);

int st_cyc = 0, st1_pulses = 0, st0_pulses = 0, st1_last = -1, st1_gap_bad = 0;
int st1_extra = 0;
logic [54:0] st1_prev = '0;
bit st_check = 0;
always @(posedge ts_clk) begin
    st_cyc++;
    if (st_check) begin
        if (st1_timer != st1_prev + 55'd1024 || st1_tx != st1_timer || st1_rx != st1_timer) begin
            $display("  ERROR [%0t] systimer %h after %h (tx %h rx %h)", $realtime, st1_timer, st1_prev, st1_tx, st1_rx);
            test_errors++;
        end
        if (st1_sync != st1_rsync || st1_ow !== 1'b1 || st1_adj != 0 || st1_adj_t != 0 || st1_adj_v != 0) begin
            $display("  ERROR [%0t] systimer control outputs", $realtime);
            test_errors++;
        end
        if (st1_sync) begin
            if (st1_last >= 0 && st_cyc - st1_last != 50) st1_extra++;
            st1_pulses++;
            st1_last = st_cyc;
        end
        if (st0_sync) st0_pulses++;
    end
    st1_prev = st1_timer;
end

// ---------------------------------------------------------------------------
initial begin
    process::self().srandom(20260925);
    repeat (10) @(posedge clk);
    aresetn = 1'b1;

    // ---- test 23 ----
    $display("[%0t] ---- test 23 tx_adapter_ptp_sideband", $realtime);
    add_frames(400, 30, 0);          // early and late records, random gaps / tready
    while (mon_frame != plan.size()) @(posedge clk);
    if (underrun) begin
        $display("  ERROR ptp_underrun set without a missing record");
        test_errors++;
    end
    add_frames(200, 20, 10);         // plus missing records: op 0, underrun sticky
    while (mon_frame != plan.size()) @(posedge clk);
    if (!underrun) begin
        $display("  ERROR ptp_underrun not set after %0d missing records", exp_missing);
        test_errors++;
    end
    // back to back, no gaps, MRMAC always ready: early records only
    src_random = 0;
    rdy_random = 0;
    add_frames(100, 0, 0);
    while (mon_frame != plan.size()) @(posedge clk);
    // aresetn in the middle of a frame: the next frame gets its record again
    src_random = 1;
    rdy_random = 1;
    add_frames(3, 0, 0);
    while (!mon_in) @(posedge clk);
    @(posedge clk);
    hold_all = 1;
    @(posedge clk);
    aresetn <= 1'b0;
    s_tvalid <= 1'b0;
    p_tvalid <= 1'b0;
    repeat (3) @(posedge clk);
    // drop the interrupted frame and its successors from the plan; restart cleanly
    begin
        int cut = mon_frame;
        plan = plan[0:cut-1];
        src_frame = cut;
        pos = 0;
        ptp_i = cut;
        for (int k = cut; k < cut + 4; k++) if (sof_present_t.exists(k)) sof_present_t.delete(k);
    end
    aresetn <= 1'b1;
    @(posedge clk);
    hold_all = 0;
    if (underrun) begin
        $display("  ERROR ptp_underrun not cleared by aresetn");
        test_errors++;
    end
    add_frames(50, 30, 0);
    while (mon_frame != plan.size()) @(posedge clk);
    repeat (20) @(posedge clk);
    $display("  %0d frames, %0d with a missing record", plan.size(), exp_missing);
    finish_test(23, "tx_adapter_ptp_sideband");

    // ---- test 24 ----
    $display("[%0t] ---- test 24 ptp_systimer", $realtime);
    @(posedge ts_clk);
    ts_aresetn <= 1'b1;
    repeat (8) @(posedge ts_clk);
    st_check = 1;
    repeat (300) @(posedge ts_clk);
    if (st1_pulses < 5 || st1_extra != 0 || st0_pulses != 1) begin
        $display("  ERROR sync pulses: mode 1 %0d (irregular %0d), mode 0 %0d", st1_pulses, st1_extra, st0_pulses);
        test_errors++;
    end
    begin
        int n_before = st1_pulses;
        @(posedge ts_clk);
        sync_req <= 1'b1;
        repeat (10) @(posedge ts_clk);
        sync_req <= 1'b0;
        repeat (10) @(posedge ts_clk);
        // the request adds exactly one pulse (unless it coincided with a periodic one)
        if (st1_pulses - n_before < 1 || st1_pulses - n_before > 2) begin
            $display("  ERROR sync_req: %0d pulses", st1_pulses - n_before);
            test_errors++;
        end
    end
    $display("  mode 1: %0d periodic pulses (period 50), mode 0: %0d pulse", st1_pulses, st0_pulses);
    st_check = 0;
    finish_test(24, "ptp_systimer");

    $display("SUMMARY: %0d passed, %0d failed", total_pass, total_fail);
    if (total_fail == 0 && total_pass > 0)
        $display("ALL TESTS PASSED");
    else
        $display("TESTS FAILED");
    $finish;
end

initial begin
    #5ms;
    $display("TESTS FAILED: global timeout (mon_frame %0d src_frame %0d ptp_i %0d plan %0d p_tvalid %0d s_tvalid %0d m_tvalid %0d pos %0d)",
             mon_frame, src_frame, ptp_i, plan.size(), p_tvalid, s_tvalid, m_tvalid, pos);
    $finish;
end

endmodule

`default_nettype wire

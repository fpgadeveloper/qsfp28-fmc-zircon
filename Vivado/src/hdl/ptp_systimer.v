// SPDX-License-Identifier: MIT
//
// ptp_systimer - free-running 55-bit PTP system timer for the Versal MRMAC
// 1588 timestamping (qsfp28-fmc-zircon 1.3.0 latency measurement).
//
// qsfp28-fmc-zircon reference design (Opsero 2x QSFP28 FMC, VCK190).
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// One instance, clocked by the MRMAC timestamp clock ts_clk (250 MHz, the
// TIMESTAMP_CLK_PERIOD_NS = 4.0 setting of the MRMAC IP), feeds every MRMAC port
// that timestamps (TX and RX of both MRMACs): the zircon_nic latency statistics
// only use differences tx_ts - rx_ts, so any timer that advances at 1 ns/ns and
// is common to both directions gives exact results; no time-of-day is needed.
//
// The counter counts in the MRMAC timestamp unit, 2^-8 ns (the 55 bits the MRMAC
// exposes on ctl_*_ptp_systemtimer / *_ptp_tstamp_out are bits [62:8] of a
// correction-field value), adding INCR every ts_clk cycle: INCR = period_ns *
// 256 = 1024 for 250 MHz. It wraps after 2^47 ns (39 h); users subtract modulo.
//
// MRMAC timer interface (PG314 "PTP TIMESTAMP Interface" / "Time Representation";
// ports ctl_{tx,rx}_ptp_systemtimer_<n>[54:0], _st_sync_<n>, _st_overwrite_<n>,
// _st_adjust_<n>[31:0], _st_adjust_type_<n>[1:0], _st_adjust_vld_<n>, all on
// TX_TS_CLK / RX_TS_CLK = ts_clk). UNCERTAINTY: the "Timer Operation" section of
// PG314 was not available when this was written. Best understanding (from the
// generated IP and AMD's example design, which ties st_overwrite = 1 and pulses
// st_sync from its timer_syncer): with st_overwrite = 1 the MRMAC loads its
// internal timer from ctl_*_ptp_systemtimer on an st_sync pulse and then runs
// from its own increment, which it derives from the sync interval (read back in
// MONITOR_{TX,RX}_1588_INCR_SYSTIMER). The protocol is therefore parameterised,
// so the block design / bench can change it without an RTL edit:
//   SYNC_MODE 0  one st_sync pulse SYNC_DELAY cycles after reset release
//             1  a pulse every SYNC_PERIOD cycles (default: 250000 = 1 ms)
//             2  st_sync held high (the timer is sampled every cycle)
//   plus a pulse on every rising edge of sync_req (asynchronous input, e.g. a
//   GPIO bit; tie 0 when unused), in every mode.
//   SYNC_LEN   st_sync pulse length in ts_clk cycles (modes 0 / 1 / sync_req)
//   OVERWRITE  value driven on st_overwrite (1 = load the timer at st_sync)
// st_adjust* are driven 0 (no frequency / phase adjustment). Bench check: the
// MRMAC STAT_{TX,RX}_1588_TOD / MONITOR_*_INCR registers should advance at
// 1 ns per ns (INCR = 4 ns for 250 MHz); zircon_nic's LAT deltas of a HW echo
// should be a stable ~1 us, not random or stuck.

`timescale 1ns / 1ps

module ptp_systimer #(
    parameter [54:0]  INCR        = 55'd1024,   // timer units (2^-8 ns) per ts_clk cycle
    parameter integer SYNC_MODE   = 1,          // 0 once, 1 periodic, 2 held high
    parameter integer SYNC_DELAY  = 64,         // mode 0: cycles after reset release
    parameter integer SYNC_PERIOD = 250000,     // mode 1: cycles between pulses (>= 4)
    parameter integer SYNC_LEN    = 1,          // pulse length (cycles, >= 1)
    parameter         OVERWRITE   = 1'b1        // st_overwrite level
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ts_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET ts_aresetn" *)
    input  wire        ts_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ts_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        ts_aresetn,

    input  wire        sync_req,                // asynchronous: a rising edge forces an st_sync pulse

    output wire [54:0] systimer,                // the timer (ts_clk domain)

    // to the MRMAC (port 0 of each MRMAC; the same value drives TX and RX)
    output wire [54:0] ctl_tx_ptp_systemtimer,
    output wire [54:0] ctl_rx_ptp_systemtimer,
    output wire        ctl_tx_ptp_st_sync,
    output wire        ctl_rx_ptp_st_sync,
    output wire        ctl_tx_ptp_st_overwrite,
    output wire        ctl_rx_ptp_st_overwrite,
    output wire [31:0] ctl_tx_ptp_st_adjust,
    output wire [31:0] ctl_rx_ptp_st_adjust,
    output wire [1:0]  ctl_tx_ptp_st_adjust_type,
    output wire [1:0]  ctl_rx_ptp_st_adjust_type,
    output wire        ctl_tx_ptp_st_adjust_vld,
    output wire        ctl_rx_ptp_st_adjust_vld
);

reg [54:0] timer_reg = 55'd0;
reg        sync_reg  = 1'b0;

// synchronised reset and sync request
reg [2:0]  rst_sr = 3'b111;
wire       rst = rst_sr[2];
(* ASYNC_REG = "TRUE" *) reg [1:0] req_sr = 2'b00;
reg        req_d = 1'b0;

always @(posedge ts_clk or negedge ts_aresetn) begin
    if (!ts_aresetn) rst_sr <= 3'b111;
    else             rst_sr <= {rst_sr[1:0], 1'b0};
end

reg [31:0] cnt = 32'd0;          // mode 0: delay counter; mode 1: period counter
reg        once_done = 1'b0;
reg [15:0] len_cnt = 16'd0;      // remaining pulse cycles

wire req_edge = req_sr[1] && !req_d;
wire trig = req_edge ||
            (SYNC_MODE == 0 && !once_done && cnt == SYNC_DELAY - 1) ||
            (SYNC_MODE == 1 && cnt == SYNC_PERIOD - 1);

always @(posedge ts_clk) begin
    timer_reg <= timer_reg + INCR;

    req_sr <= {req_sr[0], sync_req};
    req_d  <= req_sr[1];

    if (SYNC_MODE == 1) begin
        cnt <= (cnt == SYNC_PERIOD - 1) ? 32'd0 : cnt + 32'd1;
    end else if (SYNC_MODE == 0 && !once_done) begin
        cnt <= cnt + 32'd1;
        if (cnt == SYNC_DELAY - 1) once_done <= 1'b1;
    end

    if (trig) begin
        len_cnt <= SYNC_LEN[15:0];
    end else if (len_cnt != 16'd0) begin
        len_cnt <= len_cnt - 16'd1;
    end
    sync_reg <= (SYNC_MODE == 2) ? 1'b1 : (trig || len_cnt > 16'd1);

    if (rst) begin
        timer_reg <= 55'd0;
        cnt       <= 32'd0;
        once_done <= 1'b0;
        len_cnt   <= 16'd0;
        sync_reg  <= 1'b0;
        req_d     <= 1'b1;   // no pulse for a request level held through reset
    end
end

assign systimer                  = timer_reg;
assign ctl_tx_ptp_systemtimer    = timer_reg;
assign ctl_rx_ptp_systemtimer    = timer_reg;
assign ctl_tx_ptp_st_sync        = sync_reg;
assign ctl_rx_ptp_st_sync        = sync_reg;
assign ctl_tx_ptp_st_overwrite   = OVERWRITE;
assign ctl_rx_ptp_st_overwrite   = OVERWRITE;
assign ctl_tx_ptp_st_adjust      = 32'd0;
assign ctl_rx_ptp_st_adjust      = 32'd0;
assign ctl_tx_ptp_st_adjust_type = 2'd0;
assign ctl_rx_ptp_st_adjust_type = 2'd0;
assign ctl_tx_ptp_st_adjust_vld  = 1'b0;
assign ctl_rx_ptp_st_adjust_vld  = 1'b0;

endmodule

// SPDX-License-Identifier: MIT
//
// ts_gray_sync - carries a free-running binary counter (a timestamp tick count, or a
// clock-measurement counter) from its clock domain into an unrelated one with a
// Gray-code crossing.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// This file is part of the Opsero qsfp28-fmc-zircon reference design and is
// licensed under the MIT license (see LICENSE at the repo root).
//
//   src_clk   gray_reg <= src_bin ^ (src_bin >> 1)   (registered, nothing between it
//             and the first synchroniser stage)
//   dst_clk   sync1 -> sync2 (ASYNC_REG), then Gray -> binary over three pipelined
//             stages (the top, middle and bottom thirds of the word), registered out.
//
// Latency: 1 src_clk cycle + 5 dst_clk cycles (+ up to one dst_clk cycle of sampling
// phase). It is the same in every instance, so when two instances with equal dst_clk
// frequency are compared (the CMAC TX and RX timestamps) the fixed part cancels.
// src_bin must advance by at most one per src_clk cycle (a counter) for the Gray
// property to hold; a reset of the counter is a one-time discontinuity.
//
// Timing constraints (implementation): Vivado/src/constraints/zircon_cmac_us.tcl
// (set_max_delay -datapath_only / set_bus_skew from gray_reg to sync1_reg, selected by
// ORIG_REF_NAME == ts_gray_sync).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ts_gray_sync #(
    parameter int W = 45
) (
    input  wire logic          src_clk,
    input  wire logic [W-1:0]  src_bin,

    input  wire logic          dst_clk,
    output wire logic [W-1:0]  dst_bin
);

localparam int S = (W + 2) / 3;         // bits per conversion stage (top stage first)

// ---- source domain ----
(* keep = "true" *)
logic [W-1:0] gray_reg = '0;

always_ff @(posedge src_clk) begin
    gray_reg <= src_bin ^ (src_bin >> 1);
end

// ---- destination domain: two-stage synchroniser ----
(* async_reg = "true", shreg_extract = "no" *)
logic [W-1:0] sync1_reg = '0;
(* async_reg = "true", shreg_extract = "no" *)
logic [W-1:0] sync2_reg = '0;

always_ff @(posedge dst_clk) begin
    sync1_reg <= gray_reg;
    sync2_reg <= sync1_reg;
end

// ---- Gray -> binary, three pipelined stages ----
// bin[i] = XOR of gray[W-1:i]. Stage 1 resolves bits [W-1 : W-S], stage 2 the next S
// bits (seeded with stage 1's lowest binary bit), stage 3 the rest.
localparam int HI1 = W - 1;
localparam int LO1 = (W - S > 0) ? W - S : 0;
localparam int HI2 = LO1 - 1;
localparam int LO2 = (LO1 - S > 0) ? LO1 - S : 0;
localparam int HI3 = LO2 - 1;

logic [W-1:0] p1_reg = '0;   // [HI1:LO1] binary, rest still Gray
logic [W-1:0] p2_reg = '0;   // [HI1:LO2] binary
logic [W-1:0] p3_reg = '0;   // all binary

always_ff @(posedge dst_clk) begin : conv
    logic [W-1:0] t;
    // stage 1
    t = sync2_reg;
    for (int i = HI1 - 1; i >= LO1; i--) t[i] = t[i+1] ^ sync2_reg[i];
    p1_reg <= t;
    // stage 2
    t = p1_reg;
    for (int i = HI2; i >= LO2; i--) t[i] = t[i+1] ^ p1_reg[i];
    p2_reg <= t;
    // stage 3
    t = p2_reg;
    for (int i = HI3; i >= 0; i--) t[i] = t[i+1] ^ p2_reg[i];
    p3_reg <= t;
end

assign dst_bin = p3_reg;

endmodule

`resetall

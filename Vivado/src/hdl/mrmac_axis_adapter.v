// ---------------------------------------------------------------------------
// MRMAC 1x100GE CAUI-4 client TX adapter: standard AXI4-Stream -> MRMAC lanes
//
// Opsero 2x QSFP28 FMC reference design.
//
// The Versal MRMAC 100G "Independent 384b Non-Segmented" client is NOT a
// standard AXI4-Stream bus. In a block design its axis_tx_port0 interface is
// handshake-only (TVALID/TLAST/TREADY, TDATA_NUM_BYTES=0). The 384-bit data
// rides on six separate 64-bit lane ports (tx_axis_tdata0..5) plus six per-lane
// tkeep_user0..5[10:0] control words. This adapter splits a standard 384-bit
// AXIS stream (from the 512->384 axis_dwidth_converter) into those lanes.
//
// tkeep_user<M>[10:0] (PG, per 64-bit lane):
//   [7:0] = tkeep (per-byte valid, only meaningful on the TLAST beat)
//   [8]   = Err     (RX only)
//   [9]   = Preempt
//   [10]  = Resume  (TX preemption; unused here)
//
// qsfp28-fmc-zircon: the RX direction is handled by mrmac_rx_packer.v (MRMAC
// lanes -> 512-bit AXIS directly, never back-pressuring the MRMAC). The former
// mrmac_rx_axis_adapter + RX axis_dwidth_converter lost beats: that converter
// can drop S_AXIS_TREADY for a cycle at a frame end, which the MRMAC RX client
// (no rx tready) cannot honour. The TX side can be back-pressured, so the
// converter + this adapter remain there.
//
// The data path is combinational glue. aclk / aresetn clock only the small PTP
// sideband state below (1.3.0).
//
// PTP 2-step tagging (1.3.0, docs/DESIGN_SPEC.md §11). s_axis_ptp carries one
// record per frame, in frame order, from zircon_nic m_axis_tx_ptp (same clock,
// mac_tx_clk): tdata[1:0] = 1588 op (2'b10 = two-step: timestamp this frame and
// return it with the tag, 2'b00 = none), tdata[17:2] = 16-bit tag, [23:18] = 0.
// When a frame's first beat (SOF) is presented to the MRMAC, one record is popped
// and tx_ptp_1588op_in / tx_ptp_tag_field_in are driven from it from that beat
// until the frame's TLAST beat has been accepted (PG314: sampled at SOF on the
// TX AXIS clock); between frames they are 0.
// zircon_nic pushes a frame's record before the frame's first beat leaves it, so
// the record is normally waiting. If it is not there at SOF, the frame is held
// (tvalid low towards the MRMAC, only between frames - never inside a frame, so
// no TX underflow) for up to SOF_WAIT cycles; if still none arrives, the frame is
// sent with op = 0 and the sticky ptp_underrun output is set (cleared by reset).
// With s_axis_ptp_tvalid tied 0 (no PTP source) set SOF_WAIT = 0.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

// TX: standard 384b AXIS slave -> MRMAC client (6x64b + 6x tkeep_user)
module mrmac_tx_axis_adapter #(
  parameter integer SOF_WAIT = 8          // cycles (0..255) a frame waits at SOF for its PTP record
) (
  // From a standard AXIS master (axis_dwidth_converter M_AXIS, 384b)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA"  *) input  wire [383:0] s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP"  *) input  wire [47:0]  s_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST"  *) input  wire         s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *) input  wire         s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *) output wire         s_axis_tready,
  // PTP records from zircon_nic m_axis_tx_ptp: tdata[17:0] = {tag[15:0], op[1:0]}
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PTP TDATA"  *) input  wire [23:0] s_axis_ptp_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PTP TVALID" *) input  wire        s_axis_ptp_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_PTP TREADY" *) output wire        s_axis_ptp_tready,
  // To the MRMAC 100G client (loose ports; not part of an AXIS interface)
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata0,
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata1,
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata2,
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata3,
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata4,
  (* X_INTERFACE_IGNORE = "true" *) output wire [63:0] tx_axis_tdata5,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user0,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user1,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user2,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user3,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user4,
  (* X_INTERFACE_IGNORE = "true" *) output wire [10:0] tx_axis_tkeep_user5,
  (* X_INTERFACE_IGNORE = "true" *) output wire        tx_axis_tlast,
  (* X_INTERFACE_IGNORE = "true" *) output wire        tx_axis_tvalid,
  (* X_INTERFACE_IGNORE = "true" *) input  wire        tx_axis_tready,
  // MRMAC PTP TX inputs (port 0): tx_ptp_1588op_in_0 / tx_ptp_tag_field_in_0
  (* X_INTERFACE_IGNORE = "true" *) output wire [1:0]  tx_ptp_1588op_in,
  (* X_INTERFACE_IGNORE = "true" *) output wire [15:0] tx_ptp_tag_field_in,
  // sticky: a frame was sent without its PTP record (op 0); cleared by aresetn
  (* X_INTERFACE_IGNORE = "true" *) output wire        ptp_underrun,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS:S_AXIS_PTP, ASSOCIATED_RESET aresetn" *)
  input wire aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input wire aresetn
);
  // ---- PTP sideband ----
  reg        in_frame = 1'b0;         // a frame's SOF beat has been accepted, TLAST not yet
  reg [17:0] cur_rec  = 18'd0;        // {tag, op} of the frame in progress
  reg [7:0]  wait_cnt = 8'd0;         // cycles the pending SOF has waited
  reg        underrun_reg = 1'b0;

  wire sof_pend  = s_axis_tvalid && !in_frame;             // a frame's first beat is presented
  wire rec_ok    = s_axis_ptp_tvalid;
  wire give_up   = (wait_cnt >= SOF_WAIT);
  wire sof_go    = sof_pend && (rec_ok || give_up);        // present the SOF beat to the MRMAC
  wire pass      = in_frame || sof_go;
  wire beat_xfer = s_axis_tvalid && pass && tx_axis_tready;
  wire sof_xfer  = beat_xfer && !in_frame;

  assign s_axis_ptp_tready = sof_xfer && rec_ok;

  wire [17:0] rec_now = in_frame ? cur_rec : ((sof_go && rec_ok) ? s_axis_ptp_tdata[17:0] : 18'd0);
  assign tx_ptp_1588op_in    = rec_now[1:0];
  assign tx_ptp_tag_field_in = rec_now[17:2];
  assign ptp_underrun        = underrun_reg;

  always @(posedge aclk) begin
    if (sof_pend && !sof_go && wait_cnt != 8'hFF) begin
      wait_cnt <= wait_cnt + 8'd1;
    end
    if (sof_xfer) begin
      wait_cnt <= 8'd0;
      cur_rec  <= rec_ok ? s_axis_ptp_tdata[17:0] : 18'd0;
      if (!rec_ok) underrun_reg <= 1'b1;
    end
    if (beat_xfer) begin
      in_frame <= !s_axis_tlast;
    end
    if (!aresetn) begin
      in_frame     <= 1'b0;
      cur_rec      <= 18'd0;
      wait_cnt     <= 8'd0;
      underrun_reg <= 1'b0;
    end
  end

  // ---- data path ----
  assign tx_axis_tdata0 = s_axis_tdata[63:0];
  assign tx_axis_tdata1 = s_axis_tdata[127:64];
  assign tx_axis_tdata2 = s_axis_tdata[191:128];
  assign tx_axis_tdata3 = s_axis_tdata[255:192];
  assign tx_axis_tdata4 = s_axis_tdata[319:256];
  assign tx_axis_tdata5 = s_axis_tdata[383:320];
  // Per-lane keep from the AXIS tkeep; upper control bits [10:8] (Err/Preempt/
  // Resume) tied 0. tkeep is full on non-last beats and partial on the last
  // beat, exactly what the MRMAC expects (it only consults keep when tlast=1).
  assign tx_axis_tkeep_user0 = {3'b000, s_axis_tkeep[7:0]};
  assign tx_axis_tkeep_user1 = {3'b000, s_axis_tkeep[15:8]};
  assign tx_axis_tkeep_user2 = {3'b000, s_axis_tkeep[23:16]};
  assign tx_axis_tkeep_user3 = {3'b000, s_axis_tkeep[31:24]};
  assign tx_axis_tkeep_user4 = {3'b000, s_axis_tkeep[39:32]};
  assign tx_axis_tkeep_user5 = {3'b000, s_axis_tkeep[47:40]};
  assign tx_axis_tlast  = s_axis_tlast;
  assign tx_axis_tvalid = s_axis_tvalid && pass;
  assign s_axis_tready  = tx_axis_tready && pass;
endmodule

# SPDX-License-Identifier: MIT
#
# zircon_sources.tcl - add the zircon_nic RTL (Opsero MIT glue + the Taxi / Zircon
# modules it instantiates) and Taxi's CDC constraint scripts to the current project.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Usage (from a Vivado project-mode build script):
#   set repo_root <absolute path of the repository>
#   source $repo_root/Vivado/scripts/zircon_sources.tcl
# Afterwards $zircon_rtl and $zircon_xdc hold the files that were added.
#
# Every Taxi file is referenced in place from submodules/taxi (pinned, unmodified,
# CERN-OHL-S-2.0 unless marked MIT; see submodules/README.md). The same RTL list
# is used by Vivado/src/hdl/tb/run_xsim.sh - keep the two in sync.

if {![info exists repo_root]} {
    error "zircon_sources.tcl: set repo_root to the repository root before sourcing"
}

set zircon_taxi_dir [file normalize "$repo_root/submodules/taxi"]
set zircon_hdl_dir  [file normalize "$repo_root/Vivado/src/hdl"]

if {![file exists "$zircon_taxi_dir/src/zircon/rtl/zircon_ip_rx_parse.sv"]} {
    error "zircon_sources.tcl: $zircon_taxi_dir is not checked out (git submodule update --init)"
}

# Taxi library + Zircon modules used by zircon_nic_core (order: interface first)
set zircon_taxi_rel {
    src/axis/rtl/taxi_axis_if.sv
    src/axis/rtl/taxi_axis_tie.sv
    src/axis/rtl/taxi_axis_fifo.sv
    src/axis/rtl/taxi_axis_async_fifo.sv
    src/axis/rtl/taxi_axis_adapter.sv
    src/axis/rtl/taxi_axis_broadcast.sv
    src/axis/rtl/taxi_axis_concat.sv
    src/axis/rtl/taxi_axis_arb_mux.sv
    src/prim/rtl/taxi_arbiter.sv
    src/prim/rtl/taxi_penc.sv
    src/sync/rtl/taxi_sync_reset.sv
    src/sync/rtl/taxi_sync_signal.sv
    src/zircon/rtl/zircon_ip_len_cksum.sv
    src/zircon/rtl/zircon_ip_rx_parse.sv
    src/zircon/rtl/zircon_ip_rx_egress.sv
    src/zircon/rtl/zircon_ip_tx_ingress.sv
    src/zircon/rtl/zircon_ip_tx_buffer.sv
    src/zircon/rtl/zircon_ip_tx_deparse.sv
}

# Opsero MIT glue (package first); zircon_nic.v is the block-design module reference
set zircon_glue_rel {
    zircon_nic_pkg.sv
    hdr_trunc.sv
    rx_meta_capture.sv
    rx_dispatch.sv
    tx_meta_builder.sv
    tx_len_guard.sv
    raw_tx_desc_strip.sv
    tx_mac_out.sv
    ptp_tx_tagger.sv
    latency_stats.sv
    zircon_cdc_snapshot.sv
    zircon_regs.sv
    udp_gen.sv
    udp_chk.sv
    rate_meter.sv
    zircon_nic_core.sv
}

# Taxi timing-constraint scripts for the CDC primitives instantiated above
# (taxi_axis_async_fifo inside zircon_ip_rx_egress / tx_ingress, the MAC-side RX
# and TX frame FIFOs, the latency-sample FIFO and zircon_cdc_snapshot;
# taxi_sync_reset; taxi_sync_signal). latency_stats' shadow RAM is a dual-clock
# block RAM written and read at different times (LAT_CTRL.BUSY handshake): no
# constraint needed.
# They find their instances with get_cells -filter {ORIG_REF_NAME == ...}, so
# they are implementation-only (used_in_synthesis false) and the hierarchy of
# these modules must survive synthesis: do not synthesise with
# -flatten_hierarchy full (the default "rebuilt" keeps ORIG_REF_NAME).
set zircon_xdc_rel {
    src/axis/syn/vivado/taxi_axis_async_fifo.tcl
    src/sync/syn/vivado/taxi_sync_reset.tcl
    src/sync/syn/vivado/taxi_sync_signal.tcl
}

set zircon_rtl {}
foreach f $zircon_taxi_rel { lappend zircon_rtl [file normalize "$zircon_taxi_dir/$f"] }
foreach f $zircon_glue_rel { lappend zircon_rtl [file normalize "$zircon_hdl_dir/$f"] }

set zircon_xdc {}
foreach f $zircon_xdc_rel { lappend zircon_xdc [file normalize "$zircon_taxi_dir/$f"] }

add_files -norecurse -fileset sources_1 $zircon_rtl
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $zircon_rtl]

set zircon_shell [file normalize "$zircon_hdl_dir/zircon_nic.v"]
add_files -norecurse -fileset sources_1 $zircon_shell
set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $zircon_shell]
lappend zircon_rtl $zircon_shell

add_files -norecurse -fileset constrs_1 $zircon_xdc
foreach f $zircon_xdc {
    set xf [get_files -of_objects [get_filesets constrs_1] $f]
    set_property used_in_synthesis false $xf
    set_property used_in_implementation true $xf
}

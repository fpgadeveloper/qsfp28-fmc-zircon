# SPDX-License-Identifier: MIT
#
# cmac_sources.tcl - add the UltraScale+ 100G CMAC datapath to the current
# project: Taxi's 100G CMAC wrapper (taxi_eth_mac_100g_us, expanded from its
# .f file lists), the Taxi AXI-Lite -> APB bridge used for the transceiver
# control port, the Opsero MIT shim (zircon_cmac_us) that the block design
# instantiates as a module reference, and the implementation-only timing
# constraint scripts of the CDC primitives in them.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Usage (from Vivado/scripts/build.tcl, MicroBlaze targets only, after the Taxi
# IP scripts taxi_eth_mac_100g_us_cmace4.tcl / taxi_eth_mac_100g_us_gty_322.tcl
# have created the cmac_usplus and gtwizard_ultrascale IPs):
#   set repo_root <absolute path of the repository>
#   proc add_src_once {fileset file} { ... }   (see build.tcl)
#   source $repo_root/Vivado/scripts/cmac_sources.tcl
# Afterwards $cmac_rtl and $cmac_xdc hold the files that were added.
#
# Taxi's .f lists reference the rest of the library through the symbolic link
# src/eth/lib/taxi -> ../../../ (e.g. ../../lib/taxi/src/axis/rtl/...). A
# symlink does not survive every checkout (Windows, zip downloads), so the
# expander below never follows it: any path containing /lib/taxi/ is rewritten
# to the submodule root instead. Every Taxi file is used in place and
# unmodified (CERN-OHL-S-2.0 unless marked MIT; see submodules/README.md).

if {![info exists repo_root]} {
    error "cmac_sources.tcl: set repo_root to the repository root before sourcing"
}
if {[llength [info procs add_src_once]] == 0} {
    error "cmac_sources.tcl: proc add_src_once (build.tcl) is not defined"
}

set cmac_taxi_dir [file normalize "$repo_root/submodules/taxi"]
set cmac_hdl_dir  [file normalize "$repo_root/Vivado/src/hdl"]
set cmac_con_dir  [file normalize "$repo_root/Vivado/src/constraints"]

if {![file exists "$cmac_taxi_dir/src/eth/rtl/us/taxi_eth_mac_100g_us.sv"]} {
    error "cmac_sources.tcl: $cmac_taxi_dir is not checked out (git submodule update --init)"
}

# Resolve one .f entry (relative to the directory of the .f) to an absolute,
# symlink-free path inside the Taxi submodule.
proc cmac_resolve_f_entry {fdir entry} {
    set p [string map {\\ /} [file join $fdir $entry]]
    set i [string last "/lib/taxi/" $p]
    if {$i >= 0} {
        set p [file join $::cmac_taxi_dir [string range $p [expr {$i + 10}] end]]
    }
    return [file normalize $p]
}

# Expand a Taxi .f file list recursively; returns the source files in order
# (duplicates removed, first occurrence kept). A .f already being expanded
# (some Taxi lists name themselves or each other) is skipped.
set ::taxi_f_visiting {}
proc taxi_read_f {f} {
    set f [file normalize $f]
    if {[lsearch -exact $::taxi_f_visiting $f] >= 0} { return {} }
    lappend ::taxi_f_visiting $f
    if {![file exists $f]} {
        error "cmac_sources.tcl: file list not found: $f"
    }
    set fh [open $f r]
    set lines [split [read $fh] "\n"]
    close $fh
    set out {}
    set fdir [file dirname $f]
    foreach line $lines {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} { continue }
        set p [cmac_resolve_f_entry $fdir $line]
        if {[file extension $p] eq ".f"} {
            foreach s [taxi_read_f $p] {
                if {[lsearch -exact $out $s] < 0} { lappend out $s }
            }
        } else {
            if {![file exists $p]} {
                error "cmac_sources.tcl: $f lists a missing file: $line ($p)"
            }
            if {[lsearch -exact $out $p] < 0} { lappend out $p }
        }
    }
    set ::taxi_f_visiting [lrange $::taxi_f_visiting 0 end-1]
    return $out
}

# Taxi 100G CMAC wrapper (+ its GT wrappers, stats, PHY/MAC helpers) and the
# AXI-Lite -> APB adapter for the transceiver control port.
set cmac_taxi_rtl [taxi_read_f "$cmac_taxi_dir/src/eth/rtl/us/taxi_eth_mac_100g_us.f"]
foreach rel {
    src/axi/rtl/taxi_axil_if.sv
    src/axi/rtl/taxi_axil_apb_adapter.sv
    src/apb/rtl/taxi_apb_if.sv
} {
    set p [file normalize "$cmac_taxi_dir/$rel"]
    if {[lsearch -exact $cmac_taxi_rtl $p] < 0} { lappend cmac_taxi_rtl $p }
}

# Opsero MIT shim: Verilog shell (the block-design module reference must have
# a Verilog top) over the SystemVerilog implementation.
set cmac_shell [file normalize "$cmac_hdl_dir/zircon_cmac_us.v"]
set cmac_glue  [list \
    [file normalize "$cmac_hdl_dir/ts_gray_sync.sv"] \
    [file normalize "$cmac_hdl_dir/zircon_cmac_us_core.sv"] \
]

set cmac_rtl {}
foreach f [concat $cmac_taxi_rtl $cmac_glue] {
    if {![file exists $f]} {
        puts "WARNING: \[cmac_sources\] source not found (not added): $f"
        continue
    }
    add_src_once sources_1 $f
    lappend cmac_rtl $f
}
set cmac_sv [get_files -quiet -of_objects [get_filesets sources_1] $cmac_rtl]
if {[llength $cmac_sv] > 0} { set_property file_type SystemVerilog $cmac_sv }

if {[file exists $cmac_shell]} {
    add_src_once sources_1 $cmac_shell
    set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $cmac_shell]
    lappend cmac_rtl $cmac_shell
} else {
    puts "WARNING: \[cmac_sources\] module-reference shell not found: $cmac_shell"
}

# Implementation-only constraint scripts (they locate their cells by
# ORIG_REF_NAME after synthesis). Taxi's sync / async-FIFO scripts are already
# added by zircon_sources.tcl for zircon_nic and also cover the instances in
# the 100G wrapper; add_src_once keeps a single copy. zircon_cmac_us.tcl
# constrains the shim's timestamp gray-code crossings (ts_gray_sync).
set cmac_xdc {}
foreach f [list \
    "$cmac_taxi_dir/src/axis/syn/vivado/taxi_axis_async_fifo.tcl" \
    "$cmac_taxi_dir/src/sync/syn/vivado/taxi_sync_reset.tcl" \
    "$cmac_taxi_dir/src/sync/syn/vivado/taxi_sync_signal.tcl" \
    "$cmac_con_dir/zircon_cmac_us.tcl" \
] {
    set f [file normalize $f]
    if {![file exists $f]} {
        puts "WARNING: \[cmac_sources\] constraint script not found (not added): $f"
        continue
    }
    add_src_once constrs_1 $f
    set xf [get_files -of_objects [get_filesets constrs_1] $f]
    set_property used_in_synthesis false $xf
    set_property used_in_implementation true $xf
    lappend cmac_xdc $f
}

# Processing order: the CDC scripts look up each crossing's clocks with
# get_clocks -of_objects (e.g. taxi_axis_async_fifo.tcl's false path from the
# write clock to a distributed-RAM FIFO's output register is only applied when
# the write clock is found). On this target the CMAC tx_clk / rx_clk are derived
# from gt_ref_clk_0, which the target XDC creates, so every implementation-only
# script (these and zircon_sources.tcl's) must run after the target XDC and the
# IP constraints: PROCESSING_ORDER LATE.
set cmac_late $cmac_xdc
if {[info exists zircon_xdc]} { set cmac_late [concat $zircon_xdc $cmac_late] }
foreach f [lsort -unique $cmac_late] {
    set xf [get_files -quiet -of_objects [get_filesets constrs_1] [file normalize $f]]
    if {[llength $xf]} { set_property PROCESSING_ORDER LATE $xf }
}

puts "INFO: \[cmac_sources\] [llength $cmac_rtl] RTL file(s), [llength $cmac_xdc] constraint script(s)"

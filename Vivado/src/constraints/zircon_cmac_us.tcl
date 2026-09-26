# SPDX-License-Identifier: MIT
#
# zircon_cmac_us.tcl - implementation-only timing constraints of the KCU116 CMAC shim's
# Gray-code counter crossings (ts_gray_sync.sv): the ts_clk timestamp into tx_clk,
# rx_clk and ctrl_clk, and the tx_clk / rx_clk measurement counters into ctrl_clk.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# This file is part of the Opsero qsfp28-fmc-zircon reference design and is
# licensed under the MIT license (see LICENSE at the repo root).
#
# Taxi style: instances are found by ORIG_REF_NAME (survives -flatten_hierarchy
# rebuilt) or REF_NAME. For each instance, the path from the source-domain Gray
# register (gray_reg) to the first synchroniser stage (sync1_reg) gets
# set_max_delay -datapath_only 4.0 ns (at most one ts_clk period, below every source
# clock period plus the destination's) and set_bus_skew 3.0 ns (below the fastest
# source period, 3.103 ns for tx_clk / rx_clk), so at most one bit is ever in flight.
# sync1 / sync2 carry ASYNC_REG. No set_clock_groups (it would override these and the
# Taxi async-FIFO constraints). Add with USED_IN {implementation} (e.g. read_xdc -unmanaged
# or add_files + set_property USED_IN_SYNTHESIS false).

foreach inst [get_cells -quiet -hier -filter {(ORIG_REF_NAME == ts_gray_sync || REF_NAME == ts_gray_sync)}] {
    puts "Inserting timing constraints for ts_gray_sync instance $inst"

    set src_ffs [get_cells -quiet "$inst/gray_reg_reg[*]"]
    set dst_ffs [get_cells -quiet "$inst/sync1_reg_reg[*]"]
    set sync_ffs [get_cells -quiet "$inst/sync1_reg_reg[*] $inst/sync2_reg_reg[*]"]

    if {[llength $sync_ffs]} {
        set_property ASYNC_REG TRUE $sync_ffs
    }

    if {[llength $src_ffs] && [llength $dst_ffs]} {
        set_max_delay -from $src_ffs -to $dst_ffs -datapath_only 4.0
        set_bus_skew -from $src_ffs -to $dst_ffs 3.0
    } else {
        puts "WARNING: ts_gray_sync instance $inst: gray_reg / sync1_reg cells not found"
    }
}

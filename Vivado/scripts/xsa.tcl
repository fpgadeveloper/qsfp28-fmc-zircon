# Opsero Electronic Design Inc. Copyright 2026
#
# This script runs synthesis, implementation and exports the hardware for a project.
#
# This script requires the target name and number of jobs to be specified upon launch.
# It can be lauched in two ways:
#
#   1. Using two arguments passed to the script via tclargs.
#      eg. vivado -mode batch -source xsa.tcl -notrace -tclargs <target-name> <jobs>
#
#   2. By setting the target variables before sourcing the script.
#      eg. set target <target-name>
#          set jobs <number-of-jobs>
#          source xsa.tcl -notrace
#
#*****************************************************************************************

# Check the version of Vivado used
set version_required "2025.2"
set ver [lindex [split $::env(XILINX_VIVADO) /] end-1]
if {![string equal $ver $version_required]} {
  puts "###############################"
  puts "### Failed to build project ###"
  puts "###############################"
  puts "This project was designed for use with Vivado $version_required."
  puts "You are using Vivado $ver. Please install Vivado $version_required,"
  puts "or download the project sources from a commit of the Git repository"
  puts "that was intended for your version of Vivado ($ver)."
  return
}

if { $argc == 2 } {
  set target [lindex $argv 0]
  puts "Target for the build: $target"
  set jobs [lindex $argv 1]
  puts "Number of jobs: $jobs"
} elseif { [info exists target] } {
  puts "Target for the build: $target"
  if { ![info exists jobs] } {
    set jobs 8
  }
} else {
  puts ""
  puts "This script runs synthesis, implementation and exports the hardware for a project."
  puts "It can be launched in two ways:"
  puts ""
  puts "  1. Using two arguments passed to the script via tclargs."
  puts "     eg. vivado -mode batch -source xsa.tcl -notrace -tclargs <target-name> <jobs>"
  puts ""
  puts "  2. By setting the target variables before sourcing the script."
  puts "     eg. set target <target-name>"
  puts "         set jobs <number-of-jobs>"
  puts "         source xsa.tcl -notrace"
  return
}

set design_name ${target}
set block_name zircon

# Set the reference directory for source file relative paths (by default the value is script directory path)
set origin_dir "."

# Set the directory path for the original project from where this script was exported
set orig_proj_dir "[file normalize "$origin_dir/$design_name"]"

# Open project
open_project $origin_dir/$design_name/$design_name.xpr

# A run that was interrupted (killed mid-flow) or is out of date must be reset
# before it can be relaunched. When synth_1 is stale, also reset the block
# design's out-of-context synthesis runs: Vivado does not track the sources of
# a module-reference cell (src/hdl/*.sv), so an edited core would otherwise be
# built from its old out-of-context checkpoint.
set synth_stale 0
foreach r {synth_1 impl_1} {
  set st [get_property STATUS [get_runs $r]]
  puts "Run $r status: $st"
  if { ![string match "*Complete!*" $st] && ![string match "Not started" $st] } {
    puts "Resetting run $r"
    reset_run $r
    if { $r eq "synth_1" } { set synth_stale 1 }
  }
}
if { $synth_stale } {
  foreach r [get_runs -filter {IS_SYNTHESIS == 1 && NAME != "synth_1"}] {
    puts "Resetting out-of-context run $r"
    reset_run $r
  }
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
launch_runs impl_1 -jobs $jobs -to_step write_bitstream
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force -file $origin_dir/$design_name/${block_name}_wrapper.xsa
validate_hw_platform -verbose $origin_dir/$design_name/${block_name}_wrapper.xsa


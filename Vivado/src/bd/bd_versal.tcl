################################################################
# Block design build script for the qsfp28-fmc-zircon design (Versal, MRMAC 100G
# + Taxi Zircon IP stack)
#
# Opsero 2x QSFP28 FMC (OP120) reference design, QSFP port 0 or ports 0 and 1.
#
# This script is sourced by build.tcl, which sets:
#   block_name = zircon
#   board_name = vck190
#   ports      = { 0 } or { 0 1 }  (config/data.json "ports": 1 or 2)
#   fec        = rs      (config/data.json "fec": "rs" = RS-FEC CL91, "none" = bypass)
#
# The CIPS / NoC / DDR / GT quads / MRMACs / GT-control GPIO / Si5328 I2C part
# is ported from the 2x-qsfp28-fmc design (bd_versal.tcl, branch dev-yocto
# @3852c57), keeping its proven MRMAC GT clocking and reset wiring for both
# ports (port 0 = GTY_QUAD_X1Y1 / MRMAC_X0Y0 / FMC DP0-3 / GBTCLK0, port 1 =
# GTY_QUAD_X1Y2 / MRMAC_X0Y2 / FMC DP4-7 / GBTCLK1). Each port's MRMAC AXIS
# client then feeds its own zircon_nic module reference (Taxi Zircon) instead
# of an AXI MCDMA:
#
#   MRMAC rx 6 x 64b (48 B/beat) -> mrmac_rx_packer -> zircon_nic s_axis_mac_rx
#                                                             (390.625 MHz)
#   zircon_nic m_axis_mac_tx -> axis_dwidth_converter 64->48 B
#     -> mrmac_tx_axis_adapter -> MRMAC tx                    (390.625 MHz)
#   zircon_nic raw  (UI0) <-> axi_dma_raw[_1]  (SG, 512b)     (100 MHz)
#   zircon_nic sock (UI2) <-> axi_dma_sock[_1] (SG, 512b)     (100 MHz)
#   zircon_nic core                                           (300 MHz)
#
# Cell names per port <p>: qsfp_port<p> (hierarchy: mrmac, axi_gpio_gt<p>,
# rx_packer, tx_dwidth, tx_axis_adapter), gt_quad_base_<p>, zircon_nic_<p>,
# axi_gpio_qsfp<p>, axi_iic_qsfp<p>; the DMAs and MAC-side resets are
# axi_dma_raw / axi_dma_sock / rst_mac_rx / rst_mac_tx on port 0 (names kept
# from the one-port design) and carry a "_<p>" suffix on port 1.
#
# Address map and interrupt table: docs/source/design.md.
################################################################

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

create_bd_design $block_name
current_bd_design $block_name

set parentCell [get_bd_cells /]
set parentObj [get_bd_cells $parentCell]
if { $parentObj == "" } {
   puts "ERROR: Unable to find parent cell <$parentCell>!"
   return
}
set parentType [get_property TYPE $parentObj]
if { $parentType ne "hier" } {
   puts "ERROR: Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."
   return
}

set oldCurInst [current_bd_instance .]
current_bd_instance $parentObj

# Returns true if str contains substr
proc str_contains {str substr} {
  if {[string first $substr $str] == -1} { return 0 } else { return 1 }
}

# Target board checks
set is_vck190 [str_contains $board_name "vck190"]

# Number of ports
set num_ports [llength $ports]

# List of interrupt pins
set intr_list {}


# Add the CIPS
create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips versal_cips_0

# Configure the CIPS using automation feature (vck190 = DDR branch)
apply_bd_automation -rule xilinx.com:bd_rule:cips -config { \
  board_preset {Yes} \
  boot_config {Custom} \
  configure_noc {Add new AXI NoC} \
  debug_config {JTAG} \
  design_flow {Full System} \
  mc_type {DDR} \
  num_mc_ddr {1} \
  num_mc_lpddr {None} \
  pl_clocks {None} \
  pl_resets {None} \
}  [get_bd_cells versal_cips_0]

# Extra PS PMC config for this design (vck190 branch from sfp28 reference)
# - PL CLK0 = 100MHz, PL CLK1 = 50MHz
# - M_AXI_LPD enable, PL-to-PS interrupts IRQ0-15, one fabric reset
set_property -dict [list \
  CONFIG.CLOCK_MODE {Custom} \
  CONFIG.PS_BOARD_INTERFACE {Custom} \
  CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
  CONFIG.PS_PMC_CONFIG { \
    CLOCK_MODE {Custom} \
    DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
    DEBUG_MODE {JTAG} \
    DESIGN_MODE {1} \
    PMC_CRP_PL0_REF_CTRL_FREQMHZ {100} \
    PMC_CRP_PL1_REF_CTRL_FREQMHZ {50} \
    PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
    PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
    PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
    PMC_OSPI_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
    PMC_QSPI_COHERENCY {0} \
    PMC_QSPI_FBCLK {{ENABLE 1} {IO {PMC_MIO 6}}} \
    PMC_QSPI_PERIPHERAL_DATA_MODE {x4} \
    PMC_QSPI_PERIPHERAL_ENABLE {1} \
    PMC_QSPI_PERIPHERAL_MODE {Dual Parallel} \
    PMC_REF_CLK_FREQMHZ {33.3333} \
    PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
    PMC_SD1_COHERENCY {0} \
    PMC_SD1_DATA_TRANSFER_MODE {8Bit} \
    PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x36} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x2C} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
    PMC_SD1_SLOT_TYPE {SD 3.0} \
    PMC_USE_PMC_NOC_AXI0 {1} \
    PS_BOARD_INTERFACE {Custom} \
    PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
    PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
    PS_ENET1_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 12 .. 23}}} \
    PS_GEN_IPI0_ENABLE {1} \
    PS_GEN_IPI0_MASTER {A72} \
    PS_GEN_IPI1_ENABLE {1} \
    PS_GEN_IPI2_ENABLE {1} \
    PS_GEN_IPI3_ENABLE {1} \
    PS_GEN_IPI4_ENABLE {1} \
    PS_GEN_IPI5_ENABLE {1} \
    PS_GEN_IPI6_ENABLE {1} \
    PS_HSDP_EGRESS_TRAFFIC {JTAG} \
    PS_HSDP_INGRESS_TRAFFIC {JTAG} \
    PS_HSDP_MODE {NONE} \
    PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
    PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
    PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 1} {CH11 1} {CH12 1} {CH13 1} {CH14 1} {CH15 1} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 1} {CH7 1} {CH8 1} {CH9 1}} \
    PS_NUM_FABRIC_RESETS {1} \
    PS_PCIE_EP_RESET1_IO {PMC_MIO 38} \
    PS_PCIE_EP_RESET2_IO {PMC_MIO 39} \
    PS_PCIE_RESET {ENABLE 1} \
    PS_PL_CONNECTIVITY_MODE {Custom} \
    PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
    PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
    PS_USE_FPD_CCI_NOC {1} \
    PS_USE_FPD_CCI_NOC0 {1} \
    PS_USE_M_AXI_LPD {1} \
    PS_USE_NOC_LPD_AXI0 {1} \
    PS_USE_PMCPL_CLK0 {1} \
    PS_USE_PMCPL_CLK1 {1} \
    PS_USE_PMCPL_CLK2 {0} \
    PS_USE_PMCPL_CLK3 {0} \
    SMON_ALARMS {Set_Alarms_On} \
    SMON_ENABLE_TEMP_AVERAGING {0} \
    SMON_TEMP_AVERAGING_SAMPLES {0} \
  } \
] [get_bd_cells versal_cips_0]

# One or two QSFP ports: { 0 } or { 0 1 } (the port numbers select the GT
# quad, MRMAC site and FMC pins, so they must start at 0 and be contiguous).
set ports [list {*}$ports]
if { $ports ne [list 0] && $ports ne [list 0 1] } {
  error "bd_versal.tcl: ports must be { 0 } or { 0 1 } (got { $ports })"
}
if { ![info exists fec] } { set fec rs }
if { [lsearch -exact {rs none} $fec] < 0 } {
  error "bd_versal.tcl: fec must be 'rs' or 'none' (got '$fec')"
}

# Name suffix of the per-port top-level cells that had no index in the
# one-port design (axi_dma_raw, axi_dma_sock, rst_mac_rx, rst_mac_tx):
# "" for port 0 (names unchanged), "_<p>" for port p > 0.
proc port_sfx {label} {
  if { $label == 0 } { return "" } else { return "_$label" }
}

# Clock wizard for the system clock (100 MHz), the Zircon core clock
# (300 MHz) and the MRMAC timestamp clock (250 MHz). clk_100m: AXI-Lite
# control, both AXI DMAs and their NoC ports, the zircon_nic UI side, the GT
# APB and MRMAC s_axi (as in 2x-qsfp28-fmc). clk_300m: the zircon_nic core
# (Taxi Zircon + glue). ts_clk: the MRMAC 1588 timestamp clock (tx_ts_clk /
# rx_ts_clk of both MRMACs) and the shared ptp_systimer. The MRMAC IP only
# accepts a timestamp clock period of 2.8571-20 ns (TIMESTAMP_CLK_PERIOD_NS),
# so the 390.625 MHz AXIS clock cannot be used; 250 MHz (4.0 ns) is the IP
# default and what AMD's 2-step example design uses. Adding it keeps the
# MMCM at VCO 3000 MHz, D=1, M=30 with CLKOUT1/2 dividers 30/10 (unchanged:
# checked against the two-output wizard) and CLKOUT3 = /12, all at 0 phase.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard clk_wizard_0
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_100m,clk_300m,ts_clk,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {100.000,300.000,250.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
  CONFIG.CLKOUT_USED {true,true,true,false,false,false,false} \
  CONFIG.USE_LOCKED {true} \
] [get_bd_cells clk_wizard_0]
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins clk_wizard_0/clk_in1]

# System clock (100MHz) - used for all AXI-Lite control and DMA/NoC datapath
set sys_clk "clk_wizard_0/clk_100m"
# Zircon core clock (300MHz)
set core_clk "clk_wizard_0/clk_300m"
# MRMAC 1588 timestamp clock (250MHz)
set ts_clk "clk_wizard_0/ts_clk"

# AXIS client clock wizard: 100MHz -> 390.625MHz (drives MRMAC tx_axi_clk/rx_axi_clk
# and the MAC side of zircon_nic)
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard axis_clk_wiz
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
  CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
  CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
  CONFIG.CLKOUT_PORT {clk_390m625,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {390.625,100.000,100.000,100.000,100.000,100.000,100.000} \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.USE_LOCKED {true} \
] [get_bd_cells axis_clk_wiz]
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins axis_clk_wiz/clk_in1]
set axis_clk "axis_clk_wiz/clk_390m625"

# Configure the NoC. The CIPS automation pre-connects S00..S05 (FPD/LPD/PMC)
# and aclk0..5. Each port's two AXI DMAs add 3 AXI slave ports each
# (SG/MM2S/S2MM) on aclk6 (system clock): port 0 = S06..S11, port 1 =
# S12..S17. Their memory-controller CONNECTIONS are set where the DMAs are
# created. So NUM_SI = 6 (CIPS) + 3 per DMA (the 2x-qsfp28-fmc pattern of
# 3 NMUs per MCDMA, here with two DMAs per port).
set num_dmas [expr {2 * $num_ports}]
set_property -dict [list CONFIG.NUM_CLKS {7} CONFIG.NUM_SI [expr {6 + 3 * $num_dmas}]] [get_bd_cells axi_noc_0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_noc_0/aclk6]
set noc_port_index 6
set noc_dma_si {}

# Connect the AXI interface clocks
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins versal_cips_0/m_axi_lpd_aclk]

# Proc system reset for main clock (100 MHz)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_100m
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins rst_100m/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_100m/ext_reset_in]
connect_bd_net [get_bd_pins clk_wizard_0/locked] [get_bd_pins rst_100m/dcm_locked]

# Proc system reset for the Zircon core clock (300 MHz)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_300m
connect_bd_net [get_bd_pins $core_clk] [get_bd_pins rst_300m/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_300m/ext_reset_in]
connect_bd_net [get_bd_pins clk_wizard_0/locked] [get_bd_pins rst_300m/dcm_locked]

# Proc system reset for the timestamp clock (250 MHz): ptp_systimer
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ts
connect_bd_net [get_bd_pins $ts_clk] [get_bd_pins rst_ts/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_ts/ext_reset_in]
connect_bd_net [get_bd_pins clk_wizard_0/locked] [get_bd_pins rst_ts/dcm_locked]

# Latency-measurement (v1.3) wiring between the MRMAC PTP ports, the MRMAC
# client adapters, zircon_nic and ptp_systimer. The RTL side of these ports
# (src/hdl) is developed together with this script; lat_conn / lat_conn_intf
# connect a pin pair and record any pin that does not exist in lat_missing.
# With lat_strict = 1 (the default) a missing pin is an error at the end of
# the script; lat_strict = 0 (set before sourcing, or LAT_STRICT=0 in the
# environment of the build) only warns, which lets the
# block design be built against RTL that does not have the ports yet.
if { ![info exists lat_strict] } {
  set lat_strict [expr {[info exists ::env(LAT_STRICT)] ? $::env(LAT_STRICT) : 1}]
}
set lat_missing {}
proc lat_conn {src dst} {
  set s [get_bd_pins -quiet $src]
  set d [get_bd_pins -quiet $dst]
  if { $s eq "" || $d eq "" } {
    lappend ::lat_missing "$src -> $dst"
    puts "WARNING: \[bd_versal\] latency pin(s) missing, not connected: $src -> $dst"
    return
  }
  connect_bd_net $s $d
}
proc lat_conn_intf {src dst} {
  set s [get_bd_intf_pins -quiet $src]
  set d [get_bd_intf_pins -quiet $dst]
  if { $s eq "" || $d eq "" } {
    lappend ::lat_missing "$src => $dst"
    puts "WARNING: \[bd_versal\] latency interface(s) missing, not connected: $src => $dst"
    return
  }
  connect_bd_intf_net $s $d
}

# AXI SmartConnect for the AXI-Lite control interfaces (from M_AXI_LPD). Per
# port <p>, in this order: qsfp_port<p> (mrmac + gt-ctrl gpio), axi_dma_raw,
# axi_dma_sock, zircon_nic_<p>, axi_gpio_qsfp<p>, axi_iic_qsfp<p> (6 each);
# then the shared axi_iic_clk (Si5328). One port: M00..M06 (as before);
# two ports: port 0 M00..M05, port 1 M06..M11, axi_iic_clk M12.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc
set_property -dict [list CONFIG.NUM_MI [expr {6 * $num_ports + 1}] CONFIG.NUM_SI {1} ] [get_bd_cells axi_smc]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins rst_100m/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_LPD] [get_bd_intf_pins axi_smc/S00_AXI]
set smc_mi 0

# GT ref clocks (322.265625 MHz, from the FMC Si5328: CKOUT1 -> GBTCLK0 for
# port 0, CKOUT2 -> GBTCLK1 for port 1) and the GT quads, one per port.
# 322.265625 MHz + LCPLL integer-N replicates the AMD VCK190 Ethernet TRD's
# proven MRMAC GT config (see the gt_quad_base PROT0 settings below).
# GT Quad base (Transceiver wizard), GTY, 4 lanes bonded for 100G CAUI-4.
# The 4 lanes each run at 25.78125 Gb/s (raw) off the 322.265625 MHz refclk;
# lane bonding into a single 100G MAC happens inside the MRMAC core.
#
# Configure PROT0 = 4 lanes for the MRMAC by replicating the AMD VCK190
# Ethernet TRD's exact gt_quad_base PROT0_LR0_SETTINGS (PRESET None, 80-bit
# RAW, 25.78125 Gb/s, LCPLL integer-N, 322.265625 MHz refclk). The MRMAC needs
# an 80-bit RAW GT datapath that no named Ethernet preset provides - which is
# why the TRD sets PRESET None and specifies every field manually. We merge the
# TRD's field set onto THIS IP version's default LR0 dict, applying only field
# names that still exist in the 2025.2 gt_quad_base (so any 2022.1-only fields
# are silently dropped instead of erroring).
set trd_gt {
  PRESET None
  RX_PAM_SEL NRZ
  TX_PAM_SEL NRZ
  RX_GRAY_BYP true
  TX_GRAY_BYP true
  RX_GRAY_LITTLEENDIAN true
  TX_GRAY_LITTLEENDIAN true
  RX_PRECODE_BYP true
  TX_PRECODE_BYP true
  RX_PRECODE_LITTLEENDIAN false
  TX_PRECODE_LITTLEENDIAN false
  INTERNAL_PRESET None
  GT_TYPE GTY
  GT_DIRECTION DUPLEX
  TX_LINE_RATE 25.78125
  TX_PLL_TYPE LCPLL
  TX_REFCLK_FREQUENCY 322.265625
  TX_ACTUAL_REFCLK_FREQUENCY 322.265625000000
  TX_FRACN_ENABLED false
  TX_FRACN_NUMERATOR 0
  TX_REFCLK_SOURCE R0
  TX_DATA_ENCODING RAW
  TX_USER_DATA_WIDTH 80
  TX_INT_DATA_WIDTH 80
  TX_BUFFER_MODE 1
  TX_BUFFER_BYPASS_MODE Fast_Sync
  TX_PIPM_ENABLE false
  TX_OUTCLK_SOURCE TXPROGDIVCLK
  TXPROGDIV_FREQ_ENABLE true
  TXPROGDIV_FREQ_SOURCE LCPLL
  TXPROGDIV_FREQ_VAL 644.531
  TX_DIFF_SWING_EMPH_MODE CUSTOM
  TX_64B66B_SCRAMBLER false
  TX_64B66B_ENCODER false
  TX_64B66B_CRC false
  TX_RATE_GROUP A
  RX_LINE_RATE 25.78125
  RX_PLL_TYPE LCPLL
  RX_REFCLK_FREQUENCY 322.265625
  RX_ACTUAL_REFCLK_FREQUENCY 322.265625000000
  RX_FRACN_ENABLED false
  RX_FRACN_NUMERATOR 0
  RX_REFCLK_SOURCE R0
  RX_DATA_DECODING RAW
  RX_USER_DATA_WIDTH 80
  RX_INT_DATA_WIDTH 80
  RX_BUFFER_MODE 1
  RX_OUTCLK_SOURCE RXPROGDIVCLK
  RXPROGDIV_FREQ_ENABLE true
  RXPROGDIV_FREQ_SOURCE LCPLL
  RXPROGDIV_FREQ_VAL 644.531
  INS_LOSS_NYQ 20
  RX_EQ_MODE AUTO
  RX_COUPLING AC
  RX_TERMINATION PROGRAMMABLE
  RX_RATE_GROUP A
  RX_TERMINATION_PROG_VALUE 800
  RX_PPM_OFFSET 0
  RX_64B66B_DESCRAMBLER false
  RX_64B66B_DECODER false
  RX_64B66B_CRC false
  OOB_ENABLE false
  RX_COMMA_ALIGN_WORD 1
  RX_COMMA_SHOW_REALIGN_ENABLE true
  PCIE_ENABLE false
  TX_LANE_DESKEW_HDMI_ENABLE false
  RX_COMMA_P_ENABLE false
  RX_COMMA_M_ENABLE false
  RX_COMMA_DOUBLE_ENABLE false
  RX_COMMA_P_VAL 0101111100
  RX_COMMA_M_VAL 1010000011
  RX_COMMA_MASK 0000000000
  RX_SLIDE_MODE OFF
  RX_SSC_PPM 0
  RX_CB_NUM_SEQ 0
  RX_CB_LEN_SEQ 1
  RX_CB_MAX_SKEW 1
  RX_CB_MAX_LEVEL 1
  RX_CB_MASK_0_0 false
  RX_CB_VAL_0_0 0000000000
  RX_CB_K_0_0 false
  RX_CB_DISP_0_0 false
  RX_CB_MASK_0_1 false
  RX_CB_VAL_0_1 0000000000
  RX_CB_K_0_1 false
  RX_CB_DISP_0_1 false
  RX_CB_MASK_0_2 false
  RX_CB_VAL_0_2 0000000000
  RX_CB_K_0_2 false
  RX_CB_DISP_0_2 false
  RX_CB_MASK_0_3 false
  RX_CB_VAL_0_3 0000000000
  RX_CB_K_0_3 false
  RX_CB_DISP_0_3 false
  RX_CB_MASK_1_0 false
  RX_CB_VAL_1_0 0000000000
  RX_CB_K_1_0 false
  RX_CB_DISP_1_0 false
  RX_CB_MASK_1_1 false
  RX_CB_VAL_1_1 0000000000
  RX_CB_K_1_1 false
  RX_CB_DISP_1_1 false
  RX_CB_MASK_1_2 false
  RX_CB_VAL_1_2 0000000000
  RX_CB_K_1_2 false
  RX_CB_DISP_1_2 false
  RX_CB_MASK_1_3 false
  RX_CB_VAL_1_3 0000000000
  RX_CB_K_1_3 false
  RX_CB_DISP_1_3 false
  RX_CC_NUM_SEQ 0
  RX_CC_LEN_SEQ 1
  RX_CC_PERIODICITY 5000
  RX_CC_KEEP_IDLE DISABLE
  RX_CC_PRECEDENCE ENABLE
  RX_CC_REPEAT_WAIT 0
  RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000
  RX_CC_MASK_0_0 false
  RX_CC_VAL_0_0 0000000000
  RX_CC_K_0_0 false
  RX_CC_DISP_0_0 false
  RX_CC_MASK_0_1 false
  RX_CC_VAL_0_1 0000000000
  RX_CC_K_0_1 false
  RX_CC_DISP_0_1 false
  RX_CC_MASK_0_2 false
  RX_CC_VAL_0_2 0000000000
  RX_CC_K_0_2 false
  RX_CC_DISP_0_2 false
  RX_CC_MASK_0_3 false
  RX_CC_VAL_0_3 0000000000
  RX_CC_K_0_3 false
  RX_CC_DISP_0_3 false
  RX_CC_MASK_1_0 false
  RX_CC_VAL_1_0 0000000000
  RX_CC_K_1_0 false
  RX_CC_DISP_1_0 false
  RX_CC_MASK_1_1 false
  RX_CC_VAL_1_1 0000000000
  RX_CC_K_1_1 false
  RX_CC_DISP_1_1 false
  RX_CC_MASK_1_2 false
  RX_CC_VAL_1_2 0000000000
  RX_CC_K_1_2 false
  RX_CC_DISP_1_2 false
  RX_CC_MASK_1_3 false
  RX_CC_VAL_1_3 0000000000
  RX_CC_K_1_3 false
  RX_CC_DISP_1_3 false
  PCIE_USERCLK2_FREQ 250
  PCIE_USERCLK_FREQ 250
  RX_JTOL_FC 10
  RX_JTOL_LF_SLOPE -20
  RX_BUFFER_BYPASS_MODE Fast_Sync
  RX_BUFFER_BYPASS_MODE_LANE MULTI
  RX_BUFFER_RESET_ON_CB_CHANGE ENABLE
  RX_BUFFER_RESET_ON_COMMAALIGN DISABLE
  RX_BUFFER_RESET_ON_RATE_CHANGE ENABLE
  TX_BUFFER_RESET_ON_RATE_CHANGE ENABLE
  RESET_SEQUENCE_INTERVAL 0
  RX_COMMA_PRESET NONE
  RX_COMMA_VALID_ONLY 0
}

# One GT quad per port (2x-qsfp28-fmc: port 0 = gt_quad_base_0 on GBTCLK0 /
# DP0-3, port 1 = gt_quad_base_1 on GBTCLK1 / DP4-7), identical configuration.
# The quad sites follow from the pin locations in the XDC.
foreach label $ports {
  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_ref_clk_$label
  set_property CONFIG.FREQ_HZ 322265625 [get_bd_intf_ports /gt_ref_clk_$label]
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf util_ds_buf_$label
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} [get_bd_cells util_ds_buf_$label]
  connect_bd_intf_net [get_bd_intf_ports gt_ref_clk_$label] [get_bd_intf_pins util_ds_buf_$label/CLK_IN_D]

  create_bd_cell -type ip -vlnv xilinx.com:ip:gt_quad_base gt_quad_base_$label
  set_property -dict [list \
    CONFIG.PROT0_LR0_SETTINGS.VALUE_MODE MANUAL \
    CONFIG.PROT0_NO_OF_LANES.VALUE_MODE MANUAL \
  ] [get_bd_cells gt_quad_base_$label]
  array unset gtset
  array set gtset [get_property CONFIG.PROT0_LR0_SETTINGS [get_bd_cells gt_quad_base_$label]]
  foreach {k v} $trd_gt {
    if {[info exists gtset($k)]} { set gtset($k) $v }
  }
  set_property -dict [list \
    CONFIG.PROT0_LR0_SETTINGS [array get gtset] \
    CONFIG.PROT0_NO_OF_LANES {4} \
  ] [get_bd_cells gt_quad_base_$label]

  connect_bd_net [get_bd_pins util_ds_buf_$label/IBUF_OUT] [get_bd_pins gt_quad_base_$label/GT_REFCLK0]
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins gt_quad_base_$label/apb3clk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins gt_quad_base_$label/apb3presetn]

  # QSFP slot <label> GT interface (4-lane serial)
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp${label}_gt
  connect_bd_intf_net [get_bd_intf_pins gt_quad_base_$label/GT_Serial] [get_bd_intf_ports qsfp${label}_gt]

  # APB3 bridge to drive the GT quad's dynamic reconfiguration port
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_apb_bridge axi_apb_bridge_$label
  set_property -dict [list CONFIG.C_APB_NUM_SLAVES {1} CONFIG.C_M_APB_PROTOCOL {apb3}] [get_bd_cells axi_apb_bridge_$label]
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_apb_bridge_$label/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins axi_apb_bridge_$label/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_apb_bridge_$label/APB_M] [get_bd_intf_pins gt_quad_base_$label/APB3_INTF]
}

#########################################################
# QSFP port
#########################################################
#
# The QSFP port hierarchy (qsfp_port<N>) holds everything that runs in the
# MRMAC's clock domains:
#  - mrmac (1x100GE CAUI-4) with s_axi control and its GT-control GPIO
#  - per-channel bufg_gt clock buffers from gt_quad_base outclks
#  - RX: mrmac_rx_packer (MRMAC 6-lane client, 48 B/beat -> 512b AXIS; never
#    back-pressures the MRMAC); TX: axis_dwidth_converter 512b -> 384b and the
#    standard AXIS -> MRMAC 6-lane adapter (390.625 MHz)
# and presents a standard 512-bit AXIS pair (M_AXIS_RX with tuser[0] = bad
# frame, S_AXIS_TX) to zircon_nic. The hierarchy and cell names are kept from
# 2x-qsfp28-fmc (qsfp_port0/mrmac, qsfp_port0/axi_gpio_gt0) so that software
# ported from that design finds the same xparameters / device-tree labels.
#

proc create_qsfp_port {label fec} {

  set hier_obj [create_bd_cell -type hier qsfp_port$label]
  current_bd_instance $hier_obj

  # Pins
  create_bd_pin -dir I sys_clk
  create_bd_pin -dir I axis_clk
  create_bd_pin -dir I periph_rstn
  create_bd_pin -dir I intercon_rstn
  create_bd_pin -dir I mac_rx_rstn
  create_bd_pin -dir I mac_tx_rstn
  create_bd_pin -dir I gtpowergood_in
  create_bd_pin -dir O gt_rx_reset_done
  create_bd_pin -dir O gt_tx_reset_done
  create_bd_pin -dir O grn_led
  create_bd_pin -dir O red_led
  create_bd_pin -dir O -from 1 -to 0 rx_pack_stat
  # MRMAC 1588 (v1.3 latency measurement): timestamp clock and the shared
  # 55-bit system timer (ts_clk domain), and the TX timestamp return
  # (390.625 MHz axis_clk domain) to zircon_nic
  create_bd_pin -dir I ts_clk
  foreach dir {tx rx} {
    create_bd_pin -dir I -from 54 -to 0 ctl_${dir}_ptp_systemtimer
    create_bd_pin -dir I ctl_${dir}_ptp_st_sync
    create_bd_pin -dir I ctl_${dir}_ptp_st_overwrite
    create_bd_pin -dir I -from 31 -to 0 ctl_${dir}_ptp_st_adjust
    create_bd_pin -dir I -from 1 -to 0 ctl_${dir}_ptp_st_adjust_type
    create_bd_pin -dir I ctl_${dir}_ptp_st_adjust_vld
  }
  # GT-control GPIO CH1 bit 3 (spare): ptp_systimer sync_req (port 0 only)
  create_bd_pin -dir O gpio_ptp_sync_req
  create_bd_pin -dir O -from 54 -to 0 tx_ptp_tstamp
  create_bd_pin -dir O -from 15 -to 0 tx_ptp_tstamp_tag
  create_bd_pin -dir O tx_ptp_tstamp_valid
  # per-channel GT outclks (raw) and usrclks (to GT)
  foreach ch {0 1 2 3} {
    create_bd_pin -dir I ch${ch}_txoutclk
    create_bd_pin -dir I ch${ch}_rxoutclk
    create_bd_pin -dir O ch${ch}_txusrclk
    create_bd_pin -dir O ch${ch}_rxusrclk
  }

  # Interfaces
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_LITE
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_RX
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_TX
  # Per-frame TX PTP request {1588op, tag} from zircon_nic (390.625 MHz)
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_TX_PTP
  foreach ch {0 1 2 3} {
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_tx_interface_rtl:1.0 gt_tx_serdes_interface_$ch
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rx_interface_rtl:1.0 gt_rx_serdes_interface_$ch
  }

  #########################################################
  # MRMAC (1x100GE CAUI-4)
  #########################################################
  create_bd_cell -type ip -vlnv xilinx.com:ip:mrmac mrmac
  # Use the "old" GT wizard model so the MRMAC exposes the gt serdes
  # interface pins (gt_*_serdes_interface_*) that connect directly to
  # gt_quad_base TXn/RXn_GT_IP_Interface (same VLNV).
  set_property CONFIG.MRMAC_IS_GT_WIZ_OLD {1} [get_bd_cells mrmac]
  # Pin each port's MRMAC to the integrated-MAC site in the clock region of its
  # GT quad. Port 0 = GTY_QUAD_X1Y1 (region X9Y1) -> MRMAC_X0Y0; port 1 =
  # GTY_QUAD_X1Y2 (region X9Y2) -> MRMAC_X0Y2. Both MRMACs default to
  # MRMAC_X0Y0, so without this port 1 fails to place ("bel is occupied").
  set mrmac_loc_map {0 MRMAC_X0Y0 1 MRMAC_X0Y2}
  set_property CONFIG.MRMAC_LOCATION_C0 [dict get $mrmac_loc_map $label] [get_bd_cells mrmac]
  # GT reference clock = 322.265625 MHz (the FMC Si5328 output) - matches the
  # AMD TRD's MRMAC GT config. Set it (and the per-channel refclks) explicitly
  # so the MRMAC and gt_quad_base agree. Line rate stays 25.78125 Gb/s
  # (LCPLL integer-N).
  set_property -dict [list \
    CONFIG.GT_REF_CLK_FREQ_C0 {322.265625} \
    CONFIG.GT_CH0_RX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH0_TX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH1_RX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH1_TX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH2_RX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH2_TX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH3_RX_REFCLK_FREQUENCY_C0 {322.265625} \
    CONFIG.GT_CH3_TX_REFCLK_FREQUENCY_C0 {322.265625} \
  ] [get_bd_cells mrmac]

  # RS-FEC (qsfp28-fmc-zircon; 2x-qsfp28-fmc runs with FEC bypassed).
  # 100GBASE-CR4/SR4/LR4 over CAUI-4 NRZ lanes uses the IEEE 802.3 clause 91
  # RS(528,514) FEC, which is what a link partner in "auto" FEC mode (e.g. an
  # Intel E810) settles on. In the MRMAC this is FEC slice 0 in "MAC+PCS+FEC"
  # mode (slices 1-3 become N/A for 1x100GE). The GT line rate is unchanged
  # (25.78125 Gb/s per lane): the RS-FEC transcodes 4x 64b/66b to 256b/257b and
  # the saved bandwidth carries the parity.
  if { $fec eq "rs" } {
    set_property -dict [list \
      CONFIG.MRMAC_MODE_C0 {MAC+PCS+FEC} \
      CONFIG.FEC_SLICE0_CFG_C0 {100G (IEEE 802.3) - RS(528 514)} \
    ] [get_bd_cells mrmac]
  }

  # IEEE 1588 timestamping (v1.3 latency measurement), port 0 of this MRMAC
  # (the 1x100GE MAC). MAC_PORT0_ENABLE_TIME_STAMPING_C0 is what brings out
  # the PTP ports (rx_ptp_tstamp_out_0, tx_ptp_1588op_in_0, ...); without it
  # the wrapper ties them all off, whatever the operation mode says. 2-step:
  # every frame sent with tx_ptp_1588op_in = 2'b10 returns its TX timestamp
  # with its tag on tx_ptp_tstamp_*_out; every received frame gets
  # rx_ptp_tstamp_out. TIMESTAMP_CLK_PERIOD_NS = 4.0 = ts_clk (250 MHz); the
  # IP only accepts 2.8571-20 ns. The 1-step / flex / checksum-update inputs
  # are tied to 0 below. Runtime settings (CONFIGURATION_1588_REG 0x040,
  # latency adjust 0x250 / 0x260) are software: docs/source/design.md,
  # "Latency measurement hardware".
  set_property -dict [list \
    CONFIG.MAC_PORT0_ENABLE_TIME_STAMPING_C0 {1} \
    CONFIG.PORT0_1588v2_Operation_MODE_C0 {2-step} \
    CONFIG.TIMESTAMP_CLK_PERIOD_NS {4.0000} \
  ] [get_bd_cells mrmac]

  # NOTE: mrmac/s_axi_aclk (sys_clk, 100MHz) is connected at the very END of
  # this proc, after the AXIS datapath converters are wired. Connecting the
  # 100MHz control clock while the 390MHz AXIS client domain is already set
  # makes the MRMAC client interface report a 4-segment PHASE; wiring the
  # converters first (while the PHASE is still single-segment) avoids a
  # PHASE-mismatch error at validate.

  # GT power good
  connect_bd_net [get_bd_pins gtpowergood_in] [get_bd_pins mrmac/gtpowergood_in]

  # GT serdes interfaces (carry data + per-channel reset handshake)
  foreach ch {0 1 2 3} {
    connect_bd_intf_net [get_bd_intf_pins mrmac/gt_tx_serdes_interface_$ch] [get_bd_intf_pins gt_tx_serdes_interface_$ch]
    connect_bd_intf_net [get_bd_intf_pins mrmac/gt_rx_serdes_interface_$ch] [get_bd_intf_pins gt_rx_serdes_interface_$ch]
  }

  #########################################################
  # Per-channel user clock buffers (GT outclk -> usrclk + usrclk/2)
  #########################################################
  # CAUI-4 GT clocking - replicates BOTH AMD references (the MRMAC 1x100GE
  # CAUI-4 IP example design and the vck190 ethernet TRD), which wire it
  # identically:
  #   RX: each of the 4 GT lanes recovers its OWN clock, so each lane gets its
  #       own pair of BUFG_GTs - a full-rate "usrclk" and a half-rate "usrclk2"
  #       (the BUFG_GT /2 divided output). The MRMAC rx_serdes_clk/rx_core_clk
  #       buses take the per-lane FULL-rate clocks; rx_alt_serdes_clk takes the
  #       per-lane HALF-rate clocks; the GT's own chN_rxusrclk input takes the
  #       per-lane HALF-rate clock.
  #   TX: all 4 lanes share the TX PLL, so a single ch0 pair drives all four TX
  #       lanes. tx_core_clk = ch0 FULL-rate x4; tx_alt_serdes_clk and the GT
  #       chN_txusrclk inputs = ch0 HALF-rate.
  # The MRMAC clock buses are 4-bit; driving them from a 4-way ilconcat is
  # correct here (these are internal GT/MRMAC clocks, NOT the AXIS client clock,
  # so the old single-segment-PHASE concern - which only applies to the AXIS
  # client tx_axi_clk/rx_axi_clk - does not apply). The previous design drove
  # rx_serdes_clk/rx_core_clk from ch0 alone, leaving lanes 1-3 sampled in the
  # wrong recovered-clock domain: those PCS lanes never block-lock and 100G
  # alignment never completes, even with a passive loopback.

  # /2 divider value for the half-rate (usrclk2) BUFG_GT outputs.
  # BUFG_GT divides by (gt_bufgtdiv + 1), so a value of 1 gives /2.
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant bufg_gt_div_val
  set_property -dict [list CONFIG.CONST_WIDTH {3} CONFIG.CONST_VAL {1}] [get_bd_cells bufg_gt_div_val]

  # RX: per-lane full-rate + half-rate buffers
  foreach ch {0 1 2 3} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_rx$ch
    connect_bd_net [get_bd_pins ch${ch}_rxoutclk] [get_bd_pins bufg_gt_rx$ch/outclk]

    create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_rx_div2_$ch
    connect_bd_net [get_bd_pins ch${ch}_rxoutclk] [get_bd_pins bufg_gt_rx_div2_$ch/outclk]
    connect_bd_net [get_bd_pins bufg_gt_div_val/dout] [get_bd_pins bufg_gt_rx_div2_$ch/gt_bufgtdiv]
    # GT chN_rxusrclk takes the per-lane HALF-rate clock
    connect_bd_net [get_bd_pins bufg_gt_rx_div2_$ch/usrclk] [get_bd_pins ch${ch}_rxusrclk]
  }

  # TX: single ch0 full-rate + half-rate buffers feed all four TX lanes
  create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_tx0
  connect_bd_net [get_bd_pins ch0_txoutclk] [get_bd_pins bufg_gt_tx0/outclk]
  create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt bufg_gt_tx_div2_0
  connect_bd_net [get_bd_pins ch0_txoutclk] [get_bd_pins bufg_gt_tx_div2_0/outclk]
  connect_bd_net [get_bd_pins bufg_gt_div_val/dout] [get_bd_pins bufg_gt_tx_div2_0/gt_bufgtdiv]
  # All four GT chN_txusrclk inputs take ch0's HALF-rate clock
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins bufg_gt_tx_div2_0/usrclk] [get_bd_pins ch${ch}_txusrclk]
  }

  # MRMAC RX core + serdes clocks = per-lane FULL-rate, 4-bit bus {ch3,ch2,ch1,ch0}
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 rx_serdes_clk_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells rx_serdes_clk_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins bufg_gt_rx$ch/usrclk] [get_bd_pins rx_serdes_clk_cat/In$ch]
  }
  connect_bd_net [get_bd_pins rx_serdes_clk_cat/dout] [get_bd_pins mrmac/rx_core_clk]
  connect_bd_net [get_bd_pins rx_serdes_clk_cat/dout] [get_bd_pins mrmac/rx_serdes_clk]

  # MRMAC RX alt-serdes clock = per-lane HALF-rate, 4-bit bus {ch3,ch2,ch1,ch0}
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 rx_alt_serdes_clk_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells rx_alt_serdes_clk_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins bufg_gt_rx_div2_$ch/usrclk] [get_bd_pins rx_alt_serdes_clk_cat/In$ch]
  }
  connect_bd_net [get_bd_pins rx_alt_serdes_clk_cat/dout] [get_bd_pins mrmac/rx_alt_serdes_clk]

  # MRMAC TX core clock = ch0 FULL-rate on all four lanes
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 tx_core_clk_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells tx_core_clk_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins bufg_gt_tx0/usrclk] [get_bd_pins tx_core_clk_cat/In$ch]
  }
  connect_bd_net [get_bd_pins tx_core_clk_cat/dout] [get_bd_pins mrmac/tx_core_clk]

  # MRMAC TX alt-serdes clock = ch0 HALF-rate on all four lanes
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 tx_alt_serdes_clk_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells tx_alt_serdes_clk_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins bufg_gt_tx_div2_0/usrclk] [get_bd_pins tx_alt_serdes_clk_cat/In$ch]
  }
  connect_bd_net [get_bd_pins tx_alt_serdes_clk_cat/dout] [get_bd_pins mrmac/tx_alt_serdes_clk]

  #########################################################
  # MRMAC AXIS client clocks (390.625MHz) - tx_axi_clk/rx_axi_clk (4-bit bus,
  # driven from the single scalar axis_clk net).
  #########################################################
  connect_bd_net [get_bd_pins axis_clk] [get_bd_pins mrmac/tx_axi_clk]
  connect_bd_net [get_bd_pins axis_clk] [get_bd_pins mrmac/rx_axi_clk]

  #########################################################
  # MRMAC core/serdes resets (4-bit) - released by GT reset-done
  #########################################################
  # rx_core_reset / rx_serdes_reset = ~gt_rx_reset_done_out
  # tx_core_reset / tx_serdes_reset = ~gt_tx_reset_done_out
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_rx_reset
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {4}] [get_bd_cells logic_rx_reset]
  connect_bd_net [get_bd_pins mrmac/gt_rx_reset_done_out] [get_bd_pins logic_rx_reset/Op1]
  connect_bd_net [get_bd_pins logic_rx_reset/Res] [get_bd_pins mrmac/rx_core_reset]
  connect_bd_net [get_bd_pins logic_rx_reset/Res] [get_bd_pins mrmac/rx_serdes_reset]

  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_tx_reset
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {4}] [get_bd_cells logic_tx_reset]
  connect_bd_net [get_bd_pins mrmac/gt_tx_reset_done_out] [get_bd_pins logic_tx_reset/Op1]
  connect_bd_net [get_bd_pins logic_tx_reset/Res] [get_bd_pins mrmac/tx_core_reset]
  connect_bd_net [get_bd_pins logic_tx_reset/Res] [get_bd_pins mrmac/tx_serdes_reset]

  # rx_flexif_reset (4-bit) = ~periph_rstn on all four lanes (no PTP/flex used).
  # Replicate periph_rstn to 4 bits, then invert with a 4-bit NOT.
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 periph_rstn_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells periph_rstn_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins periph_rstn] [get_bd_pins periph_rstn_cat/In$ch]
  }
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_not_rstn
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {4}] [get_bd_cells logic_not_rstn]
  connect_bd_net [get_bd_pins periph_rstn_cat/dout] [get_bd_pins logic_not_rstn/Op1]
  connect_bd_net [get_bd_pins logic_not_rstn/Res] [get_bd_pins mrmac/rx_flexif_reset]

  #########################################################
  # Tie off unused MRMAC clocks (flexif) and pm_tick to 0
  #########################################################
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_zero4
  set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells const_zero4]
  connect_bd_net [get_bd_pins const_zero4/dout] [get_bd_pins mrmac/tx_flexif_clk]
  connect_bd_net [get_bd_pins const_zero4/dout] [get_bd_pins mrmac/rx_flexif_clk]
  connect_bd_net [get_bd_pins const_zero4/dout] [get_bd_pins mrmac/pm_tick]

  #########################################################
  # MRMAC 1588: timestamp clock and system timer (ts_clk, 250 MHz)
  #########################################################
  # tx_ts_clk / rx_ts_clk (4-bit, one per MAC port) all take ts_clk, as in
  # AMD's MRMAC 2-step example design; only bit 0 (port 0) is used. The
  # primitive's timing arcs put ctl_{tx,rx}_ptp_systemtimer_0, _st_sync_0,
  # _st_overwrite_0 and _st_adjust*_0 on TX_TS_CLK[0] / RX_TS_CLK[0], so
  # ptp_systimer (clocked by ts_clk) drives them directly with no CDC. The
  # MRMAC moves the time into its TX/RX AXI clock domains internally:
  # tx_ptp_1588op_in / tx_ptp_tag_field_in are sampled, and
  # tx_ptp_tstamp_*_out / rx_ptp_tstamp_out_0 are launched, on
  # TX_AXI_CLK / RX_AXI_CLK (= axis_clk), the domain of the adapters and of
  # zircon_nic's MAC side.
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 ts_clk_cat
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells ts_clk_cat]
  foreach ch {0 1 2 3} {
    connect_bd_net [get_bd_pins ts_clk] [get_bd_pins ts_clk_cat/In$ch]
  }
  connect_bd_net [get_bd_pins ts_clk_cat/dout] [get_bd_pins mrmac/tx_ts_clk]
  connect_bd_net [get_bd_pins ts_clk_cat/dout] [get_bd_pins mrmac/rx_ts_clk]
  # One timer (top-level ptp_systimer_0) for both directions and both
  # MRMACs, so a TX timestamp minus an RX timestamp is a latency on a single
  # time base. ptp_systimer drives st_adjust* to 0 (no slewing: only
  # differences of timestamps are used).
  foreach dir {tx rx} {
    foreach pin {systemtimer st_sync st_overwrite st_adjust st_adjust_type st_adjust_vld} {
      connect_bd_net [get_bd_pins ctl_${dir}_ptp_$pin] [get_bd_pins mrmac/ctl_${dir}_ptp_${pin}_0]
    }
  }
  # Unused PTP inputs tied to 0:
  #   tx_ptp_cf_offset_in_0[15:0], tx_ptp_upd_chksum_in_0
  #                               1-step correction-field / UDP checksum update
  #   tx_ptp_flex_1588op_in_0, tx_ptp_flex_1588loc_in_0[2:0],
  #     tx_ptp_flex_tag_field_in_0[15:0]   FlexE-client timestamping
  # Unused PTP outputs left open: stat_{tx,rx}_ptp_systemtimer_0 and
  # stat_{tx,rx}_ptp_st_sync_0 (the same time is readable at STAT_{TX,RX}_1588_TOD,
  # 0x7A8 / 0x7B0), {tx,rx}_ptp_rsfec_offset_out_0 (RS-FEC position offsets for
  # PTP accuracy, constant per link and not needed for latency deltas), and
  # the ports 1-3 copies of every PTP pin.
  foreach w {1 3 16} {
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 ptp_zero$w
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL {0}] [get_bd_cells ptp_zero$w]
  }
  connect_bd_net [get_bd_pins ptp_zero16/dout] [get_bd_pins mrmac/tx_ptp_cf_offset_in_0]
  connect_bd_net [get_bd_pins ptp_zero1/dout]  [get_bd_pins mrmac/tx_ptp_upd_chksum_in_0]
  connect_bd_net [get_bd_pins ptp_zero1/dout]  [get_bd_pins mrmac/tx_ptp_flex_1588op_in_0]
  connect_bd_net [get_bd_pins ptp_zero3/dout]  [get_bd_pins mrmac/tx_ptp_flex_1588loc_in_0]
  connect_bd_net [get_bd_pins ptp_zero16/dout] [get_bd_pins mrmac/tx_ptp_flex_tag_field_in_0]

  #########################################################
  # AXI-Lite SmartConnect (mrmac s_axi + gt-ctrl gpio)
  #########################################################
  # M00 -> mrmac/s_axi, M01 -> axi_gpio_gt$label/S_AXI
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_lite
  set_property CONFIG.NUM_MI {2} [get_bd_cells axi_smc_lite]
  connect_bd_net [get_bd_pins sys_clk] [get_bd_pins axi_smc_lite/aclk]
  connect_bd_net [get_bd_pins intercon_rstn] [get_bd_pins axi_smc_lite/aresetn]
  connect_bd_intf_net [get_bd_intf_pins S_AXI_LITE] [get_bd_intf_pins axi_smc_lite/S00_AXI]
  # axi_smc_lite/M00_AXI -> mrmac/s_axi is connected at the end of this proc,
  # together with mrmac/s_axi_aclk (see PHASE note at MRMAC creation).

  #########################################################
  # GT control GPIO (lets the bare-metal bring-up reset the GT and read
  # reset-done). Dual-channel AXI GPIO:
  #   Channel 1 (5 outputs): bit0=gt_reset_all, bit1=gt_reset_tx_datapath,
  #                          bit2=gt_reset_rx_datapath, bits3-4=gt-ctrl-rate (spare)
  #   Channel 2 (3 inputs):  bit0=gt_tx_reset_done, bit1=gt_rx_reset_done,
  #                          bit2=tx_axis_adapter ptp_underrun (sticky, v1.3)
  # CH1 bit3 (v1.3) = ptp_systimer sync_req (port 0's GPIO only; a rising
  # edge forces an st_sync pulse into both MRMACs); bit 4 spare.
  #########################################################
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_gt$label
  set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {5} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO2_WIDTH {3} \
    CONFIG.C_ALL_INPUTS_2 {1} \
  ] [get_bd_cells axi_gpio_gt$label]
  connect_bd_net [get_bd_pins sys_clk] [get_bd_pins axi_gpio_gt$label/s_axi_aclk]
  connect_bd_net [get_bd_pins periph_rstn] [get_bd_pins axi_gpio_gt$label/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc_lite/M01_AXI] [get_bd_intf_pins axi_gpio_gt$label/S_AXI]

  # Channel 1 outputs (5-bit gpio_io_o). The mrmac gt_reset_*_in pins are each
  # 4-bit (one bit per bonded lane), so for each control bit we slice it out of
  # gpio_io_o (1-bit) then replicate it to all 4 lanes via a 4-port ilconcat
  # (same scalar-net broadcast pattern as periph_rstn_cat).
  #   gpio bit0 -> gt_reset_all_in[3:0]
  #   gpio bit1 -> gt_reset_tx_datapath_in[3:0]
  #   gpio bit2 -> gt_reset_rx_datapath_in[3:0]
  # gpio bit 3 -> gpio_ptp_sync_req (used on port 0 only); bit 4 is spare.
  foreach {nm bit pin} {
    gt_rst_all 0 gt_reset_all_in
    gt_rst_tx  1 gt_reset_tx_datapath_in
    gt_rst_rx  2 gt_reset_rx_datapath_in
  } {
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_${nm}$label
    set_property -dict [list CONFIG.DIN_WIDTH {5} CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_${nm}$label]
    connect_bd_net [get_bd_pins axi_gpio_gt$label/gpio_io_o] [get_bd_pins slice_${nm}$label/Din]
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 cat_${nm}$label
    set_property CONFIG.NUM_PORTS {4} [get_bd_cells cat_${nm}$label]
    foreach ch {0 1 2 3} {
      connect_bd_net [get_bd_pins slice_${nm}$label/Dout] [get_bd_pins cat_${nm}$label/In$ch]
    }
    connect_bd_net [get_bd_pins cat_${nm}$label/dout] [get_bd_pins mrmac/$pin]
  }
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_ptp_sync$label
  set_property -dict [list CONFIG.DIN_WIDTH {5} CONFIG.DIN_FROM {3} CONFIG.DIN_TO {3} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_ptp_sync$label]
  connect_bd_net [get_bd_pins axi_gpio_gt$label/gpio_io_o] [get_bd_pins slice_ptp_sync$label/Din]
  connect_bd_net [get_bd_pins slice_ptp_sync$label/Dout] [get_bd_pins gpio_ptp_sync_req]

  # Channel 2 inputs <- mrmac GT reset-done outputs (each 4-bit, one per bonded
  # lane). Take lane-0's done bit from each and concat into the 2-bit gpio2_io_i:
  #   gpio2 bit0 = gt_tx_reset_done_out[0]
  #   gpio2 bit1 = gt_rx_reset_done_out[0]
  #   gpio2 bit2 = tx_axis_adapter/ptp_underrun (connected with the TX path)
  # These outputs already drive logic_tx_reset/logic_rx_reset; the extra slices
  # are just additional loads on the same nets (existing conns left intact).
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_gt_tx_done$label
  set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_gt_tx_done$label]
  connect_bd_net [get_bd_pins mrmac/gt_tx_reset_done_out] [get_bd_pins slice_gt_tx_done$label/Din]
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_gt_rx_done$label
  set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_gt_rx_done$label]
  connect_bd_net [get_bd_pins mrmac/gt_rx_reset_done_out] [get_bd_pins slice_gt_rx_done$label/Din]
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 gt_rst_done_cat$label
  set_property CONFIG.NUM_PORTS {3} [get_bd_cells gt_rst_done_cat$label]
  connect_bd_net [get_bd_pins slice_gt_tx_done$label/Dout] [get_bd_pins gt_rst_done_cat$label/In0]
  connect_bd_net [get_bd_pins slice_gt_rx_done$label/Dout] [get_bd_pins gt_rst_done_cat$label/In1]
  connect_bd_net [get_bd_pins gt_rst_done_cat$label/dout] [get_bd_pins axi_gpio_gt$label/gpio2_io_i]

  #########################################################
  # GT reset-done (all four lanes) -> MAC-side reset gating (top level)
  #########################################################
  foreach dir {rx tx} {
    create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilreduced_logic:1.0 and_gt_${dir}_done
    set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {4}] [get_bd_cells and_gt_${dir}_done]
    connect_bd_net [get_bd_pins mrmac/gt_${dir}_reset_done_out] [get_bd_pins and_gt_${dir}_done/Op1]
    connect_bd_net [get_bd_pins and_gt_${dir}_done/Res] [get_bd_pins gt_${dir}_reset_done]
  }

  #########################################################
  # TX datapath: zircon_nic (512b) -> dwidth(512->384) -> adapter -> MRMAC tx (384b)
  #########################################################
  # All in the 390.625 MHz MRMAC client domain (the clock-domain crossing to
  # the Zircon core is inside zircon_nic). zircon_nic's TX egress is a frame
  # FIFO (store-and-forward), so frames reach the MRMAC without gaps, which is
  # what the MRMAC TX client needs (the 2x-qsfp28-fmc design got this from a
  # packet-mode axis_data_fifo).
  # TX dwidth: 64 bytes (512b, Zircon side) -> 48 bytes (384b, MRMAC side).
  # The MRMAC AXIS does not propagate a TDATA width, so set both sides
  # explicitly. TLAST and TKEEP are carried. zircon_nic's tuser[0] (TX error)
  # is constant 0 and is not carried.
  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter tx_dwidth
  set_property -dict [list \
    CONFIG.S_TDATA_NUM_BYTES {64} \
    CONFIG.M_TDATA_NUM_BYTES {48} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.TUSER_BITS_PER_BYTE {0} \
  ] [get_bd_cells tx_dwidth]
  connect_bd_net [get_bd_pins axis_clk] [get_bd_pins tx_dwidth/aclk]
  connect_bd_net [get_bd_pins mac_tx_rstn] [get_bd_pins tx_dwidth/aresetn]
  connect_bd_intf_net [get_bd_intf_pins S_AXIS_TX] [get_bd_intf_pins tx_dwidth/S_AXIS]
  # TX adapter: standard 384b AXIS (from tx_dwidth) -> MRMAC 6-lane client.
  # The MRMAC axis_tx_port0 BD interface is handshake-only (TDATA_NUM_BYTES=0);
  # the data rides on loose ports tx_axis_tdata0..5 + tx_axis_tkeep_user0..5, so
  # we cannot connect tx_dwidth straight to axis_tx_port0 (that mis-delineated
  # frames). The adapter splits the 384b AXIS into the six MRMAC lanes.
  create_bd_cell -type module -reference mrmac_tx_axis_adapter tx_axis_adapter
  connect_bd_net [get_bd_pins axis_clk] [get_bd_pins tx_axis_adapter/aclk]
  connect_bd_intf_net [get_bd_intf_pins tx_dwidth/M_AXIS] [get_bd_intf_pins tx_axis_adapter/S_AXIS]
  foreach ln {0 1 2 3 4 5} {
    connect_bd_net [get_bd_pins tx_axis_adapter/tx_axis_tdata$ln]      [get_bd_pins mrmac/tx_axis_tdata$ln]
    connect_bd_net [get_bd_pins tx_axis_adapter/tx_axis_tkeep_user$ln] [get_bd_pins mrmac/tx_axis_tkeep_user$ln]
  }
  connect_bd_net [get_bd_pins tx_axis_adapter/tx_axis_tlast]  [get_bd_pins mrmac/tx_axis_tlast_0]
  connect_bd_net [get_bd_pins tx_axis_adapter/tx_axis_tvalid] [get_bd_pins mrmac/tx_axis_tvalid_0]
  connect_bd_net [get_bd_pins mrmac/tx_axis_tready_0]         [get_bd_pins tx_axis_adapter/tx_axis_tready]
  # 2-step TX timestamp request: zircon_nic pushes one {1588op, tag} record
  # per frame on S_AXIS_TX_PTP (same frame order as S_AXIS_TX); the adapter
  # pops it at the frame's first beat and holds tx_ptp_1588op_in /
  # tx_ptp_tag_field_in from SOP to TLAST. The MRMAC returns the timestamp
  # with the tag on tx_ptp_tstamp_*_out, which go back to zircon_nic.
  # tx_axis_adapter/ptp_underrun (sticky until mac_tx reset: a frame started
  # with no request record and went out with op = 0) is a debug flag, read
  # by software on GT-control GPIO CH2 bit 2.
  if { [get_bd_pins -quiet tx_axis_adapter/aresetn] ne "" } {
    connect_bd_net [get_bd_pins mac_tx_rstn] [get_bd_pins tx_axis_adapter/aresetn]
  }
  lat_conn_intf S_AXIS_TX_PTP tx_axis_adapter/S_AXIS_PTP
  lat_conn tx_axis_adapter/tx_ptp_1588op_in    mrmac/tx_ptp_1588op_in_0
  lat_conn tx_axis_adapter/tx_ptp_tag_field_in mrmac/tx_ptp_tag_field_in_0
  lat_conn tx_axis_adapter/ptp_underrun        gt_rst_done_cat$label/In2
  connect_bd_net [get_bd_pins mrmac/tx_ptp_tstamp_out_0]       [get_bd_pins tx_ptp_tstamp]
  connect_bd_net [get_bd_pins mrmac/tx_ptp_tstamp_tag_out_0]   [get_bd_pins tx_ptp_tstamp_tag]
  connect_bd_net [get_bd_pins mrmac/tx_ptp_tstamp_valid_out_0] [get_bd_pins tx_ptp_tstamp_valid]

  #########################################################
  # RX datapath: MRMAC rx (6 x 64b, 48 B/beat) -> mrmac_rx_packer -> zircon_nic (512b)
  #########################################################
  # The MRMAC RX client cannot be back-pressured (no rx tready). The data rides
  # on the loose ports rx_axis_tdata0..5 + rx_axis_tkeep_user0..5 (axis_rx_port0
  # is handshake-only). mrmac_rx_packer (src/hdl/mrmac_rx_packer.v) accepts one
  # beat EVERY cycle unconditionally, packs the 48-byte beats into 64-byte beats
  # and puts the MRMAC error flag (tkeep_user[8]) on tuser[0] of the frame's last
  # beat (Taxi "bad frame"). It replaces the former RX adapter +
  # axis_dwidth_converter (48->64) + tuser fold: that converter drops S_AXIS
  # tready for a cycle at some frame ends, and the beat the MRMAC offered in that
  # cycle was lost (bench: a frame truncated at 48 bytes merged with the next).
  # Its stat[1:0] pulses (output stalled / beats dropped) go to zircon_nic
  # STATUS b4/b5.
  create_bd_cell -type module -reference mrmac_rx_packer rx_packer
  connect_bd_net [get_bd_pins axis_clk] [get_bd_pins rx_packer/aclk]
  connect_bd_net [get_bd_pins mac_rx_rstn] [get_bd_pins rx_packer/aresetn]
  foreach ln {0 1 2 3 4 5} {
    connect_bd_net [get_bd_pins mrmac/rx_axis_tdata$ln]      [get_bd_pins rx_packer/rx_axis_tdata$ln]
    connect_bd_net [get_bd_pins mrmac/rx_axis_tkeep_user$ln] [get_bd_pins rx_packer/rx_axis_tkeep_user$ln]
  }
  connect_bd_net [get_bd_pins mrmac/rx_axis_tlast_0]  [get_bd_pins rx_packer/rx_axis_tlast]
  connect_bd_net [get_bd_pins mrmac/rx_axis_tvalid_0] [get_bd_pins rx_packer/rx_axis_tvalid]
  connect_bd_intf_net [get_bd_intf_pins rx_packer/M_AXIS] [get_bd_intf_pins M_AXIS_RX]
  connect_bd_net [get_bd_pins rx_packer/stat] [get_bd_pins rx_pack_stat]
  # RX timestamp (rx_axis_clk = axis_clk): the packer latches it on the
  # frame's first beat and carries bits [54:7] (0.5 ns units) on M_AXIS
  # tuser[48:1] of every beat of that frame (tuser[0] stays "bad frame"),
  # so it is dropped together with its frame anywhere downstream.
  lat_conn mrmac/rx_ptp_tstamp_out_0 rx_packer/rx_ptp_tstamp

  #########################################################
  # MRMAC AXI-Lite control (connected last - see note at MRMAC creation)
  #########################################################
  connect_bd_net [get_bd_pins sys_clk] [get_bd_pins mrmac/s_axi_aclk]
  connect_bd_net [get_bd_pins periph_rstn] [get_bd_pins mrmac/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc_lite/M00_AXI] [get_bd_intf_pins mrmac/s_axi]

  #########################################################
  # User LEDs
  #########################################################
  # Green LED = RX aligned (link up) on port 0; Red LED = NOT aligned.
  connect_bd_net [get_bd_pins mrmac/stat_rx_status_0] [get_bd_pins grn_led]
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_red_led
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells logic_red_led]
  connect_bd_net [get_bd_pins mrmac/stat_rx_status_0] [get_bd_pins logic_red_led/Op1]
  connect_bd_net [get_bd_pins logic_red_led/Res] [get_bd_pins red_led]


  current_bd_instance \
}

#########################################################
# Per-port subsystem: MRMAC hierarchy, MAC-side resets, AXI DMAs, zircon_nic,
# QSFP sideband GPIO and module I2C. Port 1 is an exact copy of port 0 on its
# own GT quad / MRMAC site; both share the 100/300/390.625 MHz clocks (the
# 2x-qsfp28-fmc design also drives both MRMAC AXIS clients from the one
# axis_clk_wiz output) and the Si5328 I2C.
#########################################################

# Interrupts per port, in fixed order (see docs/source/design.md):
#   raw MM2S, raw S2MM, sock MM2S, sock S2MM, iic_qsfp<p>
# The final order is port 0's five, then axi_iic_clk (Si5328), then port 1's
# five -- so the one-port pl_ps_irq0..5 assignment is unchanged.
array set port_intr {}

foreach label $ports {
  set sfx [port_sfx $label]
  set port_intr($label) {}

  # Proc system resets for the 390.625MHz MAC-side domain, one per direction.
  # Besides pl0_resetn and the MMCM lock, each is held while the MRMAC GT
  # datapath of its direction is not out of reset: aux_reset_in (active low) =
  # AND of the four lanes' gt_{rx,tx}_reset_done_out -- the same signal that
  # releases the MRMAC's own rx/tx core and serdes resets in this design. The
  # per-direction reset drives the RX (TX) adapters/width converter and
  # zircon_nic mac_rx_aresetn (mac_tx_aresetn), so a GT reset issued by software
  # through the GT-control GPIO also flushes the MAC side of the NIC.
  foreach dir {rx tx} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_mac_${dir}$sfx
    connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins rst_mac_${dir}$sfx/slowest_sync_clk]
    connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_mac_${dir}$sfx/ext_reset_in]
    connect_bd_net [get_bd_pins axis_clk_wiz/locked] [get_bd_pins rst_mac_${dir}$sfx/dcm_locked]
  }

  #########################################################
  # QSFP port <label>: MRMAC subsystem
  #########################################################
  create_qsfp_port $label $fec

  # Connect clocks/resets
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins qsfp_port$label/sys_clk]
  connect_bd_net [get_bd_pins $ts_clk] [get_bd_pins qsfp_port$label/ts_clk]
  connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins qsfp_port$label/axis_clk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins qsfp_port$label/periph_rstn]
  connect_bd_net [get_bd_pins rst_100m/interconnect_aresetn] [get_bd_pins qsfp_port$label/intercon_rstn]
  connect_bd_net [get_bd_pins rst_mac_rx$sfx/peripheral_aresetn] [get_bd_pins qsfp_port$label/mac_rx_rstn]
  connect_bd_net [get_bd_pins rst_mac_tx$sfx/peripheral_aresetn] [get_bd_pins qsfp_port$label/mac_tx_rstn]
  # GT reset-done gates the MAC-side resets (aux_reset_in is active low)
  connect_bd_net [get_bd_pins qsfp_port$label/gt_rx_reset_done] [get_bd_pins rst_mac_rx$sfx/aux_reset_in]
  connect_bd_net [get_bd_pins qsfp_port$label/gt_tx_reset_done] [get_bd_pins rst_mac_tx$sfx/aux_reset_in]

  # Port 0 = FMC slot 0 (DP0-3) = gt_quad_base_0; port 1 = slot 1 (DP4-7) =
  # gt_quad_base_1
  set gtq gt_quad_base_$label
  connect_bd_net [get_bd_pins $gtq/gtpowergood] [get_bd_pins qsfp_port$label/gtpowergood_in]

  # GT serdes interfaces (4 lanes) and per-channel out/usr clocks
  foreach ch {0 1 2 3} {
    connect_bd_intf_net [get_bd_intf_pins qsfp_port$label/gt_tx_serdes_interface_$ch] [get_bd_intf_pins $gtq/TX${ch}_GT_IP_Interface]
    connect_bd_intf_net [get_bd_intf_pins qsfp_port$label/gt_rx_serdes_interface_$ch] [get_bd_intf_pins $gtq/RX${ch}_GT_IP_Interface]
    connect_bd_net [get_bd_pins $gtq/ch${ch}_txoutclk] [get_bd_pins qsfp_port$label/ch${ch}_txoutclk]
    connect_bd_net [get_bd_pins $gtq/ch${ch}_rxoutclk] [get_bd_pins qsfp_port$label/ch${ch}_rxoutclk]
    connect_bd_net [get_bd_pins qsfp_port$label/ch${ch}_txusrclk] [get_bd_pins $gtq/ch${ch}_txusrclk]
    connect_bd_net [get_bd_pins qsfp_port$label/ch${ch}_rxusrclk] [get_bd_pins $gtq/ch${ch}_rxusrclk]
  }

  # AXI-Lite control interface (mrmac + gt gpio)
  connect_bd_intf_net [get_bd_intf_pins qsfp_port$label/S_AXI_LITE] [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI]
  incr smc_mi

  # External LED ports
  create_bd_port -dir O grn_led_qsfp$label
  create_bd_port -dir O red_led_qsfp$label
  connect_bd_net [get_bd_pins qsfp_port$label/grn_led] [get_bd_ports grn_led_qsfp$label]
  connect_bd_net [get_bd_pins qsfp_port$label/red_led] [get_bd_ports red_led_qsfp$label]

  #########################################################
  # AXI DMAs (raw = UI0, sock = UI2)
  #########################################################
  # Scatter-gather, no status/control stream, 512-bit memory-mapped and stream
  # data at 100 MHz (51.2 Gb/s per direction per DMA), 64-bit addressing,
  # 26-bit buffer length, unaligned transfers (DRE) on both channels. Max burst
  # is 64 beats: at 512 bits that is 4 KB, the AXI4 limit (the IP offers no more
  # at this width). Each DMA's SG / MM2S / S2MM masters take one NoC slave port,
  # mapped to memory-controller ports MC_0 / MC_1 / MC_2 (the 2x-qsfp28-fmc MCDMA
  # pattern; as there, both ports share the same MC ports of the single DDR
  # controller and the NoC arbitrates).
  set dma_raw  axi_dma_raw$sfx
  set dma_sock axi_dma_sock$sfx
  foreach dma [list $dma_raw $dma_sock] {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma $dma
    set_property -dict [list \
      CONFIG.c_include_sg {1} \
      CONFIG.c_sg_include_stscntrl_strm {0} \
      CONFIG.c_sg_length_width {26} \
      CONFIG.c_addr_width {64} \
      CONFIG.c_include_mm2s {1} \
      CONFIG.c_include_s2mm {1} \
      CONFIG.c_m_axi_mm2s_data_width {512} \
      CONFIG.c_m_axis_mm2s_tdata_width {512} \
      CONFIG.c_m_axi_s2mm_data_width {512} \
      CONFIG.c_s_axis_s2mm_tdata_width {512} \
      CONFIG.c_mm2s_burst_size {64} \
      CONFIG.c_s2mm_burst_size {64} \
      CONFIG.c_include_mm2s_dre {1} \
      CONFIG.c_include_s2mm_dre {1} \
    ] [get_bd_cells $dma]
    foreach clk {s_axi_lite_aclk m_axi_sg_aclk m_axi_mm2s_aclk m_axi_s2mm_aclk} {
      connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $dma/$clk]
    }
    connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins $dma/axi_resetn]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
    incr smc_mi

    # DMA memory-mapped interfaces to the NoC (-> DDR)
    foreach {intf mc} {M_AXI_SG MC_0 M_AXI_MM2S MC_1 M_AXI_S2MM MC_2} {
      set index_padded [format "%02d" $noc_port_index]
      set_property -dict [list CONFIG.CONNECTIONS [list $mc {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4}}]] [get_bd_intf_pins /axi_noc_0/S${index_padded}_AXI]
      connect_bd_intf_net [get_bd_intf_pins $dma/$intf] [get_bd_intf_pins axi_noc_0/S${index_padded}_AXI]
      lappend noc_dma_si S${index_padded}_AXI
      incr noc_port_index
    }
    lappend port_intr($label) "$dma/mm2s_introut" "$dma/s2mm_introut"
  }

  #########################################################
  # zircon_nic (Taxi Zircon IP stack, module reference)
  #########################################################
  set nic zircon_nic_$label
  create_bd_cell -type module -reference zircon_nic $nic
  # core (300 MHz)
  connect_bd_net [get_bd_pins $core_clk] [get_bd_pins $nic/clk]
  connect_bd_net [get_bd_pins rst_300m/peripheral_aresetn] [get_bd_pins $nic/aresetn]
  # MAC side (390.625 MHz, gated by this port's GT reset-done per direction)
  connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins $nic/mac_rx_clk]
  connect_bd_net [get_bd_pins rst_mac_rx$sfx/peripheral_aresetn] [get_bd_pins $nic/mac_rx_aresetn]
  connect_bd_net [get_bd_pins $axis_clk] [get_bd_pins $nic/mac_tx_clk]
  connect_bd_net [get_bd_pins rst_mac_tx$sfx/peripheral_aresetn] [get_bd_pins $nic/mac_tx_aresetn]
  # UI / AXI-Lite (100 MHz)
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $nic/ui_clk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins $nic/ui_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI] [get_bd_intf_pins $nic/s_axi]
  incr smc_mi
  # MAC-side streams
  connect_bd_intf_net [get_bd_intf_pins qsfp_port$label/M_AXIS_RX] [get_bd_intf_pins $nic/s_axis_mac_rx]
  connect_bd_net [get_bd_pins qsfp_port$label/rx_pack_stat] [get_bd_pins $nic/mac_rx_pack_stat]
  connect_bd_intf_net [get_bd_intf_pins $nic/m_axis_mac_tx] [get_bd_intf_pins qsfp_port$label/S_AXIS_TX]
  # Latency measurement (390.625 MHz): per-frame TX timestamp requests out,
  # MRMAC TX timestamps (with their tags) back in. The RX timestamps arrive
  # in-band on s_axis_mac_rx tuser[48:1].
  lat_conn_intf $nic/m_axis_tx_ptp qsfp_port$label/S_AXIS_TX_PTP
  lat_conn qsfp_port$label/tx_ptp_tstamp       $nic/tx_ptp_tstamp_in
  lat_conn qsfp_port$label/tx_ptp_tstamp_tag   $nic/tx_ptp_tstamp_tag_in
  lat_conn qsfp_port$label/tx_ptp_tstamp_valid $nic/tx_ptp_tstamp_valid_in
  # UI streams: UI0 raw <-> axi_dma_raw, UI2 socket <-> axi_dma_sock
  connect_bd_intf_net [get_bd_intf_pins $nic/m_axis_raw_rx]      [get_bd_intf_pins $dma_raw/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins $dma_raw/M_AXIS_MM2S]    [get_bd_intf_pins $nic/s_axis_raw_tx]
  connect_bd_intf_net [get_bd_intf_pins $nic/m_axis_sock_rx]     [get_bd_intf_pins $dma_sock/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins $dma_sock/M_AXIS_MM2S]   [get_bd_intf_pins $nic/s_axis_sock_tx]

  #########################################################
  # QSFP sideband GPIO (per port)
  #########################################################
  # Channel 1 (outputs): bit0=modsell, bit1=resetl, bit2=lpmode
  # Channel 2 (inputs):  bit0=modprsl, bit1=intl
  #
  # Power-on default 0x2 -> modsell=0, resetl=1 (deasserted, active-low),
  # lpmode=0 (high power). resetl MUST default high or the QSFP module powers
  # up held in reset (laser off, no link) until software writes the GPIO. The
  # sfp28-fmc-xxv reference hard-ties its SFP tx_disable to const_low for the
  # same "module enabled at config time" behaviour; here we keep the line
  # software-controllable (modsell/lpmode/resetl on the GPIO) but default it to
  # the enabled state. Nothing else drives this signal (no driver/gpio-hog).
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_qsfp$label
  set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {3} \
    CONFIG.C_GPIO2_WIDTH {2} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_DOUT_DEFAULT {0x00000002} \
  ] [get_bd_cells axi_gpio_qsfp$label]
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_gpio_qsfp$label/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins axi_gpio_qsfp$label/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI] [get_bd_intf_pins axi_gpio_qsfp$label/S_AXI]
  incr smc_mi

  # GPIO channel 1 outputs -> modsell/resetl/lpmode
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_modsell$label
  set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_modsell$label]
  connect_bd_net [get_bd_pins axi_gpio_qsfp$label/gpio_io_o] [get_bd_pins slice_modsell$label/Din]
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_resetl$label
  set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_resetl$label]
  connect_bd_net [get_bd_pins axi_gpio_qsfp$label/gpio_io_o] [get_bd_pins slice_resetl$label/Din]
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_lpmode$label
  set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {2} CONFIG.DIN_TO {2} CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_lpmode$label]
  connect_bd_net [get_bd_pins axi_gpio_qsfp$label/gpio_io_o] [get_bd_pins slice_lpmode$label/Din]

  create_bd_port -dir O modsell_qsfp$label
  create_bd_port -dir O resetl_qsfp$label
  create_bd_port -dir O lpmode_qsfp$label
  connect_bd_net [get_bd_pins slice_modsell$label/Dout] [get_bd_ports modsell_qsfp$label]
  connect_bd_net [get_bd_pins slice_resetl$label/Dout] [get_bd_ports resetl_qsfp$label]
  connect_bd_net [get_bd_pins slice_lpmode$label/Dout] [get_bd_ports lpmode_qsfp$label]

  # GPIO channel 2 inputs <- modprsl/intl
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 qsfp_in_cat$label
  set_property CONFIG.NUM_PORTS {2} [get_bd_cells qsfp_in_cat$label]
  create_bd_port -dir I modprsl_qsfp$label
  create_bd_port -dir I intl_qsfp$label
  connect_bd_net [get_bd_ports modprsl_qsfp$label] [get_bd_pins qsfp_in_cat$label/In0]
  connect_bd_net [get_bd_ports intl_qsfp$label] [get_bd_pins qsfp_in_cat$label/In1]
  connect_bd_net [get_bd_pins qsfp_in_cat$label/dout] [get_bd_pins axi_gpio_qsfp$label/gpio2_io_i]

  #########################################################
  # QSFP module management I2C (per port)
  #########################################################
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_qsfp$label
  connect_bd_intf_net [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI] [get_bd_intf_pins axi_iic_qsfp$label/S_AXI]
  incr smc_mi
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_qsfp$label/s_axi_aclk]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins axi_iic_qsfp$label/s_axi_aresetn]
  lappend port_intr($label) "axi_iic_qsfp$label/iic2intc_irpt"
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 qsfp${label}_i2c
  connect_bd_intf_net [get_bd_intf_ports qsfp${label}_i2c] [get_bd_intf_pins axi_iic_qsfp$label/IIC]
}
#########################################################
# Shared 1588 system timer (ts_clk, 250 MHz)
#########################################################
# ptp_systimer (src/hdl/ptp_systimer.v) is one free-running 55-bit timer in
# the MRMAC time format (2^-8 ns units in [54:0], +4 ns per 250 MHz cycle)
# that drives ctl_{tx,rx}_ptp_systemtimer_0 of BOTH MRMACs, with the
# st_sync / st_overwrite strobes the MRMAC uses to load it. All its outputs
# are in the ts_clk domain, which is the domain of those MRMAC inputs (see
# create_qsfp_port), so no CDC is needed between it and the MRMACs.
if { [llength [get_files -quiet */ptp_systimer.v]] > 0 } {
  create_bd_cell -type module -reference ptp_systimer ptp_systimer_0
  lat_conn $ts_clk ptp_systimer_0/ts_clk
  lat_conn rst_ts/peripheral_aresetn ptp_systimer_0/ts_aresetn
  # sync_req (asynchronous, rising edge = one extra st_sync) from port 0's
  # GT-control GPIO CH1 bit 3, for bench experiments with the timer protocol
  lat_conn qsfp_port0/gpio_ptp_sync_req ptp_systimer_0/sync_req
  foreach label $ports {
    foreach dir {tx rx} {
      foreach pin {systemtimer st_sync st_overwrite st_adjust st_adjust_type st_adjust_vld} {
        lat_conn ptp_systimer_0/ctl_${dir}_ptp_$pin qsfp_port$label/ctl_${dir}_ptp_$pin
      }
    }
  }
  # ptp_systimer_0/systimer (the raw timer) is left open: the MRMACs report
  # the same time at STAT_{TX,RX}_1588_TOD.
} else {
  lappend lat_missing "ptp_systimer.v (module reference)"
  puts "WARNING: \[bd_versal\] src/hdl/ptp_systimer.v is not in the project: the MRMAC system timers are not driven"
}

if { [llength $lat_missing] > 0 } {
  if { $lat_strict } {
    error "bd_versal.tcl: latency-measurement ports missing in the RTL: [join $lat_missing {; }]"
  }
  puts "WARNING: \[bd_versal\] lat_strict = 0: [llength $lat_missing] latency connection(s) skipped"
}

# All DMA NoC ports are clocked by aclk6 (system clock)
set_property CONFIG.ASSOCIATED_BUSIF [join $noc_dma_si ":"] [get_bd_pins axi_noc_0/aclk6]

#########################################################
# Shared I2C bus (direct, no PCA9548 mux)
#########################################################
# clk_i2c : Si5328 jitter-attenuating clock generator (one per board, shared by
# both QSFP ports - it sources both GBTCLK0 and GBTCLK1 reference clocks).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_clk
connect_bd_intf_net [get_bd_intf_pins axi_smc/M[format "%02d" $smc_mi]_AXI] [get_bd_intf_pins axi_iic_clk/S_AXI]
incr smc_mi
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_clk/s_axi_aclk]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins axi_iic_clk/s_axi_aresetn]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 clk_i2c
connect_bd_intf_net [get_bd_intf_ports clk_i2c] [get_bd_intf_pins axi_iic_clk/IIC]

# Interrupts (fixed order, see docs/source/design.md):
#   pl_ps_irq0 axi_dma_raw MM2S     pl_ps_irq1 axi_dma_raw S2MM
#   pl_ps_irq2 axi_dma_sock MM2S    pl_ps_irq3 axi_dma_sock S2MM
#   pl_ps_irq4 axi_iic_qsfp0        pl_ps_irq5 axi_iic_clk (Si5328)
#   pl_ps_irq6 axi_dma_raw_1 MM2S   pl_ps_irq7 axi_dma_raw_1 S2MM
#   pl_ps_irq8 axi_dma_sock_1 MM2S  pl_ps_irq9 axi_dma_sock_1 S2MM
#   pl_ps_irq10 axi_iic_qsfp1                          (port 1 only)
set intr_list $port_intr(0)
lappend intr_list "axi_iic_clk/iic2intc_irpt"
foreach label $ports {
  if { $label != 0 } { set intr_list [concat $intr_list $port_intr($label)] }
}
set intr_index 0
foreach intr $intr_list {
  connect_bd_net [get_bd_pins $intr] [get_bd_pins versal_cips_0/pl_ps_irq$intr_index]
  set intr_index [expr {$intr_index+1}]
}

# Assign addresses: DDR (via the NoC) for the DMA masters, and the M_AXI_LPD
# window for the AXI-Lite slaves. The LPD offsets are fixed (the bare-metal
# software's hw_config.h depends on them). Port 0 keeps the one-port map (its MRMAC /
# GPIO / IIC offsets are those of the 2x-qsfp28-fmc design); each further
# port p repeats port 0's layout at +p * 0x10_0000, so a port's register
# block is at 0x8000_0000 + p * 0x10_0000 + the same offset (port 1's
# +0x4_0000 slot is unused: the Si5328 IIC is shared). Full map:
# docs/source/design.md.
set lpd_map {}
foreach label $ports {
  set sfx  [port_sfx $label]
  set base [expr {0x80000000 + $label * 0x100000}]
  foreach {cell offset range} [list \
    qsfp_port$label/mrmac               0x00000 64K \
    axi_gpio_qsfp$label                 0x20000 64K \
    axi_iic_qsfp$label                  0x50000 64K \
    qsfp_port$label/axi_gpio_gt$label   0x70000 64K \
    axi_dma_raw$sfx                     0x80000 64K \
    axi_dma_sock$sfx                    0x90000 64K \
    zircon_nic_$label                   0xA0000 4K \
  ] {
    lappend lpd_map $cell [format "0x%08X" [expr {$base + $offset}]] $range
  }
}
lappend lpd_map axi_iic_clk 0x80040000 64K
set lpd_space [get_bd_addr_spaces versal_cips_0/M_AXI_LPD]
foreach {cell offset range} $lpd_map {
  set slv [get_bd_addr_segs -quiet -of_objects [get_bd_cells /$cell]]
  if { [llength $slv] != 1 } {
    error "bd_versal.tcl: expected one slave address segment in $cell, found [llength $slv]: $slv"
  }
  assign_bd_address -target_address_space $lpd_space -offset $offset -range $range $slv
}
# Everything else: the DMA masters' view of DDR (and the CIPS' own map)
assign_bd_address
# Layout and validate
regenerate_bd_layout
save_bd_design
validate_bd_design
save_bd_design

################################################################
# Block design build script for the qsfp28-fmc-zircon design on MicroBlaze
# (pure FPGA) targets: KCU116 (Kintex UltraScale+ XCKU5P).
#
# Opsero 2x QSFP28 FMC (OP120), QSFP port 0 only (the KCU116 FMC HPC wires
# DP0-3 = one GTY quad; the QSFP1 module is held in reset / low power).
#
# This script is sourced by build.tcl, which sets:
#   block_name = zircon
#   board_name = kcu116
#   ports      = { 0 }  (config/data.json "ports": 1)
#   fec        = rs     (RS-FEC is fixed on in Taxi's CMAC wrapper)
#
# Datapath (the vck190 MRMAC + packer + adapters are replaced by one module
# reference, zircon_cmac_us, which wraps Taxi's taxi_eth_mac_100g_us: the
# UltraScale+ CMACE4 hard MAC with RS-FEC + 4 GTY lanes, CAUI-4):
#
#   zircon_cmac_0 m_axis_mac_rx (512b, rx_clk)  -> zircon_nic_0 s_axis_mac_rx
#   zircon_nic_0 m_axis_mac_tx  (512b, tx_clk)  -> zircon_cmac_0 s_axis_mac_tx
#   zircon_nic_0 raw  (UI0) <-> axi_dma_raw  (SG, 512b)     (100 MHz)
#   zircon_nic_0 sock (UI2) <-> axi_dma_sock (SG, 512b)     (100 MHz)
#   zircon_nic_0 core                                       (300 MHz)
#
# Clocks (docs/DESIGN_SPEC.md 2.2):
#   ddr4_0/addn_ui_clkout1  100 MHz  sys_clk: MicroBlaze, AXI peripherals, both
#                                    AXI DMAs, zircon_nic ui_clk
#   ddr4_0/c0_ddr4_ui_clk  333.25 MHz  DDR SmartConnect master side only
#   clk_wiz_0/clk_out1      300 MHz  zircon_nic core (CORE_HZ 300000000)
#   clk_wiz_0/clk_out2      250 MHz  shim timestamp timebase (ts_clk)
#   clk_wiz_0/clk_out3      125 MHz  shim ctrl_clk (Taxi xcvr_ctrl_clk, GT APB,
#                                    shim s_axi)
#   zircon_cmac_0/tx_clk, rx_clk  322.265625 MHz  zircon_nic MAC side
#
# Bare-metal only: no interrupt controller (the application polls every
# peripheral). Address map: section "Address map" at the end (fixed, the
# application's hw_config.h depends on it).
################################################################

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

if { ![info exists block_name] } { set block_name zircon }
if { ![info exists ports] } { set ports { 0 } }
set ports [list {*}$ports]
if { $ports ne [list 0] } {
  error "bd_microblaze.tcl: only QSFP port 0 exists on this board (got { $ports })"
}

create_bd_design $block_name
current_bd_design $block_name

set parentCell [get_bd_cells /]
set parentObj [get_bd_cells $parentCell]
set oldCurInst [current_bd_instance .]
current_bd_instance $parentObj

# Connect a pin only if it is not already driven (the board / MicroBlaze
# automations connect some of these themselves, depending on the release).
proc ensure_net { src dst } {
  if { [llength [get_bd_nets -quiet -of_objects [get_bd_pins $dst]]] == 0 } {
    connect_bd_net [get_bd_pins $src] [get_bd_pins $dst]
  }
}

#########################################################
# DDR4 MIG (board preset) + 100 MHz system clock
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4 ddr4_0
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {default_sysclk1_300 ( 300 MHz System differential clock ) } Manual_Source {Auto}}  [get_bd_intf_pins ddr4_0/C0_SYS_CLK]
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {ddr4_sdram_075 ( DDR4 SDRAM C1 ) } Manual_Source {Auto}}  [get_bd_intf_pins ddr4_0/C0_DDR4]
set_property -dict [list CONFIG.ADDN_UI_CLKOUT1_FREQ_HZ {100}] [get_bd_cells ddr4_0]
# Board reset (CPU_RESET pushbutton, active high) -> MIG sys_rst, port "reset"
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {reset ( FPGA Reset ) } Manual_Source {Auto}}  [get_bd_pins ddr4_0/sys_rst]

#########################################################
# MicroBlaze (bare metal): caches, 128 KB LMB grown to 256 KB below, MDM,
# no interrupt controller
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0
apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config { axi_intc {0} axi_periph {Enabled} cache {32KB} clk {/ddr4_0/addn_ui_clkout1 (100 MHz)} cores {1} debug_module {Debug Only} ecc {None} local_mem {128KB} preset {None}}  [get_bd_cells microblaze_0]
# Cached instruction/data ports into the DDR4 controller (creates SmartConnect
# axi_smc: S00 = DC, S01 = IC -> ddr4_0/C0_DDR4_S_AXI). The DMA masters join it
# below.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/ddr4_0/addn_ui_clkout1 (100 MHz)} Clk_slave {/ddr4_0/c0_ddr4_ui_clk (300 MHz)} Clk_xbar {Auto} Master {/microblaze_0 (Cached)} Slave {/ddr4_0/C0_DDR4_S_AXI} ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}}  [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]

# Bare-metal processor: no MMU; barrel shifter, divider, 64-bit multiplier and
# the exceptions the AMD standalone BSP expects (as ethernet-fmc-taxi-eth).
set_property -dict [list \
  CONFIG.G_USE_EXCEPTIONS {1} \
  CONFIG.C_USE_MSR_INSTR {1} \
  CONFIG.C_USE_PCMP_INSTR {1} \
  CONFIG.C_USE_BARREL {1} \
  CONFIG.C_USE_DIV {1} \
  CONFIG.C_USE_HW_MUL {2} \
  CONFIG.C_UNALIGNED_EXCEPTIONS {1} \
  CONFIG.C_ILL_OPCODE_EXCEPTION {1} \
  CONFIG.C_M_AXI_I_BUS_EXCEPTION {1} \
  CONFIG.C_M_AXI_D_BUS_EXCEPTION {1} \
  CONFIG.C_DIV_ZERO_EXCEPTION {1} \
  CONFIG.C_PVR {2} \
  CONFIG.C_OPCODE_0x0_ILLEGAL {1} \
  CONFIG.C_ICACHE_LINE_LEN {8} \
  CONFIG.C_ICACHE_VICTIMS {8} \
  CONFIG.C_ICACHE_STREAMS {1} \
  CONFIG.C_DCACHE_VICTIMS {8} \
  CONFIG.C_USE_FPU {0} \
  CONFIG.C_USE_MMU {0} \
] [get_bd_cells microblaze_0]

# The board reset port also drives the 100 MHz processor system reset
ensure_net reset rst_ddr4_0_100M/ext_reset_in

set sys_clk     "ddr4_0/addn_ui_clkout1"
set ddr_ui_clk  "ddr4_0/c0_ddr4_ui_clk"
set sys_rstn    "rst_ddr4_0_100M/peripheral_aresetn"
set sys_rst     "rst_ddr4_0_100M/peripheral_reset"
set sys_icrstn  "rst_ddr4_0_100M/interconnect_aresetn"

#########################################################
# Clock wizard: 300 MHz core, 250 MHz timestamp, 125 MHz control
#########################################################
# MMCM from the 100 MHz system clock (already on a BUFG): VCO 1500 MHz
# (D=1, M=15), CLKOUT0 /5 = 300, CLKOUT1 /6 = 250, CLKOUT2 /12 = 125.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list \
  CONFIG.PRIMITIVE {MMCM} \
  CONFIG.PRIM_SOURCE {No_buffer} \
  CONFIG.PRIM_IN_FREQ {100.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {300.000} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {250.000} \
  CONFIG.CLKOUT3_USED {true} \
  CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {true} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
] [get_bd_cells clk_wiz_0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins $sys_rst] [get_bd_pins clk_wiz_0/reset]
set core_clk "clk_wiz_0/clk_out1"
set ts_clk   "clk_wiz_0/clk_out2"
set ctrl_clk "clk_wiz_0/clk_out3"

# Proc system resets for the three MMCM clocks (board reset + MMCM lock)
foreach {rst clk} [list rst_core_300M $core_clk rst_ts_250M $ts_clk rst_ctrl_125M $ctrl_clk] {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset $rst
  connect_bd_net [get_bd_pins $clk] [get_bd_pins $rst/slowest_sync_clk]
  connect_bd_net [get_bd_ports reset] [get_bd_pins $rst/ext_reset_in]
  connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins $rst/dcm_locked]
}

#########################################################
# DDR SmartConnect: MicroBlaze DC/IC (S00/S01) + 2 DMAs x {SG, MM2S, S2MM}
# (S02..S07). Master side on the MIG ui clock, slave side on sys_clk.
#########################################################
set_property -dict [list CONFIG.NUM_SI {8} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_smc]
ensure_net $ddr_ui_clk axi_smc/aclk
ensure_net $sys_clk axi_smc/aclk1
ensure_net $sys_icrstn axi_smc/aresetn

#########################################################
# Peripheral interconnect (MicroBlaze M_AXI_DP). All AXI-Lite slaves run on
# sys_clk except the CMAC shim's s_axi (ctrl_clk, 125 MHz).
#   M00 zircon_cmac_0  M01 axi_dma_raw  M02 axi_dma_sock  M03 zircon_nic_0
#   M04 axi_gpio_qsfp0 M05 axi_iic_qsfp0 M06 axi_iic_clk  M07 axi_uartlite_0
#   M08 axi_timer_0    M09 axi_timer_1
#########################################################
set periph microblaze_0_axi_periph
if { [llength [get_bd_cells -quiet $periph]] == 0 } {
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect $periph
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_DP] [get_bd_intf_pins $periph/S00_AXI]
}
set periph_vlnv [get_property VLNV [get_bd_cells $periph]]
set periph_num_mi 10
if { [string match "*:smartconnect:*" $periph_vlnv] } {
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI $periph_num_mi CONFIG.NUM_CLKS {2}] [get_bd_cells $periph]
  ensure_net $sys_clk $periph/aclk
  ensure_net $ctrl_clk $periph/aclk1
  ensure_net $sys_icrstn $periph/aresetn
} else {
  # AXI Interconnect: one clock / reset pin pair per master port
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI $periph_num_mi] [get_bd_cells $periph]
  ensure_net $sys_clk $periph/ACLK
  ensure_net $sys_icrstn $periph/ARESETN
  ensure_net $sys_clk $periph/S00_ACLK
  ensure_net $sys_rstn $periph/S00_ARESETN
  for {set i 0} {$i < $periph_num_mi} {incr i} {
    set m [format "M%02d" $i]
    if { $i == 0 } {
      ensure_net $ctrl_clk $periph/${m}_ACLK
      ensure_net rst_ctrl_125M/peripheral_aresetn $periph/${m}_ARESETN
    } else {
      ensure_net $sys_clk $periph/${m}_ACLK
      ensure_net $sys_rstn $periph/${m}_ARESETN
    }
  }
}
proc periph_m { i } {
  return [get_bd_intf_pins microblaze_0_axi_periph/M[format "%02d" $i]_AXI]
}

#########################################################
# zircon_cmac_0: UltraScale+ 100G CMAC (Taxi taxi_eth_mac_100g_us) shim
#########################################################
create_bd_cell -type module -reference zircon_cmac_us zircon_cmac_0
set_property -dict [list \
  CONFIG.FAMILY {kintexuplus} \
  CONFIG.CFG_LOW_LATENCY {0} \
] [get_bd_cells zircon_cmac_0]
connect_bd_net [get_bd_pins $ctrl_clk] [get_bd_pins zircon_cmac_0/ctrl_clk]
connect_bd_net [get_bd_pins rst_ctrl_125M/peripheral_aresetn] [get_bd_pins zircon_cmac_0/ctrl_aresetn]
connect_bd_net [get_bd_pins $ts_clk] [get_bd_pins zircon_cmac_0/ts_clk]
connect_bd_net [get_bd_pins rst_ts_250M/peripheral_aresetn] [get_bd_pins zircon_cmac_0/ts_aresetn]
connect_bd_intf_net [periph_m 0] [get_bd_intf_pins zircon_cmac_0/s_axi]

# GT reference clock (322.265625 MHz, FMC Si5328 CKOUT1 -> GBTCLK0) and the
# four GTY lanes of QSFP slot 0 (FMC DP0-3)
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_ref_clk_0
set_property CONFIG.FREQ_HZ 322265625 [get_bd_intf_ports gt_ref_clk_0]
connect_bd_intf_net [get_bd_intf_ports gt_ref_clk_0] [get_bd_intf_pins zircon_cmac_0/gt_ref_clk]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp0_gt
connect_bd_intf_net [get_bd_intf_pins zircon_cmac_0/gt] [get_bd_intf_ports qsfp0_gt]

#########################################################
# AXI DMAs (raw = UI0, sock = UI2)
#########################################################
# As the vck190 design (SG, no status/control stream, 512-bit MM and stream,
# DRE, 64-beat bursts = 4 KB) but 32-bit addressing: the MicroBlaze system is
# 32-bit and the 1 GB DDR4 sits at 0x8000_0000. 512-bit MM width is required
# (the stream width cannot exceed the MM width).
set smc_si 2
foreach dma {axi_dma_raw axi_dma_sock} mi {1 2} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma $dma
  set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_addr_width {32} \
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
  connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins $dma/axi_resetn]
  connect_bd_intf_net [periph_m $mi] [get_bd_intf_pins $dma/S_AXI_LITE]
  foreach m {M_AXI_SG M_AXI_MM2S M_AXI_S2MM} {
    connect_bd_intf_net [get_bd_intf_pins $dma/$m] [get_bd_intf_pins axi_smc/S[format "%02d" $smc_si]_AXI]
    incr smc_si
  }
}

#########################################################
# zircon_nic_0 (Taxi Zircon IP stack, module reference; defaults)
#########################################################
create_bd_cell -type module -reference zircon_nic zircon_nic_0
# core (300 MHz)
connect_bd_net [get_bd_pins $core_clk] [get_bd_pins zircon_nic_0/clk]
connect_bd_net [get_bd_pins rst_core_300M/peripheral_aresetn] [get_bd_pins zircon_nic_0/aresetn]
# MAC side: the CMAC's own clocks and the shim's MAC-side resets (held while
# the transceiver datapath of that direction is in reset)
connect_bd_net [get_bd_pins zircon_cmac_0/rx_clk] [get_bd_pins zircon_nic_0/mac_rx_clk]
connect_bd_net [get_bd_pins zircon_cmac_0/mac_rx_aresetn] [get_bd_pins zircon_nic_0/mac_rx_aresetn]
connect_bd_net [get_bd_pins zircon_cmac_0/tx_clk] [get_bd_pins zircon_nic_0/mac_tx_clk]
connect_bd_net [get_bd_pins zircon_cmac_0/mac_tx_aresetn] [get_bd_pins zircon_nic_0/mac_tx_aresetn]
# UI / AXI-Lite (100 MHz)
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins zircon_nic_0/ui_clk]
connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins zircon_nic_0/ui_aresetn]
connect_bd_intf_net [periph_m 3] [get_bd_intf_pins zircon_nic_0/s_axi]
# MAC-side streams
connect_bd_intf_net [get_bd_intf_pins zircon_cmac_0/m_axis_mac_rx] [get_bd_intf_pins zircon_nic_0/s_axis_mac_rx]
connect_bd_intf_net [get_bd_intf_pins zircon_nic_0/m_axis_mac_tx] [get_bd_intf_pins zircon_cmac_0/s_axis_mac_tx]
# No RX packer on this target: its status input reads 0
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_pack_stat
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0}] [get_bd_cells const_pack_stat]
connect_bd_net [get_bd_pins const_pack_stat/dout] [get_bd_pins zircon_nic_0/mac_rx_pack_stat]
# Latency measurement (tx_clk): per-frame TX timestamp requests out, fabric
# timestamps (with their tags) back in. The RX timestamps arrive in-band on
# s_axis_mac_rx tuser[48:1].
connect_bd_intf_net [get_bd_intf_pins zircon_nic_0/m_axis_tx_ptp] [get_bd_intf_pins zircon_cmac_0/s_axis_tx_ptp]
connect_bd_net [get_bd_pins zircon_cmac_0/tx_ptp_tstamp_out]       [get_bd_pins zircon_nic_0/tx_ptp_tstamp_in]
connect_bd_net [get_bd_pins zircon_cmac_0/tx_ptp_tstamp_tag_out]   [get_bd_pins zircon_nic_0/tx_ptp_tstamp_tag_in]
connect_bd_net [get_bd_pins zircon_cmac_0/tx_ptp_tstamp_valid_out] [get_bd_pins zircon_nic_0/tx_ptp_tstamp_valid_in]
# UI streams: UI0 raw <-> axi_dma_raw, UI2 socket <-> axi_dma_sock
connect_bd_intf_net [get_bd_intf_pins zircon_nic_0/m_axis_raw_rx]   [get_bd_intf_pins axi_dma_raw/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_raw/M_AXIS_MM2S]      [get_bd_intf_pins zircon_nic_0/s_axis_raw_tx]
connect_bd_intf_net [get_bd_intf_pins zircon_nic_0/m_axis_sock_rx]  [get_bd_intf_pins axi_dma_sock/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_sock/M_AXIS_MM2S]     [get_bd_intf_pins zircon_nic_0/s_axis_sock_tx]

#########################################################
# QSFP0 sideband GPIO
#########################################################
# Channel 1 (outputs): bit0=modsell, bit1=resetl, bit2=lpmode
# Channel 2 (inputs):  bit0=modprsl, bit1=intl
# Power-on default 0x2: modsell=0, resetl=1 (module out of reset), lpmode=0,
# so the module is enabled at configuration time (as the vck190 design).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_qsfp0
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {3} \
  CONFIG.C_GPIO2_WIDTH {2} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_ALL_INPUTS_2 {1} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000002} \
] [get_bd_cells axi_gpio_qsfp0]
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_gpio_qsfp0/s_axi_aclk]
connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins axi_gpio_qsfp0/s_axi_aresetn]
connect_bd_intf_net [periph_m 4] [get_bd_intf_pins axi_gpio_qsfp0/S_AXI]

foreach {sig bit} {modsell 0 resetl 1 lpmode 2} {
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_${sig}0
  set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit CONFIG.DOUT_WIDTH {1}] [get_bd_cells slice_${sig}0]
  connect_bd_net [get_bd_pins axi_gpio_qsfp0/gpio_io_o] [get_bd_pins slice_${sig}0/Din]
  create_bd_port -dir O -from 0 -to 0 ${sig}_qsfp0
  connect_bd_net [get_bd_pins slice_${sig}0/Dout] [get_bd_ports ${sig}_qsfp0]
}
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 qsfp_in_cat0
set_property CONFIG.NUM_PORTS {2} [get_bd_cells qsfp_in_cat0]
create_bd_port -dir I modprsl_qsfp0
create_bd_port -dir I intl_qsfp0
connect_bd_net [get_bd_ports modprsl_qsfp0] [get_bd_pins qsfp_in_cat0/In0]
connect_bd_net [get_bd_ports intl_qsfp0] [get_bd_pins qsfp_in_cat0/In1]
connect_bd_net [get_bd_pins qsfp_in_cat0/dout] [get_bd_pins axi_gpio_qsfp0/gpio2_io_i]

#########################################################
# QSFP0 module management I2C and the Si5328 clock generator I2C
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_qsfp0
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_qsfp0/s_axi_aclk]
connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins axi_iic_qsfp0/s_axi_aresetn]
connect_bd_intf_net [periph_m 5] [get_bd_intf_pins axi_iic_qsfp0/S_AXI]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 qsfp0_i2c
connect_bd_intf_net [get_bd_intf_ports qsfp0_i2c] [get_bd_intf_pins axi_iic_qsfp0/IIC]

# Si5328 (I2C 0x68): shared by both QSFP ports, sources GBTCLK0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_clk
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_iic_clk/s_axi_aclk]
connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins axi_iic_clk/s_axi_aresetn]
connect_bd_intf_net [periph_m 6] [get_bd_intf_pins axi_iic_clk/S_AXI]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 clk_i2c
connect_bd_intf_net [get_bd_intf_ports clk_i2c] [get_bd_intf_pins axi_iic_clk/IIC]

#########################################################
# UART console (USB-UART, board interface rs232_uart), 115200 8N1
#########################################################
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0
connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins axi_uartlite_0/s_axi_aclk]
connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins axi_uartlite_0/s_axi_aresetn]
connect_bd_intf_net [periph_m 7] [get_bd_intf_pins axi_uartlite_0/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {rs232_uart ( UART ) } Manual_Source {Auto}}  [get_bd_intf_pins axi_uartlite_0/UART]
set_property -dict [list CONFIG.C_BAUDRATE {115200} CONFIG.C_DATA_BITS {8} CONFIG.C_USE_PARITY {0}] [get_bd_cells axi_uartlite_0]

#########################################################
# Timers: axi_timer_0 = xiltimer sleep/delay (the cell name matters: the
# standalone xiltimer configuration selects it by name); axi_timer_1 = the
# application's free-running 64-bit timebase (cascade mode, set by software)
#########################################################
foreach {tmr mi} {axi_timer_0 8 axi_timer_1 9} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer $tmr
  connect_bd_net [get_bd_pins $sys_clk] [get_bd_pins $tmr/s_axi_aclk]
  connect_bd_net [get_bd_pins $sys_rstn] [get_bd_pins $tmr/s_axi_aresetn]
  connect_bd_intf_net [periph_m $mi] [get_bd_intf_pins $tmr/S_AXI]
}

#########################################################
# QSFP0 user LEDs: green = link up (CMAC RX aligned), red = not
#########################################################
create_bd_port -dir O grn_led_qsfp0
connect_bd_net [get_bd_pins zircon_cmac_0/link_up] [get_bd_ports grn_led_qsfp0]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 logic_red_led0
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells logic_red_led0]
connect_bd_net [get_bd_pins zircon_cmac_0/link_up] [get_bd_pins logic_red_led0/Op1]
create_bd_port -dir O -from 0 -to 0 red_led_qsfp0
connect_bd_net [get_bd_pins logic_red_led0/Res] [get_bd_ports red_led_qsfp0]

#########################################################
# QSFP slot 1: not connected on the KCU116 FMC HPC. The module is held in
# reset and low-power mode, its LEDs are off:
#   modsell = 1 (deselected), resetl = 0 (reset), lpmode = 1, LEDs = 0
#########################################################
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_high_qsfp1
set_property CONFIG.CONST_VAL {1} [get_bd_cells const_high_qsfp1]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_low_qsfp1
set_property CONFIG.CONST_VAL {0} [get_bd_cells const_low_qsfp1]
foreach {port net} {modsell const_high resetl const_low lpmode const_high grn_led const_low red_led const_low} {
  create_bd_port -dir O -from 0 -to 0 ${port}_qsfp1
  connect_bd_net [get_bd_pins ${net}_qsfp1/dout] [get_bd_ports ${port}_qsfp1]
}

#########################################################
# Address map (MicroBlaze Data / Instruction, 32-bit). Fixed: the bare-metal
# hw_config.h uses these (zircon_cmac_0 and zircon_nic_0 are module references
# and get no XPAR_ macros). docs/DESIGN_SPEC.md 6b.
#########################################################
# Local memory: 256 KB (the automation offers 128 KB; growing the LMB
# controllers' range resizes the BRAM behind them)
foreach sp {Data Instruction} {
  foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces microblaze_0/$sp]] {
    set slv [get_bd_addr_segs -quiet -of_objects $seg]
    if { [string match "*lmb_bram_if_cntlr*" $slv] } {
      assign_bd_address -target_address_space [get_bd_addr_spaces microblaze_0/$sp] -offset 0x00000000 -range 256K $slv -force
    }
  }
}

set mb_data [get_bd_addr_spaces microblaze_0/Data]
foreach {cell offset range} {
  axi_uartlite_0  0x40000000 64K
  axi_timer_0     0x41C00000 64K
  axi_timer_1     0x41C10000 64K
  zircon_cmac_0   0x44000000 512K
  axi_dma_raw     0x44080000 64K
  axi_dma_sock    0x44090000 64K
  zircon_nic_0    0x440A0000 4K
  axi_gpio_qsfp0  0x440B0000 64K
  axi_iic_qsfp0   0x440C0000 64K
  axi_iic_clk     0x44100000 64K
} {
  set slv [get_bd_addr_segs -quiet -of_objects [get_bd_cells /$cell]]
  if { [llength $slv] != 1 } {
    error "bd_microblaze.tcl: expected one slave address segment in $cell, found [llength $slv]: $slv"
  }
  assign_bd_address -target_address_space $mb_data -offset $offset -range $range $slv -force
}

# DDR4 (1 GB at 0x8000_0000) for the cached MicroBlaze ports and every DMA master
set ddr_seg [get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK]
foreach sp [list microblaze_0/Data microblaze_0/Instruction \
                 axi_dma_raw/Data_SG axi_dma_raw/Data_MM2S axi_dma_raw/Data_S2MM \
                 axi_dma_sock/Data_SG axi_dma_sock/Data_MM2S axi_dma_sock/Data_S2MM] {
  assign_bd_address -target_address_space [get_bd_addr_spaces $sp] -offset 0x80000000 -range 1G $ddr_seg -force
}
# Anything left (nothing expected)
assign_bd_address

# Restore current instance
current_bd_instance $oldCurInst

# Layout and validate
regenerate_bd_layout
save_bd_design
validate_bd_design
save_bd_design

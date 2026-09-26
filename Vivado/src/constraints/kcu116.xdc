#---------------------------------------------------------------------
# Constraints for Opsero qsfp28-fmc-zircon ref design for KCU116 (HPC)
#
# 2x QSFP28 FMC (OP120), QSFP port 0 only: FMC slot 0 / DP0-3 / GBTCLK0,
# GTY bank 227 (quad X0Y12-15), 1x100GbE CAUI-4 on the KU5P's single CMAC
# (CMACE4_X0Y0) through Taxi's taxi_eth_mac_100g_us wrapper (inside the
# zircon_cmac_us module reference), feeding the Taxi Zircon IP stack.
# The KCU116 FMC HPC connector wires only DP0-3, so QSFP slot 1 cannot be
# used on this board: its module is held in reset / low power by constants.
# Pin assignments are those of the 2x-qsfp28-fmc reference design
# (kcu116.xdc, proven on hardware). KCU116 VADJ is fixed at 1.8 V.
# MicroBlaze system I/O (DDR4, UART, sys clock, reset) comes from the KCU116
# board files via block-design board automation - not constrained here.
#---------------------------------------------------------------------

#####################
# Si5328 clock generator I2C (shared)
#####################
set_property PACKAGE_PIN Y17 [get_ports clk_i2c_scl_io]; # LA02_P
set_property PACKAGE_PIN AA17 [get_ports clk_i2c_sda_io]; # LA02_N
set_property IOSTANDARD LVCMOS18 [get_ports clk_i2c_*]
set_property SLEW SLOW [get_ports clk_i2c_*]
set_property DRIVE 4 [get_ports clk_i2c_*]

# QSFP0 module I2C
set_property PACKAGE_PIN AB17 [get_ports qsfp0_i2c_scl_io]; # LA03_P
set_property PACKAGE_PIN AC17 [get_ports qsfp0_i2c_sda_io]; # LA03_N

set_property IOSTANDARD LVCMOS18 [get_ports qsfp*_i2c_*]
set_property SLEW SLOW [get_ports qsfp*_i2c_*]
set_property DRIVE 4 [get_ports qsfp*_i2c_*]

#####################
# GT reference clock (from the FMC Si5328 CKOUT1, 322.265625 MHz)
#####################
set_property PACKAGE_PIN K7 [get_ports gt_ref_clk_0_clk_p]; # GBTCLK0_M2C_P (bank 227)
# The IBUFDS_GTE4 is in the shim RTL (no IP creates this clock)
create_clock -period 3.103 -name gt_ref_clk_0 [get_ports gt_ref_clk_0_clk_p]

#############
# QSFP SLOT 0 (port 0) - DP0-3, GTY bank 227 (quad X0Y12-15)
#############

# Gigabit transceivers (4 lanes -> 1x100GbE CAUI-4)
set_property PACKAGE_PIN F7 [get_ports {qsfp0_gt_gtx_p[0]}]; # DP0_C2M_P (ch0)
set_property PACKAGE_PIN F6 [get_ports {qsfp0_gt_gtx_n[0]}]; # DP0_C2M_N
set_property PACKAGE_PIN D2 [get_ports {qsfp0_gt_grx_p[0]}]; # DP0_M2C_P
set_property PACKAGE_PIN D1 [get_ports {qsfp0_gt_grx_n[0]}]; # DP0_M2C_N

set_property PACKAGE_PIN E5 [get_ports {qsfp0_gt_gtx_p[1]}]; # DP1_C2M_P (ch1)
set_property PACKAGE_PIN E4 [get_ports {qsfp0_gt_gtx_n[1]}]; # DP1_C2M_N
set_property PACKAGE_PIN C4 [get_ports {qsfp0_gt_grx_p[1]}]; # DP1_M2C_P
set_property PACKAGE_PIN C3 [get_ports {qsfp0_gt_grx_n[1]}]; # DP1_M2C_N

set_property PACKAGE_PIN D7 [get_ports {qsfp0_gt_gtx_p[2]}]; # DP2_C2M_P (ch2)
set_property PACKAGE_PIN D6 [get_ports {qsfp0_gt_gtx_n[2]}]; # DP2_C2M_N
set_property PACKAGE_PIN B2 [get_ports {qsfp0_gt_grx_p[2]}]; # DP2_M2C_P
set_property PACKAGE_PIN B1 [get_ports {qsfp0_gt_grx_n[2]}]; # DP2_M2C_N

set_property PACKAGE_PIN B7 [get_ports {qsfp0_gt_gtx_p[3]}]; # DP3_C2M_P (ch3)
set_property PACKAGE_PIN B6 [get_ports {qsfp0_gt_gtx_n[3]}]; # DP3_C2M_N
set_property PACKAGE_PIN A4 [get_ports {qsfp0_gt_grx_p[3]}]; # DP3_M2C_P
set_property PACKAGE_PIN A3 [get_ports {qsfp0_gt_grx_n[3]}]; # DP3_M2C_N

# The KU5P's only CMAC. Taxi's IP script disables the cmac_usplus LOC xdc, so
# the hard block is placed here; the GT channels follow the package pins.
set_property LOC CMACE4_X0Y0 [get_cells -hierarchical -filter {REF_NAME == CMACE4}]

# The CMAC checks the skew between its four RX_SERDES_CLK inputs (max 1.0 ns).
# Taxi drives them from one BUFG_GT per lane (RXOUTCLK), and lane 0's is also
# rx_clk, the whole MAC-side RX fabric domain: left alone, its clock root lands
# away from the CMAC (X2Y2) and the skew check fails by ~0.34 ns. Root all four
# trees in the CMACE4_X0Y0 clock region (X3Y3). (A CLOCK_DELAY_GROUP is ignored
# here: the four buffers have no common driver, [Place 30-898].)
set_property USER_CLOCK_ROOT X3Y3 [get_nets -of_objects [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == BUFG_GT && NAME =~ *bufg_gt_rxusrclk_inst}] -filter {REF_PIN_NAME == O}]]

# QSFP slot 0: module I/O and User LEDs
set_property PACKAGE_PIN AA20 [get_ports {modsell_qsfp0[0]}]; # LA04_P
set_property PACKAGE_PIN AB20 [get_ports {resetl_qsfp0[0]}]; # LA04_N
set_property PACKAGE_PIN AC22 [get_ports modprsl_qsfp0]; # LA12_P
set_property PACKAGE_PIN AC23 [get_ports intl_qsfp0]; # LA12_N
set_property PACKAGE_PIN Y18 [get_ports {lpmode_qsfp0[0]}]; # LA11_P
set_property PACKAGE_PIN AD16 [get_ports grn_led_qsfp0]; # LA07_P
set_property PACKAGE_PIN AE16 [get_ports {red_led_qsfp0[0]}]; # LA07_N

#############
# QSFP SLOT 1 (port 1) - NOT CONNECTED on KCU116 (held in reset / low-power)
#############
set_property PACKAGE_PIN AB24 [get_ports {modsell_qsfp1[0]}]; # LA15_P
set_property PACKAGE_PIN AC24 [get_ports {resetl_qsfp1[0]}]; # LA15_N
set_property PACKAGE_PIN AA18 [get_ports {lpmode_qsfp1[0]}]; # LA11_N
set_property PACKAGE_PIN AE17 [get_ports {grn_led_qsfp1[0]}]; # LA08_P
set_property PACKAGE_PIN AF17 [get_ports {red_led_qsfp1[0]}]; # LA08_N

# QSFP module I/O IOSTANDARDs (both slots)
set_property IOSTANDARD LVCMOS18 [get_ports modsell_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports resetl_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports modprsl_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports intl_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports lpmode_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports grn_led_qsfp*]
set_property IOSTANDARD LVCMOS18 [get_ports red_led_qsfp*]

#####################
# Timing
#####################
# Clocks: the MIG creates its own clocks (c0_ddr4_ui_clk 333.25 MHz and
# addn_ui_clkout1 = 100 MHz sys_clk); clk_wiz_0 derives the 300 MHz core,
# 250 MHz timestamp and 125 MHz control clocks from sys_clk (generated
# clocks); the CMAC tx_clk / rx_clk (322.265625 MHz) are generated from the
# GT reference clock above through the GTY TXOUTCLK / RXOUTCLK.
# No clock groups are declared on purpose: set_clock_groups -asynchronous
# would override the -datapath_only max delays and bus-skew constraints that
# Taxi's CDC constraint scripts (implementation only, added by
# scripts/zircon_sources.tcl and scripts/cmac_sources.tcl) and the shim's
# zircon_cmac_us.tcl put on every crossing.
#
# QSFP sideband, LEDs and the I2C buses are slow, software-driven or static
# signals with no timing relationship to any clock at the FMC connector.
set_false_path -to [get_ports {modsell_qsfp0[0] resetl_qsfp0[0] lpmode_qsfp0[0] grn_led_qsfp0 red_led_qsfp0[0]}]
set_false_path -from [get_ports {modprsl_qsfp0 intl_qsfp0}]
set_false_path -to [get_ports {modsell_qsfp1[0] resetl_qsfp1[0] lpmode_qsfp1[0] grn_led_qsfp1[0] red_led_qsfp1[0]}]
set_false_path -to [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io}]
set_false_path -from [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io}]

#####################
# Bitstream / QSPI flash boot
#####################
# The FPGA configures itself from the 128 MB QSPI flash (x4) at power-on; the
# bare-metal application is embedded in the bitstream's LMB BRAM
# (zircon_boot.bit -> zircon_boot.mcs). Compression shrinks the ~15.4 MB
# uncompressed KU5P bitstream.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
# CONFIGRATE: 33 (the 2x-qsfp28-fmc value) is not a legal UltraScale+ value
# ([Netlist 29-154]); 31.9 MHz is the nearest legal rate below it.
set_property BITSTREAM.CONFIG.CONFIGRATE 31.9 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]

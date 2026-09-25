#---------------------------------------------------------------------
# Constraints for Opsero qsfp28-fmc-zircon ref design for VCK190-FMCP1
#
# 2x QSFP28 FMC (OP120), both QSFP ports (config/data.json "ports": 2):
# port 0 = FMC slot 0 / DP0-3 / GBTCLK0, port 1 = FMC slot 1 / DP4-7 /
# GBTCLK1, each a 1x100GbE (CAUI-4, RS-FEC) MRMAC feeding its own Taxi
# Zircon IP stack. Pin assignments are those of the 2x-qsfp28-fmc reference
# design (vck190_fmcp1.xdc, both ports).
#---------------------------------------------------------------------

#####################
# Si5328 clock generator I2C (shared)
#####################
set_property PACKAGE_PIN AW24 [get_ports clk_i2c_scl_io]; # LA02_P
set_property PACKAGE_PIN AY25 [get_ports clk_i2c_sda_io]; # LA02_N
set_property IOSTANDARD LVCMOS15 [get_ports clk_i2c_*]
set_property SLEW SLOW [get_ports clk_i2c_*]
set_property DRIVE 4 [get_ports clk_i2c_*]

# QSFP0 module I2C
set_property PACKAGE_PIN AV22 [get_ports qsfp0_i2c_scl_io]; # LA03_P
set_property PACKAGE_PIN AW21 [get_ports qsfp0_i2c_sda_io]; # LA03_N

# QSFP1 module I2C
set_property PACKAGE_PIN BB16 [get_ports qsfp1_i2c_scl_io]; # LA17_CC_P
set_property PACKAGE_PIN BC16 [get_ports qsfp1_i2c_sda_io]; # LA17_CC_N

set_property IOSTANDARD LVCMOS15 [get_ports qsfp*_i2c_*]
set_property SLEW SLOW [get_ports qsfp*_i2c_*]
set_property DRIVE 4 [get_ports qsfp*_i2c_*]

#####################
# GT reference clocks (from the FMC Si5328, 322.265625 MHz: CKOUT1 ->
# GBTCLK0 for port 0, CKOUT2 -> GBTCLK1 for port 1)
#####################
# The periods come from the block design (gt_ref_clk_<p> FREQ_HZ 322265625).
set_property PACKAGE_PIN M15 [get_ports {gt_ref_clk_0_clk_p[0]}]; # GBTCLK0_M2C_P
set_property PACKAGE_PIN K15 [get_ports {gt_ref_clk_1_clk_p[0]}]; # GBTCLK1_M2C_P

#############
# QSFP SLOT 0 (port 0) - DP0-3
#############

# Gigabit transceivers (4 lanes -> 1x100GbE CAUI-4)
set_property PACKAGE_PIN AB7 [get_ports {qsfp0_gt_gtx_p[0]}]; # DP0_C2M_P
set_property PACKAGE_PIN AB6 [get_ports {qsfp0_gt_gtx_n[0]}]; # DP0_C2M_N
set_property PACKAGE_PIN AB2 [get_ports {qsfp0_gt_grx_p[0]}]; # DP0_M2C_P
set_property PACKAGE_PIN AB1 [get_ports {qsfp0_gt_grx_n[0]}]; # DP0_M2C_N

set_property PACKAGE_PIN AA9 [get_ports {qsfp0_gt_gtx_p[1]}]; # DP1_C2M_P
set_property PACKAGE_PIN AA8 [get_ports {qsfp0_gt_gtx_n[1]}]; # DP1_C2M_N
set_property PACKAGE_PIN AA4 [get_ports {qsfp0_gt_grx_p[1]}]; # DP1_M2C_P
set_property PACKAGE_PIN AA3 [get_ports {qsfp0_gt_grx_n[1]}]; # DP1_M2C_N

set_property PACKAGE_PIN Y7 [get_ports {qsfp0_gt_gtx_p[2]}]; # DP2_C2M_P
set_property PACKAGE_PIN Y6 [get_ports {qsfp0_gt_gtx_n[2]}]; # DP2_C2M_N
set_property PACKAGE_PIN Y2 [get_ports {qsfp0_gt_grx_p[2]}]; # DP2_M2C_P
set_property PACKAGE_PIN Y1 [get_ports {qsfp0_gt_grx_n[2]}]; # DP2_M2C_N

set_property PACKAGE_PIN W9 [get_ports {qsfp0_gt_gtx_p[3]}]; # DP3_C2M_P
set_property PACKAGE_PIN W8 [get_ports {qsfp0_gt_gtx_n[3]}]; # DP3_C2M_N
set_property PACKAGE_PIN W4 [get_ports {qsfp0_gt_grx_p[3]}]; # DP3_M2C_P
set_property PACKAGE_PIN W3 [get_ports {qsfp0_gt_grx_n[3]}]; # DP3_M2C_N

# QSFP slot 0: module I/O and User LEDs
set_property PACKAGE_PIN AU21 [get_ports {modsell_qsfp0[0]}]; # LA04_P
set_property PACKAGE_PIN AV21 [get_ports {resetl_qsfp0[0]}]; # LA04_N
set_property PACKAGE_PIN BG21 [get_ports modprsl_qsfp0]; # LA12_P
set_property PACKAGE_PIN BF22 [get_ports intl_qsfp0]; # LA12_N
set_property PACKAGE_PIN BF23 [get_ports {lpmode_qsfp0[0]}]; # LA11_P
set_property PACKAGE_PIN BC25 [get_ports grn_led_qsfp0]; # LA07_P
set_property PACKAGE_PIN BD25 [get_ports {red_led_qsfp0[0]}]; # LA07_N

#############
# QSFP SLOT 1 (port 1) - DP4-7
#############

# Gigabit transceivers (4 lanes -> 1x100GbE CAUI-4)
set_property PACKAGE_PIN V7 [get_ports {qsfp1_gt_gtx_p[0]}]; # DP4_C2M_P
set_property PACKAGE_PIN V6 [get_ports {qsfp1_gt_gtx_n[0]}]; # DP4_C2M_N
set_property PACKAGE_PIN V2 [get_ports {qsfp1_gt_grx_p[0]}]; # DP4_M2C_P
set_property PACKAGE_PIN V1 [get_ports {qsfp1_gt_grx_n[0]}]; # DP4_M2C_N

set_property PACKAGE_PIN U9 [get_ports {qsfp1_gt_gtx_p[1]}]; # DP5_C2M_P
set_property PACKAGE_PIN U8 [get_ports {qsfp1_gt_gtx_n[1]}]; # DP5_C2M_N
set_property PACKAGE_PIN U4 [get_ports {qsfp1_gt_grx_p[1]}]; # DP5_M2C_P
set_property PACKAGE_PIN U3 [get_ports {qsfp1_gt_grx_n[1]}]; # DP5_M2C_N

set_property PACKAGE_PIN T7 [get_ports {qsfp1_gt_gtx_p[2]}]; # DP6_C2M_P
set_property PACKAGE_PIN T6 [get_ports {qsfp1_gt_gtx_n[2]}]; # DP6_C2M_N
set_property PACKAGE_PIN T2 [get_ports {qsfp1_gt_grx_p[2]}]; # DP6_M2C_P
set_property PACKAGE_PIN T1 [get_ports {qsfp1_gt_grx_n[2]}]; # DP6_M2C_N

set_property PACKAGE_PIN R9 [get_ports {qsfp1_gt_gtx_p[3]}]; # DP7_C2M_P
set_property PACKAGE_PIN R8 [get_ports {qsfp1_gt_gtx_n[3]}]; # DP7_C2M_N
set_property PACKAGE_PIN R4 [get_ports {qsfp1_gt_grx_p[3]}]; # DP7_M2C_P
set_property PACKAGE_PIN R3 [get_ports {qsfp1_gt_grx_n[3]}]; # DP7_M2C_N

# QSFP slot 1: module I/O and User LEDs
set_property PACKAGE_PIN AY22 [get_ports {modsell_qsfp1[0]}]; # LA15_P
set_property PACKAGE_PIN AY23 [get_ports {resetl_qsfp1[0]}]; # LA15_N
set_property PACKAGE_PIN BF24 [get_ports modprsl_qsfp1]; # LA05_P
set_property PACKAGE_PIN BG23 [get_ports intl_qsfp1]; # LA05_N
set_property PACKAGE_PIN BE22 [get_ports {lpmode_qsfp1[0]}]; # LA11_N
set_property PACKAGE_PIN BC22 [get_ports grn_led_qsfp1]; # LA08_P
set_property PACKAGE_PIN BC21 [get_ports {red_led_qsfp1[0]}]; # LA08_N

# QSFP module I/O IOSTANDARDs (both slots)
set_property IOSTANDARD LVCMOS15 [get_ports modsell_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports resetl_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports modprsl_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports intl_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports lpmode_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports grn_led_qsfp*]
set_property IOSTANDARD LVCMOS15 [get_ports red_led_qsfp*]

#####################
# Timing
#####################
# Clocks: pl0_ref_clk (100 MHz) -> clk_wizard_0 -> clk_100m (AXI-Lite, DMA,
# NoC, zircon_nic UI) and clk_300m (zircon_nic core); pl0_ref_clk ->
# axis_clk_wiz -> clk_390m625 (MRMAC AXIS client, adapters, AMD dwidth
# converters, zircon_nic MAC side). The clocks come from the clk_wizard IP
# constraints (each wizard's own 100 MHz clock on its clk_in1, i.e.
# pl0_ref_clk -- methodology TIMING-2/TIMING-4, as in 2x-qsfp28-fmc). No
# clock groups are declared: Vivado times all three as related clocks, and
# every path between them is a CDC with a datapath-only max delay. All AMD IP
# on the MAC side (adapters, width converters) is in the single 390.625 MHz
# domain. No create_clock is needed here. The clock-domain crossings
# inside zircon_nic (Taxi async FIFOs, reset and signal synchronizers) are
# constrained by Taxi's own Tcl constraint scripts, added to constrs_1 by
# scripts/zircon_sources.tcl as implementation-only constraints.

# QSFP sideband, LEDs and the I2C buses are slow, software-driven or static
# signals with no timing relationship to any clock at the FMC connector.
set_false_path -to [get_ports {modsell_qsfp0[0] resetl_qsfp0[0] lpmode_qsfp0[0] grn_led_qsfp0 red_led_qsfp0[0]}]
set_false_path -from [get_ports {modprsl_qsfp0 intl_qsfp0}]
set_false_path -to [get_ports {modsell_qsfp1[0] resetl_qsfp1[0] lpmode_qsfp1[0] grn_led_qsfp1 red_led_qsfp1[0]}]
set_false_path -from [get_ports {modprsl_qsfp1 intl_qsfp1}]
set_false_path -to [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io qsfp1_i2c_scl_io qsfp1_i2c_sda_io}]
set_false_path -from [get_ports {clk_i2c_scl_io clk_i2c_sda_io qsfp0_i2c_scl_io qsfp0_i2c_sda_io qsfp1_i2c_scl_io qsfp1_i2c_sda_io}]

# The MAC-side resets (rst_mac_rx / rst_mac_tx, port 1: rst_mac_rx_1 /
# rst_mac_tx_1) take the MRMAC GT reset-done
# on proc_sys_reset aux_reset_in, which crosses into 390.625 MHz through the
# IP's own xpm_cdc_single (constrained by the XPM): nothing to add here.

#####################
# 1588 timestamp clock (v1.3 latency measurement)
#####################
# ts_clk (250 MHz) is the third output of clk_wizard_0 and gets its clock
# from the wizard's own constraints, like clk_100m / clk_300m. It clocks
# ptp_systimer_0 and the MRMACs' TX_TS_CLK / RX_TS_CLK; the timer inputs of
# the MRMAC are on those clocks, so ptp_systimer -> MRMAC is a synchronous
# ts_clk path, and the MRMAC moves the time into its 390.625 MHz AXI clock
# domain internally (tx/rx_ptp_tstamp_out, tx_ptp_1588op_in and
# tx_ptp_tag_field_in are all on the AXI clock). Two slow fabric crossings
# remain, both on level signals:
#  - sync_req: axi_gpio_gt0 CH1 bit 3 (clk_100m) -> ptp_systimer's ASYNC_REG
#    two-flop synchroniser (ts_clk); the first flop's D is not timed.
#  - ptp_underrun: tx_axis_adapter's sticky flag (390.625 MHz) -> the
#    axi_gpio_gt<p> CH2 input synchroniser (clk_100m).
set_false_path -to [get_pins -hier -filter {NAME =~ */ptp_systimer_0/*req_sr_reg[0]/D}]
set_false_path -from [get_cells -hier -filter {NAME =~ */tx_axis_adapter/*underrun_reg* && IS_SEQUENTIAL}] -to [get_cells -hier -filter {NAME =~ */axi_gpio_gt*/* && IS_SEQUENTIAL}]

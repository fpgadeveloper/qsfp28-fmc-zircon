# Bring-up notes

The register-level sequences the bare-metal application (`Vitis/common/src/`) uses to bring
both 100G ports up, for anyone who ports them to other software. Sources: the 2x-qsfp28-fmc
design's `vadj.c`, `si5328.c` and `mrmac.c`, and the MRMAC IP's generated example code for this
configuration
(`Vivado/vck190_fmcp1/vck190_fmcp1.gen/sources_1/bd/zircon/ip/zircon_mrmac_0/sample_c_files/mrmac_exdes_test.c`,
available after the project is built). Addresses: see [Hardware design](design.md).

Order (`main.c`): VADJ on → Si5328 programmed (GT refclks) → per port: zircon_nic registers
(datapath still disabled) → GT reset → MRMAC init (incl. RS-FEC and 1588) → 1588 timer check →
lwIP and DMAs → latency set-up → `CTRL` enables → poll the links.

## 1. VADJ = 1.5 V (FMC I/O: Si5328 I2C, QSFP sideband)

VCK190 VADJ comes from the IR38164 buck at I2C **0x1E**, behind the PCA9548-style mux at
**0x74** (write **0x01** = channel 0) on **LPD I2C0** (PS I2C0, MIO 46/47, `ff020000`,
`XPAR_XIICPS_0_BASEADDR`). Write, in order (reg, value):

| reg | 0x24 | 0x25 | 0x3A | 0x3B | 0x3D | 0x3E | 0x3F | 0x40 | 0x41 | 0x42 | **0x22** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1.5 V | 0x01 | 0x80 | 0x01 | 0xF3 | 0x01 | 0xF3 | 0x00 | 0x00 | 0x00 | 0x00 | **0x80** (enable, last) |

(1.2 V table for reference: 0x25=0x33, 0x3B=0x8F, 0x3E=0x8F, rest identical.) Implementation:
`vadj.c` (XIicPs at 400 kHz, `vadj_enable(VADJ_1V5)`, then wait ~1 s).

## 2. Si5328 → GT refclk 322.265625 MHz

On `axi_iic_clk` (0x8004_0000), **direct, no mux**, I2C address **0x68**. Free-run from the
card's 114.285 MHz crystal; CKOUT1 → GBTCLK0 (port 0), CKOUT2 → GBTCLK1 (port 1), both at the
same frequency. Nothing is preset in hardware: without this step there is no GT refclk and the
GT never completes reset.

Sequence (`si5328.c`): reg 136 = 0x80 (RST_ALL), 20 ms, reg 136 = 0x00, 20 ms, then:

| reg | value | meaning |
|---|---|---|
| 0 | 0x54 | FREE_RUN |
| 2 | 0x62 | BWSEL = 6 |
| 3 | 0x55 | CKSEL_REG = CKIN2, SQ_ICAL |
| 4 | 0x12 | AUTOSEL manual |
| 6 | 0x3F | both outputs LVDS |
| 10 | 0x00 | CKOUT2 enabled |
| 11 | 0x41 | power down CKIN1 |
| 19 | 0x23 | FOS defaults |
| **21** | **0xFC** | CKSEL_PIN = 0 (ignore CS_CA pin; otherwise ICAL never completes) |
| 43,44,45 | 0x00,0x1D,0xC2 | N31 = 7619 |
| 46,47,48 | 0x00,0x1D,0xC2 | N32 = 7619 |
| 137 | 0x01 | FASTLOCK |
| 25 | 0x80 | N1_HS = 8 |
| 31,32,33 | 0x00,0x00,0x01 | NC1_LS = 2 |
| 34,35,36 | 0x00,0x00,0x01 | NC2_LS = 2 |
| 40 | 0xE0 | N2_HS = 11 |
| 41,42 | 0x7A,0x11 | N2_LS = 31250 |
| **136** | **0x40** | ICAL — write last, then wait 1 s |

f3 = 114.285 MHz / 7619 = 15 kHz; fosc = 15 kHz × 11 × 31250 = 5156.25 MHz;
fout = fosc / (8 × 2) = 322.265625 MHz.

## 3. GT reset (per port: GT-control GPIO at 0x8007_0000 / 0x8017_0000)

CH1 outputs: bit0 gt_reset_all, bit1 gt_reset_tx_datapath, bit2 gt_reset_rx_datapath (bit3 of
port 0's GPIO: `ptp_systimer` sync request). CH2 inputs: bit0 tx_reset_done, bit1
rx_reset_done (lane 0), bit2 PTP underrun. `mrmac_gt_reset()`, once per port after power-on:
CH1 = 0x1, 1 ms, CH1 = 0; poll CH2 until both reset-done bits are set (≤ 100 × 10 ms); CH1 = 0x2,
1 ms, 0, 1 ms; CH1 = 0x4, 1 ms, 0, 1 ms. While the GT reset-done bits are low the MAC side of
that port's zircon_nic (and the RX packer and TX width converter) is held in reset by hardware.

## 4. MRMAC (per port: 0x8000_0000 / 0x8010_0000) with RS-FEC

Each MRMAC runs as 1x100GE, so only its port 0 register page (offset 0) is used. Registers:
RESET 0x004, MODE 0x008, CONFIGURATION_TX_REG1 0x00C, CONFIGURATION_RX_REG1 0x010,
CONFIGURATION_RX_MTU 0x014, TICK 0x02C, CONFIGURATION_1588_REG 0x040,
**FEC_CONFIGURATION_REG1 0x0D0**, STAT_RX_STATUS 0x744, STAT_RX_BLOCK_LOCK 0x754.

`mrmac_port_init()`:

1. RESET |= 0x7F (RX serdes [3:0], TX serdes [4], RX [5], TX [6]); 1 ms.
2. MODE: DATA_RATE = 100G, SERDES_WIDTH = 100G "wide", AXIS_CFG = independent 384b
   non-segmented, PM_TICK bit 30 (statistics latched by TICK writes).
3. **FEC_CONFIGURATION_REG1 (0x0D0) = 0x00001008**: `ctl_fec_mode[3:0]` = 0b1000 = IEEE 802.3
   clause 91 RS(528,514) and bit 12 `ctl_tx_fec_four_lane_pmd`, the values Vivado 2025.2
   generates for this MRMAC configuration (the E810 also links with 0x8 alone). PG314 ("Port FEC
   Mode"): a change of this register requires a port reset afterwards, so it is written while the
   resets of step 1 are asserted. RS(544,514) would be 0x100A, FEC off 0x0 (console key `f`).
4. CONFIGURATION_1588_REG: bit 0 `CTL_TX_PTP_1STEP_ENABLE` = 0 (2-step, its reset value; the
   register reads 0x2 with `CTL_TX_PTP_SAT_ENABLE` at its reset value). Which frames are
   timestamped is chosen per frame on the MRMAC's PTP pins.
5. CONFIGURATION_RX_MTU: `CTL_RX_MAX_PACKET_LEN` (bits 30:16) at least 9600, so 9000-byte UDP
   payloads are accepted.
6. RESET &= ~0x7F.
7. CONFIGURATION_TX_REG1 = 0xC03 (enable, FCS insertion, IPG 12) and CONFIGURATION_RX_REG1 = 0x33
   (enable, FCS deletion, SFD and preamble checks): the register reset values, and what AMD's
   example writes. Writing 0x3 alone would zero the TX IPG and disable the RX checks.
8. TICK = 1.
9. Link: write 0xFFFFFFFF to 0x754, then read bit 0 (block lock); write 0xFFFFFFFF to 0x744, then
   read bit 0 (RX status). While a link is down, the application re-runs `mrmac_port_init` every
   2 seconds (the GT does not re-align on a partner that appears after the last reset).

With RS-FEC on, a link partner must also run RS-FEC (clause 91). The bench's Intel E810 links
with its FEC in `auto`; if another partner does not come up, try `ethtool --set-fec <if>
encoding rs` on the host.

## 5. 1588 timer check

`lat_print_1588()`: write TICK, read `MONITOR_TX_1588_SAMPLE_SYSTIMER` (0x268 / 0x26C) and
`MONITOR_RX_1588_SAMPLE_SYSTIMER` (0x278 / 0x27C), wait 10 ms of A72 time, repeat, and check
that both advanced by about 10 ms (units 2⁻⁸ ns in bits [54:0]); also print
`MONITOR_*_1588_INCR_SYSTIMER` (0x270 / 0x280). If the timer does not advance, pulse port 0's
GT-control GPIO CH1 bit 3 (`sync_req`) and check again. `STAT_*_1588_TOD` (0x7A8 / 0x7B0) is not
used for this: on the bench its read-backs were not monotonic, while the SAMPLE registers were.

## 6. Other facts

- UART0 (MIO 42/43), 115200 8N1.
- `axi_gpio_qsfp<p>` resets to 0x2 (module out of reset, high-power mode), so a module works
  without software. Module management I2C = `axi_iic_qsfp<p>` (0x8005_0000 / 0x8015_0000),
  module at 0x50.

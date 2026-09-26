# Revision History

## 2025.2 — version 1.3, KCU116 target (zircon_nic 1.3.0, unchanged), 2026-09-25

A second target, `kcu116`: QSFP28 port 0 of the 2x QSFP28 FMC on the KCU116's HPC connector
(Kintex UltraScale+ XCKU5P), bare-metal on a MicroBlaze. See
[KCU116 target](description.md#kcu116-target).

* Hardware: the XCKU5P's integrated 100G CMAC (CAUI-4, RS-FEC fixed on) through the Taxi
  library's `taxi_eth_mac_100g_us` wrapper, unmodified, behind a new MIT shim `zircon_cmac_us`
  that adds fabric timestamps for the latency measurement, a register block and access to the
  transceiver control bus (see [KCU116 block design](design.md#kcu116-block-design)). New block
  design `bd_microblaze.tcl`: MicroBlaze with 256 KB of local memory, DDR4, two AXI DMAs, UART
  Lite, two AXI timers. `zircon_nic` is the same RTL as on the VCK190 (`VERSION` stays
  `0x00010300`).
* Build: `./build.sh all --target kcu116` also writes the QSPI flash image `zircon_boot.mcs`
  (128 MB MT25QU01G, SPI x4), so the board boots the design at power-on (see
  [Build instructions](build_instructions.md#kcu116-bitstream-and-qspi-flash)). Builds with the
  free Vivado Standard edition plus AMD's no-charge CMAC license.
* Echo server: one source tree for both targets, with a MAC abstraction (`mac.h`: the MRMAC and
  the Taxi CMAC backends), a 64-bit timebase on an AXI timer, the UART Lite console and the
  MicroBlaze cache and memory layout. The VCK190 build is unchanged.
* Simulation: a testbench for the CMAC shim with `zircon_nic` (`tb_zircon_cmac_us.sv`).
* Measured on the KCU116 with a 100G host: all host tests pass; hardware UDP echo latency
  385 ns (64 B) and 718 ns (1472 B), MAC client to MAC client; 12 million echoes with no loss;
  generator and checker against the host with no errors; boot from QSPI. See
  [Testing](testing.md#kcu116-port-0-microblaze-v130).
* Measured on the KCU116 with a QSFP28 loopback plug: `L 0` at 100 Gb/s line rate from 726-byte
  payloads up and 16.67 Mpps below, `e` through the plug, a 5-minute soak and 9000-byte jumbo
  payloads, all with no errors. See
  [Testing](testing.md#loopback-plug-port-0-2026-09-25-19401954).
* Limits of this target: one port (no cross-port loopback test), FEC not switchable, maximum frame
  length fixed at the CMAC default (9000-byte payloads verified).

## 2025.2 — version 1.3 (zircon_nic 1.3.0), 2026-09-25

Latency measurement in hardware, from the MRMAC's IEEE 1588 timestamps (see
[Latency measurement](echo_server.md#latency-measurement)).

* Hardware: both MRMACs timestamp in IEEE 1588 **2-step** mode against one shared timer
  (`ptp_systimer`, new 250 MHz `ts_clk`). The RX packer carries each frame's receive timestamp
  with the frame; the TX adapter passes each frame's timestamp request to the MRMAC and flags a
  missing one (`ptp_underrun`, GT-control GPIO CH2 bit 2). GT-control GPIO CH1 bit 3 of port 0
  can re-synchronise the timer.
* `zircon_nic` 1.3.0 (`VERSION` = `0x00010300`): two statistics banks per port (0: hardware UDP
  echo, 1: software replies on UI0) with count, sum, sum of squares, minimum, maximum, last value
  and a 64-bin histogram; registers `0x100`-`0x118` and the snapshot at `0x200`-`0x7FF`. Optional
  64-byte `ZRXT` (receive) and `ZTXT` (transmit) descriptors on UI0 carry the timestamps to and
  from software; both are off after reset, so the UI0 formats are unchanged unless software
  enables them. `s_axis_mac_rx_tuser` is 49 bits wide and the block has new PTP ports.
* Echo server: checks that the 1588 timer runs at bring-up, enables the measurement on both
  ports, times its TCP echo (bank 1), prints the statistics with `T` and serves them on UDP port
  5002; the status line shows the hardware echo latency. Per-port address modes (DHCP then
  static, static, DHCP) with the `i` console command. The lwIP TCP window is 32 KB, so a host
  sends 1460-byte segments.
* `scripts/zircon_echo_test.py --latency` compares the board's latency figures with the host's
  round-trip times.
* Measured on the VCK190: the hardware UDP echo takes about 0.5 µs (64 B) to 0.8 µs (1472 B)
  from RX PCS to TX PCS, with a spread of a few ns, even at 100 Gb/s line rate; the software TCP
  echo takes about 7 to 10 µs. See [Testing](testing.md#latency-measurement).

## 2025.2 — version 1.2 (zircon_nic 1.2.0), 2026-09-24

Second QSFP28 port and a hardware traffic generator, so that the design can be tested at the
full 100 Gb/s without a 100G host (details in [Design notes](design_notes.md#phase-2-second-port-and-hardware-traffic-generator-version-120)).
Validated on the VCK190 with a port 0 ↔ port 1 optical cable, a loopback plug and a 100G host
(see [Testing](testing.md#measured-results)).

* Hardware: **QSFP28 port 1** of the card on FMCP1 (FMC DP4-7, GTY_QUAD_X1Y2, MRMAC_X0Y2 with
  RS-FEC, GBTCLK1 from the Si5328's CKOUT2), with its own `zircon_nic_1`, `axi_dma_raw_1` and
  `axi_dma_sock_1`, QSFP sideband GPIO and I2C. Port *p*'s registers are at
  `0x8000_0000 + p × 0x10_0000`; port 0's addresses and interrupts are unchanged.
* `zircon_nic` 1.2.0: a **hardware UDP generator** (`udp_gen`) and **checker** (`udp_chk`, UDP
  port 5001) with sequence-number and pseudo-random payload checks, and per-second **rate
  meters**, in each port (registers `0x090`-`0x0FC`, `VERSION` = `0x00010200`). `CTRL.STAT_CLR`
  also clears the generator and checker counters.
* `zircon_nic` 1.2.0: the transmit header path is faster (18 instead of 21 core cycles per
  packet); every hardware path now reaches 100 Gb/s line rate for UDP payloads of 726 bytes or
  more.
* Echo server: both ports, each with its own MAC address (`…:a0`, `…:a1`), DHCP with a static
  fallback (192.168.20.2 and 192.168.21.2), hardware echo, socket demo and TCP echo; the
  **loopback test** (`l` cross-port, `e` through port 1's hardware echo, `L <port>` one port on a
  QSFP28 loopback plug, `p` payload size) with a
  once-a-second table and a `LOOPBACK: PASS` / `FAIL` verdict, started automatically when the
  two ports are cabled together; no automatic FEC fallback (both ports stay in RS-FEC); MRMAC
  maximum receive frame raised to 9600 bytes; non-blocking console output. Status lines are now tagged with the port (`P0`, `P1`).
* `scripts/zircon_echo_test.py --port N` tests either port from a host;
  `scripts/zircon_prbs_tool.py` is the host side of the generator and checker.
* Documentation: the two test setups (loopback cable, host with a 100G NIC), measured throughput
  limits replacing the earlier estimates, and a new block diagram.

## 2025.2 — version 1.1 (zircon_nic 1.1.0)

Fixes from the design review and bench testing (details in [Design notes](design_notes.md)):

* RX: `mrmac_rx_packer` replaces the RX adapter + AMD width converter, which could lose a beat
  (frames cut at 48 bytes and merged) because the MRMAC RX client cannot be back-pressured.
* RX: per-path FIFOs for UI0, UI2 and the echo, so one stalled consumer no longer blocks the
  others; new counters `RX_RAW_DROP`, `RX_SOCK_DROP`, `RX_ECHO_DROP`.
* RX: frames cut short by a MAC-side reset are dropped (`RX_BAD_FRAME`), and the MAC-side FIFO no
  longer replays stale data after such a reset.
* RX: short UDP datagrams with non-zero Ethernet padding are echoed / delivered again.
* TX: UI transfers longer than 9618 bytes are dropped and counted (`TX_OVERSIZE_DROP`) instead of
  stalling the transmit path.
* `STATUS` bits 4/5 report the RX packer being stalled / overflowing.

## 2025.2 — version 1 (initial release)

First release of the 2x QSFP28 FMC Zircon Ethernet reference design.

* Built for Vivado / Vitis 2025.2. **Bare-metal only**: no Linux (PetaLinux or Yocto) flow, no
  Makefiles; builds are driven by the cross-platform runner (`build.py` / `build.sh` /
  `build.bat`) on Windows or Linux.
* Target: VCK190 (`vck190_fmcp1`), 2x QSFP28 FMC on FMCP1, QSFP28 port 0 at 100 Gb/s.
* Hardware: Versal MRMAC, 1x100GE CAUI-4 with RS-FEC (clause 91, RS(528,514)), feeding the
  `zircon_nic` module reference: the Zircon IP stack from the Taxi transport library (git
  submodule `submodules/taxi`, pinned at `cc70b27`, CERN-OHL-S-2.0) plus Opsero's MIT glue (header
  truncation, rule matching and dispatch, socket descriptor, TX metadata builder, UDP checksum
  workaround, registers and counters). Three user interfaces: UI0 raw frames, UI1 hardware UDP
  echo, UI2 hardware UDP socket. Two AXI DMAs (raw and socket).
* Self-checking xsim testbench for `zircon_nic` (`Vivado/src/hdl/tb/run_xsim.sh`).
* No processor in the datapath: the PS runs the `echo_server` bring-up and control application
  (VADJ, Si5328, MRMAC + RS-FEC, zircon_nic registers) and a control-plane lwIP stack on the raw
  path (ARP, ICMP, DHCP, software TCP echo on port 7 for comparison). Hardware UDP echo on port 7,
  hardware UDP socket demo on port 5000, live counters and console keys.
* Host-side test script `scripts/zircon_echo_test.py`.
* 2026-09-24: scope reduced to bare-metal only before release; the planned Linux driver and
  Yocto image were removed (see [Design notes](design_notes.md#scope-change-bare-metal-only-2026-09-24)).
* Bench validation results: to be published on the [Testing](testing.md#measured-results) page.

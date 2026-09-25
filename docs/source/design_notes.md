# Design notes and lessons learned

This page records the non-obvious findings from developing this design. They are the things
that cost real time, and that anyone extending the design, porting it to another board, updating
the Taxi submodule or debugging the link is likely to run into again. The sections follow the
build chain: Zircon itself, the MRMAC, Vivado, software. The later sections record the change
of scope to a bare-metal-only design, the review fixes of version 1.1 and the second port and
hardware traffic generator of version 1.2 ("Phase 2").

## Zircon at Taxi `cc70b27`

* **Building blocks, not a stack.** Zircon at this commit has eight RTL modules and unit
  testbenches for three of them (parser, deparser, length/checksum). There is no top level, no
  register interface, no rules engine, no dispatch, no header stripping and no ARP or ICMP. The
  README describes rule matching, multiplexing between application interfaces and payload-only
  delivery, but these are planned, not implemented. Everything the design needs beyond the blocks
  is MIT glue in `Vivado/src/hdl/` (see [Description](description.md#what-zircon-provides-and-what-the-glue-adds)).
  None of Zircon's wrapper modules (`rx_ingress`, `rx_egress`, `tx_ingress`, `tx_buffer`,
  `tx_egress`) is covered by an upstream testbench, so the design's own xsim testbench is what
  verifies the composed datapath.
* **`zircon_ip_rx_ingress` cannot run at 100G.** It broadcasts the whole frame in lockstep into
  the 32-bit parser, and the parser consumes the entire frame, not just the headers. The receive
  path is then limited to 32 bits per clock (about 10 Gb/s at 300 MHz) whatever the data width.
  The design rebuilds the receive front end from the same Zircon modules with a header truncator
  (`hdr_trunc.sv`) that feeds only the first 64 bytes to the parser, and decouples the parser
  branch from the data branch with FIFOs. Zircon's own parser testbench feeds truncated headers
  too, so this matches how the parser is meant to be used.
* **Width rules.** `zircon_ip_len_cksum` works only with a power-of-two number of byte lanes; a
  384-bit (48-lane) stream would silently build a wrong adder tree. `taxi_axis_adapter` computes
  its width ratio without checking that it is an integer, so a 48 ↔ 64 byte conversion also
  builds silently and is broken. The design therefore uses AMD's `axis_dwidth_converter` for the
  48 ↔ 64 byte step and runs Zircon at 512 bits. The UI side and the MAC side of Zircon's CDC FIFOs
  must have the same width as the core.
* **The length/checksum metadata cannot be back-pressured.** `zircon_ip_len_cksum` ignores
  `tready` on its metadata output. Its consumers therefore sit behind FIFOs sized for the worst
  case: twice the number of one-beat packets the matching data FIFO can hold. An overflow (which
  cannot happen by construction) would set `STATUS.RX_META_ERR` / `TX_META_ERR`.
* **Deadlock freedom has to be designed in.** A frame may only leave the packet FIFO once both
  of its metadata records exist. Because the packet FIFO's head is always the oldest packet, its
  header record is always the next one the parser produces. The packet FIFO is at least as deep
  as the MAC-side FIFO (checked at elaboration), so any frame that passed the MAC-side FIFO fits
  completely and its length record always arrives.
* **The parser ignores `tkeep` and the input `tuser`.** It sees neither the length of the last
  beat nor the MAC's bad-frame flag. Bad frames are dropped before the core (in the MAC-side
  frame FIFO), and the header truncator forces `tlast`. With 64 bytes of header, an IPv4 header
  with more than 28 bytes of options is cut short; such frames may count as `RX_L3_BAD_CSUM` but
  go to the raw path anyway.
* **The deparser must always get all 16 metadata beats.** Its IPv4 header checksum is folded on
  beats 14-15, so an early `tlast` corrupts it. It always emits IHL 5, never sets Don't-Fragment,
  and with `FLG_EN` = 0 it emits an empty header, which is how the raw path passes frames through
  unchanged.
* **The deparser folds the UDP checksum only once.** About 1 packet in 65536 goes out with a UDP
  checksum one too small when the header part of the sum exceeds 0xFFFF (replies to ephemeral
  ports hit this). The receiver drops those packets silently, which looks like random loss.
  `tx_meta_builder.sv` pre-computes the checksum and passes an adjusted payload sum so the
  deparser's single fold gives the right result (see
  [the workaround](description.md#the-udp-checksum-workaround)). The formula was checked against
  3.3 million sum pairs, and test 12 of the testbench reproduces the original error. This is
  worth reporting upstream; remove the workaround when Zircon fixes it.
* **Undriven ports.** `zircon_ip_tx_ingress.m_axis_ui_tx_cpl` is never driven and
  `zircon_ip_tx_egress.s_axis_mac_tx_cpl.tready` is left undriven. The glue ties off the
  completion input and leaves the completion output unused.
* **The metadata format still changes upstream.** Commit `f2ff93f` ("Reorganize metadata for
  better rules engine interface") changed the byte layout that the glue depends on. Pin the
  submodule, and re-run the testbench whenever it is updated.

## MRMAC and RS-FEC

* **Enabling RS-FEC in the IP.** In Vivado 2025.2 the MRMAC preset "1x100GE CAUI-4 Wide" only
  offers FEC bypass until `MRMAC_MODE_C0` is set to `MAC+PCS+FEC`. Only then does
  `FEC_SLICE0_CFG_C0` accept `100G (IEEE 802.3) - RS(528 514)`. `bd_versal.tcl` sets both.
* **The run-time FEC register.** `FEC_CONFIGURATION_REG1` (port offset `0x0D0`) holds
  `ctl_fec_mode`. PG314 requires a port reset after it changes, so software writes it while the
  port's resets are asserted. The value for clause 91 is `ctl_fec_mode` = `0x8`, the value the
  MRMAC example design generated for this configuration writes. The bare-metal application
  writes `0x1008`: bit 12 (`ctl_tx_fec_four_lane_pmd`) is also set in the IP's static
  configuration for RS(528,514) at 100G, as read from the generated IP wrapper. Which of the two
  run-time values is strictly needed will be confirmed on the bench (`MRMAC_FEC_KEEP` in
  `app_config.h` leaves the static configuration untouched instead).
* **FEC and the link partner.** With RS-FEC on, a partner in FEC auto mode links without any
  configuration. The earlier FEC-off 2x QSFP28 FMC design needed the partner's FEC *forced* off,
  because a partner in auto mode kept probing RS-FEC and the link flapped. Choosing RS-FEC here
  means an unmodified host (and a user without root on it) can test the design.
* **The GT does not re-align on a late partner.** If the link partner appears after the last MAC
  reset (cable plugged in later, partner rebooted), the Versal GTY does not lock on its own. The
  echo server re-runs the MAC/PCS reset every 2 seconds while the link is down.
* **The MRMAC bad-frame flag.** The MRMAC reports a bad frame with bit 8 of the TLAST beat's
  per-lane `tkeep_user`. The RX adapter spreads it over a per-byte `tuser` so that it survives the
  48 → 64 byte width converter (`TUSER_BITS_PER_BYTE` = 1), and a small module ORs the last beat's
  `tuser` bits into Taxi's `tuser[0]` "bad frame" bit.
* **The MRMAC adds the FCS but does not pad.** Frames shorter than 60 bytes are padded by
  `tx_mac_out.sv` in the core.

## Vivado

* **A module reference needs a Verilog top.** Vivado refuses a SystemVerilog top file for a
  block-design module reference, so `zircon_nic.v` is a Verilog-2001 shell over
  `zircon_nic_core.sv`. `X_INTERFACE_INFO` / `X_INTERFACE_PARAMETER` attributes on the shell make
  Vivado infer the AXI-Stream and AXI-Lite interfaces and their clocks and resets. A module
  reference may have no `xparameters.h` entry of its own, so the bare-metal code falls back to
  the addresses assigned in `bd_versal.tcl` (`0x800A_0000` for `zircon_nic_0`, `0x801A_0000` for
  `zircon_nic_1`).
* **Vivado does not track the sources of a module reference.** After editing the glue,
  `synth_1` can be out of date while the cell's out-of-context run is not, and the next
  implementation silently reuses the old netlist. `Vivado/scripts/xsa.tcl` resets the
  out-of-context runs when `synth_1` is stale.
* **`xvlog --relax`.** `zircon_ip_rx_parse.sv` uses a signal before its declaration
  (`[VRFC 10-3380]`), which the simulator's strict mode rejects, and `taxi_axis_if` has no
  timescale, so `xelab` needs `--timescale`. `run_xsim.sh` passes both. Synthesis accepts the
  sources as they are.
* **Taxi's timing constraints.** Taxi ships Tcl constraint scripts for its CDC structures (async
  FIFOs, synchronizers). They find their cells by `ORIG_REF_NAME`, so they are added as
  implementation-only files (`Vivado/scripts/zircon_sources.tcl`) and the hierarchy must not be
  flattened.
* **Expected methodology warnings.** Twelve `CDC-11` entries are Taxi's reset re-synchronizers
  inside its async FIFOs, covered by `taxi_sync_reset.tcl`. The counter snapshot CDC uses LUTRAM,
  which gives `CDC-26` warnings. Both are expected.
* **Timing.** Post-synthesis, every domain met timing, with the 390.625 MHz MAC receive domain the
  tightest (Taxi async-FIFO write-enable fan-out). The Zircon parser and deparser are large
  single-cycle logic cones, and `rx_dispatch` has a combinational classifier in front of a 3:1
  512-bit multiplexer. If a modification fails timing, those are the first places to add
  pipeline stages. The core clock can drop to 250 MHz (still 128 Gb/s of bus capacity) as a last
  resort.

## Software

* **512-bit AXI DMA and alignment.** Use 64-byte aligned buffers with the 512-bit AXI DMAs. The
  bare-metal DMA driver (`zdma.c`) aligns its receive buffers and copies unaligned transmit
  frames into aligned bounce buffers. (A Linux `xilinx_dma` driver would treat the data
  realignment engine as absent at this width, so any future OS port needs the same care.)
* **Everything is polled.** The echo server services the DMA rings, the link, the console and the
  lwIP timers from its main loop, with no interrupts. This keeps the application independent of
  how the DMA interrupts are wired and avoids the xiltimer tick-timer workaround.
* **The local IPv4 register must follow DHCP.** The hardware rules match on it. The echo server
  compares lwIP's address with the programmed value in its main loop and rewrites the register
  when it changes.
* **The socket demo re-connects.** It programs `SOCK_REMOTE_*` from the first datagram's
  descriptor, and again whenever a datagram arrives from a different sender, so repeated host
  test runs from new ephemeral source ports keep working.
* **lwIP checksums.** The AMD lwIP port turns software checksums off for the Versal PS Ethernet
  controller, which computes them in hardware. The zircon_nic raw path does not, so the
  repository overrides `lwipopts.h` (`EmbeddedSw/`) to force software checksums.
* **Si5328 programming.** Register 21 must be written with `CKSEL_PIN` = 0 (`0xFC`), otherwise
  the internal calibration never completes, and the calibration (`ICAL`, register 136) must be
  written last. Both outputs are programmed: CKOUT1 is port 0's reference clock (GBTCLK0) and
  CKOUT2 is port 1's (GBTCLK1).
* **VADJ is set by the application.** The Versal boot flow has no FSBL hook for FMC power, so the
  echo server programs the VCK190's VADJ regulator to 1.5 V itself before it touches the Si5328.

## Bench bring-up lessons (VCK190 + Intel E810, 2026-09-24)

* **FEC.** With the E810 left on automatic FEC, the link comes up at 100 Gb/s with RS-FEC. Both
  `FEC_CONFIGURATION_REG1` = 0x1008 (what the application writes: `ctl_fec_mode` 8 plus
  `ctl_tx_fec_four_lane_pmd`, which is the IP's power-up value) and 0x8 (AMD's example design)
  link. With FEC off (0x0) the MRMAC reports local fault while the E810 claims a link with FEC
  off, so a partner forced to FEC off is not a supported configuration. No clause-73
  auto-negotiation was needed.
* **CONFIGURATION_TX/RX_REG1 must be written whole.** Writing 0x3 (enable + FCS) zeroes the
  TX inter-packet gap and disables the RX SFD and preamble checks. The application writes the
  reset and example-design values, 0xC03 and 0x33.
* **MRMAC statistics.** In TICK_REG mode, each tick copies the counts since the previous tick,
  and those are only valid once `STAT_STATISTICS_READY` reads 0x3. If you read straight after
  the tick you get 0. The application waits for READY and keeps its own totals.
* **The MRMAC may link before the application runs.** After the PDI is loaded, the hard block
  can come up with its static configuration and the partner starts sending. `CTRL` resets to 0,
  so zircon_nic drops these frames and counts them in `RX_FIFO_DROP`, for example 25 frames
  before the application opened the datapath. This is expected.
* **Static fallback subnet.** The fallback (192.168.20.2/24) only works on a partner port that
  serves 192.168.20.0/24. On the bench the cable was on the E810's second port
  (192.168.21.1/24). There, DHCP gave 192.168.21.162, and the static fallback would have been
  unreachable.
* **The RX width converter must never stall (fixed in 1.1.0).** In 1.0.0,
  `mrmac_rx_axis_adapter` passed the MRMAC RX client straight to a 48-to-64-byte
  `axis_dwidth_converter` and ignored its tready. The MRMAC cannot be back-pressured, so a beat
  offered while the converter stalled was lost. On the bench this merged back-to-back small
  frames: the first 48-byte beat of one frame was followed by the whole next frame. It happened
  for bursts of 60-byte frames, about once in several thousand frames. 1.1.0 replaces the chain
  with `mrmac_rx_packer` (see "Review fixes" below). On the bench, 4 million 12-byte datagrams
  then gave `RX_L4_BAD_CSUM` = 0, and the MRMAC good-frame count equalled `RX_FRAMES` exactly.
* **A stalled PS no longer stops the hardware echo (1.1.0, bench-verified).** The Cortex-A72
  was halted from xsdb for 10 s while the host ran two flows. The hardware echo carried 3,000,000
  64-byte datagrams with none lost. About 50,000 raw frames per second went to a port nobody
  listens on (UDP 9). 515,645 raw frames were dropped and counted in `RX_RAW_DROP`. Nothing
  wedged, and after `con` the raw path resumed.
* **The old "RX wedge" is gone.** 1.0.0 once froze its receive path after the first raw frame
  (seen once, root cause not isolated). With 1.1.0 it did not recur in three cold loads (power
  cycle, JTAG load, DHCP, echo test).
* **JTAG loading on Versal.** `scripts/bench.py program <board> --arch versal --bit <pdi>
  --elf <elf>` works with the board's boot switches on SD: force the JTAG boot mode, reset the
  PMC (`rst -type pmc-srst`), `device program` the PDI, then `rst -processor` and `dow` on
  Cortex-A72 #0. There is no FSBL: the PLM in the PDI sets up the PS, the NoC and DDR.
  One Python/xsdb load that started 15 s after power-on (with the SD card's Linux still booting)
  hung after `device program`. A retry with the same 15 s delay worked, so the step is
  intermittent. `jtag_boot.py` now line-buffers its output, so the journal shows where a hang
  happens.
* **Debugging with no debug cores.** With xsdb connected to the `Versal*` target,
  `mrd -force` reads the zircon_nic and MRMAC registers, the AXI DMA registers and the DMA
  descriptors and buffers in DDR while the application runs. The raw-path receive buffers keep
  the last 64 frames the PS received, which is how the frame merge above was found.

## Scope change: bare-metal only (2026-09-24)

The design was first planned with a Yocto / EDF Linux image as well: a `zircon_nic` network
driver on the raw path, a `/dev/zircon-sock` character device for the hardware socket, sysfs
controls and a board self-test. On 2026-09-24 the scope was reduced to **bare-metal only**, and
the Linux and Yocto parts were removed from the repository before the first release.

The change was a customer decision, and it keeps the design focused on its point: **there is no
processor in the datapath**: the datagrams of the hardware UDP echo and of the traffic
generator and checker never reach the PS, and the hardware socket parses and builds its headers
in logic and delivers only the payloads. The two AXI DMAs of each port are a separate
control-plane and raw path (ARP, ICMP, DHCP, a software TCP echo for comparison, and the socket
payloads) that the PS uses to bring the hardware up, configure it and observe it. The
design is now built with Vivado and Vitis only, on Windows or Linux, and no Linux build machine is
needed.

## Review fixes (version 1.1.0)

A design review and bench testing of 1.0.0 found six defects in the MIT glue. Each fix has a
regression test in `Vivado/src/hdl/tb` that fails without it.

* **RX beats lost at the 48→64 byte conversion (bench).** The MRMAC RX client cannot be
  back-pressured, but the AMD `axis_dwidth_converter` (48→64 bytes, a non-integer ratio) lowers
  its `S_AXIS_TREADY` for a cycle when two valid beats follow a TLAST beat. The beat offered in
  that cycle was lost: about 1 in 10,000 back-to-back 12-byte UDP datagrams arrived as a frame cut
  at 48 bytes merged with the next one, with no error counted anywhere. The RX adapter, the
  converter and `mrmac_rx_tuser` are replaced by `mrmac_rx_packer.v`, which accepts a beat every
  cycle and never depends on tready (unit testbench `tb_mrmac_rx_packer.sv`). Lesson: a stream
  source without tready must never feed an IP that is allowed to deassert it.
* **Stale error bits after the converter.** The same converter's upsizer never clears the TUSER
  of an accumulator slot it does not write, so after an errored 97-144 byte frame, good 65-96 byte
  frames (TCP ACKs) were flagged bad until a larger frame came. First fixed by masking TUSER with
  TKEEP; the packer now makes the problem impossible (it only looks at the TLAST beat's own lanes).
* **Head-of-line blocking.** `rx_dispatch` had one output register for all paths, so a stalled
  UI0 consumer (a DMA ring without a free descriptor) stopped the hardware echo, and a busy TX
  stopped UI0. RAW and SOCK now go through 32 KB drop-when-full frame FIFOs, and echo requests
  are only accepted when their whole payload fits the echo FIFO; drops are counted
  (`RX_RAW_DROP`, `RX_SOCK_DROP`, `RX_ECHO_DROP`).
* **MAC-side reset in the middle of a frame.** The Taxi async FIFO ends a frame it is reading
  out with a "bad" terminate beat when its write side is reset (link down), but the bad marker was
  not carried into the core, so the truncated frame was delivered. It is now carried on the length
  record and the dispatcher drops it (`RX_BAD_FRAME`). Testing this found a second problem: after
  a write-side reset the FIFO's read side (in frame mode) can keep its old commit pointer and
  replay stale memory as frames. The core now also resets the read side itself, between frames.
  Taxi is unmodified; worth reporting upstream.
* **Non-zero Ethernet padding.** The UDP checksum check compared the parser's expected sum with a
  sum that included the padding bytes, so short datagrams from senders that pad with non-zero
  bytes went RAW (and lwIP answered "port unreachable"). The padding sum is now subtracted.
* **Oversize UI TX transfer.** A UI0/UI2 transfer of 32 KB or more wedged `zircon_ip_tx_buffer`
  (and with it the echo and the receive dispatch) until reset. `tx_len_guard.sv` drops anything
  longer than 9618 bytes (`TX_OVERSIZE_DROP`).

## Phase 2: second port and hardware traffic generator (version 1.2.0)

The customer asked for a way to test the design **without a 100G host, and at the full
100 Gb/s**. A host running a socket-based script can check that the hardware answers correctly,
but it cannot load the link: the bench host reached about 1.5 Gb/s. Version 1.2 therefore adds
the card's second QSFP28 port and a hardware UDP generator and checker in each `zircon_nic`, so
that a single QSFP28 cable between port 0 and port 1 tests both ports at line rate in both
directions. The host test of version 1.1 remains as the second test setup, on either port.

What changed:

* **Port 1 is an exact copy of port 0**, as in Opsero's 2x-qsfp28-fmc design: `gt_quad_base_1`
  on GTY_QUAD_X1Y2 (FMC DP4-7), `qsfp_port1/mrmac` on MRMAC_X0Y2 with the same RS-FEC setting,
  its own BUFG_GT tree and GT-reset-done gating, `zircon_nic_1`, `axi_dma_raw_1`,
  `axi_dma_sock_1`, and its own QSFP sideband GPIO and I2C. The 390.625, 300 and 100 MHz clocks
  and the Si5328 I2C are shared. `bd_versal.tcl` loops over the `ports` of `config/data.json`,
  so a one-port build is still possible.
* **Address map rule.** Port 1 repeats port 0's layout at +0x10_0000 instead of taking the next
  free windows, so software has one rule for every register: `0x8000_0000 + p × 0x10_0000 +
  offset`. Port 0's addresses are unchanged from version 1.1. The new DMAs use NoC ports S12-S17
  and interrupts `pl_ps_irq6`-`10` (see [Hardware design](design.md)).
* **Port 1's reference clock.** GBTCLK1 comes from the Si5328's CKOUT2. The bare-metal
  programming table already enabled CKOUT2, so no software change was needed. (The stock Linux
  Si5324 driver disables CKOUT2; that only matters for a future Linux port.)
* **`zircon_nic` 1.2.0** adds `udp_gen.sv`, `udp_chk.sv` and `rate_meter.sv`, a fourth transmit
  source (UI3) and a CHK rule in `rx_dispatch.sv`. The parameter `GEN_EN` (default 1) removes the
  generator and checker (about 5,400 LUTs per port); the rate meters are always built. The
  parameter `CORE_HZ` sets the rate-meter window and must equal the real core clock.
* **The echo server** manages both ports through one per-port structure, runs the loopback test
  (cross-port, or through port 1's hardware echo), buffers its console output so that the
  once-a-second table never blocks the DMA service, and raises the MRMAC's maximum receive frame
  length to 9600 bytes so that 9000-byte payloads fit.

Design choices and lessons:

* **A payload the checker can verify without memory.** Each payload is a 64-bit sequence number
  followed by eight independent xorshift64 generators, one per 8-byte lane, seeded from the
  sequence number and stepped once per 64-byte beat (DESIGN_SPEC §10.1 and the
  [register map](registers.md#payload)). Generator and checker produce one beat per clock with no
  memory and no multiplier. Because the checker re-seeds from every datagram, one lost datagram
  counts exactly one sequence error and no bit errors, and the checker never has to
  resynchronise.
* **The checker never back-pressures.** It accepts a beat every cycle, so the receive path
  behaves exactly as it does for the echo. Frames that the receive side cannot take are dropped
  whole at the MAC-side FIFO, as always, and appear as sequence errors.
* **Rate meters need 64-bit byte counts.** At 100 Gb/s a port moves about 1.25 × 10^10 bytes per
  second, which does not fit in 32 bits. The four counts of one window are latched in the same
  clock cycle, and reading `RATE_SEQ` latches all six rate registers, so software always reads a
  consistent sample. A MAC transmit reset in the middle of a window (a link flap) is detected by
  the byte count going backwards.
* **Measure the packet rate; do not estimate it.** The first draft of this phase estimated
  27-30 core cycles per packet for the Zircon deparser, and so a floor of about 1250 bytes of
  payload for line rate; version 1.1's documentation quoted about 19 cycles for the parser and
  "line rate for frames of about 1 KB". Measurement showed different limits. The receive parser
  needs 16 cycles, and the transmit limit was not the deparser at all but `tx_meta_builder`, at
  21 cycles per packet. Overlapping the builder's checksum preparation with its 16 output beats
  brought transmit down to 18 cycles (16.7 million packets per second). Line rate now needs
  684 bytes of payload on transmit and 726 on receive.
* **How the throughput was measured.** Test 70 of the `zircon_nic` testbench
  (`Vivado/src/hdl/tb`) sweeps the payload size. For each size it runs the generator
  continuously through the whole transmit path into a model of the MAC at 100 Gb/s, loops the
  frames back into the receive path and the checker, and measures the core cycles per packet in
  steady state on each side. The cost formulas in [Description](description.md#throughput)
  (DESIGN_SPEC §10.5) are fitted to these results. Test 50 runs the same loop at 1472 bytes and
  requires every datagram to arrive with no error and no drop (1,575 datagrams, 8.13 million
  packets per second, 100.0 Gb/s line rate). Test 60 checks that the rate meters report exact
  counts per window. On hardware, the same rate meters give the measurement, independent of any
  host: the loopback table shows each port's line rate, 8 × (bytes + 24 × frames) per second.
* **Timing.** The two-port block design, built before the generator and checker were added, met
  timing with 0.020 ns of slack in the 300 MHz core domain, so the core clock domain is the one
  to watch when modifying the design. In out-of-context synthesis the new blocks have at least
  1.3 ns of slack. The two new counter-snapshot FIFOs add six `CDC-11` methodology warnings of
  the same (expected) kind as before.
* **Automatic start.** A customer who has just fitted the loopback cable should not need to
  type anything. The application infers the cable from the absence of DHCP: when both ports have
  link and neither has received a lease for 15 seconds, it starts the test, and it stops again if
  the checkers see nothing within 3 seconds. Any DHCP lease since power-on disables the automatic
  start.

Version 1.2 was validated on the bench; the results, including the throughput for payloads from
64 to 9000 bytes, are on the [Testing](testing.md#measured-results) page.

### Phase 2 bench lessons (2026-09-24)

* **Two ports, one subnet.** When one port falls back to its static address inside the other
  port's DHCP subnet, plain lwIP routes replies by destination and uses the wrong port. The TCP
  echo on port 0 timed out on the bench. `LWIP_HOOK_IP4_ROUTE_SRC` (lwipopts overlay +
  `zircon_ip4_route_src()`) now routes by source address.
* **No automatic FEC fallback.** A port that falls back to FEC off while its partner (the other
  port, or a loopback plug) is still coming up would never link in RS-FEC. The default is now to
  stay in the configured mode; `f` switches by hand. Both a passive loopback plug and an optical
  SR4 port-to-port cable align in RS-FEC.
* **Line rate.**
  * Cross-port, both directions: 100.00 Gb/s line rate at 726, 1472 and 9000 B payloads.
  * The same with a single port on a loopback plug (`L <port>`).
  * Hardware echo through port 1: 100.00 Gb/s.
  * Below 726 B the generator is the limit: about 16.7 Mpps, e.g. 77 Gb/s at 512 B. The receive
    side keeps up, so the checker sees no sequence errors.
  * A 621 s soak moved 5.05 × 10⁹ datagrams per direction with zero errors and zero FEC
    codeword corrections.
  * Re-measured on the final zircon_nic 1.3.0 build (2026-09-25, SD-card boot): the same line
    and payload rates at every payload size, packet rates within 32 packets/s of 1.2.0, and a
    635 s soak with 5.16 × 10⁹ datagrams per direction, zero errors and zero FEC codewords.
* **Counters wrap.** The 32-bit hardware counters wrap in under 9 minutes at 100G line rate with
  1472 B frames. Software that reports long runs must accumulate them (the loopback test keeps
  64-bit totals).

## v1.3 latency bring-up lessons (2026-09-24)

* **The 1588 timer runs with no software help.** The `ptp_systimer` periodic `st_sync` (every 1 ms,
  `st_overwrite` = 1) works as parameterised, and `sync_req` was not needed. Over 10 ms of A72
  time the MRMAC's systimer sample registers advanced to within 10 ns.
* **Do not trust `STAT_{TX,RX}_1588_TOD` read-backs.** Over 200 TICK+read pairs per MRMAC:
  * about 50 % of the TOD values had bit 54 set (a jump of 2⁴⁶ ns), and
  * with bit 54 masked, about 8 % went backwards.
  * The `MONITOR_{TX,RX}_1588_SAMPLE_SYSTIMER` registers were monotonic and never had bit 54
    set.

  The application's bring-up check now uses the sample registers. Before this change it printed
  "advanced 70368754177664 ns" (2⁴⁶ + 10⁷). The frame timestamps are not affected: there were 0
  implausible deltas in more than 8 × 10⁸ samples.
* **`MONITOR_*_1588_INCR_SYSTIMER` reads 0x18D3018D302, not 4 ns.** It is the increment the MRMAC
  derived for its internal timer clock. The value equals 1.5515 ns × 2⁴⁰, which is one period of
  a 644.53 MHz clock (the 100G serdes/PCS clock) if the unit is 2⁻⁴⁰ ns. It does not have to
  match `ts_clk`.
* **RX timestamps are valid.** `CTL_PCS_RX_TS_EN` at its default did not stop them.
  `RX_TS_BEAT` is aligned: isolated datagrams (1 ms apart) and 100G back-to-back traffic give the
  same echo latency, within 16 ns.
* **The hardware UDP echo takes about 0.48 µs (64 B) to 3.0 µs (9000 B)** from RX PCS to TX PCS,
  with a few ns of jitter at line rate.
* **Uncorrected FEC codewords at link-up.** Port 0's MRMAC counted 19 uncorrected RS-FEC
  codewords (and 1 corrected) at each link-up on the optical cable, and none afterwards. This is
  a link-up transient; clear the counters (`c`) after the link is up before judging a soak.


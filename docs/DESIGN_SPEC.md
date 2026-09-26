# qsfp28-fmc-zircon — design specification (zircon_nic 1.3.0, targets `vck190_fmcp1` and `kcu116`)

This is the engineering contract of the design: the RTL (`Vivado/src/hdl/`), the block designs
(`Vivado/src/bd/bd_versal.tcl`, `Vivado/src/bd/bd_microblaze.tcl`) and the bare-metal software
(`Vitis/common/src/`) implement it, and it must describe what they do now. Change it in the same
commit as the sources. It is not user documentation: the user guide is the Sphinx site in
`docs/source/` (hosted at <https://qsfp28-zircon.ethernetfmc.com>); `registers.md` and
`design.md` there are kept consistent with §3.3, §6, §6b and §6c.

## 1. Scope

100 GbE on the Opsero **2x QSFP28 FMC (OP120)**, on two targets that share `zircon_nic`, its
register map and the bare-metal application:

| target | board / connector | QSFP ports | MAC | processor | boot |
|---|---|---|---|---|---|
| `vck190_fmcp1` | VCK190 (XCVC1902), FMCP1 | 0 and 1 | per port a **Versal Integrated MRMAC** hard block (§6) | Versal PS (Cortex-A72) | `BOOT.BIN` (SD card) or JTAG |
| `kcu116` | KCU116 (XCKU5P-FFVB676-2-E), HPC | 0 only (the KCU116 HPC wires FMC DP0-3 only) | the KU5P's **CMACE4** hard block through Taxi's `taxi_eth_mac_100g_us` wrapper, behind the MIT shim `zircon_cmac_us` (§6b, §6c) | MicroBlaze, 100 MHz | `zircon_boot.bit` over JTAG, or `zircon_boot.mcs` from QSPI |

Each port is 1x100GE CAUI-4 on 4x GTY at 25.78125 Gb/s with **RS-FEC clause 91, RS(528,514)**,
and has its own **`zircon_nic`**, a block-design module reference built around the **Taxi Zircon
IP stack**. Per port, `zircon_nic` offers:

- **UI0 "raw"**: complete Ethernet frames (no FCS) to and from the processor through an AXI DMA
  (`axi_dma_raw[_1]`). Carries everything the hardware rules do not claim (ARP, ICMP, DHCP, TCP,
  broadcasts, UDP to other ports); the bare-metal application runs lwIP on it.
- **UI1 "hardware UDP echo"**: IPv4/UDP datagrams to `ECHO_PORT` (default 7) are answered by
  the hardware (addresses and ports swapped, headers and checksums rebuilt, payload untouched).
  They never reach the PS.
- **UI2 "hardware UDP socket"**: datagrams to `SOCK_LOCAL_PORT` reach the PS payload-only behind a
  64-byte descriptor (§5) through a second AXI DMA (`axi_dma_sock[_1]`); payloads the PS writes
  get Ethernet/IPv4/UDP headers built from the `SOCK_*` registers.
- **Hardware UDP generator and checker** (§10): a line-rate datagram source (TX input 3) with a
  sequence number and a pseudo-random payload, and a checker that claims datagrams to
  `CHK_PORT` (default 5001) and counts sequence, bit and length errors, both entirely in logic.
  **Rate meters** latch RX/TX frames and bytes once a second.
- **Latency measurement** (§11): TX timestamp of a reply − RX timestamp of its request, for the
  hardware echo (bank 0) and for software replies on UI0 (bank 1), with per-bank statistics and
  a 64-bin histogram. On the vck190 the timestamps are the MRMAC's IEEE 1588 two-step
  timestamps (RX PCS → TX PCS); on the kcu116 they are fabric timestamps taken by the shim at
  the MAC-client interface (§11.7).

**There is no processor in the datapath** of UI1, the generator or the checker. The processor
(the Versal PS, or the MicroBlaze on the kcu116) runs one bare-metal application (`echo_server`,
§8) that is the control plane: it powers the FMC (vck190), programs the Si5328, brings the MACs
up, configures `zircon_nic`, runs lwIP on UI0, bounces the socket demo's payloads and drives the
loopback and latency tests.

Zircon and the Taxi library are used **unmodified** from `submodules/taxi` (pinned at
`cc70b27`, CERN-OHL-S-2.0). That includes Taxi's 100G CMAC wrapper and its IP-generation
scripts on the kcu116. Everything Taxi does not provide at that commit (header truncation, rule
matching and dispatch, header strip, socket descriptor, TX metadata, the UDP checksum
workaround, generator, checker, rate meters, latency measurement, registers, counters, the MRMAC
adapters and the CMAC shim with its timestamps) is Opsero MIT glue in `Vivado/src/hdl/`, or
software.

`config/data.json` is the manifest with two targets: `vck190_fmcp1` (`ports: 2`, `fec: "rs"`,
`bdscript: "versal"`, group `versal`) and `kcu116` (`ports: 1`, `fec: "rs"`, `bdscript:
"microblaze"`, group `fpga`, `cfgmem: true`, `flashsize: "128"`, `flashintf: "SPIx4"`). The
Versal block design also builds `ports: 1` (port 0 only) and `fec: "none"` (MRMAC FEC bypassed);
neither is a published target. `bd_microblaze.tcl` accepts only `ports { 0 }`, and `fec` is
fixed at `rs` there.

Design decisions that explain the current shape:

- **Bare-metal only.** A Linux flow (netdev driver on UI0, a socket character device, a Yocto
  image) was planned and removed on 2026-09-24, before the first release, by customer decision:
  the design demonstrates hardware datapaths, and the PS only configures and observes them. It
  builds with Vivado and Vitis alone, on Windows or Linux.
- **RS-FEC on.** A 100G link partner in FEC "auto" mode (the bench host's Intel E810, whose FEC
  cannot be changed without root) settles on clause 91 RS(528,514). Unlike the FEC-off
  2x-qsfp28-fmc design, this one links to such a partner without reconfiguring it.
- **No automatic FEC fallback in software.** In a port 0 ↔ port 1 loopback both ports must stay
  in RS-FEC; a port that had fallen back to FEC off while waiting for a link would never link to
  the other. `FEC_FALLBACK_MS` exists but defaults to 0; the console key `f` cycles the mode by
  hand (vck190 only).
- **kcu116: Taxi's CMAC wrapper, not AMD's example design.** The UltraScale+ `cmac_usplus` IP is
  used through `taxi_eth_mac_100g_us` (with its own GT wrappers, reset sequencer, watchdog and
  IP-generation scripts), so the kcu116 datapath is Taxi end to end and the Taxi sources stay
  unmodified. That wrapper, at `cc70b27`, hard-wires RS-FEC on and **does not implement PTP
  timestamps** (the ports exist, the outputs are never driven), so the shim takes its own
  timestamps in logic (§6c) and `zircon_nic` stays unchanged.
- **kcu116: the zircon core stays on a free-running 300 MHz clock.** The MAC side of
  `zircon_nic` runs directly on the CMAC `tx_clk` / `rx_clk` (its MAC-side async FIFOs already
  separate those domains). Running the core on `tx_clk` was rejected: that clock only exists
  while the GT is up (not before the Si5328 is programmed, not during a GT reset), so UI ↔ core
  handshakes would stall, and `CORE_HZ` and the rate meters would change meaning. 300 MHz keeps
  §10.5 unchanged; 250 MHz would not be enough (RX needs 31 cycles against 30.8 available for a
  1514-byte frame).

### 1.1 Known limitations of the kcu116 target

- **One port.** The KCU116 HPC connector wires FMC DP0-3 only (one GTY quad, bank 227), so only
  QSFP28 port 0 exists; the QSFP1 module is held in reset and low-power mode by constants. The
  KU5P also has only one CMAC (CMACE4_X0Y0).
- **No cross-port loopback.** With one port there is no port-to-port cable test. On a QSFP28
  loopback plug in port 0, `L 0` (and `l`, the same test on a one-port build) runs 100 Gb/s line
  rate, and `e` echoes through the plug with requests and replies sharing port 0's transmit path
  (half the line each; at 64 B the echo drops ~0.05 % for lack of transmit room). Bench-run
  2026-09-25 19:40–19:54, §12.8.1.
- **FEC not switchable.** RS(528,514) is hard-wired in the Taxi wrapper: `APP_FEC_MODE` is
  ignored, the `f` key only prints `FEC fixed on this target`, and there are no RS-FEC codeword
  counters (the status line prints `cw corr n/a uncorr n/a`). The partner must run RS-FEC.
- **Maximum frame length not configurable.** The CMAC's maximum frame length is the static IP
  default: Taxi's `cfg_tx/rx_max_pkt_len` ports are not connected to the CMAC. 9000-byte
  payloads (9046-byte frames with FCS) were **verified on the loopback plug** (`L 0` at line
  rate, `e`, paced echoes; 0 errors, §12.8.1), so the limit is ≥ 9046 bytes; the exact value
  (believed 9600) was not probed. Jumbo frames were not tested against a host (MTU 1500).
- **Latency figures are not comparable with the vck190's** (MAC-client SOF → SOF instead of
  PCS → PCS, 4 ns quantisation; §11.7).
- **Software TCP echo** runs on a 100 MHz MicroBlaze: ~0.1–0.5 ms per exchange instead of
  7–10 µs on the A72 (§12.8). The hardware paths are unaffected.

## 2. Clocks, widths, domains

### 2.1 `vck190_fmcp1`

| domain | clock | width | blocks |
|---|---|---|---|
| MRMAC client | `axis_clk_wiz/clk_390m625`, 390.625 MHz (one clock for both ports) | 384 b, six 64-bit lanes (independent 384b non-segmented) | MRMAC AXIS, `rx_packer`, `tx_dwidth`, `tx_axis_adapter` |
| MAC side of zircon_nic (`mac_rx_clk`, `mac_tx_clk`) | the same 390.625 MHz | 512 b | MAC-side FIFOs, `tx_mac_out`, `ptp_tx_tagger`, MAC-domain counters |
| zircon_nic core (`clk`) | `clk_wizard_0/clk_300m`, 300 MHz | 512 b (32 b inside the Zircon parser and deparser) | all Zircon modules and glue, generator, checker, rate meters, `latency_stats` |
| UI / DMA / AXI-Lite (`ui_clk`) | `clk_wizard_0/clk_100m`, 100 MHz | 512 b streams, 32-bit AXI-Lite | four AXI DMAs, zircon_nic UI side and registers, NoC `aclk6`, MRMAC `s_axi_aclk`, GPIO / IIC |
| 1588 timestamp (`ts_clk`) | `clk_wizard_0/ts_clk`, 250 MHz | 55-bit timer | `ptp_systimer_0`, both MRMACs' `tx_ts_clk` / `rx_ts_clk` |
| GT | per port, BUFG_GT from the GT quad (322.265625 MHz refclk) | — | that port's MRMAC core / serdes clocks, GT user clocks |

`clk_wizard_0` is one MMCM (VCO 3000 MHz, D 1, M 30, output dividers 30 / 10 / 12, all at phase
0); `axis_clk_wiz` makes 390.625 MHz. Both take the CIPS `pl0_ref_clk` (100 MHz), so all PL
clocks are related. The MRMAC IP accepts a timestamp clock period of 2.8571–20 ns only, hence
the separate 250 MHz `ts_clk`. The MRMAC timer inputs (`ctl_*_ptp_systemtimer`, `st_*`) are on
`TX_TS_CLK` / `RX_TS_CLK` and driven by `ptp_systimer` directly; every other PTP pin
(`tx_ptp_1588op_in`, `tx_ptp_tag_field_in`, `tx_ptp_tstamp_*_out`, `rx_ptp_tstamp_out`) is on
the MRMAC AXI clock (390.625 MHz), so the only `ts_clk` crossing is inside the MRMAC.

Resets are active-low per domain from `proc_sys_reset` `peripheral_aresetn`, all waiting for
`pl0_resetn` and their MMCM lock: `ui_aresetn` = `rst_100m`, `aresetn` = `rst_300m`,
`ts_aresetn` = `rst_ts`, and per port `mac_rx_aresetn` = `rst_mac_rx[_1]`, `mac_tx_aresetn` =
`rst_mac_tx[_1]`. The two MAC-side resets are also held while the port's GT reset-done of that
direction (AND of the four lanes, on `aux_reset_in`) is low, the same signal that releases the
MRMAC core and serdes resets, so a GT reset from software flushes the MAC side of that port's
`zircon_nic`. `zircon_nic` converts each to a Taxi-style synchronous active-high reset
(`taxi_sync_reset`).

The MRMAC strips the FCS on RX and inserts it on TX (run-time settings written by software, §6).
The MRMAC RX client has **no back-pressure**. `mrmac_rx_packer.v` takes the six RX lanes directly
and accepts one 48-byte beat every cycle unconditionally: a 0/16/32/48-byte accumulator emits a
512-bit beat per 64 bytes and, at TLAST, one beat or a full beat plus a flush beat (a 16-entry
two-bank LUTRAM FIFO takes both in one cycle). The MRMAC error flag (`tkeep_user[8]` of the lanes
holding bytes, masked with tvalid) goes on `tuser[0]` of the last output beat (Taxi "bad
frame"); the RX timestamp goes on `tuser[48:1]` (§11.2). If the output is ever back-pressured
the packer buffers; if its FIFO would overflow it drops beats and delivers the damaged frame(s)
with `tuser[0]` = 1. `stat[1:0]` (stall / overflow pulses) → STATUS b4 / b5. An AMD
`axis_dwidth_converter` cannot be used on RX: it lowers `S_AXIS_TREADY` for a cycle when two
valid beats follow a TLAST beat, and the beat the MRMAC offered then was lost (seen on the bench
as a frame cut at 48 bytes merged with the next). On TX, where the MRMAC does back-pressure, the
path is `axis_dwidth_converter` 64 → 48 bytes + `mrmac_tx_axis_adapter` (lanes, PTP sideband).

### 2.2 `kcu116`

| domain | clock | width | blocks |
|---|---|---|---|
| system / UI / DMA / AXI-Lite (`sys_clk`) | `ddr4_0/addn_ui_clkout1`, 100 MHz | 512 b streams, 32-bit AXI-Lite | MicroBlaze, peripheral SmartConnect `aclk`, both AXI DMAs (lite, SG, MM2S, S2MM), zircon_nic `ui_clk`, GPIO / IIC / UART Lite / timers, DDR SmartConnect slave side (`aclk1`) |
| DDR4 controller | `ddr4_0/c0_ddr4_ui_clk`, 333.25 MHz (MIG preset `ddr4_sdram_075`) | — | DDR SmartConnect `axi_smc` master side only |
| zircon_nic core (`clk`) | `clk_wiz_0/clk_out1`, 300 MHz | 512 b | as on the vck190 (`CORE_HZ` 300000000 unchanged) |
| timestamp timebase (`ts_clk`) | `clk_wiz_0/clk_out2`, 250 MHz | 45-bit tick counter | shim timebase (§6c) |
| control (`ctrl_clk`) | `clk_wiz_0/clk_out3`, 125 MHz | 32-bit AXI-Lite, 16-bit APB | shim `ctrl_clk`: Taxi `xcvr_ctrl_clk` (GT free-run / DRP, APB), shim `s_axi` (peripheral SmartConnect `aclk1`) |
| CMAC TX (`tx_clk`) | shim output: Taxi `tx_clk` (BUFG_GT, TXPROGDIVCLK), 322.265625 MHz | 512 b | zircon_nic `mac_tx_clk`, shim TX side |
| CMAC RX (`rx_clk`) | shim output: Taxi `rx_clk` (lane 0 recovered clock, BUFG_GT), 322.265625 MHz nominal | 512 b | zircon_nic `mac_rx_clk`, shim RX side |
| GT reference | Si5328 CKOUT1 → GBTCLK0 → K7/K6, `IBUFDS_GTE4` inside the shim, 322.265625 MHz | — | QPLL0 of GTY bank 227 |

`clk_wiz_0` is one MMCM fed by `sys_clk` (`PRIM_SOURCE No_buffer`, VCO 1500 MHz: D 1, M 15,
dividers 5 / 6 / 12), reset by `rst_ddr4_0_100M/peripheral_reset`. Taxi requires the 125 MHz
`xcvr_ctrl_clk` (its GT wizard `FREERUN_FREQUENCY` and the CMAC `GT_DRP_CLK` are 125). The
vck190's 390.625 MHz `axis_clk`, the RX packer, `tx_dwidth` and `mrmac_tx_axis_adapter` do not
exist on this target: the CMAC client is already 512-bit Taxi-convention AXI-Stream, and the TX
/ RX clock difference is absorbed by zircon_nic's two MAC-side async FIFOs. The CMAC client, like
the MRMAC's, has no RX back-pressure (Taxi `m_axis_rx` comes straight from the CMAC; `tuser[0]`
= error on the last beat). `mac_rx_pack_stat` is tied to 0, so STATUS b4 / b5 read 0.

Resets (`proc_sys_reset`, `ext_reset_in` = board `reset` pushbutton, `dcm_locked` =
`clk_wiz_0/locked` for the three MMCM clocks): `rst_ddr4_0_100M` (board / MicroBlaze automation;
DMAs, peripherals, zircon_nic `ui_aresetn`), `rst_core_300M` (zircon_nic `aresetn`),
`rst_ts_250M` (shim `ts_aresetn`), `rst_ctrl_125M` (shim `ctrl_aresetn`); the MIG automation adds
`rst_ddr4_0_333M`. zircon_nic's `mac_rx_aresetn` / `mac_tx_aresetn` come from the shim (§6c):
low while Taxi's `rx_rst_out` / `tx_rst_out`, `CTRL.XCVR_RST` or `ctrl_aresetn` is asserted,
released synchronously in `rx_clk` / `tx_clk`.

## 3. `zircon_nic`

Verilog shell `Vivado/src/hdl/zircon_nic.v` (a block-design module reference needs a `.v` top)
around `zircon_nic_core.sv`, which instantiates the Taxi / Zircon modules. The shell is
authoritative for port names and widths; it carries the `X_INTERFACE_*` attributes for the AXIS
and AXI-Lite interfaces and their clock / reset associations (`clk` has `ASSOCIATED_BUSIF none`,
reset polarity ACTIVE_LOW).

```
module zircon_nic #(
    DATA_W         = 512,        // MAC-side, core and UI width (only 512 is supported)
    TRUNC_BYTES    = 64,         // header bytes fed to the 32-bit Zircon parser per packet
    RX_FIFO_BEATS  = 512,        // MAC-side RX frame FIFO (drop-bad, drop-when-full, drop-oversize), 32 KB
    PKT_FIFO_BEATS = 512,        // core store-and-forward RX frame FIFO (>= RX_FIFO_BEATS)
    TX_RAM_SIZE    = 32768,      // zircon_ip_tx_buffer payload RAM (bytes)
    TX_FIFO_BEATS  = 512,        // MAC-side TX frame FIFO (jumbo-capable)
    GEN_EN         = 1,          // generator + checker built (0: not built, their registers read 0)
    CORE_HZ        = 300000000,  // core cycles per rate-meter window (must equal the core clock)
    C_S_AXI_ADDR_WIDTH = 12      // must be 12
)(
    clk, aresetn,                                   // core, 300 MHz
    mac_rx_clk, mac_rx_aresetn,                     // vck190 390.625 MHz; kcu116 CMAC rx_clk 322.265625 MHz
    s_axis_mac_rx_{tdata[511:0], tkeep[63:0], tvalid, tready, tlast},
    s_axis_mac_rx_tuser[48:0],                      // [0] bad frame (last beat), [48:1] RX timestamp ts[54:7]
    mac_rx_pack_stat[1:0],                          // mrmac_rx_packer: [0] stalled, [1] beats dropped (kcu116: 0)
    mac_tx_clk, mac_tx_aresetn,                     // vck190 390.625 MHz; kcu116 CMAC tx_clk 322.265625 MHz
    m_axis_mac_tx_{tdata, tkeep, tvalid, tready, tlast}, m_axis_mac_tx_tuser[0:0] (always 0),
    m_axis_tx_ptp_{tdata[23:0], tvalid, tready},    // one {tag, 1588 op} record per TX frame (§11.3)
    tx_ptp_tstamp_in[54:0], tx_ptp_tstamp_tag_in[15:0], tx_ptp_tstamp_valid_in,   // from the MRMAC / the CMAC shim
    ui_clk, ui_aresetn,                             // 100 MHz
    m_axis_raw_rx_*,  s_axis_raw_tx_*,              // UI0, {tdata, tkeep, tvalid, tready, tlast}
    m_axis_sock_rx_*, s_axis_sock_tx_*,             // UI2
    s_axi_*                                         // AXI4-Lite, 32-bit data, 12-bit address (§3.3)
);
```

Internal parameters of `zircon_nic_core` (not on the shell): `HDR_FIFO_BEATS` 64 truncated
headers, `UI_FIFO_BEATS` 64 (rx_egress / tx_ingress async FIFOs), `ECHO_META_DEPTH` 256 echo
records, `RX_PATH_FIFO_BEATS` 512 (the RAW, SOCK and echo frame FIFOs, 32 KB each),
`MAX_TX_BYTES` 9618, `TX_GUARD_BEATS` 256. Elaboration checks: `DATA_W` = 512,
`PKT_FIFO_BEATS` ≥ `RX_FIFO_BEATS`, power-of-two FIFO depths holding ≥ 16 KB,
`MAX_TX_BYTES` and the guard FIFO below `TX_RAM_SIZE`, `TX_RAM_SIZE` above the largest
generator payload, 46 ≤ `TRUNC_BYTES` ≤ 1020.

### 3.1 RX datapath

All glue is MIT; `taxi_*` / `zircon_ip_*` are the unmodified Taxi modules. Verified in xsim (§3.4).

```
s_axis_mac_rx (mac_rx_clk, 512 b, tuser 49 b)
 → taxi_axis_async_fifo  FRAME_FIFO, DROP_BAD_FRAME (tuser[0]), DROP_WHEN_FULL,
   DROP_OVERSIZE_FRAME, RX_FIFO_BEATS deep; tready = 1 (never back-pressures the MAC).
   Its overflow / bad-frame pulses are counted in the mac_rx domain
   (RX_FIFO_DROP, RX_BAD_FRAME).                                             → core clk
   tuser (bad marker + timestamp) is carried past the FIFO. If mac_rx_aresetn asserts
   while a frame is being read out, the FIFO terminates it with tuser = bad and
   rx_dispatch drops it (RX_BAD_FRAME); the read side then gets its own reset once it
   is between frames (output gated meanwhile), because in FRAME_FIFO mode Taxi only
   clears the read side's synchronised commit pointer on m_rst and would otherwise
   replay stale RAM contents as frames.
 → taxi_axis_broadcast (2 outputs, lockstep)
     [A] → zircon_ip_len_cksum (START_OFFSET 14) → taxi_axis_fifo FRAME_FIFO (store and
           forward), PKT_FIFO_BEATS, never drops (the packet's metadata already exists);
           the {sum, len} record (+ the last beat's tuser) has no back-pressure in Zircon
           → taxi_axis_fifo, 2 × PKT_FIFO_BEATS entries
     [B] → hdr_trunc: first TRUNC_BYTES bytes, tlast forced, the rest consumed at full
           width → taxi_axis_fifo (HDR_FIFO_BEATS) → taxi_axis_adapter 512 → 32
         → zircon_ip_rx_parse (HASH_EN 0)
         → rx_meta_capture: takes the 16 × 64 b metadata block at 1 beat/cycle and pushes
           ONE rx_hdr_rec_t per packet (flags, payload length, pkt_sum, dst/src MAC,
           dst/src IPv4, dst/src port; 272 b) → taxi_axis_fifo (PKT_FIFO_BEATS records;
           back-pressures the parser when full)
 → rx_dispatch: waits until the packet, len and record FIFO heads are all valid (a frame
   is never popped before both of its records exist), then IDLE (capture the heads and the
   UDP checksum field, bytes 40..41) → PAD (padding mask, address / port / flag rules) →
   SUM (padding sum) → ADJ (UDP checksum) → CLS (route) → EVAL (pop both records, push
   the echo record) → [DESC: one 64-byte descriptor beat] → FWD at 1 beat/cycle → [FLUSH]
     cand      = IPv4 ∧ UDP ∧ ¬VLAN_S ∧ ¬VLAN_C ∧ ¬FRAG ∧ ¬L3_OPT ∧ ¬L4_BAD_LEN ∧ PARSE_DONE
                 ∧ dst MAC = local ∧ dst IP = local ∧ payload_len ≠ 0
                 ∧ frame_len ≥ 42 + payload_len
     ECHO rule : cand ∧ UDP dst port = ECHO_PORT ∧ CTRL.ECHO_EN ∧ L3 ok ∧ L4 ok
     SOCK rule : cand ∧ UDP dst port = SOCK_LOCAL_PORT ∧ CTRL.SOCK_EN ∧ L3 ok ∧ L4 ok
     CHK rule  : cand ∧ UDP dst port = CHK_PORT ∧ CHK_CTRL.EN ∧ L3 ok ∧ L4 ok (GEN_EN only)
                 precedence on equal ports: ECHO > SOCK > CHK
     otherwise : RAW, the frame unchanged (broadcast, other MACs, everything else)
     CTRL.RX_EN = 0 : every frame is consumed and dropped here (counted in RX_FIFO_DROP)
     bad marker     : a frame whose len record carries tuser = bad is dropped here
                      (counted in RX_BAD_FRAME, not in RX_FRAMES)
   L3 ok = ¬L3_BAD_CKSUM (parser).
   L4 ok = (UDP checksum field = 0) ∨ (pkt_sum ≡ len.sum − pad_sum, ones'-complement
           arithmetic and equality, 0x0000 ≡ 0xFFFF). pad_sum is the sum of the Ethernet
           padding [42 + payload_len, frame_len) of a frame of ≤ 64 bytes (the only case
           with padding: len.sum covers it, pkt_sum does not), so non-zero padding does not
           fail short datagrams. A longer frame with bytes beyond the IP datagram goes RAW.
           A rule candidate failing only L4 goes RAW and counts RX_L4_BAD_CSUM;
           RX_L3_BAD_CSUM counts every IPv4 frame the parser flags.
   ECHO: fixed 42-byte strip (a constant realignment with a 22-byte carry register, no
         barrel shifter), trimmed to payload_len (padding is never echoed) → echo frame
         FIFO (RX_PATH_FIFO_BEATS) → zircon_ip_tx_buffer input 1 (tdest 1); the echo_rec_t
         {rx src/dst MAC, IP, port, rx_ts} is pushed to the echo-metadata FIFO
         (ECHO_META_DEPTH) first. If the echo FIFO has no room for the whole payload or
         the metadata FIFO is full, the request is dropped here (RX_ECHO_DROP): dispatch
         never waits on the TX path.
   SOCK: ZSKT descriptor (§5) + stripped / trimmed payload → socket RX FIFO → rx_egress → UI2
   CHK : stripped / trimmed payload → udp_chk (tready = 1, nothing forwarded)
   RAW : [ZRXT descriptor if LAT_CTRL.RAW_RX_DESC (§11.2)] + frame → raw RX FIFO
         → zircon_ip_rx_egress → UI0
   The raw and socket RX FIFOs are taxi_axis_fifo FRAME_FIFO, DROP_WHEN_FULL,
   DROP_OVERSIZE_FRAME, RX_PATH_FIFO_BEATS: a frame that does not fit is dropped whole
   (with its descriptor) and counted (RX_RAW_DROP / RX_SOCK_DROP), so a stalled consumer
   (DMA S2MM ring empty or halted) never blocks the other paths.
```

The two `zircon_ip_rx_egress` instances (`UI_RX_FIFO_DEPTH` = `UI_FIFO_BEATS`) do the core →
`ui_clk` crossing; routing is the dispatcher's own output registers (no `taxi_axis_demux`).

Per-packet cost: the parser branch reads the 64-byte truncated header 4 bytes per cycle, 16 core
cycles per packet (xsim-measured, §10.5); `rx_dispatch` needs 6 cycles to classify (7 when it
emits a descriptor: SOCK, or RAW with `RAW_RX_DESC`) plus one per beat, and one FLUSH beat when
the payload tail sits in the last input beat. Frames arriving faster than that are dropped whole
at the MAC-side FIFO (RX_FIFO_DROP, STATUS.RX_FIFO_OVF), never truncated.

Deadlock freedom: the head of the packet FIFO is always the oldest packet, so its header record
is the next one the parser produces. `PKT_FIFO_BEATS` ≥ `RX_FIFO_BEATS` guarantees that a frame
accepted by the MAC-side FIFO fits the packet FIFO completely, so its len record always arrives.
The len FIFOs (RX and TX) hold twice the number of 1-beat packets their data store can hold,
because `zircon_ip_len_cksum`'s output cannot be back-pressured; an overflow (impossible by
construction) sets STATUS.RX_META_ERR / TX_META_ERR.

### 3.2 TX datapath

```
UI0 raw  (ui_clk) → zircon_ip_tx_ingress → tx_len_guard → raw_tx_desc_strip → tdest 0 ┐
UI1 echo (core, from rx_dispatch via the echo frame FIFO)                    → tdest 1 ├→ zircon_ip_tx_buffer
UI2 sock (ui_clk) → zircon_ip_tx_ingress → tx_len_guard                      → tdest 2 ┤   (TX_RAM_SIZE; N_UI 4,
UI3 gen  (core, udp_gen payloads, GEN_EN, §10)                               → tdest 3 ┘    3 without GEN_EN)
   tx_len_guard: store-and-forward taxi_axis_fifo (TX_GUARD_BEATS = 16 KB, DROP_BAD_FRAME +
     DROP_OVERSIZE_FRAME); a beat counter marks a frame longer than MAX_TX_BYTES bad on its
     last beat. Drops count TX_OVERSIZE_DROP. tx_buffer only produces a length record after
     a whole payload, so a transfer ≥ TX_RAM_SIZE would otherwise wedge it and, through the
     shared arbiter, the echo and RX dispatch. UI frames also enter tx_buffer at the core
     clock rate instead of holding the arbiter at the UI rate.
   raw_tx_desc_strip: removes a ZTXT descriptor (LAT_CTRL.RAW_TX_DESC, §11.3) and emits one
     latency record per frame into a TX_RAM_SIZE/64-entry FIFO; without RAW_TX_DESC every
     frame passes untouched with record want = 0.
   ↓ m_axis_meta_len {sum, len} + tdest → taxi_axis_fifo (2 × TX_RAM_SIZE/64 entries)
tx_meta_builder: the 16 × 64 b deparser metadata block per packet (§4), 16 cycles/packet
    (a prep stage computes the next packet's fields and checksum adjustment, 1 + 4 cycles,
    while the output stage emits the current 16 beats)
    tdest 0 → flags = 0 (FLG_EN = 0: the deparser emits no header, the raw frame passes as-is)
    tdest 1 → pops the echo record: dst = rx src MAC/IP/port, src = rx dst (local MAC/IP,
              ECHO_PORT); flags = EN|IPV4|UDP
    tdest 2 → dst = SOCK_REMOTE_MAC/IP/PORT, src = local MAC/IP, SOCK_LOCAL_PORT
    tdest 3 → dst = GEN_DST_MAC/IP/PORT, src = local MAC/IP, GEN_SRC_PORT
    IPv4: TTL register, DSCP/ECN 0, identification = one 16-bit counter incremented per
    hardware-built (echo / socket / generator) packet, IHL 5 and DF clear (deparser).
    One latency record per packet, in packet order, → 32-entry FIFO (§11.3).
 → Zircon TX egress, instantiated as its parts (same modules and parameters as
   zircon_ip_tx_egress): zircon_ip_tx_deparse → taxi_axis_adapter 32 → 512 (header) +
   payload → taxi_axis_concat → latency record attached to every beat (tuser[51:1])
   → taxi_axis_async_fifo (frame FIFO, TX_FIFO_BEATS)                         → mac_tx_clk
 → tx_mac_out: CTRL.TX_EN gate sampled at each frame's first beat (a frame that starts while
   TX is disabled is discarded whole, so nothing upstream stalls), zero-padding of frames
   < 60 bytes to 60 (the MAC adds the FCS → 64), two-entry skid register, TX_FRAMES /
   TX_BYTES (plus never-cleared copies for the rate meter)
 → ptp_tx_tagger (§11.3): one m_axis_tx_ptp record per frame, TX timestamp lookup,
   latency samples
 → m_axis_mac_tx (tuser = 0)
```

`s_axis_mac_tx_cpl` of the egress is tied off (tvalid 0) and `m_axis_ui_tx_cpl` of the ingress
is left unused (Zircon never drives it). The tx_buffer arbitrates per packet, round robin. TX
capacity (xsim-measured): max(18, ⌈F/64⌉ + 1) core cycles per packet, F = frame bytes (§10.5).

### 3.3 Register map (AXI4-Lite, byte offsets, 32-bit, little-endian)

| offset | name | R/W | meaning |
|---|---|---|---|
| 0x000 | ID | R | `0x5A495243` ("ZIRC") |
| 0x004 | VERSION | R | `0x00010300` = 1.3.0 (bits 23:16 major, 15:8 minor, 7:0 patch; earlier values in §13) |
| 0x008 | CTRL | RW | b0 RX_EN, b1 TX_EN, b2 ECHO_EN, b3 SOCK_EN, b4 PROMISC (reserved, no effect: frames for other MACs always go RAW), b31 STAT_CLR (write 1 with byte lane 3: zeroes the counters in every clock domain; reads 0). b4:0 are written with byte lane 0. |
| 0x00C | STATUS | R/W1C | b0 RX_FIFO_OVF (sticky, W1C: the MAC-side FIFO dropped a frame), b1 TX_UNDERRUN (always 0: the MAC-side TX FIFO is a frame FIFO), b2 RX_META_ERR, b3 TX_META_ERR (RO, sticky until reset: internal len-metadata FIFO overflow, must never be set), b4 RX_PACK_STALL (sticky, W1C: the packer output saw tready low; expected only around a MAC-side reset), b5 RX_PACK_OVF (sticky, W1C: the packer dropped beats; the frames concerned were delivered as bad). b4 / b5 always read 0 on the kcu116 (no packer; `mac_rx_pack_stat` tied 0) |
| 0x010 | MAC_LO | RW | local MAC bytes 0..3 (byte 0, first on the wire, in bits 7:0) |
| 0x014 | MAC_HI | RW | local MAC bytes 4..5 in bits 15:0 |
| 0x018 | IPV4 | RW | local IPv4, first octet in bits 31:24 (192.168.10.2 = 0xC0A80A02) |
| 0x01C | ECHO_PORT | RW | bits 15:0, default 7 |
| 0x020 | SOCK_LOCAL_PORT | RW | bits 15:0 |
| 0x024 | SOCK_REMOTE_PORT | RW | bits 15:0 |
| 0x028 | SOCK_REMOTE_IP | RW | as IPV4 |
| 0x02C | SOCK_REMOTE_MAC_LO | RW | as MAC_LO |
| 0x030 | SOCK_REMOTE_MAC_HI | RW | as MAC_HI |
| 0x034 | TTL | RW | TTL of hardware-built IPv4 headers, bits 7:0, default 64 |
| 0x040 | RX_FRAMES | R | frames entering the core (after the MAC-side FIFO's bad-frame / overflow drops), including frames dropped because RX_EN = 0 |
| 0x044 / 0x048 | RX_BYTES_LO / _HI | R | 64-bit, bytes of those frames (FCS excluded) |
| 0x04C | RX_BAD_FRAME | R | frames dropped for a bad marker: MAC error at the MAC-side FIFO, plus frames the FIFO terminated on a MAC-side reset (dropped by rx_dispatch) |
| 0x050 | RX_FIFO_DROP | R | frames dropped by the MAC-side FIFO (full or oversize), plus frames dropped by rx_dispatch while RX_EN = 0 |
| 0x054 | RX_L3_BAD_CSUM | R | IPv4 header checksum failures flagged by the parser |
| 0x058 | RX_L4_BAD_CSUM | R | UDP checksum failures of rule candidates (then routed RAW) |
| 0x05C | RX_RAW | R | frames routed to UI0 (including those then dropped by the raw RX FIFO) |
| 0x060 | RX_ECHO | R | requests echoed (not counting RX_ECHO_DROP) |
| 0x064 | RX_SOCK | R | datagrams routed to UI2 (including those then dropped by the socket RX FIFO) |
| 0x068 | TX_FRAMES | R | frames handed to the MAC (not counting frames discarded while TX_EN = 0) |
| 0x06C / 0x070 | TX_BYTES_LO / _HI | R | 64-bit, after padding to 60 bytes, FCS excluded |
| 0x074 | TX_RAW | R | packets whose TX metadata was built, per source, counted in the core before the TX_EN gate |
| 0x078 | TX_ECHO | R | |
| 0x07C | TX_SOCK | R | (generated datagrams are counted in GEN_TX_PKTS, not here) |
| 0x080 | RX_RAW_DROP | R | RAW frames dropped by the raw RX FIFO (UI0 consumer too slow) |
| 0x084 | RX_SOCK_DROP | R | SOCK datagrams dropped by the socket RX FIFO (UI2 consumer too slow) |
| 0x088 | RX_ECHO_DROP | R | echo requests dropped by rx_dispatch: no room in the echo payload FIFO or the echo-metadata FIFO |
| 0x08C | TX_OVERSIZE_DROP | R | UI0 / UI2 TX transfers longer than 9618 bytes dropped by tx_len_guard (not in TX_RAW / TX_SOCK) |
| 0x090 | GEN_CTRL | RW | b0 EN (a 0→1 edge starts a run; clearing it stops after the datagram in progress), b1 CONT (continuous, else GEN_COUNT datagrams; sampled at the start), b2 CLR (write 1: sequence number and GEN_TX_* to 0; reads 0), b31 BUSY (RO) |
| 0x094 | GEN_LEN | RW | UDP payload bytes, bits 15:0, default 1472; used clamped to 8..9000, reads the written value |
| 0x098 | GEN_COUNT | RW | datagrams per run when CONT = 0 (0: none) |
| 0x09C | GEN_GAP | RW | idle core cycles after every generated datagram (0: back to back) |
| 0x0A0 / 0x0A4 | GEN_DST_MAC_LO / _HI | RW | as MAC_LO / MAC_HI |
| 0x0A8 | GEN_DST_IP | RW | as IPV4 |
| 0x0AC | GEN_DST_PORT | RW | bits 15:0 |
| 0x0B0 | GEN_SRC_PORT | RW | bits 15:0 |
| 0x0B4 | GEN_TX_PKTS | R | datagrams handed to zircon_ip_tx_buffer |
| 0x0B8 / 0x0BC | GEN_TX_BYTES_LO / _HI | R | 64-bit, UDP payload bytes of those datagrams |
| 0x0C0 | CHK_CTRL | RW | b0 EN (enables the CHK rule; a 0→1 edge resynchronises), b2 CLR (write 1: CHK_* to 0 and resynchronise; reads 0), b31 SYNC (RO: a datagram has been checked since enable / CLR) |
| 0x0C4 | CHK_PORT | RW | bits 15:0, default 5001 |
| 0x0C8 | CHK_RX_PKTS | R | datagrams checked (payload ≥ 8 bytes) |
| 0x0CC / 0x0D0 | CHK_RX_BYTES_LO / _HI | R | 64-bit, UDP payload bytes of those datagrams |
| 0x0D4 | CHK_SEQ_ERR | R | sequence discontinuities (+1 per datagram whose sequence number ≠ expected, then resync) |
| 0x0D8 / 0x0DC | CHK_BIT_ERR_LO / _HI | R | 64-bit, payload bits (bytes 8..end) differing from the regenerated pattern |
| 0x0E0 | CHK_LEN_ERR | R | datagrams to CHK_PORT with a payload < 8 bytes (not checked, not in CHK_RX_PKTS) |
| 0x0E4 | RATE_SEQ | R | rate-meter windows completed since reset; **a read latches** the six registers below from one window |
| 0x0E8 / 0x0EC | RX_RATE_BYTES_LO / _HI | R | bytes that entered the core (RX_BYTES events) in the latched window |
| 0x0F0 | RX_RATE_PKTS | R | frames that entered the core (RX_FRAMES events) in the latched window |
| 0x0F4 / 0x0F8 | TX_RATE_BYTES_LO / _HI | R | bytes handed to the MAC (TX_BYTES events) in the latched window |
| 0x0FC | TX_RATE_PKTS | R | frames handed to the MAC in the latched window |
| 0x100 | LAT_CTRL | RW | byte lane 0: b0 EN (request TX timestamps: echo replies → bank 0, UI0 frames with a ZTXT TS_REQ → bank 1), b1 CLR0 / b2 CLR1 (write 1: clear bank 0 / 1), b3 SNAP (write 1: copy both banks to the snapshot region); byte lane 1: b8 RAW_RX_DESC (ZRXT descriptor in front of every UI0 RX frame), b9 RAW_TX_DESC (strip and honour ZTXT descriptors on UI0 TX). b1..b3 are commands and read 0 except that **b3 and b31 read BUSY** (a command is still running, ≈1 µs for a snapshot) |
| 0x104 | LAT_STATUS | R/W1C | sticky: b0 STALE (a TX timestamp came back for no pending tag), b1 LOST (a pending entry was reused before its timestamp came back), b2 OVF (a sample was lost: statistics FIFO full) |
| 0x108 | LAT_BIN_BASE | RW | ns, lower edge of the linear histogram bins (both banks), default 0 |
| 0x10C | LAT_BIN_WIDTH | RW | ns, width W of the linear bins, a power of two (a written value is rounded down to one; 0 → 1), default 64 |
| 0x110 | LAT_STALE_CNT | R | STALE events |
| 0x114 | LAT_LOST_CNT | R | LOST events |
| 0x118 | LAT_OVF_CNT | R | OVF events |
| 0x200 + 0x40·b | bank b snapshot (b = 0, 1) | R | +0x00/+0x04 COUNT_LO/HI, +0x08/+0x0C SUM_LO/HI (ns), +0x10/+0x14 SUMSQ_LO/HI (ns², saturating), +0x18 MIN (0xFFFFFFFF when COUNT = 0), +0x1C MAX, +0x20 IMPLAUSIBLE (deltas ≥ 1 s, not accumulated elsewhere), +0x24 LAST, +0x28 BIN_BASE, +0x2C BIN_WIDTH (the geometry at snapshot time), +0x30..+0x3C 0 |
| 0x400 + 0x200·b + 8·i | bank b bin i | R | i = 0..63: +0 count[31:0], +4 count[47:32] (48-bit bins) |

Reads of undefined offsets return 0 (0x280..0x3FF included); writes to them are ignored. All
counters wrap; SUMSQ saturates. Defaults after reset: CTRL = 0 (the whole datapath, raw path
included, is closed until software enables it), ECHO_PORT 7, TTL 64, GEN_LEN 1472, CHK_PORT
5001, LAT_BIN_WIDTH 64, everything else 0.

- `GEN_EN` = 0: 0x090..0x0E0 read 0 and ignore writes (software probes `GEN_LEN` ≠ 0). The rate
  meters (0x0E4..0x0FC) and the latency block (0x100..0x7FF) are always built.
- `CTRL.STAT_CLR` zeroes every counter, including GEN_TX_*, CHK_* and LAT_*_CNT. It does not
  touch the generator's sequence number, the checker's sync, the rate meters or the latency
  banks (LAT_CTRL.CLR0 / CLR1).
- 64-bit counters: reading `_LO` latches `_HI` from the same snapshot; read LO, then HI. The six
  rate registers are latched by the RATE_SEQ read instead.
- Counters are kept in the clock domain of their event (mac_rx, core, mac_tx) and cross to
  `ui_clk` as whole snapshots (`zircon_cdc_snapshot`, a small Taxi async FIFO), so each group is
  coherent; values lag by < 1 µs. The configuration word crosses to the core clock the same
  way; CTRL.TX_EN and the STAT_CLR toggle reach the MAC domains through `taxi_sync_signal`.
- 0x200..0x7FF is the `latency_stats` shadow RAM (read with one extra cycle): it changes only
  when a SNAP completes. It has no reset: it reads 0 after configuration, and keeps the last
  snapshot across a core reset.

### 3.4 Verification (xsim)

`Vivado/src/hdl/tb/run_xsim.sh` (xvlog / xelab / xsim, Vivado 2025.2; `ZIRCON_TESTS=15,18` runs a
subset; exits non-zero on any failure) generates the vectors with `gen_vectors.py` (a plain
Python packet builder: frames, expected replies with IPv4/UDP checksums, descriptors, the
generator payload model `gen_payload()`, counter values) and runs `tb_zircon_nic.sv` against the
`zircon_nic` shell:

| tests | checks |
|---|---|
| 9, 1–8, 10–12 | register defaults and every register; raw RX/TX (9000-byte jumbo, short-frame padding); hardware echo (payloads 1/18/100/1472/8000, bad UDP / IPv4 checksum → RAW, UDP checksum 0 → echoed); socket RX/TX; MAC-error drop; 200 back-to-back 64-byte frames with UI0 held then released; VLAN → RAW; RX_EN / TX_EN gating; 60 mixed frames with random back-pressure on every sink; the UDP checksum carry corner cases (§4) |
| 15–19, 21 | UI0/UI2 held while echo traffic flows; MAC TX held while raw traffic flows; MAC-side reset during a frame read-out; non-zero Ethernet padding; oversize UI TX transfers; packer STATUS bits |
| 30–34, 40–44 | generator: count mode with exact headers, checksums, sequence numbers and payload; GEN_LEN 8 / 9000 and clamping; GEN_GAP; continuous mode stopped cleanly. Checker: 13 sizes, flipped payload bits, a lost datagram, bad checksum / short payload / disabled / moved port; GEN_EN = 0 build |
| 50, 60, 70 | the loopback in simulation (MAC TX fed back into MAC RX, TX shaped to 100 Gb/s, GEN_TX_PKTS = CHK_RX_PKTS, zero errors, 100.0 Gb/s line rate on the rate meter); rate meters with a 20000-cycle window; informational throughput sweep (`RATE` / `RXRATE` lines, §10.5) |
| 80–85 | latency measurement (§11.6) |

The TB builds a second snapshot with `GEN_EN` = 0 and runs tests 9, 1, 3, 5, 44 and 60 on it.
`tb_mrmac_rx_packer.sv` drives `mrmac_rx_packer` with back-to-back MRMAC beats (tests 13, 14,
20: lengths 1..9000, 48-byte multiples, single-beat TLAST frames, errored frames, tready drops,
FIFO overflow, and the RX timestamp on every output beat). `tb_ptp_units.sv` covers the TX
adapter's PTP sideband (23) and `ptp_systimer` (24).

`run_xsim.sh` also builds `tb_zircon_cmac_us.sv`, the kcu116 shim (§6c) around Taxi's
`taxi_eth_mac_100g_us` with `SIM` = 1, whose sources it expands from Taxi's `.f` lists as the
Vivado flow does (§7.1). Taxi's SIM mode drops the GT and CMAC IP but does **not** loop TX to RX:
it leaves the GT user clocks (`gt_txoutclk` / `gt_rxoutclk` of every lane) and the wrapper's
internal CMAC client interfaces undriven, and Taxi's own cocotb benches drive them
hierarchically. The TB does the same with xsim `force` and models the CMAC (TX tready always /
random / shaped to 100 Gb/s, an optional TX → RX loop with a fixed delay across unrelated clocks,
injected RX frames). Without the CMAC the shim substitutes: RX_GOOD_PKTS = error-free RX frames,
TX_GOOD_PKTS = frames accepted, RX_BAD_FCS and RX_HIGH_BER = 0, RX_BLOCK_LOCK = RX_STATUS, a
1250-cycle (×100) clock window, and `IBUFDS_GTE4` bypassed. `taxi_eth_phy_10g_usxgmii_an.sv`
(pulled in by the `.f` list, unused by the 100G wrapper) does not compile in xsim (VRFC 10-3400)
and is left out of the simulation list only.

| test | checks |
|---|---|
| 101 | register defaults (ID, VERSION, CTRL 0x31, TS_INCR, STICKY); `mac_*_aresetn` low and GT APB answering SLVERR while XCVR_RST is set; release → TX_RST_OUT / RX_RST_OUT clear, RX_STATUS, `link_up`, `mac_*_aresetn` high |
| 102 | AXI-Lite → `taxi_axil_apb_adapter` → the wrapper's GT APB registers: 32- and 16-bit accesses, lane address split, a 16-bit write leaves the neighbouring 16-bit register alone |
| 103 | TS_NOW advances at 1 ns/ns (LO latches HI); TX_CLK_KHZ / RX_CLK_KHZ match the model clocks |
| 104 | injected RX frames (1..40 beats, error flags, gaps): data unchanged, `tuser[48:1]` on every beat = the first-beat timestamp, within the `ts_gray_sync` window of the true arrival time; counters |
| 105 | op 2'b10 records (queued ahead, in the SOF cycle, several frames ahead), op 0 records, random CMAC tready: one return per op-2 frame one cycle after the SOF handshake, right tag and time; none for op 0 |
| 106 | a frame without a record goes out untagged and intact, STICKY.PTP_UNDERRUN set, W1C clears it |
| 107 | TX → RX loop at three RX periods / phases: \|(RX ts − TX ts) − true delay\| ≤ 8 ns for every frame |
| 108 | (monitors over the whole run) every `ts_gray_sync` output monotonic, +0/+1 per cycle (+2/3 in `ctrl_clk`), lag spread ≤ 8 ns per domain and across TX and RX |
| 109 | CTRL.RX_RST → `mac_rx_aresetn` low, STICKY.LINK_LOST; CTRL.TX_RST → `mac_tx_aresetn` low; recovery |
| 110 | zircon_nic + shim, `mac_tx_clk` ≠ `mac_rx_clk`, CMAC TX shaped to 100 Gb/s and looped: 200 generated 1472-byte datagrams checked, no errors, drops or PTP underrun |
| 111 | 20 UDP echo requests with LAT_CTRL.EN: bank 0 COUNT 20, MIN / MAX within 8 ns of the true RX-first-beat → TX-SOF delays, LAT_STATUS 0 |

## 4. Metadata handling (Zircon formats, Taxi `cc70b27`)

The parser output and deparser input are 16 beats × 64 bit (128 bytes). Byte layout
(`zircon_ip_rx_parse.sv:38-54`, `zircon_ip_tx_deparse.sv:40-56`): flags u32 LE at 0, L4 payload
length u16 at 4, pkt / payload sum u16 at 6, offsets at 12/13/15 (32-bit words, byte offset =
n × 4 + 2), S/C-TCI at 16/18, Eth dst at 24..29, Eth src at 32..37, ethertype at 38..39 (BE), IP
proto at 56, TTL at 57, IPv4 ID u16 LE at 60, DSCP/ECN at 63, dst IP at 64..67 (IPv4), src IP at
80..83, L4 dst port u16 LE at 96, src port at 98. Flags: b1 VLAN_S, b2 VLAN_C, b3 IPV4, b4 IPV6,
b5 FRAG, b6 ARP, b7 ICMP, b8 TCP, b9 UDP, b16 L3_OPT, b17 L4_OPT, b24 L3_BAD_CKSUM, b25
L4_BAD_LEN, b31 PARSE_DONE (RX) / FLG_EN (TX). MAC and IPv4 addresses are in wire order (first
byte in bits 7:0). The AXI-Lite registers hold IPv4 addresses as network-order u32 (first octet
in bits 31:24); `zircon_regs` byte-swaps. **All 16 beats always go to the deparser.** The
deparser fixes IHL = 5 and never sets DF; it computes the UDP checksum from the pseudo-header and
the payload sum supplied in bytes 6..7 (from `zircon_ip_tx_buffer`'s len_cksum, START_OFFSET 0).

RX `pkt_sum` (bytes 6..7) is the value that the len_cksum sum of bytes 14..end must have if the
UDP checksum is valid; the parser folds it completely, so it is compared with ones'-complement
equality (0x0000 ≡ 0xFFFF). The parser consumes the whole frame it is given (hence `hdr_trunc`)
and ignores tkeep; with TRUNC_BYTES = 64 an IPv4 header with more than 28 bytes of options is
truncated, so such frames may be counted in RX_L3_BAD_CSUM (they are RAW anyway: the rules
exclude options).

**UDP checksum workaround (Zircon `cc70b27`).** The deparser sums the UDP checksum in a 21-bit
register l4 = payload_sum + K (K = UDP length + ports + once-folded pseudo-header) and emits
`~(l4[15:0] + l4[20:16])`, a single end-around-carry fold (`zircon_ip_tx_deparse.sv:496`). When
that addition carries out of 16 bits the checksum is one too small (≈ 1 packet in 2^16 when K >
0xFFFF, e.g. replies to ephemeral source ports; reproduced in xsim, test 12). `tx_meta_builder`
computes K and the full fold T itself and passes an adjusted payload sum in bytes 6..7 so that
the deparser's single fold yields exactly T; for the (K, T) pairs no adjusted value can reach
(T ≤ K[20:16] with K[15:0] ≠ 0, odds ≈ 1e-9) it makes the deparser emit 0x0000 (IPv4 UDP "no
checksum"). Raw (FLG_EN = 0) metadata is unaffected. The arithmetic runs in the builder's prep
stage, overlapped with the previous packet's output, so it costs no throughput. Worth reporting
upstream.

## 5. Hardware socket descriptor (UI2 RX, 64 bytes in front of each payload, little-endian)

| bytes | field |
|---|---|
| 0..3 | magic `0x5A534B54` ("ZSKT") |
| 4..5 | payload length (bytes) = UDP length − 8 |
| 6..7 | source UDP port |
| 8..11 | source IPv4 (network byte order in memory, i.e. the bytes as on the wire) |
| 12..17 | source MAC (wire order) |
| 18..19 | destination UDP port |
| 20..23 | destination IPv4 |
| 24..27 | parser flags (§4), e.g. 0x80000208 = PARSE_DONE \| UDP \| IPV4 |
| 28..63 | 0 |

The payload that follows is exactly `payload length` bytes (Ethernet padding removed); descriptor
and payload are one AXI-Stream frame (one DMA transfer). UI2 TX from the PS is payload only (no
descriptor, at least 1 byte; the frame must fit the partner's MTU, 8972 bytes for a 9000-byte
MTU); the headers come from the SOCK_* registers. A UI0 / UI2 TX transfer longer than
MAX_TX_BYTES (9618) is dropped by `tx_len_guard` and counted in TX_OVERSIZE_DROP.

## 6. Block design, vck190 (`Vivado/src/bd/bd_versal.tcl`, bd name `zircon`)

Derived from the VCK190 block design of the 2x-qsfp28-fmc reference design (`bd_versal.tcl`,
branch dev-yocto @3852c57): CIPS, NoC / DDR4, the MRMAC + `gt_quad_base` per QSFP port with its
per-lane BUFG_GT tree and GT reset wiring, the GT-control GPIO, the QSFP sideband GPIO and I2C,
and the FMC Si5328 I2C are kept; the AXI MCDMA datapath is replaced by `zircon_nic` and two AXI
DMAs per port. `build.tcl` passes `ports` (`{ 0 }` or `{ 0 1 }`, from `config/data.json`
`ports`) and `fec` (`rs` or `none`); the script loops over the ports.

Per port p (port 1 is an exact copy of port 0 on its own resources):

| | port 0 | port 1 |
|---|---|---|
| FMC lanes / GT quad | DP0-3, `gt_quad_base_0` on GTY_QUAD_X1Y1 | DP4-7, `gt_quad_base_1` on GTY_QUAD_X1Y2 |
| GT refclk (322.265625 MHz) | `gt_ref_clk_0` = GBTCLK0 = Si5328 CKOUT1 | `gt_ref_clk_1` = GBTCLK1 = Si5328 CKOUT2 |
| MRMAC | `qsfp_port0/mrmac` on MRMAC_X0Y0 | `qsfp_port1/mrmac` on MRMAC_X0Y2 |
| other cells | `qsfp_port0/{axi_gpio_gt0, rx_packer, tx_dwidth, tx_axis_adapter}`, `zircon_nic_0`, `axi_dma_raw`, `axi_dma_sock`, `axi_gpio_qsfp0`, `axi_iic_qsfp0`, `rst_mac_rx`, `rst_mac_tx` | the same with index 1, and a `_1` suffix on the DMAs and MAC-side resets |

Shared: `clk_wizard_0` (100 / 300 / 250 MHz), `axis_clk_wiz` (390.625 MHz), `ptp_systimer_0`,
`axi_iic_clk` (Si5328), `axi_noc_0`, `axi_smc`.

```
MRMAC rx 6 × 64 b lanes ─ rx_packer (48 → 64 B, no back-pressure, RX timestamp) ─ zircon_nic.s_axis_mac_rx
rx_packer.stat[1:0] ─ zircon_nic.mac_rx_pack_stat (STATUS b4 / b5)
zircon_nic.m_axis_mac_tx ─ tx_dwidth 64 → 48 B ─ tx_axis_adapter ─ MRMAC tx lanes
zircon_nic.m_axis_tx_ptp → tx_axis_adapter/S_AXIS_PTP → mrmac tx_ptp_1588op_in_0 / tx_ptp_tag_field_in_0
mrmac tx_ptp_tstamp_out_0 / _tag_out_0 / _valid_out_0 → zircon_nic tx_ptp_tstamp_in / _tag_in / _valid_in
zircon_nic.m_axis_raw_rx  → axi_dma_raw  S2MM ┐  (SG, 512-bit, 100 MHz, NoC → DDR4)
zircon_nic.s_axis_raw_tx  ← axi_dma_raw  MM2S ┘
zircon_nic.m_axis_sock_rx → axi_dma_sock S2MM ┐
zircon_nic.s_axis_sock_tx ← axi_dma_sock MM2S ┘
zircon_nic.s_axi          ← CIPS M_AXI_LPD via axi_smc (100 MHz)
```

**MRMAC (both ports).** 1x100GE CAUI-4 Wide, independent 384b non-segmented client, no flow
control, no AN/LT, reference clock 322.265625 MHz. With `fec rs`: `MRMAC_MODE_C0 =
MAC+PCS+FEC`, `FEC_SLICE0_CFG_C0 = 100G (IEEE 802.3) - RS(528 514)`. 1588:
`MAC_PORT0_ENABLE_TIME_STAMPING_C0 = 1`, `PORT0_1588v2_Operation_MODE_C0 = 2-step`,
`TIMESTAMP_CLK_PERIOD_NS = 4.0`. Run-time settings are software's (§8):
`FEC_CONFIGURATION_REG1` (0x0D0) is written while the port is held in reset (0x1008, the IP's
power-up value with `FOUR_LANE_PMD`; the E810 also links with 0x8), `CONFIGURATION_TX_REG1`
(0x00C) = 0xC03 and `CONFIGURATION_RX_REG1` (0x010) = 0x33 (enables, FCS insertion / deletion), maximum RX frame 9600 bytes,
`CONFIGURATION_1588_REG` left at its reset value (2-step).

**Latency wiring.** One `ptp_systimer_0` (ts_clk, `rst_ts`; default parameters: INCR 1024,
SYNC_MODE 1 = an `st_sync` pulse every 250000 cycles = 1 ms, OVERWRITE 1) drives
`ctl_{tx,rx}_ptp_{systemtimer, st_sync, st_overwrite, st_adjust, st_adjust_type,
st_adjust_vld}_0` of both MRMACs through the `qsfp_port<p>` hierarchy pins; its `sync_req` is
port 0's `axi_gpio_gt0` CH1 bit 3. Per port: `mrmac/rx_ptp_tstamp_out_0` → `rx_packer`
`rx_ptp_tstamp`; the TX request and return as in the sketch above; `tx_axis_adapter/ptp_underrun`
→ `axi_gpio_gt<p>` CH2 bit 2. 1-step and FlexE PTP inputs are tied 0. The MRMAC 1588 registers
software may read are tabulated in `docs/source/design.md`.

**GPIO.** `axi_gpio_qsfp<p>` CH1 (outputs, reset value 0x2): b0 ModSelL, b1 ResetL (high =
module out of reset), b2 LPMode; CH2 (inputs): b0 ModPrsL, b1 IntL. `axi_gpio_gt<p>` CH1 (5
outputs): b0 gt_reset_all, b1 gt_reset_tx_datapath, b2 gt_reset_rx_datapath (each to all four
lanes), b3 `ptp_systimer_0/sync_req` (port 0 only), b4 spare; CH2 (3 inputs): b0
gt_tx_reset_done, b1 gt_rx_reset_done (lane 0), b2 `ptp_underrun`. LEDs: `grn_led_qsfp<p>` =
that MRMAC's `stat_rx_status_0`, `red_led_qsfp<p>` its inverse. The GT quads' APB3 ports are
not software accessible.

**AXI DMAs (four).** Scatter-gather, no status/control stream, MM2S and S2MM, 512-bit
memory-map and stream, 64-bit addresses, 26-bit buffer length, DRE on both channels, max burst
64 beats (4 KB), all at 100 MHz (51.2 Gb/s per direction per DMA). SG / MM2S / S2MM of each DMA
take one NoC slave port each (S06..S08 `axi_dma_raw`, S09..S11 `axi_dma_sock`, S12..S14
`axi_dma_raw_1`, S15..S17 `axi_dma_sock_1`, all on `aclk6`) routed to MC_0 / MC_1 / MC_2 of the
single DDR4 controller, 500 MB/s read + 500 MB/s write requested per connection. The DMA
masters see DDR at 0x0_0000_0000 (2 GB) and 0x8_0000_0000 (6 GB).

**Address map (CIPS `M_AXI_LPD`).** Port p's block is at `0x8000_0000 + p × 0x10_0000`:

| offset | size | cell |
|---|---|---|
| +0x0_0000 | 64 KB | `qsfp_port<p>/mrmac` |
| +0x2_0000 | 64 KB | `axi_gpio_qsfp<p>` |
| +0x5_0000 | 64 KB | `axi_iic_qsfp<p>` |
| +0x7_0000 | 64 KB | `qsfp_port<p>/axi_gpio_gt<p>` |
| +0x8_0000 | 64 KB | `axi_dma_raw` / `axi_dma_raw_1` |
| +0x9_0000 | 64 KB | `axi_dma_sock` / `axi_dma_sock_1` |
| +0xA_0000 | 4 KB | `zircon_nic_<p>` |

plus `axi_iic_clk` (Si5328, shared) at 0x8004_0000; port 1's +0x4_0000 slot is empty. So port 0
is 0x8000_0000 … 0x800A_0000 and port 1 is 0x8010_0000 … 0x801A_0000. Port 0's MRMAC, GPIO and
IIC offsets are those of 2x-qsfp28-fmc's port 0.

**Interrupts.** All level, active high, to the CIPS PL-to-PS IRQs (GIC SPI 84 + n):

| pin | source | pin | source |
|---|---|---|---|
| pl_ps_irq0 | `axi_dma_raw` MM2S | pl_ps_irq6 | `axi_dma_raw_1` MM2S |
| pl_ps_irq1 | `axi_dma_raw` S2MM | pl_ps_irq7 | `axi_dma_raw_1` S2MM |
| pl_ps_irq2 | `axi_dma_sock` MM2S | pl_ps_irq8 | `axi_dma_sock_1` MM2S |
| pl_ps_irq3 | `axi_dma_sock` S2MM | pl_ps_irq9 | `axi_dma_sock_1` S2MM |
| pl_ps_irq4 | `axi_iic_qsfp0` | pl_ps_irq10 | `axi_iic_qsfp1` |
| pl_ps_irq5 | `axi_iic_clk` | | |

The MRMACs and `zircon_nic` have no interrupt outputs. The bare-metal application is fully
polled and uses none of them.

## 6b. Block design, kcu116 (`Vivado/src/bd/bd_microblaze.tcl`, bd name `zircon`)

A pure-FPGA MicroBlaze system. Its skeleton follows the bare-metal MicroBlaze block design of
ethernet-fmc-taxi-eth (`bd_mb-us.tcl`) and the KCU116 board-automation names of the
2x-qsfp28-fmc design (`bd_mb.tcl`); the MRMAC, packer and adapters of §6 are replaced by one
module reference, `zircon_cmac_0` (§6c). `build.tcl` passes `ports { 0 }` and `fec rs`; any other
port list is an error. No interrupt controller and no interrupt nets: the application is fully
polled.

```
zircon_cmac_0 m_axis_mac_rx (512 b, rx_clk, tuser 49 b) ─ zircon_nic_0.s_axis_mac_rx
zircon_nic_0.m_axis_mac_tx  (512 b, tx_clk)             ─ zircon_cmac_0.s_axis_mac_tx
zircon_nic_0.m_axis_tx_ptp                              → zircon_cmac_0.s_axis_tx_ptp
zircon_cmac_0 tx_ptp_tstamp_out / _tag_out / _valid_out → zircon_nic_0 tx_ptp_tstamp_in / _tag_in / _valid_in
const_pack_stat (2'b00)                                 → zircon_nic_0.mac_rx_pack_stat
zircon_nic_0.m_axis_raw_rx  → axi_dma_raw  S2MM ┐  (SG, 512-bit, 100 MHz, axi_smc → DDR4)
zircon_nic_0.s_axis_raw_tx  ← axi_dma_raw  MM2S ┘
zircon_nic_0.m_axis_sock_rx → axi_dma_sock S2MM ┐
zircon_nic_0.s_axis_sock_tx ← axi_dma_sock MM2S ┘
zircon_cmac_0.link_up → grn_led_qsfp0, and through an inverter → red_led_qsfp0
```

| cell | configuration |
|---|---|
| `ddr4_0` | MIG, board automation: `default_sysclk1_300` → `C0_SYS_CLK`, `ddr4_sdram_075` → `C0_DDR4` (32-bit, 1 GB, `c0_ddr4_ui_clk` 333.25 MHz), `ADDN_UI_CLKOUT1_FREQ_HZ` 100 (= `sys_clk`), board `reset` (CPU_RESET, active high) → `sys_rst` |
| `microblaze_0` | automation `axi_intc {0}`, `cache {32KB}`, `debug_module {Debug Only}` (`mdm_1`), `local_mem {128KB}`, then both LMB controllers grown to **256 KB** with `assign_bd_address -range 256K`. No MMU, no FPU; barrel shifter, divider, `C_USE_HW_MUL` 2, the exceptions the standalone BSP expects, `C_PVR` 2. 32 KB I- and D-cache; the D-cache is write-through (so `C_DCACHE_VICTIMS` is ignored by the IP: a warning only). Cached DDR through `axi_smc` |
| `axi_smc` | DDR SmartConnect: `NUM_SI` 8 (S00 MicroBlaze DC, S01 IC, S02..S04 `axi_dma_raw` SG / MM2S / S2MM, S05..S07 `axi_dma_sock` SG / MM2S / S2MM), `NUM_MI` 1 → `ddr4_0/C0_DDR4_S_AXI`, `NUM_CLKS` 2 (`aclk` = `c0_ddr4_ui_clk`, `aclk1` = `sys_clk`) |
| `microblaze_0_axi_periph` | peripheral SmartConnect on `M_AXI_DP`: `NUM_MI` 10, `NUM_CLKS` 2 (`aclk` 100 MHz, `aclk1` 125 MHz for the shim). M00 `zircon_cmac_0`, M01 `axi_dma_raw`, M02 `axi_dma_sock`, M03 `zircon_nic_0`, M04 `axi_gpio_qsfp0`, M05 `axi_iic_qsfp0`, M06 `axi_iic_clk`, M07 `axi_uartlite_0`, M08 `axi_timer_0`, M09 `axi_timer_1` |
| `clk_wiz_0` | MMCM 300 / 250 / 125 MHz from `sys_clk` (§2.2) |
| `rst_core_300M`, `rst_ts_250M`, `rst_ctrl_125M` | `proc_sys_reset` per MMCM clock (§2.2) |
| `zircon_cmac_0` | module reference `zircon_cmac_us` (§6c), `FAMILY kintexuplus`, `CFG_LOW_LATENCY 0`, polarities 0 |
| `zircon_nic_0` | module reference `zircon_nic` (§3), default parameters (`DATA_W` 512, `GEN_EN` 1, `CORE_HZ` 300000000) |
| `axi_dma_raw`, `axi_dma_sock` | as on the vck190 (SG, no status/control stream, 512-bit MM and stream, DRE, 64-beat bursts, 26-bit length) but `c_addr_width` 32. The 512-bit MM width is required: the stream width cannot exceed it |
| `axi_gpio_qsfp0` | CH1 3 outputs, reset 0x2 (b0 ModSelL, b1 ResetL, b2 LPMode); CH2 2 inputs (b0 ModPrsL, b1 IntL) |
| `axi_iic_qsfp0`, `axi_iic_clk` | QSFP0 module management; FMC Si5328 (I2C 0x68) |
| `axi_uartlite_0` | console, board interface `rs232_uart`, 115200 8N1 (fixed in the IP: nothing to program) |
| `axi_timer_0` | xiltimer's sleep timer (`usleep()` / `sleep()`); selected by name in `pre_platform_build.py` |
| `axi_timer_1` | the application's free-running 64-bit timebase (cascade mode, set up by software, §8.2) |
| QSFP1 constants | `modsell_qsfp1` = 1, `resetl_qsfp1` = 0, `lpmode_qsfp1` = 1, `grn/red_led_qsfp1` = 0: the QSFP1 module is held in reset and low power |

There is no `axi_quad_spi`: the FPGA configures itself from the QSPI flash and Vivado programs
the flash (§7.1). There is no VADJ control: the KCU116 fixes VADJ at 1.8 V, and all FMC I/O is
LVCMOS18.

**Address map (MicroBlaze `Data` / `Instruction`, 32-bit).** Every segment is pinned with
`assign_bd_address -offset -range -force`: `zircon_cmac_0` and `zircon_nic_0` are module
references and get no `XPAR_` macros, so `hw_config.h` has them as fixed fallback addresses.

| base | size | cell |
|---|---|---|
| 0x0000_0000 | 256 KB | LMB (`ilmb` / `dlmb` BRAM controllers) |
| 0x4000_0000 | 64 KB | `axi_uartlite_0` |
| 0x41C0_0000 | 64 KB | `axi_timer_0` |
| 0x41C1_0000 | 64 KB | `axi_timer_1` |
| 0x4400_0000 | 512 KB | `zircon_cmac_0` (registers +0x0_0000, GT APB +0x4_0000; §6c) |
| 0x4408_0000 | 64 KB | `axi_dma_raw` |
| 0x4409_0000 | 64 KB | `axi_dma_sock` |
| 0x440A_0000 | 4 KB | `zircon_nic_0` |
| 0x440B_0000 | 64 KB | `axi_gpio_qsfp0` |
| 0x440C_0000 | 64 KB | `axi_iic_qsfp0` |
| 0x4410_0000 | 64 KB | `axi_iic_clk` (Si5328) |
| 0x8000_0000 | 1 GB | `ddr4_0` `C0_DDR4_ADDRESS_BLOCK`, also mapped in the SG / MM2S / S2MM spaces of both DMAs |

The +0x8 / +0x9 / +0xA offsets inside the 0x4400_0000 block match port 0's layout on the vck190;
the vck190's +0x0 MRMAC slot holds the CMAC shim.

**Synthesis.** The block design stays in the default out-of-context (hierarchical) mode. The
`zircon_cmac_0` module-reference OOC run synthesises `cmac_usplus` inline (Taxi's IP script sets
`generate_synth_checkpoint false`) and treats the four GT wizards as black boxes, filled from
their own OOC checkpoints at link. The CMAC IP's LOC xdc, which Taxi's script disables, is still
parsed in that OOC run; it names the same CMACE4_X0Y0, so it is harmless. `create_clock
gt_ref_clk_0` in `kcu116.xdc` raises no duplicate-clock warning (the wizards' refclk clocks
exist only out of context).

**Constraints (`Vivado/src/constraints/kcu116.xdc`).**

- Pins from 2x-qsfp28-fmc's proven `kcu116.xdc`, all LVCMOS18: Si5328 I2C Y17 / AA17; QSFP0 I2C
  AB17 / AC17; refclk `gt_ref_clk_0_clk_p` K7 (GBTCLK0, bank 227); GTY lanes (TX p / RX p) F7 / D2,
  E5 / C4, D7 / B2, B7 / A4; QSFP0 ModSelL AA20, ResetL AB20, ModPrsL AC22, IntL AC23, LPMode Y18,
  LEDs AD16 / AE16; QSFP1 ModSelL AB24, ResetL AC24, LPMode AA18, LEDs AE17 / AF17. GT lanes are
  in order with no polarity inversion (CAUI-4 lane reordering is the CMAC's job). The
  XCKU5P-FFVB676-2-E's GTYs run 25.78125 Gb/s here, although the board catalog lists "16.5 Gb/s
  max" for the device (the catalog entry is wrong; Taxi's RK_XCKU5P_F example and the KCU116's
  own SFP28 cages also run 25.78 Gb/s).
- `create_clock -period 3.103 -name gt_ref_clk_0` on the refclk port (the `IBUFDS_GTE4` is in
  the shim RTL; no IP creates this clock).
- `LOC CMACE4_X0Y0` on the CMACE4 cell: Taxi's IP script disables the `cmac_usplus` LOC xdc; the
  GT channels follow the package pins.
- `USER_CLOCK_ROOT X3Y3` (the CMACE4_X0Y0 clock region) on the output nets of Taxi's four
  `bufg_gt_rxusrclk_inst` buffers. The CMAC checks the skew between its four RX_SERDES_CLK inputs
  (max 1.0 ns); lane 0's RX clock is also the whole `rx_clk` fabric domain, its root landed in
  X2Y2 and the check failed (1.342 ns). A `CLOCK_DELAY_GROUP` is ignored by the placer here
  ([Place 30-898]: the four buffers have no common driver).
- False paths to / from the QSFP sideband, LED and I2C ports.
- **No `set_clock_groups -asynchronous`**: it would override the `set_max_delay -datapath_only`
  and `set_bus_skew` constraints that Taxi's CDC scripts and `zircon_cmac_us.tcl` put on every
  crossing.
- Bitstream: `COMPRESS TRUE`, `CONFIGRATE 31.9`, `SPI_BUSWIDTH 4`, `SPI_FALL_EDGE YES`,
  `SPI_32BIT_ADDR YES`. The 2x-qsfp28-fmc value `CONFIGRATE 33` is not a legal UltraScale+ rate
  (CRITICAL WARNING [Netlist 29-154]); 31.9 is the nearest legal rate below it.
- `Vivado/src/constraints/zircon_cmac_us.tcl` (MIT, implementation only, cells found by
  `ORIG_REF_NAME == ts_gray_sync`): `ASYNC_REG` on the two synchroniser stages, `set_max_delay
  -datapath_only 4.0` and `set_bus_skew 3.0` from each instance's Gray register to its first
  synchroniser stage (five instances, §6c).

**Implementation (build of 2026-09-25 16:56, the validated bitstream).** All constraints met:
WNS +0.050 ns (core 300 MHz), WHS +0.011 ns, pulse width and max skew clean, bus skew ≥ +2.0 ns.
The MicroBlaze implementation settings in `build.tcl` (strategy
`Performance_ExplorePostRoutePhysOpt`, post-route `phys_opt_design` directive
`ExploreWithAggressiveHoldFix` for the MIG 333 MHz ↔ 100 MHz SmartConnect hold paths) were
enough: no pblock and no lower core clock was needed. Utilisation of the XCKU5P: 91.0 k LUT
(41.9 %), 113.4 k FF (26.1 %), 276 BRAM36 (57.5 %), 11 DSP, 1 CMACE4, 4 GTYE4, 2 MMCM. Known
benign CRITICAL WARNINGs: `[Designutils 20-1280]` ×2 for the xdc of the unused `_ll_` GT wizard
IPs (created by Taxi's script, not instantiated with `CFG_LOW_LATENCY 0`); the evaluation-license
warning `[12-1790]` is the usual false positive.

## 6c. `zircon_cmac_us` — UltraScale+ CMAC shim (kcu116)

Opsero MIT module reference that turns Taxi's `taxi_eth_mac_100g_us` into the MAC-side interface
`zircon_nic` expects on the vck190: 512-bit Taxi-convention AXI-Streams, the RX timestamp on
`tuser[48:1]`, a TX timestamp request / return path with tags, and an AXI-Lite register block.

- `Vivado/src/hdl/zircon_cmac_us.v`: flat-port Verilog shell with the `X_INTERFACE_*`
  attributes (a module reference needs a `.v` top), the same style as `zircon_nic.v`.
- `Vivado/src/hdl/zircon_cmac_us_core.sv`: the implementation. Instantiates
  `taxi_eth_mac_100g_us`, `taxi_axil_apb_adapter`, `taxi_sync_reset`, `taxi_sync_signal`,
  `zircon_cdc_snapshot` and the `taxi_axis_if` / `taxi_axil_if` / `taxi_apb_if` interfaces.
- `Vivado/src/hdl/ts_gray_sync.sv` (MIT): Gray-code crossing of a free-running binary counter.

Parameters (shell): `FAMILY` "kintexuplus", `CFG_LOW_LATENCY` 0 (Taxi's RK_XCKU5P_F example
builds with 1; either works), `GT_TX_POLARITY` / `GT_RX_POLARITY` 4'b0000, `C_S_AXI_ADDR_WIDTH`
19 (elaboration check), `TS_INCR` 1024 (a power of two), `SIM` 0. Core-only: `CTRL_HZ` 125000000
(the clock-measurement window).

```
gt_ref_clk_clk_p/_n                    in   diff_clock gt_ref_clk (FREQ_HZ 322265625), IBUFDS_GTE4 inside
gt_gtx_p/n[3:0], gt_grx_p/n[3:0]       out/in  gt interface "gt"
ctrl_clk, ctrl_aresetn                 in   125 MHz; ASSOCIATED_BUSIF s_axi
ts_clk, ts_aresetn                     in   250 MHz timestamp timebase
tx_clk, rx_clk                         out  322.265625 MHz (Taxi tx_clk / rx_clk)
mac_tx_aresetn, mac_rx_aresetn         out  active low, released synchronously (4-stage taxi_sync_reset) in tx_clk / rx_clk
m_axis_mac_rx_{tdata[511:0], tkeep[63:0], tvalid, tlast, tuser[48:0]}, m_axis_mac_rx_tready (ignored)
s_axis_mac_tx_{tdata[511:0], tkeep[63:0], tvalid, tready, tlast, tuser[0:0]}
s_axis_tx_ptp_{tdata[23:0], tvalid, tready}     [1:0] op, [17:2] tag
tx_ptp_tstamp_out[54:0], tx_ptp_tstamp_tag_out[15:0], tx_ptp_tstamp_valid_out   (tx_clk)
link_up                                out  CMAC rx_status (rx_clk, unregistered; LED only)
s_axi_*                                     AXI4-Lite, 32-bit data, 19-bit address (ctrl_clk)
```

**Taxi wrapper as used.** `taxi_eth_mac_100g_us` with 4 GTY lanes, `PTP_TS_EN` 0, `PTP_TD_EN` 0,
`STAT_EN` 0 (its unused `m_axis_stat` and `m_axis_tx_cpl` are terminated in the shim),
`xcvr_ctrl_clk` = `ctrl_clk`, `xcvr_ctrl_rst` = `CTRL.XCVR_RST` or `ctrl_aresetn` low, both QPLL
refclk inputs from the one `IBUFDS_GTE4`, `rx_rst_in` / `tx_rst_in` = CTRL.RX_RST / TX_RST,
`cfg_tx_enable` / `cfg_rx_enable` = CTRL.TX_EN / RX_EN (synchronised into `tx_clk` / `rx_clk`).
What the wrapper does at `cc70b27`, and therefore this target:

- **RS-FEC is hard-wired on** (`ctl_tx/rx_rsfec_enable`, correction and indication), with no
  run-time change and no FEC counters (`stat_rx_rsfec_*` are left open).
- **No PTP.** `tx_ptp_ts_out`, `rx_ptp_ts_out`, `*_ptp_locked` and `m_axis_tx_cpl` are declared but
  never driven, the CMAC `tx/rx_ptp_tstamp_*` outputs are open and `ctl_*_systemtimerin` is tied
  0. With `PTP_TS_EN` = 1 `m_axis_rx.tuser` would be 97 bits wide but driven by a 1-bit tuser.
- `cfg_tx/rx_max_pkt_len` exist but are not connected to the CMAC: the maximum frame length is
  the IP's static default (≥ 9046 verified on the bench with 9000-byte payloads, believed 9600; §1.1, §12.8.1).
- `m_axis_rx` comes straight from the CMAC (no back-pressure; `tuser[0]` = error on the last
  beat); `s_axis_tx` goes through `taxi_axis_pad` (`UNDERFLOW_DROP_EN`) into the CMAC.
- A built-in watchdog resets the CMAC RX when `rx_status` has been low for 2²⁸ `rx_clk` cycles
  (~0.83 s).
- The IPs are created by Taxi's own scripts (§7.1): CMAC `taxi_eth_mac_100g_us_cmac` (CAUI-4,
  AXIS, `INCLUDE_RS_FEC 1`, `ENABLE_TIME_STAMPING 1`, `GT_LOCATION 0`, IP LOC xdc disabled) and
  the GT wizards `taxi_eth_mac_100g_us_gty_{full,ch,ll_full,ll_ch}` (`DISABLE_LOC_XDC 1`).

**RX (rx_clk).** One register stage after the CMAC. `tuser[0]` = CMAC error (last beat);
`tuser[48:1]` = ts55[54:7] sampled at the frame's first CMAC beat, on every beat (the
`mrmac_rx_packer` contract, so `rx_dispatch`, ZRXT and `echo_rec_t` are unchanged). No
back-pressure: `m_axis_mac_rx_tready` is ignored (zircon_nic's MAC-side FIFO never deasserts it).

**TX (tx_clk).** `s_axis_mac_tx` goes straight into the wrapper. `s_axis_tx_ptp` records wait in
a 16-entry LUTRAM FIFO with fall-through (a record may arrive in the same cycle as its frame's
first beat); `tready` = not full. At the handshake of each frame's first beat (`tvalid & tready
& sof`) the head record is popped; for op 2'b10 `{ts55, tag}` is returned on `tx_ptp_tstamp_*`
one cycle later (pipelined, deterministic); op 0 returns nothing. No record at SOF: the frame goes
out untagged and STICKY.PTP_UNDERRUN is set. The shim never gates `tvalid` on a record (the CMAC
must not see a mid-frame underflow). A TX reset clears the record FIFO.

**Timebase.** A 45-bit tick counter on `ts_clk` (reset by `ts_aresetn`); ts55 = `{tick, 10'b0}`
(`TS_INCR` 1024 = 2⁻⁸ ns units, 4 ns per tick: the same format as the vck190's `ptp_systimer`,
which is not instantiated on this target). Three `ts_gray_sync` instances (W = 45) carry the tick
count into `tx_clk`, `rx_clk` and `ctrl_clk`: the source registers `gray = bin ^ (bin >> 1)`; the
destination has two `ASYNC_REG` stages, then Gray → binary over three pipelined stages (top,
middle, bottom thirds) and an output register. Latency: 1 source cycle + 5 destination cycles
(+ up to one of sampling phase), identical in the `tx_clk` and `rx_clk` instances, so the fixed
part cancels in TX − RX. Two more instances (W = 20) carry the `tx_clk` / `rx_clk` measurement
counters into `ctrl_clk` (five in total, all covered by `zircon_cmac_us.tcl`).

**Register map** (AXI4-Lite, 32-bit, `ctrl_clk`, byte offsets from the shim base, 0x4400_0000 on
the kcu116). Bit 18 of the address selects the GT APB space; below it, offsets 0x000..0x0FF are
decoded and the rest of 0x0_0000..0x3_FFFF reads 0 and ignores writes. CTRL and STICKY are
written with byte lane 0.

| offset | name | R/W | meaning |
|---|---|---|---|
| 0x000 | ID | R | `0x434D4143` ("CMAC") |
| 0x004 | VERSION | R | `0x00010000` (1.0.0) |
| 0x008 | CTRL | RW | b0 XCVR_RST (Taxi `xcvr_ctrl_rst`: GT + CMAC held in reset), b1 RX_RST, b2 TX_RST (levels to Taxi `rx_rst_in` / `tx_rst_in`), b4 TX_EN (`cfg_tx_enable`), b5 RX_EN (`cfg_rx_enable`). **Reset value 0x31** = XCVR_RST \| TX_EN \| RX_EN: the transceivers stay in reset until software releases them after programming the Si5328 |
| 0x00C | STATUS | R | synchronised into `ctrl_clk`: b0 RX_STATUS (CMAC RX aligned, = `link_up`), b1 RX_BLOCK_LOCK, b2 RX_HIGH_BER, b3 TX_RST_OUT, b4 RX_RST_OUT (Taxi's reset outputs), b5 GTPOWERGOOD, b6 TX_CLK_ALIVE, b7 RX_CLK_ALIVE (TX_CLK_KHZ / RX_CLK_KHZ non-zero) |
| 0x010 | STICKY | R/W1C | b0 LINK_LOST (RX_STATUS fell), b1 PTP_UNDERRUN (a TX frame started with no PTP record), b2 TS_RECORD_OVF (a PTP record was offered while the 16-entry record FIFO was full; zircon_nic then waits, so it means records without frames) |
| 0x020 | TS_NOW_LO | R | ts55[31:0] as seen in `ctrl_clk`; **a read latches TS_NOW_HI** |
| 0x024 | TS_NOW_HI | R | ts55[54:32] in bits 22:0, latched by the last TS_NOW_LO read |
| 0x028 | TS_INCR | R | `TS_INCR` (1024: 2⁻⁸ ns units per 250 MHz `ts_clk` cycle) |
| 0x030 | RX_GOOD_PKTS | R | CMAC `stat_rx_pkt_good` events |
| 0x034 | RX_BAD_FCS | R | CMAC `stat_rx_err_bad_fcs` events |
| 0x038 | RX_ERR_FRAMES | R | frames delivered with `tuser[0]` = 1 |
| 0x03C | TX_GOOD_PKTS | R | CMAC `stat_tx_pkt_good` events |
| 0x040 | TX_FRAMES | R | frame starts accepted at the shim |
| 0x044 | TX_TS_RET | R | TX timestamps returned (op 2'b10 frames) |
| 0x048 | TX_CLK_KHZ | R | `tx_clk` counted over a 1 ms window of `ctrl_clk` (322265 expected) |
| 0x04C | RX_CLK_KHZ | R | the same for `rx_clk` |
| 0x4_0000..0x7_FFFF | GT_APB | RW | Taxi's transceiver-control APB (§ below) |

Counters 0x030..0x044 are 32 bits, count in their event domain (`rx_clk` / `tx_clk`), cross to
`ctrl_clk` as coherent snapshots (`zircon_cdc_snapshot`) and are **never reset**: they only wrap,
so software deltas stay valid across link and GT resets. The register block itself is reset by
`ctrl_aresetn` (CTRL back to 0x31, STICKY 0).

**GT APB window (0x4_0000..0x7_FFFF).** `taxi_axil_apb_adapter` converts each AXI-Lite access
into 16-bit APB transfers on Taxi's `s_apb_ctrl` (18-bit APB address = AXI address [17:0]); the
wrapper's `taxi_apb_interconnect_1s` gives lane *n* a 16-bit register space at
0x4_0000 + *n* × 0x1_0000. Per-lane registers (byte offsets within the lane): 0x1000 TX reset /
PMA / PCS (done bits 9..11), 0x1010 TX polarity / electrical idle / inhibit, 0x1012..0x1018 TX
driver, 0x2000 RX resets (done bits 9..11), 0x2004 loopback, 0x2010 RX polarity, 0x2024 LPM;
QPLL0 / QPLL1 in lane 0 only, at 0x0BB8 / 0x0C1C (Taxi's decimal `14'd3000` / `14'd3100`). The
adapter splits a 32-bit access into two 16-bit transfers starting at segment `addr[1]` (a 16-bit
access at +2 is one transfer, one at +0 two, the second with `pstrb` = 0). The Taxi GT registers
ignore `pstrb`, so the shim's APB filter completes any write segment with `pstrb` = 0 itself
without forwarding it: **a 16-bit write touches only its register**, a 32-bit write writes both
halves, reads read what the adapter asks. While CTRL.XCVR_RST is set, and for 32 `ctrl_clk`
cycles after it clears, the wrapper's APB interconnect is held in reset and would never answer,
so the filter completes every GT_APB transfer with **SLVERR** (read data 0) instead of hanging
the AXI bus. The application does not use the GT APB space.

## 7. Repository layout

```
config/data.json, config/update.py      manifest (two targets) and the README / docs table updater
build.py, build.sh, build.bat           cross-platform build runner (no Makefiles, no Linux flow)
Vivado/scripts/{build.tcl, xsa.tcl, zircon_sources.tcl}
Vivado/scripts/cmac_sources.tcl         kcu116: Taxi 100G CMAC sources (.f expander), shim, CDC scripts (§7.1)
Vivado/scripts/cfgmem.tcl               kcu116: QSPI .mcs / .prm from zircon_boot.bit (§7.1)
Vivado/src/bd/bd_versal.tcl             vck190 block design (§6)
Vivado/src/bd/bd_microblaze.tcl         kcu116 block design (§6b)
Vivado/src/constraints/                 vck190_fmcp1.xdc, kcu116.xdc, zircon_cmac_us.tcl (shim CDC)
Vivado/src/hdl/                         zircon_nic.v (shell), zircon_nic_core.sv, zircon_nic_pkg.sv,
                                        zircon_regs.sv, zircon_cdc_snapshot.sv, hdr_trunc.sv,
                                        rx_meta_capture.sv, rx_dispatch.sv, tx_len_guard.sv,
                                        raw_tx_desc_strip.sv, tx_meta_builder.sv, tx_mac_out.sv,
                                        udp_gen.sv, udp_chk.sv, rate_meter.sv, ptp_tx_tagger.sv,
                                        latency_stats.sv, mrmac_rx_packer.v, mrmac_axis_adapter.v
                                        (mrmac_tx_axis_adapter), ptp_systimer.v (vck190);
                                        zircon_cmac_us.v, zircon_cmac_us_core.sv, ts_gray_sync.sv (kcu116)
Vivado/src/hdl/tb/                      run_xsim.sh, gen_vectors.py, tb_zircon_nic.sv,
                                        tb_mrmac_rx_packer.sv, tb_ptp_units.sv, tb_zircon_cmac_us.sv
Vitis/py/{args.json, build-vitis.py, make-boot.py, pre_platform_build.py}
Vitis/common/src/                       the echo_server application (§8)
EmbeddedSw/                             lwipopts.h.in override (software checksums), every target
EmbeddedSw.microblaze/                  lwip220 overlay for MicroBlaze (lwip220.yaml, CMakeLists.txt)
scripts/                                zircon_echo_test.py, zircon_prbs_tool.py, echo_test.py (host side)
docs/                                   Sphinx user guide (docs/source), this spec
submodules/taxi                         Taxi transport library incl. Zircon (CERN-OHL-S-2.0), pinned
```

Target `vck190_fmcp1`: board VCK190, connector FMCP1, family versal, `ports` 2, `fec` rs,
`baremetal` true, `petalinux` false, `yocto` false, `license` true (the no-cost MRMAC license;
Vivado Enterprise for the XCVC1902). Boot file `Vitis/boot/vck190_fmcp1/BOOT.BIN`.

Target `kcu116`: board KCU116, connector HPC, group `fpga` (build family microblaze), `ports` 1,
`fec` rs, `baremetal` true, `petalinux` false, `yocto` false, `license` false (the XCKU5P is in
the free Vivado Standard edition), `ip_license` true (the no-charge CMAC license), `cfgmem` true
with `flashsize` 128 (MB) and `flashintf` SPIx4. Boot files `Vitis/boot/kcu116/zircon_boot.bit`
(bitstream with the application in the LMB BRAM) and `zircon_boot.mcs` / `.prm` (QSPI image).
The bootimage zip carries all three.

### 7.1 Build flow of the kcu116 (MicroBlaze) target

`./build.sh all --target kcu116` runs `xsa → standalone → cfgmem → package`. The data.json group
`fpga` maps to the build family `microblaze` in `build.py`; `config/update.py` writes
`dict set target_dict kcu116 { xilinx.com kcu116 microblaze { 0 } rs }` into the UPDATER block of
`build.tcl`, which then sources `src/bd/bd_microblaze.tcl` and `src/constraints/kcu116.xdc`.

- **Vivado IP from Taxi's own scripts.** Before the block design is sourced, `build.tcl` (only
  when `bd_script` is `microblaze`) sources Taxi's unmodified
  `src/eth/rtl/us/taxi_eth_mac_100g_us_cmace4.tcl` and `taxi_eth_mac_100g_us_gty_322.tcl`, which
  `create_ip` the CMAC and the four GT wizards in the open project, then
  `scripts/cmac_sources.tcl`. There is no `ip` stage for this target.
- **`.f` expander** (`cmac_sources.tcl`, proc `taxi_read_f`). Taxi's file lists
  (`taxi_eth_mac_100g_us.f` → `_gt.f`, `_gt_ll.f`, `../taxi_eth_mac_phy_10g.f`,
  `../taxi_eth_mac_stats.f`, …) reference the rest of the library through the symlink
  `src/eth/lib/taxi -> ../../../`, which does not survive every checkout (Windows, zip downloads).
  The expander never follows it: an entry is resolved relative to its `.f`, and any path that
  contains `/lib/taxi/` is rewritten to the submodule root plus the rest (`../../lib/taxi/src/…`
  → `submodules/taxi/src/…`). It recurses into `.f` entries, skips a list already being expanded
  (`taxi_eth_mac_stats.f` names itself), drops duplicates, and adds every file through
  `add_src_once` (so nothing is added twice with `zircon_sources.tcl`). It then adds
  `taxi_axil_if.sv`, `taxi_axil_apb_adapter.sv`, `taxi_apb_if.sv` and the shim
  (`zircon_cmac_us.v` as Verilog, the rest as SystemVerilog). `build.tcl`'s generic
  `src/hdl/*` glob skips the three shim files, so the vck190 project's file list is unchanged.
- **Constraint processing order LATE.** `cmac_sources.tcl` adds the implementation-only Taxi
  CDC scripts (`taxi_axis_async_fifo.tcl`, `taxi_sync_reset.tcl`, `taxi_sync_signal.tcl`) and
  `zircon_cmac_us.tcl`, and on this target sets `PROCESSING_ORDER LATE` on them and on
  `zircon_sources.tcl`'s scripts. The scripts look up each crossing's clocks with `get_clocks
  -of_objects`; here the CMAC `tx_clk` / `rx_clk` derive from `gt_ref_clk_0`, which
  `kcu116.xdc` creates. With the default order they ran first, found no GT-derived clock, and
  `taxi_axis_async_fifo.tcl` skipped the write-clock → LUTRAM output-register false path; the
  router then detoured those paths for hold (core clock WNS −13.1 ns, `ctrl_clk` −8.9 ns in the
  first build). The vck190 flow is unaffected (its clocks all come from IP xdc).
- **Implementation settings** (`build.tcl`, MicroBlaze branch): `write_bitstream` instead of
  Versal's `write_device_image`; strategy `Performance_ExplorePostRoutePhysOpt`; post-route
  `phys_opt_design` directive `ExploreWithAggressiveHoldFix`.
- **Vitis** (`Vitis/py/args.json`): `linker_script_mods {"microblaze": "code_local_bss_ddr"}`,
  `compile_optimization {"microblaze": "-O2"}`, `gc_sections {"microblaze": true}`,
  `stack_size` 0x8000 / `heap_size` 0x10000 on MicroBlaze, `pre_platform_build_script`
  `py/pre_platform_build.py` (xiltimer `XILTIMER_sleep_timer` = `axi_timer_0` on MicroBlaze, no
  tick timer; nothing on Versal), `combine_bit_elf` true (read only for MicroBlaze).
  `build-vitis.py` layers `EmbeddedSw.microblaze/` over `EmbeddedSw/` on MicroBlaze (lwip220
  refuses to build without an AMD MAC otherwise), applies the linker modification after the stack
  and heap sizes, and prints the LMB use of the ELF. The Versal app keeps `-O0`, no gc, and an
  unchanged `lscript.ld`.
- **Boot file.** `make-boot.py` embeds the ELF in the bitstream with `updatemem` (`-proc
  zircon_i/microblaze_0`) → `Vitis/boot/kcu116/zircon_boot.bit`.
- **QSPI image** (`build.py` stage `cfgmem`, `Vivado/scripts/cfgmem.tcl <target> <bit> <out_mcs>
  [flashsize] [flashintf]`): on a MicroBlaze bare-metal target the source is `zircon_boot.bit`
  (so the `.mcs` boots the application too) and `zircon_boot.mcs` / `.prm` are written next to
  it; `write_cfgmem -format mcs -size 128 -interface SPIx4 -loadbit "up 0x0 …" -checksum`. The
  compressed image spans 0x0000_0000..0x00BC_8DEB of the 128 MB flash.
- **Flash part.** The KCU116 configuration flash identifies as a Micron **MT25QU01G** (1 Gb =
  128 MB, JEDEC 20 BB 21); Vivado's `program_hw_cfgmem` part is `mt25qu01g-spi-x1_x2_x4`
  (`mt25qu256` is rejected). The board catalog's "2 × 32 MB QSPI" does not match the fitted
  part. Mode pins M[2:0] = 001 (master SPI) as delivered.

### 7.2 Licensing and tool editions

| target | Vivado edition | IP license |
|---|---|---|
| `vck190_fmcp1` | Enterprise (the XCVC1902 is not in Standard) | Versal MRMAC, no charge; needed for the device image |
| `kcu116` | Standard (free) suffices for the XCKU5P | UltraScale+ 100G CMAC (`cmac_usplus` with RS-FEC), AMD's no-charge license key |

On the build host the kcu116 bitstream generation shows only the usual `[12-1790]`
evaluation-license warning, a known false positive. Zircon, Taxi (including the CMAC wrapper)
and the Opsero glue need no license key; the Taxi sources are CERN-OHL-S-2.0.

## 8. Software behaviour (bare-metal `echo_server`)

One polled main loop, no interrupts; lwIP 2.2.0 (`lwip220`, NO_SYS, raw API) with its timers
paced from a free-running 64-bit timebase (`timebase.h`: the Arm generic timer through
`XTime_GetTime()` on the vck190, `axi_timer_1` on the kcu116, §8.2); console output through a
RAM ring drained without blocking. `NUM_PORTS` follows the XSA (2 when it has `axi_dma_raw_1`;
`-DNUM_PORTS=1` builds port 0 only; always 1 on the kcu116). All settings are in `app_config.h`
and can be overridden with `-D`. The same sources build for both targets; the differences are
behind `HW_MAC_CMAC` (§8.1) and `__MICROBLAZE__` (§8.2).

**Bring-up** (`main.c`, each step depends on the previous; vck190 — the kcu116 sequence is in
§8.2): VADJ = 1.5 V (VCK190 regulator over
the PS I2C) → Si5328 free-run 322.265625 MHz on CKOUT1 and CKOUT2 → per port: `zircon_nic` ID
check, MAC, `ECHO_PORT` 7, `SOCK_LOCAL_PORT` 5000, TTL 64, `CHK_PORT` 5001 (datapath still
disabled; a port whose `zircon_nic` does not answer is skipped); GT reset; MRMAC configuration
(§6) and a check that the 1588 timer advances (two reads of `MONITOR_{TX,RX}_1588_SAMPLE_SYSTIMER`
10 ms apart; if it does not, one `sync_req` pulse and a retry) → lwIP, one netif per port on UI0
→ socket DMA → latency set-up (bins `LAT_BIN_BASE_NS` 0 / `LAT_BIN_WIDTH_NS` 64, both banks
cleared, `LAT_CTRL` = EN | RAW_RX_DESC | RAW_TX_DESC with `LAT_RAW_TS_DESC_DEFAULT` = 1) →
`CTRL` = RX_EN | TX_EN | ECHO_EN | SOCK_EN → TCP echo on port 7 and the latency statistics
service on UDP 5002 → wait up to 5 s for the links → main loop. While a link is down, its
MRMAC reset is re-issued every 2 s (`LINK_RETRY_MS`): the GTY does not re-align on a partner that
appears after its last reset.

**Per port.** MAC `00:0a:35:06:21:a0` + port number. Address mode (`IP_MODE_DEFAULT`, per port
at run time with `i <port> dhcp|static|auto`): `auto` = DHCP, then the static address after 10 s
without a lease (default); `static`; `dhcp` only. Static defaults 192.168.20.2/24 (gw .1) for
port 0 and 192.168.21.2/24 for port 1; the two ports must be on different subnets (lwIP picks
the output port of a software reply by subnet). The IPV4 register follows lwIP's address.
Services: hardware UDP echo (UDP 7), hardware socket demo (UDP 5000: each datagram's payload is
sent back through UI2 after `SOCK_REMOTE_*` are set from its descriptor), software TCP echo
(TCP 7), ping / ARP / DHCP (lwIP), latency statistics (UDP 5002). lwIP options: DHCP, pbuf pool
2048, 64 TX / 64 RX descriptors, `TCP_WND` 32768, `TCP_SND_BUF` 16384, software checksums (the
`EmbeddedSw` lwipopts override: the raw path computes none). The DMA driver uses 64-byte aligned
buffers and copies unaligned TX frames into aligned bounce buffers.

**Latency on the software path.** The netif strips the ZRXT descriptor of every received frame
and keeps its `rx_ts`; the TCP echo arms that `rx_ts` for the reply, and the netif sends the reply
behind a ZTXT descriptor with TS_REQ. The request is disarmed after `netif->input()` returns (lwIP
defers `tcp_output()` of the pcb being processed until the receive callback has returned).
Bank 1 therefore counts exactly one sample per TCP exchange of up to one segment.

**Console** (vck190: PS UART0; kcu116: `axi_uartlite_0`; 115200 8N1): `h`/`?` help, `s` status,
`z` register dump, `c` clear counters (`STAT_CLR`), `f` cycle the FEC mode of both ports
(RS(528,514) → off → RS(544,514); on the kcu116 it only prints `FEC fixed on this target`), `l`
cross-port loopback test, `e` echo-through-loopback test, `L <port>` self-loopback test (QSFP28
loopback plug), `p <bytes>` test payload (8..9000, default 1472), `i [<port> <mode>]` address
mode, `T [<port>] [c]` latency report / clear. A status line per port (`P0`, `P1`) is printed on
change (at most once a second) and every 30 s; once the hardware echo has been measured it ends
with ` | hw lat n … min … mean … p99 … max … ns`.

**Loopback tests** (`loopback.c`). `l`: each port's generator → cable → the other port's checker
(GEN_DST_MAC/IP = the other port's, GEN_DST_PORT = GEN_SRC_PORT = 5001), both directions at
once. `e`: port 0's generator → port 1's hardware echo (GEN_DST_PORT 7, GEN_SRC_PORT 5001) →
port 0's checker. `L <p>`: the port's generator → loopback plug → its own checker. Once a second
a table per port (link / FEC, generated and checked packets, sequence / bit / length errors,
line-rate and payload-rate Gb/s from the rate meters). Verdict after a 2 s warm-up:
`LOOPBACK: PASS` once every direction has been ≥ 90 Gb/s line rate (`LOOPBACK_PASS_CGBPS` 9000)
with zero errors for 10 s (`LOOPBACK_VERDICT_S`); `LOOPBACK: FAIL errors`, `FAIL link down` or
`FAIL rate: …` if the condition persists for 10 s (payloads below 726 bytes therefore end in
`FAIL rate`: they are throughput measurements). The echo test prints `LOOPBACK-ECHO:` instead.
Auto-start (`LOOPBACK_AUTOSTART` 0): `l` starts by itself when every port has had link for 15 s
without a DHCP lease (static ports never ask for one; a port in `dhcp`-only mode prevents it),
and stops again if the checkers see nothing within 3 s.

**Latency report.** `T` prints per port and bank: count, min, mean, max, standard deviation,
p50 / p90 / p99 / p99.9 (upper edge of the histogram bin holding them, capped at max), the
non-empty bins and LAT_STATUS / STALE / LOST / OVF / PTP_UNDERRUN. UDP 5002 (`latency_wire.h`,
mirrored in `zircon_echo_test.py`): `STAT?` [`<p>`] → one datagram, a 288-byte header (magic
"ZLAT" 0x5A4C4154, version 1, port, flags, bin geometry and lower edges, VERSION, LAT_STATUS,
uptime) + two 552-byte banks (count, sum, sumsq, min, max, implausible, last, 64 bins); `CLR`
[`<p>`] → `CLR OK`; anything else → `ERR`.

**UART strings the bench keys on:** `Port <n>: link up, 100 Gb/s, FEC RS(528,514)`,
`Port <n>: IP <a.b.c.d> … (DHCP|static)`, `LOOPBACK: PASS` / `LOOPBACK: FAIL …`,
`LOOPBACK-ECHO: PASS`, `zircon_nic <x.y.z> at <addr> (port <n>)`. They are identical on both
targets.

### 8.1 MAC abstraction (`mac.h`)

`port.c`, `main.c`, `latency.c` and `loopback.c` reach the MAC only through `mac.h`. Every call
takes the port's `const hw_port_t *` (`hw_config.h`; its MAC base is `.mac`, and `.gpio_gt`
exists only on Versal), so a backend uses whichever resources it needs:

| call | vck190: `mrmac.c` | kcu116: `cmac_taxi.c` |
|---|---|---|
| `mac_hw_reset` | GT reset through the port's GT-control GPIO | shim ID check; CTRL = XCVR_RST \| TX_EN \| RX_EN, 10 ms (`CMAC_XCVR_RST_HOLD_MS`), clear XCVR_RST, wait up to 100 ms for STATUS.TX_RST_OUT = 0 (else print STATUS, GTPOWERGOOD, TX_CLK_KHZ / RX_CLK_KHZ), clear STICKY |
| `mac_port_init(fec)` | MRMAC 100G configuration with the FEC (§6); also the link retry | TX_EN \| RX_EN and a 1 ms CTRL.RX_RST pulse, statistics baseline; the FEC argument is ignored; also the link retry |
| `mac_link_up` | MRMAC `stat_rx_status` | STATUS.RX_STATUS |
| `mac_get_fec` / `mac_fec_name` | the programmed mode | always RS(528,514) |
| `mac_tick(stats)` | MRMAC statistics | 32-bit shim counter deltas into `u64` totals: rx packets = RX_GOOD_PKTS + RX_ERR_FRAMES, tx packets = TX_FRAMES; FEC codeword totals stay 0 (printed `n/a`) |
| `mac_ptp_underrun` | GT-control GPIO CH2 b2 | STICKY.PTP_UNDERRUN |
| `mac_supports_fec_change` | 1 | 0 (`f` prints `FEC fixed on this target`, `APP_FEC_MODE` other than RS(528,514) prints a NOTE) |
| `mac_ts_now` / `mac_ts_incr` | — (the 1588 check reads the MRMAC monitor registers) | TS_NOW (LO then HI), TS_INCR |

On Versal the `mac_*` calls are inline wrappers around the unchanged `mrmac_*` API; `mrmac.c` is
compiled only without `HW_MAC_CMAC`, and `cmac_taxi.c` only with it. `hw_config.h` defines
`HW_MAC_CMAC` for `__MICROBLAZE__` (overridable). The link retry is the same on both: while a link
is down `port.c` calls `mac_port_init()` every `LINK_RETRY_MS` (2 s); on the kcu116 the Taxi
wrapper's watchdog also resets the CMAC RX by itself after ~0.83 s without `rx_status`. The
latency bring-up check on the kcu116 reads the shim's TS_NOW twice 10 ms apart and prints the
advance against CPU time (`shim timestamp timer … advanced … ns in … ns of CPU time`).

### 8.2 MicroBlaze specifics (kcu116)

- **Bring-up order** (`main.c`): I- and D-cache enable (the 2025.2 MicroBlaze start-up code
  leaves them off) → `timebase_init()` → no VADJ step (fixed 1.8 V) → Si5328 322.265625 MHz on
  CKOUT1 → per port: zircon_nic set-up, **then** `mac_hw_reset()` releases CTRL.XCVR_RST (the
  Taxi GT reset sequencer needs the reference clock, so the release must follow the Si5328) →
  `mac_port_init()` → the rest as on the vck190.
- **`hw_config.h`**: `HW_NUM_PORTS` 1; `ZIRCON_NIC_0_FALLBACK_BASEADDR` 0x440A0000 and
  `CMAC_0_FALLBACK_BASEADDR` 0x44000000 (module references, no `XPAR_`); DMAs, IIC, GPIO from
  `XPAR_*`; `TIMEBASE_BASEADDR` from `axi_timer_1`.
- **Timebase** (`timebase.[ch]`): `axi_timer_1` with both 32-bit counters cascaded into one 64-bit
  up-counter, read hi / lo / hi, `TB_HZ` = the timer clock (100 MHz). xiltimer's `XTime` on an
  AXI timer is only 32 bits (43 s at 100 MHz), and `axi_timer_0` belongs to xiltimer's
  `usleep()` / `sleep()`. `timebase_ms()` keeps a running millisecond count (one 32-bit divide
  per call instead of a 64-bit libgcc divide on every main-loop pass).
- **Console** (`console.c`): the UART Lite backend (`xuartlite_l.h`, non-blocking drain, polled
  RX); the baud rate is fixed in the IP.
- **DMA** (`zdma.c`): no MMU to remap the BD rings non-cacheable, so they stay cached and the AXI
  DMA driver's BD flush / invalidate macros (compiled in on non-A53 targets) keep them coherent;
  buffers keep their explicit flush / invalidate calls; 32-bit addresses; `mbar 1` as the data
  barrier.
- **64-bit arithmetic** is soft (libgcc); newlib's `%llu` works (`_svfprintf_r` uses
  `__udivdi3` / `__umoddi3`); `double` in `latency.c` is soft float.
- **Memory layout** (`build-vitis.py` linker modification `code_local_bss_ddr`): `.text`,
  `.init`, `.fini`, `.rodata*`, `.sdata2`, `.sbss2`, `.data*`, `.sdata`, `.sbss`, constructors,
  `.eh_frame`, `.init_array` / `.fini_array`, `.drvcfg_sec` and the 32 KB stack in the 256 KB LMB
  (`.sdata` and `.sbss` stay together: the r13 small-data window); `.bss` (lwIP pbuf pools, DMA
  rings and buffers) and the heap in DDR4, zeroed by the start-up code. Only the LMB is embedded
  in the bitstream by `updatemem`, which is why nothing initialised may live in DDR. The
  application at `-O2` with `--gc-sections` uses 218,752 of 262,144 LMB bytes (83 %); `.bss` +
  heap in DDR are ~6.9 MB.
- **Boot**: `zircon_boot.bit` (JTAG) or `zircon_boot.mcs` from QSPI (§7.1); there is no FSBL and
  no SD card. The application starts from the LMB as soon as the FPGA is configured; on the
  bench it ran cleanly from QSPI with no reset after DDR4 calibration.
- **Speed**: the 100 MHz MicroBlaze makes the software paths (lwIP, the TCP echo, the socket
  demo) roughly 14× (64 B) to 50× (1460 B) slower than on the A72 (§12.8); the hardware paths
  are unaffected.

## 9. Bench / validation contract

Every hardware change is validated on the target it affects: on the VCK190 with the build's
`BOOT.BIN` (SD card) or its PDI + ELF over JTAG; on the KCU116 with `zircon_boot.bit` (or
`zircon_wrapper.bit` + `echo_server.elf`) over JTAG, and for a release also from QSPI
(`zircon_boot.mcs`, then a power cycle with JTAG idle). A change to `zircon_nic` is validated on
both. The result is reported with the build commit and date. Fixtures and pass criteria (the
cross-port rows need two ports and apply to the VCK190 only):

| fixture | test | pass |
|---|---|---|
| none (simulation) | `Vivado/src/hdl/tb/run_xsim.sh` | exit 0 (every test) |
| QSFP28 cable port 0 ↔ port 1 (DAC / AOC / optical) | power-on or load, no keys | `LOOPBACK: PASS` (auto-start, 1472 B) |
| same | `l` at other payloads, `e` (echo through port 1), long `l` soak | PASS where the payload allows line rate; zero checker errors, zero RS-FEC uncorrectable codewords, zero drop counters |
| same | `e` + `T 1` | bank 0 counts every echo, LAT_STATUS 0, no implausible sample |
| QSFP28 loopback plug in port p | `L <p>` | `LOOPBACK: PASS` |
| port 0 or 1 cabled to a 100G NIC in RS-FEC "auto" (bench: Intel E810-C, DHCP from the host) | `scripts/zircon_echo_test.py <ip> --port <p> [--ping] [--jumbo] [--latency]` | `VERDICT: PASS` (hardware UDP echo incl. a 20000-datagram burst, software TCP echo, socket bounce; with `--latency` both banks counted the exchanges) |
| same | `scripts/zircon_prbs_tool.py listen / send` | generator → host and host → checker, zero errors |
| KCU116, QSFP port 0 cabled to the same host | JTAG load, then the host rows above | UART `Port 0: link up, 100 Gb/s, FEC RS(528,514)` and `Port 0: IP …`, then `VERDICT: PASS` (the software TCP echo is slower; `--timeout` exists if needed) |
| same | QSPI programmed with `zircon_boot.mcs` (`mt25qu01g-spi-x1_x2_x4`), power cycle, no JTAG | `Port 0: link up …` and `Port 0: IP …` on the UART, `VERDICT: PASS` |

A cross-port run also shows that both ports' MRMACs, GT quads and reference clocks work. After
a DMA wedge the board is power-cycled, never soft-reset (a MicroBlaze target has no JTAG system
reset: power-cycle, then re-program).

## 10. Hardware UDP generator / checker and rate meters

`GEN_EN` (default 1) builds `udp_gen.sv` (tx_buffer input 3, tdest 3) and `udp_chk.sv`
(rx_dispatch route CHK). With `GEN_EN` = 0 neither exists, the tx_buffer has 3 inputs, the CHK
rule never matches and 0x090..0x0E0 read 0. `rate_meter.sv` is always built; its window is
`CORE_HZ` core cycles (default 300,000,000 = 1 s; the block design keeps the default, which must
equal the real core clock). Registers: §3.3.

### 10.1 Payload definition (generator and checker; reproducible in software)

Datagram with 64-bit sequence number S (0 after GEN_CTRL.CLR, +1 per datagram, continuing across
runs) and payload length L (GEN_LEN clamped to 8..9000):

```
K[j]      = (j + 1) * 0x9E3779B97F4A7C15 mod 2^64          j = 0..7
          = 9E3779B97F4A7C15 3C6EF372FE94F82A DAA66D2C7DDF743F 78DDE6E5FD29F054
            1715609F7C746C69 B54CDA58FBBEE87E 538454127B096493 F1BBCDCBFA53E0A8
xs(x)     : x ^= x << 13; x ^= x >> 7; x ^= x << 17        (xorshift64, mod 2^64)
x_j(0)    = (S XOR K[j]) OR 2^63                             (never 0)
x_j(n+1)  = xs(x_j(n))
payload[i], i >= 8 : byte (i mod 8) of x_j(b + 1), little-endian,
                     b = i div 64 (64-byte beat), j = (i mod 64) div 8 (lane)
payload[0..7]      : S, little-endian
```
Python (`gen_vectors.py`, `scripts/zircon_prbs_tool.py`):
```
x = [(S ^ K[j]) | 1 << 63 for j in range(8)]; out = b""
while len(out) < L: x = [xs(v) for v in x]; out += b"".join(v.to_bytes(8, "little") for v in x)
payload = S.to_bytes(8, "little") + out[8:L]
```
The eight lanes are independent 64-bit xorshift generators (period 2^64 − 1 each), advanced once
per 512-bit beat, so the hardware produces and checks one beat per cycle with no memory and no
multiplier, and the checker re-seeds from the sequence number of every datagram.

### 10.2 Generator (`udp_gen`)

A run starts on a 0→1 edge of GEN_CTRL.EN (CONT and COUNT are sampled then). Continuous runs last
until EN is cleared; count runs send GEN_COUNT datagrams (0: none), or fewer if EN is cleared.
Clearing EN always finishes the datagram being emitted (never a truncated frame). Per datagram:
one SEED cycle, ⌈L/64⌉ payload beats at one beat per cycle (back-pressured only by tx_buffer),
then GEN_GAP idle cycles. `tx_meta_builder` builds the headers (tdest 3): Ethernet dst
GEN_DST_MAC, src MAC_*; IPv4 src IPV4, dst GEN_DST_IP, TTL, the shared identification counter;
UDP src GEN_SRC_PORT, dst GEN_DST_PORT, checksum (with the §4 workaround). Generated frames take
the normal TX path (round robin with UI0 / echo / UI2 per packet, CTRL.TX_EN gate, padding to
60). GEN_TX_PKTS / GEN_TX_BYTES count datagrams / payload bytes handed to tx_buffer. GEN_CTRL.CLR
zeroes the sequence number and GEN_TX_*; CTRL.STAT_CLR zeroes GEN_TX_* only.

### 10.3 Checker (`udp_chk`)

Rule CHK (§3.1; ECHO and SOCK take precedence on equal ports; a CHK_PORT datagram with a bad UDP
checksum goes RAW and counts RX_L4_BAD_CSUM). The datagram is stripped to its payload like
ECHO / SOCK and consumed by the checker, which never back-pressures (tready = 1) and takes one
beat per cycle:

* payload < 8 bytes: CHK_LEN_ERR only;
* else CHK_RX_PKTS += 1, CHK_RX_BYTES += L; sequence: the first datagram after CHK_CTRL.EN 0→1 or
  CHK_CTRL.CLR only synchronises (CHK_CTRL.SYNC = 1); afterwards S ≠ expected counts
  CHK_SEQ_ERR once; expected := S + 1 always (resync), so one lost datagram = one SEQ_ERR;
* CHK_BIT_ERR += popcount(payload XOR PRBS(S)) over bytes 8..L−1.

Datagrams lost before the checker (e.g. RX_FIFO_DROP when the receive side is overloaded) show up
as CHK_SEQ_ERR. Pipeline: A input register (lane states loaded with xs(x_j(0)) from the first
beat's bytes 0..7, advanced once per beat), B 512 error bits masked by tkeep and the sequence
bytes + sequence compare, C 16 × popcount32, D 4 × sum of 4, E sum of 4 (≤ 512), F 64-bit
accumulators.

### 10.4 Rate meters (`rate_meter`)

Every CORE_HZ core cycles the deltas of four free-running counters (never cleared by STAT_CLR)
are latched together and RATE_SEQ increments: RX = frames / bytes entering the core (the
RX_FRAMES / RX_BYTES events, FCS excluded), TX = frames / bytes handed to the MAC (the TX_FRAMES
/ TX_BYTES events, after padding, FCS excluded; crossed from mac_tx_clk as one coherent snapshot,
lagging by < 100 ns). Software reads RATE_SEQ (which latches the six rate registers of that
window), then the values; a new sample exists when RATE_SEQ changed. After a reset the meter
waits 127 cycles before taking its reference, so the first sample is a full window; a TX (or
RX) counter that restarted inside a window (MAC TX reset on a link flap) is detected by its
64-bit byte count going backwards, and that sample reports the counts since the restart. With a
1 s window: payload-agnostic frame rate = 8 × BYTES / 1 s; **line rate = 8 × (BYTES + 24 × PKTS)
/ 1 s** (FCS 4 + preamble/SFD 8 + IPG 12 bytes per frame).

### 10.5 Throughput (core 300 MHz, 512 bit; xsim-measured, test 70)

| side | cost per packet (core cycles) | limited by |
|---|---|---|
| TX (gen → MAC) | max(18, ⌈F/64⌉ + 1), F = frame bytes = L + 42 | 18: builder 16 + deparser / egress; else the payload beats |
| RX (MAC → chk) | max(16, 6 + ⌈F/64⌉ + flush) | 16: 32-bit parser on the 64-byte truncated header; else rx_dispatch's 6-cycle classify + beats (+1 when the payload tail needs a FLUSH beat) |

100 GbE carries one packet per (F + 24) × 0.024 core cycles. TX sustains 100G for L ≥ 684 B, RX
for L ≥ 726 B, so **every hardware path (gen → cable → chk, and the hardware echo) runs at 100G
line rate for UDP payloads ≥ 726 B**; the default 1472 B has 48 % / 23 % headroom on TX / RX.
Below that the packet rate is the limit: TX 300 / 18 = 16.7 Mpps, RX 300 / 16 = 18.75 Mpps (e.g.
512 B: TX ≈ 77 Gb/s line rate). Beyond the RX limit (traffic from another source) the MAC-side
FIFO drops whole frames (RX_FIFO_DROP, seen by the checker as CHK_SEQ_ERR). Jumbo (9000 B) is far
from both limits. The UI0 / UI2 DMAs move 512 bits per 100 MHz cycle, 51.2 Gb/s per direction.
The kcu116 runs the same core at the same 300 MHz, so these limits apply to it unchanged; its MAC
side (512 b at 322.27 MHz, 165 Gb/s of bus capacity) is not a limit either. Bench measurements:
§12.

## 11. Latency measurement

Measures, per `zircon_nic`, the latency of the hardware UDP echo (bank 0) and of a software path
through the PS (bank 1, the lwIP TCP echo in `echo_server`) with the MRMAC's IEEE 1588 two-step
timestamps: **delta = TX timestamp − RX timestamp**. The MRMAC takes both at the first PCS block
of the frame (PG314 "Timestamping"), so the window is RX-PCS SOP of the request → TX-PCS SOP of
the reply: serdes, PCS and RS-FEC latency excluded, every store-and-forward stage included.
§11.1–11.6 describe the vck190; on the kcu116 the same `zircon_nic` logic, formats and registers
work on fabric timestamps from the CMAC shim (§11.7).

### 11.1 Time base and formats

- MRMAC timestamps are 55 bits in units of **2⁻⁸ ns** (bits 62:8 of a correction-field value).
  `ptp_systimer` (ts_clk 250 MHz) adds `INCR` = 1024 (4 ns) per cycle and drives both MRMACs'
  `ctl_{tx,rx}_ptp_systemtimer` with `st_sync` pulses (parameter SYNC_MODE: 0 once, 1 periodic —
  the default, every SYNC_PERIOD = 250000 cycles = 1 ms — or 2 held high; plus one pulse per
  `sync_req` rising edge in every mode), `st_overwrite` = 1, `st_adjust*` = 0. The exact
  `st_sync` semantics are not documented in the PG314 material available (see the RTL header);
  on the bench the MRMAC timer advances at 1 ns/ns and HW-echo deltas are stable to a few ns.
- The RX timestamp travels with the frame as `tuser[48:1]` = ts[54:7] (**0.5 ns units, 48
  bits**); every place that needs the full unit reconstructs `{ts[54:7], 7'b0}`.
- delta = (tx_ts − {rx_ts[54:7], 7'b0}) mod 2⁵⁵, then `>> 8` → ns (32 bits). The timer wraps
  after 2⁴⁷ ns ≈ 39 h; the modular subtraction handles it. delta ≥ 1 s (10⁹ ns) is
  **implausible**: counted per bank, never accumulated.

### 11.2 RX

- `mrmac_rx_packer`: registers `rx_ptp_tstamp` before any logic, samples it on client beat
  `RX_TS_BEAT` (0 = SOF, the default; −1 = TLAST; N = N-th beat) and puts ts[54:7] on
  `m_axis_tuser[48:1]` of **every** output beat of the frame (for RX_TS_BEAT ≠ 0: at least the
  last beat). The value rides in the same pipeline registers / FIFO entries as the data.
- `zircon_nic`: `tuser` is 49 bits wide on the MAC-side async FIFO (bad-frame mask still bit 0),
  the broadcast and the len-record FIFO; `zircon_ip_len_cksum` forwards the last beat's tuser into
  the len record, so every frame's timestamp is dropped exactly with the frame.
- `rx_dispatch` captures it with the len record and (a) stores it in `echo_rec_t.rx_ts` for ECHO
  requests; (b) with LAT_CTRL.RAW_RX_DESC emits a 64-byte **ZRXT descriptor** beat in front of
  every RAW frame (the DESC state), inside the frame in the drop-when-full RAW FIFO, so a dropped
  frame takes its descriptor with it.

ZRXT descriptor (UI0 RX, little-endian, 64 bytes, then the unchanged frame):

| bytes | field |
|---|---|
| 0..3 | magic `0x5A525854` ("ZRXT" as a LE u32) |
| 4..5 | length of the frame that follows (bytes, FCS excluded) |
| 6..7 | 0 |
| 8..15 | rx_ts, u64 in the MRMAC unit 2⁻⁸ ns (bits 6:0 and 63:55 are 0) |
| 16..23 | 0 |
| 24..27 | parser flags (§4) |
| 28..63 | 0 |

### 11.3 TX

- **Latency record** `lat_rec_t {want, bank[1:0], rx_ts[47:0]}` (51 bits): `tx_meta_builder`
  pushes one per packet, in packet order, into a 32-entry FIFO: ECHO → {LAT_CTRL.EN, 0, rx_ts of
  the request}; RAW → the record made by `raw_tx_desc_strip` (want gated by EN); SOCK / GEN →
  want 0.
- **`raw_tx_desc_strip`** (after `tx_len_guard` on UI0, LAT_CTRL.RAW_TX_DESC): a frame whose first
  beat is a full (all 64 tkeep bits), non-last beat starting with the ZTXT magic loses that beat
  and yields {want = TS_REQ, bank 1, rx_ts}; every other frame passes untouched with want = 0.
  One record per frame into a TX_RAM_SIZE/64-entry FIFO popped by the builder (a full FIFO only
  back-pressures UI0).
- The record is attached to every beat of its frame as the frame leaves the Zircon concat
  (`tuser[51:1]`; deparser and concat never drop or reorder), crosses to mac_tx_clk **inside the
  MAC TX frame FIFO** and passes `tx_mac_out`. It is therefore dropped exactly with its frame
  (TX_EN = 0 discard, mac_tx reset flush): there is no side FIFO to realign.
- **`ptp_tx_tagger`** (mac_tx_clk): at each frame's first beat it pushes `{tag, op}` into a
  16-entry LUTRAM FIFO (1-cycle latency) → `m_axis_tx_ptp`, and releases the beat one cycle later,
  so the record always precedes its frame (one idle cycle per frame on a bus with 2× the line
  rate). op = 2'b10 (two-step) with tag = a 16-bit sequence number for want, else op = 0, tag =
  0. A tagged frame takes entry tag[5:0] of a 64-entry pending table {tag[15:6], bank, rx_ts}
  (LUTRAM + valid bits). The MRMAC's `tx_ptp_tstamp_*` outputs are registered once in
  `zircon_nic` before any logic. A returned timestamp looks up tag[5:0] (the table read is
  registered) and checks tag[15:6]: hit → 5-stage delta pipeline → sample {bank, implausible,
  delta_ns[31:0]} → 512-entry async FIFO → core clock; miss → STALE; reusing a still-pending
  entry → LOST; sample FIFO full → OVF. A mac_tx reset clears the pending table and the PTP FIFO
  (the sequence number keeps counting, so pre-reset timestamps are STALE).
- **`mrmac_tx_axis_adapter`** pops one record at each SOF and drives `tx_ptp_1588op_in` /
  `tx_ptp_tag_field_in` from the cycle the SOF beat is presented until its TLAST beat is
  accepted (0 between frames). If the record is not there it holds the frame (tvalid low, only
  at SOF) for up to `SOF_WAIT` (8) cycles, then sends it with op 0 and sets the sticky
  `ptp_underrun` output (reset by its `aresetn`).

`m_axis_tx_ptp` record: tdata[1:0] op, [17:2] tag, [23:18] 0; one per frame on `m_axis_mac_tx`,
in order; a full FIFO holds the TX path (tie tready to 1 if unused).

ZTXT descriptor (UI0 TX, little-endian, 64 bytes in the transfer's first beat, then the frame):

| bytes | field |
|---|---|
| 0..3 | magic `0x5A545854` ("ZTXT" as a LE u32) |
| 4..5 | 0 |
| 6 | flags: b0 TS_REQ (timestamp this frame, account it to bank 1; needs LAT_CTRL.EN) |
| 7 | 0 |
| 8..15 | rx_ts of the request, u64 in the MRMAC unit (as in ZRXT; bits 6:0 ignored) |
| 16..63 | 0 |

Only honoured with LAT_CTRL.RAW_TX_DESC = 1 (without it the frame is sent as written); a
descriptor-only transfer (magic on a TLAST beat) is not a descriptor.

### 11.4 Statistics engine (`latency_stats.sv`, core clock)

Per bank (2): COUNT (64), SUM (64, ns), SUMSQ (64, ns², saturating; a 32×32 multiplier), MIN /
MAX / LAST (32, ns), IMPLAUSIBLE (32) and a 64-bin histogram of 48-bit counters (bank × bin RAM,
read-modify-write). Bins (x = delta − BASE, W = 2^k = LAT_BIN_WIDTH, q = x / W):

| bin | range |
|---|---|
| 0..47 | q (linear, [BASE + iW, BASE + (i+1)W)); **x < 0 is counted in bin 0** |
| 48..62 | 48·2^(i−48) ≤ q < 48·2^(i−47) (each doubles; default W 64 ns: from 3.07 µs up to 100.7 ms) |
| 63 | q ≥ 48·2¹⁵ (overflow) |

One sample takes 5 core cycles. Commands arrive as toggles in the configuration word (coherent
with it): CLEAR bank b (64-cycle sweep of its bins + scalars; MIN ← 0xFFFFFFFF), SNAPSHOT (both
banks' scalars and bins copied into a 512 × 32 dual-clock block RAM, ≈ 300 cycles). Samples wait
in the input FIFO during a command, so a snapshot is coherent (Σ bins = COUNT). LAT_CTRL.BUSY is
a request / acknowledge toggle pair (ui ↔ core). The shadow RAM is written only by a snapshot and
read (AXI-Lite, one extra cycle) only when BUSY is 0, so the two ports never touch a word at the
same time. Both banks are cleared after reset. BASE and W are one setting for both banks; a
change applies to new samples only (clear the banks after changing them).

### 11.5 Software sequence

1. LAT_BIN_BASE / LAT_BIN_WIDTH; LAT_CTRL = EN (+ RAW_RX_DESC + RAW_TX_DESC for the software
   path) | CLR0 | CLR1; poll BUSY.
2. Traffic. For the software path: take rx_ts from the ZRXT descriptor of the request and put it
   in the ZTXT descriptor of the reply with TS_REQ.
3. Write LAT_CTRL with SNAP, keeping the enables (e.g. 0x309); poll until b3 / b31 = 0; read
   0x200.. / 0x400.. . mean = SUM / COUNT, σ² = SUMSQ / COUNT − mean², percentiles from the bins.
4. LAT_STATUS / LAT_*_CNT flag STALE / LOST / OVF (STALE is expected after a link flap).

### 11.6 Verification (xsim)

The TB models the MRMAC: a 55-bit timer (+1024 per 4 ns), RX timestamp = timer at each MAC RX
frame's first beat on tuser[48:1], and for each MAC TX frame it pops the `m_axis_tx_ptp` record
at the first beat (it must already be there) and returns timer-at-SOF with the tag 4..24 (or
PTPDELAY) cycles later. Expected samples are paired with tagged frames by UDP ports and
accumulated per bank; LATCHK snapshots and compares COUNT, SUM, SUMSQ, MIN, MAX, LAST,
IMPLAUSIBLE and all 64 bins exactly, and every echo delta against the simulated SOF time
difference (± 5 ns).

| test | checks |
|---|---|
| 9 | latency register defaults, BASE / WIDTH r/w (WIDTH rounding), a snapshot of empty banks |
| 80 | 48 HW echoes (1..8972 B) → bank 0, default bins, then BASE 450 / W 8 (below-base, linear, tail bins); the timer wraps 2⁵⁵ mid-test; bank 1 stays 0 |
| 81 | ZTXT: 10 TS_REQ frames → bank 1 exact; TS_REQ 0 stripped, untagged; no descriptor / short magic frame untouched; rx_ts 2 s old → IMPLAUSIBLE; EN 0 → stripped, untagged; RAW_TX_DESC 0 → sent as written |
| 82 | RAW_RX_DESC: ZRXT (magic, length, rx_ts, zeros) on ARP / TCP / UDP / 9000-byte / other-MAC frames; off again → plain frames |
| 83 | echo + ZTXT + plain raw + socket + generator mixed, random MAC tready and random `m_axis_tx_ptp` tready: one record per frame in order, op 2 exactly for the 50 timestamped frames of 90, both banks exact |
| 84 | mac_tx reset with timestamps outstanding: no wedge, STALE set, LOST / OVF 0, then exact again |
| 85 | three snapshots while 400 echoes are measured: each coherent (Σ bins = COUNT, count monotonic); CLEAR of bank 0 leaves bank 1 intact |
| 23 (unit) | TX adapter: 750 frames, records early / late within SOF_WAIT / missing, random gaps and tready, op / tag held SOF → TLAST and 0 between frames, underrun sticky, aresetn mid-frame |
| 24 (unit) | systimer: +1024 per cycle, periodic st_sync, sync_req pulse, once mode |
| 13 / 14 / 20 (unit) | packer: RX timestamp on every output beat of every frame (random per frame, garbage elsewhere) |

### 11.7 kcu116: fabric timestamps

Taxi's CMAC wrapper provides no timestamps at `cc70b27`, so `zircon_cmac_us` takes them in logic
(§6c) and `zircon_nic` is unchanged: same 55-bit, 2⁻⁸ ns format, same `tuser[48:1]` RX contract,
same `m_axis_tx_ptp` / `tx_ptp_tstamp_*` TX contract, same banks, registers, descriptors and
software.

- **Time base**: a 45-bit tick counter on the 250 MHz `ts_clk`, ts55 = `{tick, 10'b0}` (+1024 per
  4 ns); software reads it as the shim's TS_NOW. It does not count anything but time: there is no
  `st_sync` and no `sync_req`.
- **What is measured**: the RX timestamp is taken at the first beat of each frame at the CMAC
  **client** RX interface, the TX timestamp at the first beat accepted at the shim / Taxi
  boundary (the wrapper's `s_axis_tx`, in front of `taxi_axis_pad` and the CMAC). The window is
  therefore **MAC-client SOF (RX) → MAC-client SOF (TX)**: the constant CMAC TX + RX pipeline (estimated
  100–300 ns) is excluded, besides the serdes / PCS / RS-FEC stages the MRMAC figure already
  excludes. **Absolute kcu116 numbers are not comparable with the vck190's PCS → PCS numbers.**
- **Resolution**: 4 ns quantisation, plus up to one `ts_clk` and one destination-clock cycle of
  sampling phase in each `ts_gray_sync` crossing: roughly ±4–7 ns per sample (estimate), the
  mean unbiased (the fixed crossing latency is identical in `tx_clk` and `rx_clk` and cancels).
  **Measured**: standard deviation 2.3 ns (64 B) to 2.8 ns (1472 B) for the hardware echo from a
  host, against 1.0–2.4 ns with the vck190's MRMAC timestamps (§12.5, §12.8).
- **Underrun**: `mac_ptp_underrun()` reads STICKY.PTP_UNDERRUN instead of the GT-control GPIO.
- Rejected alternatives: Taxi's `taxi_ptp_td_phc` + leaf clock (more logic, a lock phase, 96/64-bit
  formats), the CMAC's hard timestamps (they need changes to Taxi, whose sources stay unmodified),
  and dropping the feature on this target.
- xsim: `tb_zircon_cmac_us.sv` tests 104–108 and 111 (§3.4).

## 12. Performance measurements

Bench results on the VCK190 + 2x QSFP28 FMC (OP120) on FMCP1, 100GBASE-R CAUI-4, RS-FEC
RS(528,514). "Loopback" = an optical QSFP28 patch cable (100GBASE-SR4 modules) between port 0
and port 1, no host; "host" = port 0 cabled to an Intel E810-C. Times are bench-journal times.
The user-facing account with UART excerpts is `docs/source/testing.md`. §12.1–12.7 are the
VCK190; the KCU116 results are in §12.8.

| build label | commit / load | date |
|---|---|---|
| kcu116 1.3.0 | kcu116 target 6e24f6d (bitstream built 16:56, `zircon_boot.bit` 17:00); JTAG, then QSPI | 2026-09-25 17:02–17:22 (journal `logs/_bench/kcu116_journal.log`) |
| kcu116 1.3.0, loopback plug | same `zircon_boot.mcs`, booted from QSPI (repo 7bb5d25) | 2026-09-25 19:40–19:54 (same journal) |
| 1.3.0 final SD | hardware d8eda55, application c1ae2c1; `BOOT.BIN` booted from the SD card | 2026-09-25 08:13–08:31 |
| 1.3.0 Phase B | hardware d8eda55 (+ application c1ae2c1 for the host run), JTAG | 2026-09-25 02:36 (loopback), 07:15 (host) |
| 1.3.0 Phase A | first 1.3.0 build f684f59, JTAG | 2026-09-24 22:01 |
| 1.2.0 | v1.2.0 (JTAG; SD card for the throughput sweep and auto-start) | 2026-09-24 |
| 1.1.0 / 1.0.0 | JTAG, port 0 to the host | 2026-09-24 |

### 12.1 Throughput vs payload — cross-port `l`, both directions at once, values per direction

1.3.0 final SD: 2026-09-25 08:14:11–08:16:27, 15 s per size, pps = mean generator-TX delta over
8 × 1 s (tables 6–14 s), spread ≤ ±17 pps. 1.2.0 (SD boot): 2026-09-24 19:36–19:38, 14 s per
size, 7 × 1 s deltas (6–13 s), spread < ±15 pps. Fixture: loopback.

| UDP payload | frame incl. FCS | line rate (1.3.0 = 1.2.0) | payload rate (1.3.0 = 1.2.0) | pps 1.3.0 | pps 1.2.0 | errors seq/bit/len (both) | verdict (both) |
|---|---|---|---|---|---|---|---|
| 64 B | 110 B | 17.33 Gb/s | 8.53 Gb/s | 16,666,499 | 16,666,500 | 0/0/0 | FAIL rate (expected, TX header path 16.67 Mpps) |
| 128 B | 174 B | 25.86 Gb/s | 17.06 Gb/s | 16,666,498 | 16,666,500 | 0/0/0 | FAIL rate (expected) |
| 256 B | 302 B | 42.93 Gb/s | 34.13 Gb/s | 16,666,499 | 16,666,500 | 0/0/0 | FAIL rate (expected) |
| 512 B | 558 B | 77.06 Gb/s | 68.26 Gb/s | 16,666,499 | 16,666,500 | 0/0/0 | FAIL rate (expected) |
| 726 B | 772 B | 100.00 Gb/s | 91.66 Gb/s | 15,782,812 | 15,782,780 | 0/0/0 | PASS |
| 1024 B | 1070 B | 100.00 Gb/s | 93.94 Gb/s | 11,467,878 | 11,467,850 | 0/0/0 | PASS |
| 1472 B | 1518 B | 100.00 Gb/s | 95.70 Gb/s | 8,127,432 | 8,127,410 | 0/0/0 | PASS |
| 1500 B | 1546 B | 100.00 Gb/s | 95.78 Gb/s | 7,982,114 | 7,982,090 | 0/0/0 | PASS |
| 9000 B | 9046 B | 100.00 Gb/s | 99.27 Gb/s | 1,378,777 | 1,378,774 | 0/0/0 | PASS |

Theoretical 100GBASE-R frame rate = 100e9 / 8 / (frame + 20): 726 B 15,782,828; 1472 B
8,127,438; 9000 B 1,378,778. 1.3.0 is within 0.0001 %, 1.2.0 within 0.0003 %; the largest
1.3.0 − 1.2.0 difference (32 pps at 726 B) is table-timing noise. Below 726 B the TX header path
sets the rate (300 MHz / 18 cycles = 16.67 Mpps, §10.5).

### 12.2 Cross-port `l` and echo-through `e` verdicts (fixture: loopback)

| version, date | test | payload | duration | line / payload Gb/s per direction | datagrams checked (P0 / P1) | errors | verdict |
|---|---|---|---|---|---|---|---|
| 1.3.0 final SD, 2026-09-25 08:13 | `l` auto-start | 1472 B | 29 s | 100.00 / 95.70 | 239,546,475 / 239,546,473 | 0/0/0 | PASS |
| 1.3.0 final SD, 2026-09-25 08:15:42 | `l` | 1472 B | 15 s | 100.00 / 95.70 | 173,696,525 / 173,696,524 | 0/0/0 | PASS |
| 1.3.0 final SD, 2026-09-25 08:16:12 | `l` | 9000 B | 51 s | 100.00 / 99.27 | 70,870,125 / 70,870,124 | 0/0/0 | PASS |
| 1.3.0 final SD, 2026-09-25 08:15:12 | `l` | 726 B | 15 s | 100.00 / 91.66 | 239,016,385 / 239,016,382 | 0/0/0 | PASS |
| 1.3.0 final SD, 2026-09-25 08:14:57 | `l` | 512 B | 15 s | 77.06 / 68.26 | 252,443,520 / 252,443,518 | 0/0/0 | FAIL rate (expected) |
| 1.3.0 final SD, 2026-09-25 08:17:34 | `e` P0 gen → P1 HW echo → P0 chk | 1472 B | 30 s | 100.00 / 95.70 | 245,205,879 | 0/0/0 | PASS |
| 1.3.0 final SD, 2026-09-25 08:18:47 | `e` | 9000 B | 30 s | 100.00 / 99.27 | 41,596,876 | 0/0/0 | PASS |
| 1.2.0 JTAG, 2026-09-24 18:42 | `l` (36 s table) | 1472 B | 36 s | 100.00 / 95.70 | 294,246,625 / 294,246,623 | 0/0/0 | PASS |
| 1.2.0 JTAG, 2026-09-24 | `l` | 9000 B | ~11 s | 100.00 / 99.27 | 15,485,258 / 15,485,257 | 0/0/0 | PASS |
| 1.2.0 JTAG, 2026-09-24 | `l` | 726 B | ~11 s | 100.00 / 91.66 | 177,198,728 / 177,198,725 | 0/0/0 | PASS |
| 1.2.0 JTAG, 2026-09-24 | `l` | 512 B | ~11 s | 77.06 / 68.26 | 183,310,322 / 183,310,386 | 0/0/0 | FAIL rate (expected) |
| 1.2.0 JTAG, 2026-09-24 | `e` | 1472 B | ~11 s | 100.00 / 95.70 | 89,398,614 | 0/0/0 | PASS |
| 1.2.0 JTAG, 2026-09-24 | `e` | 9000 B | ~11 s | 100.00 / 99.27 | 15,163,967 | 0/0/0 | PASS |

Echo counters: 1.3.0 port 1 RX_ECHO = TX_ECHO = 286,802,755 (both `e` runs), RX_ECHO_DROP 0;
1.2.0: 106,873,949 echoed, RX_ECHO_DROP 0. Link-up transient (1.3.0 final SD, 08:13): port 0's
MRMAC counted 19 uncorrectable RS-FEC codewords during link-up (before 5 s) and none afterwards
(still 19 at 355 s); port 1 0. Cleared with `c` before the soak.

### 12.3 Soak (`l`, 1472 B, after `c`; fixture: loopback)

| | 1.3.0 final SD (2026-09-25 08:19:46–08:30:07) | 1.2.0 JTAG (2026-09-24 18:45:38–18:56:00) |
|---|---|---|
| duration | 635 s (621 s table: 5,047,131,112 gen TX P1) | 621 s |
| datagrams per direction (gen TX / chk RX) | P0 5,164,570,389 / 5,164,570,390; P1 5,164,570,390 / 5,164,570,389 | P0 5,049,248,410 / 5,049,248,412; P1 5,049,248,412 / 5,049,248,410 |
| payload per direction | ~7.60 TB | ~7.43 TB |
| seq / bit / len errors | 0 / 0 / 0 | 0 / 0 / 0 |
| rate | 100.00 Gb/s line both ways every table (from 2 s) | 100.00 Gb/s every second |
| RS-FEC corrected / uncorrected (both MRMACs) | 0 / 0 | 0 / 0 |
| MRMAC bad FCS | 0 | 0 |
| MRMAC RX frames vs zircon_nic | P0 MRMAC RX 5,164,570,390 = P1 gen = P0 chk; zircon RX_FRAMES 869,603,094 = MRMAC − 2^32 exactly (P1: 5,164,570,389 / 869,603,093) | MRMAC RX ~4.93e9 good per port at 606 s; zircon 754,281,116 = 5,049,248,412 − 2^32 |
| STATUS / LAT_STATUS / drops (fifo, bad, csum, raw, sock, echo, txbig) | 0 / 0 / all 0 | 0 / n.a. / all 0 |

Also 1.3.0 Phase B (JTAG, 2026-09-25 02:40:41–02:45:41): 319 s soak, 2,594,728,161 datagrams per
direction, 0 errors, 0 / 0 FEC, 0 bad FCS, STATUS and drops 0.

### 12.4 Auto-start from power-on (SD-card boot, fixture: loopback, no console input)

| event | 1.3.0 final SD (2026-09-25, power-on 08:13:22.3) | 1.2.0 (2026-09-24, power-on 20:07:14) |
|---|---|---|
| boot PDI loaded / app banner | +2.7 s | n.r. |
| zircon_nic probed, 1588 timer check | +4.7 s | n.a. |
| both links up (RS-FEC aligned) | +5.1 s | n.r. |
| static fallback (no DHCP, 10 s) | +15.2 s | n.r. |
| LOOPBACK auto-start (15 s after links up) | +20.2 s | n.r. |
| `LOOPBACK: PASS` | +31.2 s | +31 s (20:07:45, 1 s resolution) |

n.r. = not recorded. 1.3.0 SD boot with the host serving DHCP (2026-09-25, power-on 07:40:34):
`Port 0: IP ... (DHCP)` at 07:40:49 = +15 s.

### 12.5 Latency (MRMAC 1588, RX PCS → TX PCS, ns; 1.3.0 only — 1.2.0 and earlier have no latency measurement)

Hardware UDP echo (bank 0):

| version / build, date | fixture / setup | payload (frame) | traffic | samples | min | mean | max | stddev | p50 / p99 / p99.9 (bin upper edge) |
|---|---|---|---|---|---|---|---|---|---|
| 1.3.0 Phase A f684f59, 2026-09-24 22:01 | loopback `e`, P1 bank 0 | 64 B (106 B) | 16.7 Mpps, 30 s | 536,350,656 | 478 | 498.0 | 514 | 1.6 | 512 / 512 / 512 |
| 1.3.0 Phase A f684f59, 2026-09-24 | loopback `e` | 1472 B (1514 B) | 100.00 Gb/s, 30 s | 261,542,980 | 811 | 830.8 | 844 | 1.0 | 832 / 844 / 844 |
| 1.3.0 Phase A f684f59, 2026-09-24 | loopback `e` | 9000 B (9042 B) | 100.00 Gb/s, 30 s | 44,371,457 | 2972 | 2991.1 | 3005 | 2.3 | 3005 / 3005 / 3005 |
| 1.3.0 Phase A f684f59, 2026-09-24 | loopback, isolated | 1472 B | 1000 datagrams 1 ms apart | 1000 | 810 | 814.1 | 826 | 1.9 | 826 |
| 1.3.0 Phase A f684f59, 2026-09-24 | loopback, isolated | 64 B | 1000 datagrams 1 ms apart | 1000 | 479 | 481.6 | 486 | 1.6 | 486 |
| 1.3.0 Phase B d8eda55, 2026-09-25 02:36 | loopback `e` | 1472 B | 100.00 Gb/s, 30 s | 261,483,497 | 812 | 832.1 | 846 | 1.0 | – |
| 1.3.0 Phase B d8eda55, 2026-09-25 02:36 | loopback `e` | 64 B | 16.7 Mpps, 30 s | 536,316,595 | 474 | 498.0 | 515 | 1.9 | – |
| 1.3.0 final SD, 2026-09-25 08:17:34 | loopback `e` | 1472 B (1518 B) | 100.00 Gb/s, 30 s | 245,205,879 | 808 | 831.1 | 845 | 1.0 | 832 / 845 / 845 |
| 1.3.0 final SD, 2026-09-25 08:18:47 | loopback `e` | 9000 B (9046 B) | 100.00 Gb/s, 30 s | 41,596,876 | 2969 | 2992.0 | 3006 | 2.4 | 3006 / 3006 / 3006 |
| 1.3.0 Phase B, 2026-09-25 07:15 | host E810, 1 in flight | 64 B | 1000 req/resp | 1000 | 477 | 485 | 494 | – | – |
| 1.3.0 Phase B, 2026-09-25 07:15 | host E810, 1 in flight | 512 B | 1000 | 1000 | 581 | 590 | 606 | – | – |
| 1.3.0 Phase B, 2026-09-25 07:15 | host E810, 1 in flight | 1024 B | 1000 | 1000 | 700 | 712 | 723 | – | – |
| 1.3.0 Phase B, 2026-09-25 07:15 | host E810, 1 in flight | 1472 B | 1000 | 1000 | 809 | 817 | 832 | 3.0 | 768–832: 999, 832–896: 1 |
| 1.3.0 Phase B, 2026-09-25 07:15 | host E810, 64 in flight burst | 1472 B | 20,000 datagrams (108,686/s) | 20,001 | – | – | 834 | 3.8 | 768–832: 19,995; 832–896: 5 |

Slope ≈ 0.29 ns per byte (store-and-forward stages). All loopback runs: LAT_STATUS 0,
stale / lost / ovf 0, implausible 0, no PTP_UNDERRUN. Frame sizes in the Phase A rows are without
FCS (1514 / 9042 / 106 B), in the final-SD rows with FCS (1518 / 9046 B): the same frames.

Software TCP echo (bank 1), 1.3.0 Phase B, host E810, 2026-09-25 07:15, 1000 exchanges,
`TCP_NODELAY`, one in flight:

| payload | min | mean | max | stddev | histogram | bank count |
|---|---|---|---|---|---|---|
| 64 B | 6.01 µs | 6.79 µs | 7.86 µs | – | 3072–6144: 64; 6144–12288: 936 | 1000 |
| 512 B | 7.04 µs | 7.69 µs | 8.51 µs | – | 6144–12288: 1000 | 1000 |
| 1024 B | 8.02 µs | 8.80 µs | 9.67 µs | – | 6144–12288: 1000 | 1000 |
| 1460 B | 8.953 µs | 9.698 µs | 10.822 µs | 366.9 ns | 6144–12288: 1000 | 1000 |

Host round-trip times in the same run (1.3.0 Phase B, 2026-09-25 07:15; one Python process):

| payload | host RTT UDP mean / p50 / p99 | host RTT TCP mean / p50 / p99 |
|---|---|---|
| 64 B | 33.9 / 27.7 / 125.9 µs | 32.7 / 32.1 / 39.8 µs |
| 512 B | 29.6 / 29.2 / 37.2 µs | 44.2 / 37.0 / 135.0 µs |
| 1024 B | 33.6 / 32.2 / 50.9 µs | 46.7 / 40.6 / 166.4 µs |
| 1472 B (TCP 1460 B) | 35.7 / 35.1 / 47.3 µs | 40.6 / 39.9 / 48.5 µs |

### 12.6 Host-mode echo test (`scripts/zircon_echo_test.py` against an Intel E810-C, port 0)

| version, date | load | verdict | ping | UDP HW echo sweep 1..1472 B | UDP burst 20000 × 1472 B, window 64 | TCP SW echo | HW socket | host csum errors | small-frame / other |
|---|---|---|---|---|---|---|---|---|---|
| 1.0.0, 2026-09-24 | JTAG | PASS | 3/3, RTT 75–109 µs | 1472/1472; RTT min 34, median 48, p99 78 µs | 20000/20000, 107,474 pps | 100/100 | 55/55 | +0 | small-datagram bursts with ≥ 64 in flight lost 1 in 2,000–11,000 (RX width converter bug, fixed in 1.1.0); HW echo bursts 12 B 150,634/s, 64 B 154,805/s, 1472 B 127,291/s (host-limited) |
| 1.1.0, 2026-09-24 | JTAG, 3 cold loads | PASS × 3 | 3/3, RTT 64–68 µs | 1472/1472; RTT min 26, median 32, p99 124 µs | 20000/20000 | 100/100 | 55/55 | +0 | 12 B × 2,000,000 window 64: 0 lost (159,951/s); window 256: 71 lost = host RcvbufErrors; 1–17 B × 2000: all intact; A72 halted 10 s: HW echo 3,000,000/3,000,000, raw drops counted |
| 1.2.0, 2026-09-24 | JTAG, two-port build, port 1 empty | PASS | – | 1472/1472 intact | 20000/20000 | 100/100 | 55/55 | +0 | 12 B × 2,000,000 window 64: 0 lost (162,949/s), RX_ECHO = TX_ECHO = 2,021,473; generator → host 1000/1000 contiguous, all bits OK; checker from host 10,000/10,000, bit-flip and seq-jump detected |
| 1.3.0 Phase B, 2026-09-25 07:15 | JTAG, port 1 on loopback plug | PASS (all normal tests + latency) | yes (`--ping`) | passed | passed | passed | passed | +0 | latency check PASS (§12.5) |
| 1.3.0 final (c1ae2c1 app), 2026-09-25 07:40 | SD-card boot | PASS (`--port 0 --latency --lat-sizes 1472`) | – | – | – | – | – | – | power-on to DHCP 15 s |

### 12.7 Port 1 self-loopback on a QSFP28 loopback plug (`L 1`) — measured on 1.2.0 (2026-09-24), not repeated as a table on 1.3.0

| payload | line rate TX = RX | payload rate | checker (12 s run) | verdict |
|---|---|---|---|---|
| 1472 B | 100.00 Gb/s | 95.70 Gb/s | 89,394,893, 0/0/0 errors | PASS |
| 9000 B | 100.00 Gb/s | 99.27 Gb/s | 15,164,623, 0 errors | PASS |
| 726 B | 100.00 Gb/s | 91.66 Gb/s | 173,589,011, 0 errors | PASS |
| 512 B | 77.06 Gb/s | 68.26 Gb/s | 183,314,304, 0 errors | FAIL rate (expected) |
| 64 B | 17.33 Gb/s | 8.53 Gb/s | 187,128,404, 0 errors | FAIL rate (expected) |

1.2.0 rate registers (xsdb) at 1472 B: 8,127,485 frames / 12,305,012,290 B per window =
100.001 Gb/s; after the runs RX_FRAMES = TX_FRAMES = 939,192,648, STATUS 0. 1.3.0 spot check
(JTAG, 2026-09-25 07:35:59): `L 1` 1472 B PASS, 100.00 Gb/s, 91,259,616 datagrams in 11 s,
0 errors, LAT_STATUS 0.

### 12.8 KCU116 (`kcu116`, port 0, zircon_nic 1.3.0, 2026-09-25 17:02–17:22 host, 19:40–19:54 loopback plug)

Fixture (host): OP120 on the KCU116 HPC slot, QSFP port 0 cabled to the host's Intel E810-C
(`ens6f1np1`, FEC auto → RS, MTU 1500, DHCP from the host); jumbo not tested against the host
(MTU 1500). The loopback-plug results (§12.8.1) followed the same day.

| check | result |
|---|---|
| JTAG load (`bench.py program kcu116 --arch microblaze --bit zircon_wrapper.bit --elf echo_server.elf`) | first load, no software change: `zircon_nic 1.3.0 at 0x440a0000 (port 0)`, `tx_clk` 322,270 kHz (322,265.625 expected), shim timer advanced 10,003,240 ns in 10,003,240 ns of CPU time, `Port 0: link up, 100 Gb/s, FEC RS(528,514)`, DHCP lease; host 100000 Mb/s, FEC RS; link up for the whole session. (The `configured` line's clock readings overlap the XCVR_RST release and are partial.) |
| `zircon_echo_test.py --ping` | `VERDICT: PASS`: ping 3/3 (RTT 0.130 ms), HW UDP echo sweep 1..1472 B intact, burst 20,000 × 1472 B at 102,716 datagrams/s with 64 in flight (host-limited), SW TCP echo 100/100 (18.8 Mb/s), socket 55/55, host checksum errors +0 |
| HW echo soak (17:06:01–17:07:24, after `c` and `T 0 c`) | 12,000,000 × 1472 B, 64 in flight, 143,759 datagrams/s (1.69 Gb/s payload each way, host-limited): `VERDICT: PASS`, 0 lost, 0 corrupt. zircon_nic RX = TX = 12,000,003, echo 12,000,001, every drop / checksum counter and STATUS 0. CMAC RX 12,000,003 good, 0 bad FCS, 0 error frames; TX 12,000,003 good, 12,000,001 TX timestamps returned. Bank 0: 12,000,001 samples, min 712 / mean 718.1 / max 740 ns, stddev 2.8 ns, all in the 704–768 ns bin; LAT_STATUS 0, stale / lost / ovf 0 |
| checker from the host (`zircon_prbs_tool.py send --count 10000 --len 1000`, registers written with xsdb) | CHK_RX_PKTS 10,000, 0 sequence / bit / length errors |
| generator to the host (1000 × 1000 B, GEN_GAP 3000, `zircon_prbs_tool.py listen`) | 1000/1000, sequence 0..999 contiguous, 0 bit errors, `VERDICT: PASS` |
| QSPI boot (`program_hw_cfgmem` `mt25qu01g-spi-x1_x2_x4`, erase + program + verify 17:11–17:16; power cycle 17:16:30, no JTAG) | configured from flash, `Port 0: link up …`, `Port 0: IP … (DHCP)` at 17:16:38 (~8 s after power-on, 3 s of application time); `zircon_echo_test.py` `VERDICT: PASS` again |

Latency (shim fabric timestamps, MAC-client SOF → SOF, §11.7; **not comparable with §12.5**),
1000 exchanges per size, one in flight, board figures from `T 0`:

| payload | board HW UDP echo min / mean / max, stddev | board SW TCP echo min / mean / max, stddev | host RTT UDP mean / p50 / p99 | host RTT TCP mean / p50 / p99 |
|---|---|---|---|---|
| 64 B | 380 / 385.2 / 392 ns, 2.3 ns | 86.3 / 93.1 / 117.2 µs, 3.8 µs | 29.2 / 28.7 / 38.8 µs | 131.6 / 126.8 / 164.3 µs |
| 1472 B (TCP 1460 B) | 712 / 717.8 / 732 ns, 2.8 ns | 484.6 / 501.4 / 555.4 µs, 13.6 µs | 30.3 / 29.5 / 39.6 µs | 650.5 / 654.5 / 743.1 µs |

Bank 1 counted exactly one sample per TCP exchange. The software TCP echo on the 100 MHz
MicroBlaze takes 93.1 µs (64 B) and 501.4 µs (1460 B), against 6.79 µs and 9.70 µs on the A72.

#### 12.8.1 KCU116 on a QSFP28 loopback plug (2026-09-25 19:40–19:54)

Fixture: passive QSFP28 loopback plug in port 0 (host cable removed); v1.3.0 `zircon_boot.mcs`
booted from QSPI after `bench.py power kcu116 cycle` (plug on 19:40:24). Link: `Port 0: link up,
100 Gb/s, FEC RS(528,514)` on the first power-on, no retry, no intermediate link-down line; static
fallback 192.168.20.2 (no DHCP); up for the whole session.

Throughput vs payload, self-loop `L 0` (19:41:36–19:43:29), 16 s per size, pps = mean
generator-TX delta over 9 × 1 s (tables 6–15 s), spread ≤ ±122 pps; totals from the stop
summary. 128 B and 1500 B not run.

| UDP payload | frame incl. FCS | line rate TX = RX | payload rate | pps | errors seq/bit/len | gen TX = chk RX at stop | verdict |
|---|---|---|---|---|---|---|---|
| 64 B | 110 B | 17.33 Gb/s | 8.53 Gb/s | 16,666,658 | 0/0/0 | 268,892,613 | FAIL rate (expected, TX header path 16.67 Mpps) |
| 256 B | 302 B | 42.93 Gb/s | 34.13 Gb/s | 16,666,661 | 0/0/0 | 268,848,842 | FAIL rate (expected) |
| 512 B | 558 B | 77.06 Gb/s | 68.26 Gb/s | 16,666,661 | 0/0/0 | 268,838,799 | FAIL rate (expected) |
| 726 B | 772 B | 100.00 Gb/s | 91.66 Gb/s | 15,783,067 | 0/0/0 | 254,589,833 | PASS |
| 1024 B | 1070 B | 100.00 Gb/s | 93.94 Gb/s | 11,468,070 | 0/0/0 | 184,974,080 | PASS |
| 1472 B | 1518 B | 100.00 Gb/s | 95.71 Gb/s | 8,127,557 | 0/0/0 | 131,116,293 | PASS |
| 9000 B | 9046 B | 100.00 Gb/s | 99.27 Gb/s | 1,378,799 | 0/0/0 | 22,237,117 | PASS |

Same line / payload rates as §12.1 (95.71 vs 95.70 is rounding). pps at ≥ 726 B are ~+15 ppm
above the theoretical 100GBASE-R rate (1472 B: 8,127,557 vs 8,127,438) while 64–512 B are within
0.5 ppm of 300 MHz / 18: the table's time base follows the core clock, the line rate the Si5328
GT refclk, so the 15 ppm is the offset between the two oscillators. After the sweep zircon_nic
RX_FRAMES = TX_FRAMES = 1,399,497,581, drops and STATUS 0.

Echo-through `e` (19:43:56–19:46:37, 31 s each, `T c` before / `T 0` after). One port: gen 0 →
plug → port 0 HW echo (UDP 7) → plug → chk 0. Requests and replies share port 0's TX (round robin
per packet), so each gets half the line; the rate meters count both.

| payload | line / payload Gb/s (all frames) | datagrams/s checked | gen TX / chk RX | errors seq/bit/len | RX_ECHO_DROP | verdict |
|---|---|---|---|---|---|---|
| 64 B | 17.33 / 8.53 | 8,331,416 (gen 8,335,247) | 259,751,123 / 259,631,513 | 119,425/0/0 | 119,610 | FAIL rate (expected); drops = gen − chk exactly (TX header path oversubscribed by requests + replies) |
| 726 B | 100.00 / 91.66 | 7,891,545 | 246,057,344 / 246,057,344 | 0/0/0 | 0 | PASS |
| 1472 B | 100.00 / 95.71 | 4,063,787 | 126,683,970 / 126,683,970 | 0/0/0 | 0 | PASS |
| 9000 B | 100.00 / 99.27 | 689,400 | 21,483,850 / 21,483,850 | 0/0/0 | 0 | PASS |

Latency, bank 0 (shim, MAC-client SOF RX → TX, ns, §11.7; `LAT_STATUS` 0, stale / lost / ovf 0,
0 implausible after every run). Under `e` load the reply queues behind the generator, so these
measure the TX queue, not the path:

| payload | traffic | samples | min | mean | max | stddev |
|---|---|---|---|---|---|---|
| 64 B | `e`, 31 s | 259,631,513 | 6468 | 31,252.0 | 43,964 | 23.8 |
| 726 B | `e`, 31 s | 246,057,344 | 940 | 5909.0 | 5936 | 4.7 |
| 1472 B | `e`, 31 s | 126,683,970 | 1236 | 7510.8 | 7540 | 5.9 |
| 9000 B | `e`, 31 s | 21,483,850 | 4580 | 8943.5 | 8972 | 6.6 |
| 64 B | 1000 paced, 1 ms apart | 1000 | 384 | 384.8 | 388 | 1.6 |
| 726 B | 1000 paced | 1000 | 540 | 545.7 | 552 | 2.8 |
| 1472 B | 1000 paced | 1000 | 716 | 720.1 | 736 | 2.5 |
| 9000 B | 1000 paced | 1000 | 2876 | 2881.5 | 2896 | 2.4 |

Paced rows (19:47:35–19:48:24): generator set over xsdb (MicroBlaze stopped briefly), GEN_DST =
own MAC / 192.168.20.2:7, GEN_SRC_PORT 5001, GEN_COUNT 1000, GEN_GAP 300,000; each 1000/1000
checked, 0 errors. They match the host figures above (385.2 / 717.8 ns) to within 2.3 ns;
1472 → 9000 B slope 0.29 ns/B.

Soak: `e` at 1472 B after `c` and `T c`, 19:48:43–19:53:45 (302 s).

| item | result |
|---|---|
| verdict / rate | `LOOPBACK-ECHO: PASS` at 11 s, no FAIL, no link-down; 100.00 Gb/s line, 95.71 Gb/s payload every table from 2 s |
| gen TX / chk RX | 1,228,045,072 / 1,228,045,072 (1.81 TB payload), 0/0/0 errors |
| CMAC | RX 2,456,090,144 good, 0 bad FCS, 0 error; TX 2,456,090,144 good, 1,228,045,072 TX timestamps; no RS-FEC counters on this target |
| zircon_nic | RX_FRAMES = TX_FRAMES = 2,456,090,144; RX_ECHO = TX_ECHO = 1,228,045,072; bad, fifo, L3/L4 csum, raw / sock / echo drop, TX oversize, STATUS all 0 |
| latency bank 0 | 1,228,045,072 samples, min 1220 / mean 7510.8 / max 7540 ns, stddev 5.3 (queueing, as above); LAT_STATUS 0, stale / lost / ovf 0 |

Jumbo: 9000 B payloads (9046 B frames) pass end to end through the CMAC (`L 0` at line rate,
`e`, paced echoes; 0 errors, 0 drops), so the CMAC's static maximum frame length is ≥ 9046 B
(§1.1). The exact limit was not probed.

## 13. Revision history of `zircon_nic` and the design

| version (VERSION) | date | what changed |
|---|---|---|
| 1.0.0 (0x00010000) | 2026-09-24 | First build: QSFP port 0 only; MRMAC with RS-FEC; UI0 raw, UI1 hardware UDP echo, UI2 hardware UDP socket; header truncation, dispatch, TX metadata builder, the UDP checksum workaround; registers 0x000..0x07C. RX path: `mrmac_rx_axis_adapter` + AMD 48 → 64 B width converter. Linux / Yocto flow removed before release (§1). |
| 1.1.0 (0x00010100) | 2026-09-24 | Review fixes: `mrmac_rx_packer` replaces the RX adapter + width converter (lost beats: frames cut at 48 bytes and merged); per-path drop-when-full RX FIFOs (no head-of-line blocking) with RX_RAW_DROP / RX_SOCK_DROP / RX_ECHO_DROP; frames cut by a MAC-side reset dropped and no stale replay; non-zero Ethernet padding no longer fails the UDP check; `tx_len_guard` and TX_OVERSIZE_DROP (a ≥ 32 KB UI transfer used to wedge TX); STATUS b4 / b5. |
| 1.2.0 (0x00010200) | 2026-09-24 | Second QSFP port (`ports: 2`; port 0's addresses and IRQs unchanged); hardware UDP generator and checker (`GEN_EN`, 0x090..0x0E0), rate meters (0x0E4..0x0FC); two-stage `tx_meta_builder`, 16 cycles per packet instead of 21 (TX capacity 16.7 instead of 14.3 Mpps; 100G line rate from 684 instead of 809 B payloads); `STAT_CLR` also clears GEN_TX_* / CHK_*. Software: both ports, loopback tests `l` / `e` / `L`, auto-start, no automatic FEC fallback. |
| 1.3.0 (0x00010300) | 2026-09-25 | Latency measurement: MRMAC 2-step 1588 timestamping on both ports, 250 MHz `ts_clk` and `ptp_systimer`; `s_axis_mac_rx_tuser` widened to 49 bits (RX timestamp) and new ports `m_axis_tx_ptp`, `tx_ptp_tstamp_*`; ZRXT / ZTXT descriptors on UI0 (off by default: the UI0 formats are unchanged unless LAT_CTRL.RAW_RX_DESC / RAW_TX_DESC are set); `latency_stats` with registers 0x100..0x118 and the 0x200..0x7FF snapshot; TX egress instantiated as its parts. Software: `T` report, UDP 5002 statistics service, TCP echo timestamps, lwIP TCP window 32 KB, per-port address modes (`i`). |

| 1.3.0 (unchanged), kcu116 target | 2026-09-25 | New target `kcu116`: QSFP port 0 on the KCU116 HPC, the KU5P's CMACE4 through Taxi's `taxi_eth_mac_100g_us` (RS-FEC fixed on) behind the new MIT shim `zircon_cmac_us` (VERSION `0x00010000`: fabric timestamps, registers, GT APB window; §6c), block design `bd_microblaze.tcl` (MicroBlaze, DDR4, 256 KB LMB; §6b), `kcu116.xdc`, `cmac_sources.tcl`, `cfgmem.tcl` and the QSPI `.mcs`. `zircon_nic` itself is unchanged. Software: `mac.h` MAC abstraction with the `mrmac.c` / `cmac_taxi.c` backends, `timebase.[ch]`, MicroBlaze console / DMA / cache / linker support; the Versal build is unchanged. xsim: `tb_zircon_cmac_us.sv`. |

Software written for 1.2.0 runs unchanged on 1.3.0 (LAT_CTRL resets to 0, so UI0 carries plain
frames); `echo_server` reads VERSION and enables the latency features only from 1.3.0.

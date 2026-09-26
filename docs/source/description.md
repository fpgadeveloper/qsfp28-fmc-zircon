# Description

**There is no processor in the datapath.** The datagrams that the hardware UDP echo answers,
and the datagrams that the traffic generator sends and the checker verifies, are received,
classified, answered and transmitted by programmable logic and never reach the Versal PS; for
the hardware UDP socket, the headers are also parsed and built in logic. Separately, each port
has two AXI DMAs to the PS: a control-plane and raw path that carries ARP, ICMP, DHCP, the
software TCP echo and the socket payloads, which the PS uses to configure and observe the
design. The design has **two identical 100G
ports**, one for each QSFP28 cage of the card, and each port has its own MAC, its own
`zircon_nic` and its own pair of DMAs.

This page describes the architecture of the design on the VCK190: what the blocks are, how a
frame travels through them, which clocks and widths they use, and how fast they can go. The
KCU116 target uses the same `zircon_nic`; what differs there is described in
[KCU116 target](#kcu116-target) at the end of the page. The full
block-design reference (address map, interrupts, resets, MRMAC settings) is on the
[Hardware design](design.md) page.

## Block diagram

![2x QSFP28 FMC Zircon design block diagram](images/zircon-block-diagram.png)

The shaded region is the hardware datapath. Port 0 is drawn in detail; port 1 is an exact copy
and is drawn compact below it. Received frames are parsed and classified by `zircon_nic`. The
UI1 hardware echo turns round inside `zircon_nic`, and datagrams for the checker (`udp_chk`) end
there, without reaching a DMA or the processor. The generator (`udp_gen`) feeds the transmit
path from inside `zircon_nic` too. The PS on the left is the control plane: it configures the
hardware over `M_AXI_LPD`, and it exchanges only the raw (UI0) and socket (UI2) traffic with
each `zircon_nic`, through that port's two AXI DMAs. The column on the right shows the two
test setups: a QSFP28 loopback cable between the two ports, or a 100G link partner on either
port.

Reading from the wire inwards:

* **2x QSFP28 FMC.** QSFP28 port 0 connects to FMC data pairs DP0-3 and port 1 to DP4-7, which
  land on two GTY quads of the VCK190. The card's **Si5328** clock synthesizer makes the
  322.265625 MHz GT reference clocks of both ports (CKOUT1 → GBTCLK0 for port 0, CKOUT2 → GBTCLK1
  for port 1). Nothing presets it in hardware: software must program it before the transceivers
  can come out of reset (see [Bring-up notes](notes_bringup.md)). Each QSFP module's sideband
  signals (ModSelL, ResetL, LPMode, ModPrsL, IntL) and its management I2C bus are wired to an AXI
  GPIO and an AXI IIC of its own.
* **MRMAC.** Each port uses one Versal Integrated 100G Multirate Ethernet MAC hard block
  (`MRMAC_X0Y0` for port 0, `MRMAC_X0Y2` for port 1), running one 100GBASE-R port (CAUI-4) with
  the **clause 91 RS(528,514) FEC** enabled. It inserts the FCS on transmit and strips it on
  receive, and takes an IEEE 1588 timestamp of received frames and of the transmitted frames
  that ask for one. Its client interface is 384 bits wide ("independent 384b non-segmented") at
  390.625 MHz. One free-running timer (`ptp_systimer`, 250 MHz) feeds both MRMACs, so all
  timestamps share one time base.
* **RX packer, TX adapter and width converter.** On receive, `mrmac_rx_packer` (MIT) packs the
  MRMAC's six 64-bit lanes (48 bytes per beat) into 64-byte AXI4-Stream beats. It accepts a beat
  on every clock cycle, because the MRMAC cannot be slowed down, and it carries the MRMAC's
  "bad frame" flag to the last beat of each frame (`tuser[0]`), which is where the Taxi modules
  expect it, and the frame's receive timestamp on every beat (`tuser[48:1]`). On transmit, an AMD `axis_dwidth_converter` goes from 64 to 48 bytes and
  `mrmac_tx_axis_adapter` (MIT) spreads the stream over the MRMAC's lanes and passes each frame's
  timestamp request to the MRMAC.
* **`zircon_nic_0` and `zircon_nic_1`.** Block-design *module references* that hold the Zircon IP
  stack and Opsero's glue logic, including the traffic generator, the checker, the rate meters
  and the latency measurement. They are described below.
* **Two AXI DMAs per port.** `axi_dma_raw` / `axi_dma_raw_1` carry UI0 (raw frames) and
  `axi_dma_sock` / `axi_dma_sock_1` carry UI2 (socket payloads). All four are scatter-gather DMAs
  with 512-bit streams at 100 MHz, reaching DDR4 through the NoC.
* **CIPS.** The Versal processing system (PS) runs the bare-metal
  [echo server application](echo_server.md). It is the control plane only: it powers the FMC
  (VADJ), programs the Si5328, brings up both MRMACs with RS-FEC, sets the zircon_nic registers,
  and runs lwIP on the raw path of each port for ARP, ICMP, DHCP and a software TCP echo. It also
  supplies and collects the payloads of the UI2 socket demo, runs the loopback tests (it sets up
  the generators and checkers and prints their counters and the measured rates once a second)
  and reports the measured latency.
  It reaches the control registers through `M_AXI_LPD`; port *p*'s registers are at
  `0x8000_0000 + p × 0x10_0000` (see the [address map](design.md#address-map-cips-m_axi_lpd)).

## Inside `zircon_nic`

`zircon_nic` is a Verilog shell (`Vivado/src/hdl/zircon_nic.v`) around the SystemVerilog core
(`zircon_nic_core.sv`). The core instantiates the Zircon and Taxi modules unmodified from
`submodules/taxi` and adds the missing pieces. The contract between the blocks is
`docs/DESIGN_SPEC.md` in the repository.

### Receive path

```
MAC RX (512 b, 390.625 MHz)
  → MAC-side frame FIFO (async, 32 KB): drops frames with a MAC error, and drops
    whole frames when full. It never back-pressures the MAC.
  → broadcast, two branches in lockstep (core clock, 300 MHz):
      [A] length / ones'-complement checksum of the whole frame (zircon_ip_len_cksum)
          → store-and-forward packet FIFO
      [B] header truncator (first 64 bytes only) → 512→32-bit adapter
          → Zircon header parser (zircon_ip_rx_parse) → one compact header record per packet
  → rx_dispatch: waits for the frame and both of its records, classifies, then moves the frame:
      ECHO  → the 42-byte header is removed, the payload → echo FIFO → TX payload buffer (UI1)
      SOCK  → 64-byte descriptor + payload → socket FIFO → UI2 → axi_dma_sock
      CHK   → the 42-byte header is removed, the payload → udp_chk (never back-pressures)
      RAW   → the unmodified frame (optionally behind a 64-byte ZRXT descriptor that carries
              its receive timestamp) → raw FIFO → UI0 → axi_dma_raw
```

Each path has its own 32 KB FIFO, so one slow consumer cannot hold up the others. If software
does not take UI0 or UI2 frames in time, the frames that no longer fit are dropped and counted
(`RX_RAW_DROP`, `RX_SOCK_DROP`) while the hardware echo keeps answering; if the transmit side is
busy, echo requests are dropped and counted (`RX_ECHO_DROP`) while UI0 and UI2 keep receiving.

A frame goes to **ECHO**, **SOCK** or **CHK** only if all of the following are true:

* it is an IPv4 UDP datagram with no VLAN tag, no IP options and no fragmentation;
* it is addressed to the local MAC and the local IPv4 address;
* its IPv4 header checksum is good;
* its UDP checksum is good, or is zero ("no checksum");
* its UDP payload is not empty;
* its destination port is `ECHO_PORT`, `SOCK_LOCAL_PORT` or `CHK_PORT`, and the matching enable
  bit is set (the echo and the socket take precedence if a port number is shared).

Everything else is **RAW**. That includes ARP, ICMP, TCP, broadcasts and UDP to any other port,
so the control-plane lwIP stack on the PS still sees a normal network interface: it answers ARP
requests (which the hardware echo and socket depend on, since link partners must resolve the
board's MAC address), replies to pings and obtains the DHCP lease.

The UDP checksum is verified without reading the payload twice. The parser produces the sum that
the frame *must* have if the checksum is right. Branch A measures the sum the frame actually has.
The dispatcher compares the two, after taking out the Ethernet padding of short frames (some
senders pad with non-zero bytes). The padding is also trimmed off, so it is never echoed or
delivered to the socket.

### Transmit path

```
UI0 raw   (100 MHz) → length guard → ZTXT strip ─┐
UI1 echo  (300 MHz) → echo FIFO ─────────────────┤
UI2 socket(100 MHz) → length guard ──────────────┼→ zircon_ip_tx_buffer (32 KB payload RAM;
UI3 gen   (300 MHz) → udp_gen ───────────────────┘   length + checksum of each payload;
                                                     round robin per packet)
   → tx_meta_builder: builds Zircon's 128-byte header metadata for each packet
        raw    : "no header", the frame passes through unchanged
        echo   : destination = the sender of the received datagram, source = local MAC/IP/port
        socket : destination = SOCK_REMOTE_MAC/IP/PORT registers, source = local MAC/IP/port
        gen    : destination = GEN_DST_MAC/IP/PORT registers, source = local MAC/IP, GEN_SRC_PORT
   → Zircon header deparser (Ethernet + IPv4 + UDP, both checksums), header/payload
     concatenation, MAC-side frame FIFO (390.625 MHz); each frame carries its latency record
   → tx_mac_out: TX enable gate, pad to 60 bytes (the MRMAC adds the FCS), counters
   → ptp_tx_tagger: timestamp request to the MRMAC, latency of the returned timestamp
   → MAC TX
```

The payload buffer has to hold a complete payload before its header can be built, because the
UDP checksum depends on the payload, so a frame of 32 KB or more would stall it for good. The
**length guards** in front of it therefore drop any UI0 frame or UI2 payload **longer than
9618 bytes** and count it (`TX_OVERSIZE_DROP`). That is above the 9000-byte jumbo MTU that the
software supports, so the software in this repository never gets near it.

### Traffic generator, checker and rate meters

These three blocks let the design test itself at line rate, with no 100G host. They are part of Opsero's MIT glue; the full definition is in the
[register map](registers.md#traffic-generator-120).

* **Generator (`udp_gen`).** Produces UDP payloads at one 64-byte beat per core clock cycle and
  hands them to the transmit payload buffer as a fourth source (UI3). The hardware builds the
  headers from the `GEN_DST_*` registers, exactly as it does for the socket. Each payload starts
  with a 64-bit sequence number, followed by a pseudo-random pattern that is a function of that
  number only: eight independent 64-bit xorshift generators, one per 8-byte lane, seeded from
  the sequence number and stepped once per beat. The generator needs no memory and no
  multiplier, and software can reproduce any payload (a Python reference is in the register map).
  It sends a given number of datagrams or runs until stopped, with a programmable length (8 to
  9000 bytes) and an optional gap between datagrams, and always finishes the datagram in
  progress when stopped.
* **Checker (`udp_chk`).** Receives the datagrams that the dispatcher's CHK rule sends it (UDP
  port `CHK_PORT`, default 5001, with good checksums) at one beat per cycle and never
  back-pressures. It re-seeds the pattern from the sequence number of every datagram and counts
  the differing payload bits (`CHK_BIT_ERR`), counts each break in the sequence once
  (`CHK_SEQ_ERR`: a lost, duplicated or reordered datagram), and counts datagrams too short to
  hold a sequence number (`CHK_LEN_ERR`). Because it re-seeds from every datagram, one lost
  datagram gives exactly one sequence error and no bit errors.
* **Rate meters (`rate_meter`).** Every second (300,000,000 core clock cycles) they latch how many
  frames and bytes the port received and sent in that second, all in the same cycle. Software
  converts them to line rate: 8 × (bytes + 24 × frames) per second, adding the FCS, preamble and
  inter-packet gap that the meters do not see. They count all traffic, not just the generator's.

With a loopback cable between the two ports, each generator addresses the other port's MAC and
IPv4 address, and each checker verifies the other port's traffic: a 100 Gb/s stream in each
direction of the cable at the same time, entirely in hardware. The echo server can also send port 0's generator through
port 1's hardware UDP echo and back to port 0's checker, which exercises the complete receive
and transmit header path at line rate (see [Loopback test](echo_server.md#loopback-test)).

### Latency measurement

Each `zircon_nic` measures how long the frames it answers spend in the board, from the MRMAC's
IEEE 1588 two-step timestamps: **latency = TX timestamp of the reply − RX timestamp of the
request**. The MRMAC takes both at the first PCS block of the frame, so the figure covers every
buffer between the receive and the transmit PCS and excludes the serdes, PCS and RS-FEC delays.
The full definition is in the [register map](registers.md#latency-measurement-130).

* **Receive.** The RX packer attaches the MRMAC's receive timestamp to every beat of the frame,
  so the timestamp travels with the frame through every FIFO and is dropped with it. The
  dispatcher keeps it with each echo request, and can put it in a 64-byte `ZRXT` descriptor in
  front of every frame on UI0.
* **Transmit.** Every hardware echo reply asks the MRMAC for a transmit timestamp. Software can
  ask for one too: a UI0 frame sent behind a 64-byte `ZTXT` descriptor that carries the request's
  receive timestamp is timestamped and counted in a second bank. The echo server's TCP echo does
  this, which measures the software path through the processor with the same clock.
  `ptp_tx_tagger` tags each timestamped frame, matches the returned timestamp to it and computes
  the difference in ns.
* **Statistics (`latency_stats`).** Two banks (0: hardware echo, 1: software): count, sum, sum of
  squares, minimum, maximum, last value, results of 1 s or more (discarded as implausible) and a
  64-bin histogram (48 linear bins of a programmable width, then 15 bins that each double, then
  an overflow bin). Software takes a coherent snapshot of both banks and reads it at leisure.

## Clocks and widths

| Domain | Clock | Width | Blocks |
|--------|-------|-------|--------|
| MRMAC client | 390.625 MHz (`axis_clk_wiz`) | 384 bits | MRMAC AXIS, `mrmac_rx_packer`, `mrmac_tx_axis_adapter` |
| MAC side of zircon_nic | 390.625 MHz | 512 bits | RX packer, TX width converter, MAC-side FIFOs of zircon_nic, `ptp_tx_tagger` |
| zircon_nic core | 300 MHz (`clk_wizard_0`) | 512 bits (32 bits in the parser and deparser) | all Zircon modules and the glue, including the generator, checker, rate meters and latency statistics |
| UI / DMA / control | 100 MHz (`clk_wizard_0`) | 512-bit streams, 32-bit AXI-Lite | all four AXI DMAs, AXI-Lite registers |
| 1588 timestamp | 250 MHz (`clk_wizard_0`) | 55-bit timer | `ptp_systimer`, the MRMACs' timestamp clock |

All these clocks are made from the CIPS `pl0_ref_clk` and are shared by both ports. The GT user
clocks (644.53 / 322.27 MHz) are separate for each port and only drive that port's MRMAC and
transceivers.

### Why 512 bits at 300 MHz

* **Zircon needs a power-of-two width.** Its length/checksum module (`zircon_ip_len_cksum`) uses
  an adder tree that works only with a power-of-two number of byte lanes. Taxi's width adapter
  needs an integer ratio between widths. The MRMAC's 384-bit (48-byte) client width meets neither
  requirement, so the RX packer (and on transmit an AMD width converter) goes between 48 and 64
  bytes outside Zircon.
* **Enough bandwidth.** 512 bits at 300 MHz is 153.6 Gb/s of bus capacity, 1.5 times the 100 Gb/s
  line rate. That leaves room for the idle cycles the per-packet processing costs.
* **Timing.** The Zircon parser and deparser contain large single-cycle logic cones. 300 MHz is a
  comfortable target for them on the XCVC1902. At 390.625 MHz, the MAC clock, they would be hard
  to close.

## Throughput

Two limits decide how fast each path can go: how many packets per second the header path
handles, and how many bytes per second the DMAs move. The figures below are for one port; the
two ports are independent.

**Packets per second in the header path.** The Zircon parser and deparser work 32 bits at a
time, so each packet costs a fixed number of core clock cycles (300 MHz) whatever its size.
These costs were measured in simulation (test 70 of the `zircon_nic` testbench, a sweep of
payload sizes through the generator, the transmit path, a 100G MAC model and the checker):

| Side | Core cycles per packet | Limit |
|------|------------------------|-------|
| Transmit (header build) | max(18, ⌈F/64⌉ + 1), where F = frame bytes = payload + 42 | 16.7 million packets per second: 16 cycles of header metadata in `tx_meta_builder`, plus the deparser |
| Receive (parse + dispatch) | max(16, 6 + ⌈F/64⌉ + f), where f = 1 when the payload tail needs an extra flush beat, else 0 | 18.75 million packets per second: the parser reads the 64-byte truncated header at 4 bytes per clock; above that, `rx_dispatch` needs 6 cycles to classify plus one per beat |

A 100 Gb/s link carries one frame every (F + 24) × 8 bits, which is (F + 24) × 0.024 core
cycles (the 24 bytes are the FCS, preamble and inter-packet gap). Transmit keeps up for UDP
payloads of **684 bytes** and more, receive for **726 bytes** and more. So:

* **With UDP payloads of 726 bytes or more, every hardware path runs at the full 100 Gb/s line
  rate**: the generator → cable → checker loopback, and the hardware echo (receive, then
  transmit). At the default 1472-byte payload, transmit has 48 % headroom and receive 23 %. On
  the bench, 1472-byte datagrams ran at 8.13 million packets per second, which is 100.00 Gb/s
  line rate, in both directions with no loss (see [Measured throughput](#measured-throughput)).
* **With smaller payloads, the packet rate is the limit.** On the bench, the generator's
  transmit path sent 16.67 million packets per second at every payload size from 64 to 512
  bytes (77.06 Gb/s line rate at 512 bytes), and the receiving port checked all of them with no
  loss. The receive side is designed for up to 18.75 million packets per second. When frames from another
  source arrive faster than that, excess frames are dropped whole at the MAC-side FIFO and
  counted in `RX_FIFO_DROP` (with `STATUS.RX_FIFO_OVF` set); the checker sees them as
  `CHK_SEQ_ERR`. They are never truncated or corrupted. For comparison, minimum-size 64-byte frames at 100 Gb/s arrive at
  148.8 million packets per second, far beyond any design that treats each packet individually
  at this clock rate.
* **Jumbo payloads** (up to 9000 bytes) are far from both limits.

Before the header truncator was added, the parser would have had to consume every frame at
4 bytes per clock (about 10 Gb/s at 300 MHz). Zircon's own `zircon_ip_rx_ingress` wrapper works
that way, which is why the design builds its own receive front end from the Zircon modules.

**Bytes per second in the DMAs.** Each AXI DMA moves 512 bits per 100 MHz clock, which is
51.2 Gb/s per direction. The raw path (UI0) and the socket path (UI2) therefore cannot reach
100 Gb/s. The raw path is the control plane and is not meant to carry bulk traffic; in practice lwIP
running on one Cortex-A72 core limits it to much less than that.
The **hardware echo** (UI1) and the **generator and checker** do not go through a DMA or the PS
at all, so they are the paths that show what the Zircon datapath itself can do.

| Path (per port) | Theoretical limit | Measured |
|------|-------------------|----------|
| Receive parse / classify | line rate for payloads ≥ 726 B; 18.75 Mpps otherwise | bench: 100.00 Gb/s at 726 to 9000 B; 16.67 Mpps with no loss at 64 to 512 B (the most the generator sends) |
| Transmit header build | line rate for payloads ≥ 684 B; 16.7 Mpps otherwise | bench: 100.00 Gb/s at 726 to 9000 B; 16.67 Mpps at 64 to 512 B |
| Generator → loopback cable → checker | line rate for payloads ≥ 726 B | bench: see [Measured throughput](#measured-throughput) |
| UI1 hardware echo | the lower of the receive and transmit limits: line rate for payloads ≥ 726 B | bench: 100.00 Gb/s at 1472 B and 9000 B, zero loss |
| UI0 raw / control plane (DMA) | 51.2 Gb/s per direction (DMA), in practice limited by lwIP | not measured |
| UI2 socket (DMA) | 51.2 Gb/s per direction (DMA) | not measured |

### Measured throughput

Measured on the VCK190 (2026-09-25, booted from the SD card): the cross-port loopback test
(port 0 ↔ port 1, optical QSFP28 cable, both directions at once), for each UDP payload size. The
values are the same on both ports and in both directions. The UART output and the method are in
[Testing](testing.md#throughput-vs-payload-size-v130-port-0--port-1-optical-loopback).

| UDP payload | Line rate | UDP payload rate | Packets per second | Errors (seq / bit / len) |
|---|---|---|---|---|
| 64 B | 17.33 Gb/s | 8.53 Gb/s | 16,666,499 | 0 / 0 / 0 |
| 128 B | 25.86 Gb/s | 17.06 Gb/s | 16,666,498 | 0 / 0 / 0 |
| 256 B | 42.93 Gb/s | 34.13 Gb/s | 16,666,499 | 0 / 0 / 0 |
| 512 B | 77.06 Gb/s | 68.26 Gb/s | 16,666,499 | 0 / 0 / 0 |
| 726 B | 100.00 Gb/s | 91.66 Gb/s | 15,782,812 | 0 / 0 / 0 |
| 1024 B | 100.00 Gb/s | 93.94 Gb/s | 11,467,878 | 0 / 0 / 0 |
| 1472 B (default) | 100.00 Gb/s | 95.70 Gb/s | 8,127,432 | 0 / 0 / 0 |
| 1500 B | 100.00 Gb/s | 95.78 Gb/s | 7,982,114 | 0 / 0 / 0 |
| 9000 B (jumbo) | 100.00 Gb/s | 99.27 Gb/s | 1,378,777 | 0 / 0 / 0 |

Line rate includes the FCS, preamble and inter-packet gap; 100 Gb/s is the maximum.

A raw frame sent by the PS holds the transmit arbiter for the whole frame at the 100 MHz
UI rate. The echo and generator paths wait during that time, and the receive packet FIFO absorbs
the delay.

## What Zircon provides, and what the glue adds

At the pinned commit (Taxi `cc70b27`), Zircon is **a set of building blocks, not a complete
stack**. It has no top level, no configuration registers, no rules engine and no ARP or ICMP.
Its README describes features, such as rule matching and payload-only delivery, that are still
planned upstream. The upstream testbenches cover the parser, the deparser and the
length/checksum module individually, not the wrappers or any composed datapath.

| Function | Provided by |
|----------|-------------|
| Header parser: Ethernet / VLAN / IPv4 / IPv6 / TCP / UDP fields, IPv4 header checksum check, the sum used to verify the L4 checksum | Zircon `zircon_ip_rx_parse` |
| Header deparser: Ethernet / IPv4 / UDP header with length and checksum insertion | Zircon `zircon_ip_tx_deparse` (in `zircon_ip_tx_egress`) |
| Length and ones'-complement checksum of a packet stream | Zircon `zircon_ip_len_cksum` |
| Clock-domain crossing to and from the UI clock, TX payload buffer and arbiter, MAC-side TX frame FIFO | Zircon `zircon_ip_rx_egress`, `zircon_ip_tx_ingress`, `zircon_ip_tx_buffer`, and the parts of `zircon_ip_tx_egress` (instantiated individually so that each frame can carry its latency record) |
| AXI-Stream FIFOs, width adapter, broadcast, synchronizers | Taxi `taxi_axis_*`, `taxi_sync_*` |
| Header truncation for a line-rate parser branch | MIT glue: `hdr_trunc.sv` |
| Joining each frame with its two metadata records, rule matching (MAC / IP / port / checksums), three-way dispatch, header strip, socket descriptor | MIT glue: `rx_meta_capture.sv`, `rx_dispatch.sv` |
| TX header metadata per source (raw / echo / socket), IPv4 identification counter, UDP checksum workaround | MIT glue: `tx_meta_builder.sv` |
| TX enable gate, short-frame padding, statistics | MIT glue: `tx_mac_out.sv` |
| Hardware UDP traffic generator with sequence number and pseudo-random payload | MIT glue: `udp_gen.sv` (headers built by `tx_meta_builder.sv` and the Zircon deparser) |
| Hardware UDP checker: sequence, bit-error and length checks | MIT glue: `udp_chk.sv` (fed by the CHK rule of `rx_dispatch.sv`) |
| Per-second receive and transmit rate meters | MIT glue: `rate_meter.sv` |
| Latency measurement: shared 1588 timer, receive timestamps with the frames, `ZRXT` / `ZTXT` descriptors, timestamp requests and matching, statistics and histograms | MIT glue: `ptp_systimer.v`, `mrmac_rx_packer.v`, `mrmac_axis_adapter.v`, `rx_dispatch.sv`, `raw_tx_desc_strip.sv`, `ptp_tx_tagger.sv`, `latency_stats.sv` |
| Register file, counters, safe clock-domain crossing of counter snapshots | MIT glue: `zircon_regs.sv`, `zircon_cdc_snapshot.sv` |
| ARP, ICMP, DHCP, TCP (control plane) | Software: lwIP in the bare-metal application, over UI0 |

### The UDP checksum workaround

At commit `cc70b27`, the Zircon deparser adds up the UDP checksum in a 21-bit register and folds
the carry back into 16 bits **only once**. When that single fold produces another carry, the
checksum it emits is one too small. This happens for about 1 packet in 65536 whenever the header
part of the sum exceeds 0xFFFF, which is common for replies to high ("ephemeral") source ports.
The receiving host silently drops such a packet as corrupted.

The glue works around it without modifying Zircon. `tx_meta_builder` computes the correct
checksum itself and gives the deparser an adjusted payload sum, chosen so that the deparser's
single fold lands exactly on the right value. For the very rare combinations where no adjusted
value can produce it (about 1 in 10<sup>9</sup>), the packet is sent with a UDP checksum of zero,
which IPv4 defines as "no checksum". The simulation testbench reproduces the original error
and checks the fix. The arithmetic takes 4 clock cycles per hardware-built packet, in a stage
that overlaps the previous packet's output, so it does not reduce the packet rate. The issue is
worth reporting upstream; once Zircon fixes it, the workaround can be removed.

## Software

The design is **bare-metal only**; there is no Linux image. The PS runs one Vitis application,
the [echo server](echo_server.md):

| Role | What it does |
|------|--------------|
| Bring-up | VADJ 1.5 V, Si5328 at 322.265625 MHz (both outputs); for each port: GT reset, MRMAC with RS-FEC, zircon_nic registers |
| Control plane (UI0) | lwIP on each port: ARP, ICMP, DHCP client with a static fallback (or static / DHCP only, per port), and a software TCP echo on port 7 for comparison with the hardware echo |
| Socket demo (UI2) | Receives payloads with their descriptors and sends them back through the socket; the hardware builds the headers |
| Loopback tests | Sets up the generators and checkers (cross-port, through port 1's hardware echo, or one port on a loopback plug), prints a table of counters and measured rates every second and a `LOOPBACK: PASS` / `FAIL` verdict; the cross-port test starts by itself when the two ports are cabled together |
| Latency | Enables the timestamps and descriptors, lets the TCP echo request transmit timestamps, prints the statistics of both banks (`T`) and serves them on UDP port 5002 |
| Monitoring | Link, FEC and zircon_nic counters on the UART, console keys |

The hardware UDP echo (UI1) needs no software at all once the registers are set, and the
generator and checker need software only to start them and to read their counters.

## KCU116 target

The `kcu116` target runs the same design on the Kintex UltraScale+ KCU116, with the 2x QSFP28 FMC
on the board's HPC connector. That connector wires the transceiver lanes of **one QSFP28 port
(port 0)**, so the design has one 100G port. What stays the same: `zircon_nic` (the same RTL,
version 1.3.0, the same [registers](registers.md)), the 300 MHz core clock and therefore the
same [throughput limits](#throughput), the hardware UDP echo, socket, generator, checker, rate
meters and latency statistics, the bare-metal application and its console, and the host test
scripts. What differs:

* **MAC.** The XCKU5P has an integrated 100G Ethernet MAC (CMAC) with RS-FEC, which the design
  uses through the Taxi library's own 100G CMAC wrapper (`taxi_eth_mac_100g_us`, unmodified). A
  small Opsero MIT shim, `zircon_cmac_us`, connects it to `zircon_nic`. The CMAC's client
  interface is already 512 bits wide, so there is no RX packer or TX width converter, and the MAC
  side of `zircon_nic` runs on the CMAC's own 322.27 MHz clocks.
* **RS-FEC is fixed on** in the Taxi wrapper, so the link partner must use RS-FEC (a partner in
  FEC "auto" does), and there are no FEC codeword counters.
* **Latency timestamps** are taken in the shim, at the CMAC's client interface, because the Taxi
  wrapper provides none. They are quantised to 4 ns and exclude the CMAC's own pipeline, so the
  KCU116 latency figures cannot be compared directly with the VCK190's (see
  [KCU116 timestamps](design.md#timestamps-on-the-kcu116)).
* **Processor.** A MicroBlaze soft processor at 100 MHz, with 32 KB caches, 256 KB of on-chip
  local memory for the application and 1 GB of DDR4 for the lwIP buffers and DMA rings. It is
  the control plane, exactly as the Versal PS is on the VCK190, but it is much slower: the
  software TCP echo takes about 0.1 to 0.5 ms instead of 7 to 10 µs. The hardware paths do not
  depend on it.
* **Boot.** The application is embedded in the bitstream (`zircon_boot.bit`), which is loaded
  over JTAG or programmed into the KCU116's QSPI flash (`zircon_boot.mcs`) so that the board
  boots the design at power-on. See [Build instructions](build_instructions.md#kcu116-bitstream-and-qspi-flash).
* **Testing.** With one port there is no cross-port loopback test. The KCU116 is tested with a
  100G host (`scripts/zircon_echo_test.py`, `scripts/zircon_prbs_tool.py`), or with a QSFP28
  loopback plug in port 0 (`L 0`: 100 Gb/s line rate from 726-byte payloads up, 9000-byte jumbo
  payloads included, no errors). Results:
  [Testing](testing.md#kcu116-port-0-microblaze-v130).

The block design, address map and shim registers are on the
[Hardware design](design.md#kcu116-block-design) page.

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/

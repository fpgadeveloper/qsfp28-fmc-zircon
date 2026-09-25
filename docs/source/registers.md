# Register map

`zircon_nic_0` (port 0) has a 4 KB AXI4-Lite register window at **`0x800A_0000`** on the CIPS
`M_AXI_LPD` bus, and `zircon_nic_1` (port 1) the same window at **`0x801A_0000`**. The registers are 32 bits wide, little-endian, and addressed by byte offset. This page
documents version **1.3.0** of the block (`VERSION` = `0x00010300`). The register file is
implemented in `Vivado/src/hdl/zircon_regs.sv`. The contract it implements is §3.3 and §5 of
`docs/DESIGN_SPEC.md`.

The bare-metal driver for these registers is `Vitis/common/src/zircon.c`. The echo server's `z`
console key dumps them (see [console keys](echo_server.md#console-keys)).

## Summary

| Offset | Name | Access | Reset value | Description |
|--------|------|--------|-------------|-------------|
| `0x000` | `ID` | R | `0x5A495243` | Block identifier, ASCII "ZIRC" |
| `0x004` | `VERSION` | R | `0x00010300` | major.minor.patch in bits 23:16 / 15:8 / 7:0 (1.3.0; 1.2.0 was `0x00010200`, 1.1.0 `0x00010100`, 1.0.0 `0x00010000`) |
| `0x008` | `CTRL` | RW | `0x00000000` | Datapath enables, counter clear |
| `0x00C` | `STATUS` | R / W1C | `0x00000000` | Sticky error flags |
| `0x010` | `MAC_LO` | RW | `0` | Local MAC address, bytes 0-3 |
| `0x014` | `MAC_HI` | RW | `0` | Local MAC address, bytes 4-5 |
| `0x018` | `IPV4` | RW | `0` | Local IPv4 address |
| `0x01C` | `ECHO_PORT` | RW | `7` | UDP port of the hardware echo |
| `0x020` | `SOCK_LOCAL_PORT` | RW | `0` | Local UDP port of the hardware socket |
| `0x024` | `SOCK_REMOTE_PORT` | RW | `0` | Remote UDP port of the hardware socket |
| `0x028` | `SOCK_REMOTE_IP` | RW | `0` | Remote IPv4 address of the hardware socket |
| `0x02C` | `SOCK_REMOTE_MAC_LO` | RW | `0` | Remote MAC address, bytes 0-3 |
| `0x030` | `SOCK_REMOTE_MAC_HI` | RW | `0` | Remote MAC address, bytes 4-5 |
| `0x034` | `TTL` | RW | `64` | TTL of hardware-built IPv4 headers |
| `0x040` | `RX_FRAMES` | R | `0` | Frames that entered the core |
| `0x044` | `RX_BYTES_LO` | R | `0` | Received bytes, bits 31:0 |
| `0x048` | `RX_BYTES_HI` | R | `0` | Received bytes, bits 63:32 |
| `0x04C` | `RX_BAD_FRAME` | R | `0` | Frames dropped for a MAC error or cut by a MAC-side reset |
| `0x050` | `RX_FIFO_DROP` | R | `0` | Frames dropped for lack of space, size, or RX disabled |
| `0x054` | `RX_L3_BAD_CSUM` | R | `0` | IPv4 header checksum failures |
| `0x058` | `RX_L4_BAD_CSUM` | R | `0` | UDP checksum failures |
| `0x05C` | `RX_RAW` | R | `0` | Frames delivered to UI0 |
| `0x060` | `RX_ECHO` | R | `0` | Datagrams echoed by the hardware |
| `0x064` | `RX_SOCK` | R | `0` | Datagrams delivered to UI2 |
| `0x068` | `TX_FRAMES` | R | `0` | Frames handed to the MAC |
| `0x06C` | `TX_BYTES_LO` | R | `0` | Transmitted bytes, bits 31:0 |
| `0x070` | `TX_BYTES_HI` | R | `0` | Transmitted bytes, bits 63:32 |
| `0x074` | `TX_RAW` | R | `0` | Frames sent from UI0 |
| `0x078` | `TX_ECHO` | R | `0` | Echo replies built by the hardware |
| `0x07C` | `TX_SOCK` | R | `0` | Socket datagrams built by the hardware |
| `0x080` | `RX_RAW_DROP` | R | `0` | UI0 frames dropped because the raw receive FIFO was full (1.1.0) |
| `0x084` | `RX_SOCK_DROP` | R | `0` | UI2 datagrams dropped because the socket receive FIFO was full (1.1.0) |
| `0x088` | `RX_ECHO_DROP` | R | `0` | Echo requests dropped because the transmit side had no room (1.1.0) |
| `0x08C` | `TX_OVERSIZE_DROP` | R | `0` | UI0 / UI2 transmit transfers longer than 9618 bytes, dropped (1.1.0) |
| `0x090` | `GEN_CTRL` | RW | `0` | Traffic generator control and status (1.2.0) |
| `0x094` | `GEN_LEN` | RW | `1472` | Generated UDP payload length in bytes (8 to 9000) |
| `0x098` | `GEN_COUNT` | RW | `0` | Datagrams per run when not continuous |
| `0x09C` | `GEN_GAP` | RW | `0` | Idle core-clock cycles after every generated datagram |
| `0x0A0` | `GEN_DST_MAC_LO` | RW | `0` | Destination MAC address of generated datagrams, bytes 0-3 |
| `0x0A4` | `GEN_DST_MAC_HI` | RW | `0` | Destination MAC address, bytes 4-5 |
| `0x0A8` | `GEN_DST_IP` | RW | `0` | Destination IPv4 address of generated datagrams |
| `0x0AC` | `GEN_DST_PORT` | RW | `0` | Destination UDP port of generated datagrams |
| `0x0B0` | `GEN_SRC_PORT` | RW | `0` | Source UDP port of generated datagrams |
| `0x0B4` | `GEN_TX_PKTS` | R | `0` | Datagrams generated |
| `0x0B8` | `GEN_TX_BYTES_LO` | R | `0` | Generated payload bytes, bits 31:0 |
| `0x0BC` | `GEN_TX_BYTES_HI` | R | `0` | Generated payload bytes, bits 63:32 |
| `0x0C0` | `CHK_CTRL` | RW | `0` | Checker control and status (1.2.0) |
| `0x0C4` | `CHK_PORT` | RW | `5001` | UDP destination port the checker claims |
| `0x0C8` | `CHK_RX_PKTS` | R | `0` | Datagrams checked |
| `0x0CC` | `CHK_RX_BYTES_LO` | R | `0` | Checked payload bytes, bits 31:0 |
| `0x0D0` | `CHK_RX_BYTES_HI` | R | `0` | Checked payload bytes, bits 63:32 |
| `0x0D4` | `CHK_SEQ_ERR` | R | `0` | Sequence-number discontinuities (lost or reordered datagrams) |
| `0x0D8` | `CHK_BIT_ERR_LO` | R | `0` | Payload bit errors, bits 31:0 |
| `0x0DC` | `CHK_BIT_ERR_HI` | R | `0` | Payload bit errors, bits 63:32 |
| `0x0E0` | `CHK_LEN_ERR` | R | `0` | Datagrams to `CHK_PORT` with less than 8 bytes of payload |
| `0x0E4` | `RATE_SEQ` | R | `0` | Rate-meter windows completed; reading it latches the six registers below (1.2.0) |
| `0x0E8` | `RX_RATE_BYTES_LO` | R | `0` | Received bytes in the last window, bits 31:0 |
| `0x0EC` | `RX_RATE_BYTES_HI` | R | `0` | Received bytes in the last window, bits 63:32 |
| `0x0F0` | `RX_RATE_PKTS` | R | `0` | Received frames in the last window |
| `0x0F4` | `TX_RATE_BYTES_LO` | R | `0` | Transmitted bytes in the last window, bits 31:0 |
| `0x0F8` | `TX_RATE_BYTES_HI` | R | `0` | Transmitted bytes in the last window, bits 63:32 |
| `0x0FC` | `TX_RATE_PKTS` | R | `0` | Transmitted frames in the last window |
| `0x100` | `LAT_CTRL` | RW | `0` | Latency measurement enables and commands (1.3.0) |
| `0x104` | `LAT_STATUS` | R / W1C | `0` | Sticky latency error flags |
| `0x108` | `LAT_BIN_BASE` | RW | `0` | Lower edge of the linear histogram bins, ns |
| `0x10C` | `LAT_BIN_WIDTH` | RW | `64` | Width of the linear histogram bins, ns (a power of two) |
| `0x110` | `LAT_STALE_CNT` | R | `0` | TX timestamps that matched no pending frame |
| `0x114` | `LAT_LOST_CNT` | R | `0` | Timestamped frames whose TX timestamp never came back |
| `0x118` | `LAT_OVF_CNT` | R | `0` | Latency samples lost because the statistics FIFO was full |
| `0x200`-`0x27F` | `LAT_BANK0/1` | R | `0` | Snapshot of the statistics of bank 0 (`0x200`) and bank 1 (`0x240`) |
| `0x400`-`0x7FF` | `LAT_HIST0/1` | R | `0` | Snapshot of the 64-bin histograms of bank 0 (`0x400`) and bank 1 (`0x600`) |

Reads of undefined offsets return 0, and writes to them are ignored. A build of the block
without the generator and checker (parameter `GEN_EN` = 0) reads 0 at `0x090`-`0x0E0` and
ignores writes there; software can test for the generator by reading `GEN_LEN` (non-zero when
present). The rate meters (`0x0E4`-`0x0FC`) and the latency measurement (`0x100`-`0x7FF`) are
always present.

## Control and status

### `CTRL` (0x008)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `RX_EN` | Receive enable. While 0, every received frame is consumed and dropped at the dispatcher (counted in `RX_FRAMES` and `RX_FIFO_DROP`). |
| 1 | `TX_EN` | Transmit enable. Sampled at the start of each frame on the MAC side. A frame that starts while TX is disabled is discarded whole, so nothing upstream stalls. |
| 2 | `ECHO_EN` | Enables the hardware UDP echo rule (UI1). |
| 3 | `SOCK_EN` | Enables the hardware UDP socket rule (UI2). |
| 4 | `PROMISC` | Reserved, no effect. Frames for other MAC addresses always go to UI0. |
| 31 | `STAT_CLR` | Write 1 to zero every counter in every clock domain. Reads as 0. |

`CTRL` resets to 0: the whole datapath, including the raw path, stays closed until software has
programmed the addresses and enabled it.

### `STATUS` (0x00C)

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | `RX_FIFO_OVF` | W1C, sticky | The MAC-side receive FIFO dropped a frame because it was full. Expected under a flood of small frames (see [throughput](description.md#throughput)). |
| 1 | `TX_UNDERRUN` | R | Always 0. The MAC-side transmit FIFO is a frame FIFO, so it cannot underrun. |
| 2 | `RX_META_ERR` | R, sticky until reset | An internal receive metadata FIFO overflowed. Must never be set; if it is, please report it. |
| 3 | `TX_META_ERR` | R, sticky until reset | An internal transmit metadata FIFO overflowed. Must never be set. |
| 4 | `RX_PACK_STALL` | W1C, sticky | The MRMAC receive packer (`mrmac_rx_packer`) saw its output back-pressured. Only expected while the MAC-side receive FIFO is in reset (link down/up). |
| 5 | `RX_PACK_OVF` | W1C, sticky | The MRMAC receive packer had to drop beats. The frames concerned were delivered marked bad and dropped (counted in `RX_BAD_FRAME`). Must not be set in normal operation; please report it. |

Write 1 to a W1C bit to clear it (for example `0x31` clears bits 0, 4 and 5).

## Addresses and ports

All addresses are stored so that the **first byte on the wire is in the lowest bits** for MAC
addresses, and so that the IPv4 address reads naturally as a 32-bit number:

| Register | Format | Example |
|----------|--------|---------|
| `MAC_LO`, `SOCK_REMOTE_MAC_LO` | MAC bytes 0-3; byte 0 (first on the wire) in bits 7:0 | `00:0a:35:06:21:a0` → `0x06350A00` |
| `MAC_HI`, `SOCK_REMOTE_MAC_HI` | MAC bytes 4-5 in bits 15:0; byte 4 in bits 7:0 | `00:0a:35:06:21:a0` → `0x0000A021` |
| `IPV4`, `SOCK_REMOTE_IP` | First octet in bits 31:24 | `192.168.10.2` → `0xC0A80A02` |
| `ECHO_PORT`, `SOCK_LOCAL_PORT`, `SOCK_REMOTE_PORT` | Port number in bits 15:0 | port 5000 → `0x00001388` |
| `TTL` | TTL in bits 7:0 | 64 → `0x00000040` |

The local MAC and IPv4 address serve two purposes. The receive rules only send a datagram to the
echo or the socket if it is addressed to them. The transmit side uses them as the source address
of every packet the hardware builds. They have no effect on the raw path. The echo server keeps
`IPV4` in step with lwIP's address, including DHCP changes.

The hardware echo takes precedence when `ECHO_PORT` and `SOCK_LOCAL_PORT` are equal.

## Counters

| Counter | What it counts |
|---------|----------------|
| `RX_FRAMES`, `RX_BYTES` | Frames (and their bytes, FCS excluded) that entered the core: after the MAC-error and FIFO-overflow drops, including frames then dropped because `RX_EN` = 0 |
| `RX_BAD_FRAME` | Frames the MRMAC flagged as bad (FCS error, runt, too long) and the core dropped, plus frames cut short by a MAC-side reset (link down while the frame was being read out of the MAC-side FIFO), which the core also drops |
| `RX_FIFO_DROP` | Frames dropped because the MAC-side FIFO was full or the frame was oversize, plus frames dropped while `RX_EN` = 0 |
| `RX_L3_BAD_CSUM` | IPv4 frames whose header checksum is wrong, as flagged by the parser. The parser only sees the first 64 bytes, so an IPv4 header with more than 28 bytes of options can also be counted here; such frames go to UI0 anyway. |
| `RX_L4_BAD_CSUM` | Echo or socket candidates whose UDP checksum is wrong. They go to UI0 instead, where the network stack drops them. |
| `RX_RAW`, `RX_ECHO`, `RX_SOCK` | Frames routed to each user interface. `RX_RAW` and `RX_SOCK` include frames then dropped by their receive FIFO; `RX_ECHO` does not include dropped echo requests. |
| `RX_RAW_DROP`, `RX_SOCK_DROP` | Frames dropped whole because the receive FIFO of UI0 / UI2 (32 KB each) was full, i.e. software did not take them in time (for example no free DMA descriptor). The other paths keep running meanwhile. |
| `RX_ECHO_DROP` | Echo requests dropped because the echo payload FIFO (32 KB) or the echo metadata FIFO (256 requests) had no room, i.e. the transmit side was busy. The receive paths keep running meanwhile. |
| `TX_OVERSIZE_DROP` | UI0 frames or UI2 payloads longer than 9618 bytes that the hardware dropped instead of transmitting |
| `TX_FRAMES`, `TX_BYTES` | Frames (and bytes, after padding to 60, FCS excluded) handed to the MAC. Frames discarded because `TX_EN` = 0 are not counted. |
| `TX_RAW`, `TX_ECHO`, `TX_SOCK` | Packets whose transmit metadata was built, per source. Counted before the `TX_EN` gate. |

* All counters wrap around.
* The byte counters are 64 bits wide. Reading `_LO` latches `_HI` from the same snapshot, so read
  `_LO` first, then `_HI`.
* Each counter is kept in the clock domain of its event (MAC RX, core or MAC TX clock). The groups
  cross into the register clock domain as whole snapshots, so the counters of one group are
  consistent with each other. The values lag reality by less than 1 µs.
* `CTRL.STAT_CLR` zeroes them all, including the `GEN_TX_*` and `CHK_*` counters. It does not
  reset the generator's sequence number, the checker's synchronisation or the rate meters.

## Traffic generator (1.2.0)

The generator is a hardware source of UDP datagrams at up to 100 Gb/s line rate, for testing
without a 100G host (for example with a QSFP28 loopback cable between two ports, each
generator sending to the other port's checker). The hardware builds the headers like it does
for the socket:

| Header field | Taken from |
|--------------|------------|
| Ethernet destination / source | `GEN_DST_MAC_*` / `MAC_*` |
| IPv4 destination / source | `GEN_DST_IP` / `IPV4` |
| UDP destination / source port | `GEN_DST_PORT` / `GEN_SRC_PORT` |
| IPv4 TTL, identification, checksums | As for the socket (see [socket transmit](#socket-transmit-ui2-transmit)) |

### `GEN_CTRL` (0x090)

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | `EN` | RW | Setting it (0 → 1) starts a run. Clearing it stops the generator after the datagram in progress, so no frame is ever cut short. |
| 1 | `CONT` | RW | 1: run until `EN` is cleared. 0: send `GEN_COUNT` datagrams, then stop (`BUSY` returns to 0; clear and set `EN` again for another run). Sampled when the run starts. |
| 2 | `CLR` | W | Write 1 to reset the sequence number to 0 and zero `GEN_TX_PKTS` / `GEN_TX_BYTES`. Reads as 0. |
| 31 | `BUSY` | R | A run is in progress. |

`GEN_LEN` values below 8 are used as 8 and values above 9000 as 9000 (the register reads back
what was written). A 9000-byte payload makes a 9042-byte frame, so the link partner must accept
jumbo frames of that size. `GEN_GAP` inserts that many idle cycles of the 300 MHz core clock
after every datagram, which limits the rate (0 = as fast as the transmit path allows).

The generated frames go through the normal transmit path: they share the link with UI0, the
echo and UI2 (round robin per packet), they are subject to `CTRL.TX_EN`, and they are counted in
`TX_FRAMES` / `TX_BYTES` as well as in `GEN_TX_PKTS` / `GEN_TX_BYTES` (payload bytes).

### Payload

Every payload carries a 64-bit sequence number and a pseudo-random pattern derived from it, so a
receiver can check every bit without any shared state. The sequence number S starts at 0 after
`GEN_CTRL.CLR` and increments per datagram, also across runs.

* Bytes 0-7: S, little-endian.
* Bytes 8 onwards: eight 64-bit xorshift generators, one per 8-byte lane of each 64-byte block.
  Lane j (0-7) starts at `x = (S XOR K[j]) OR 2^63` with `K[j] = (j + 1) × 0x9E3779B97F4A7C15`
  (mod 2^64) and is stepped once per 64-byte block (`x ^= x << 13; x ^= x >> 7; x ^= x << 17`,
  64-bit arithmetic) *before* it is used, so block b holds the value after b + 1 steps. Byte i
  of the payload is byte `i mod 8` (little-endian) of lane `(i mod 64) / 8` of block `i / 64`.

In Python:

```python
M = (1 << 64) - 1
K = [((j + 1) * 0x9E3779B97F4A7C15) & M for j in range(8)]

def xs(x):
    x ^= (x << 13) & M; x ^= x >> 7; x ^= (x << 17) & M
    return x

def gen_payload(seq, n):
    x = [(seq ^ k) | (1 << 63) for k in K]
    out = b""
    while len(out) < n:
        x = [xs(v) for v in x]
        out += b"".join(v.to_bytes(8, "little") for v in x)
    return seq.to_bytes(8, "little") + out[8:n]
```

## Checker (1.2.0)

A received IPv4/UDP datagram without VLAN tag, IP options or fragmentation, addressed to the
local MAC and IPv4 address, with correct checksums and destination port `CHK_PORT`, goes to the
checker while `CHK_CTRL.EN` = 1 (the echo and the socket take precedence if their port is the
same). The checker consumes it in hardware at line rate, nothing is forwarded:

* It regenerates the pattern from the sequence number in the datagram and adds the number of
  differing payload bits (bytes 8 onwards) to `CHK_BIT_ERR`.
* It compares the sequence number with the one it expects (the previous one + 1). A mismatch
  (lost, duplicated or reordered datagrams) adds 1 to `CHK_SEQ_ERR`, then the checker expects the
  received number + 1. The first datagram after enabling or clearing the checker only sets the
  expectation.
* Datagrams with less than 8 bytes of payload are only counted in `CHK_LEN_ERR`.
* A datagram to `CHK_PORT` whose UDP checksum is wrong is not checked; it goes to UI0 and is
  counted in `RX_L4_BAD_CSUM`. Datagrams lost before the checker (for example dropped by the
  MAC-side FIFO when the receive side is overloaded, `RX_FIFO_DROP`) show up as `CHK_SEQ_ERR`.

### `CHK_CTRL` (0x0C0)

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | `EN` | RW | Enables the checker rule. Setting it (0 → 1) also resynchronises the sequence check. |
| 2 | `CLR` | W | Write 1 to zero the `CHK_*` counters and resynchronise. Reads as 0. |
| 31 | `SYNC` | R | The checker has received a datagram since it was enabled or cleared. |

## Rate meters (1.2.0)

Once per second (300,000,000 cycles of the core clock) the hardware latches, in the same clock
cycle, how many frames and bytes entered the core (the events counted by `RX_FRAMES` /
`RX_BYTES`) and how many were handed to the MAC (`TX_FRAMES` / `TX_BYTES`) during that second,
and increments `RATE_SEQ`. Read `RATE_SEQ` first: the read latches all six rate registers from
the same second, so the values read afterwards always belong together. A changed `RATE_SEQ`
means a new sample. The meters run all the time and are not affected by `CTRL.STAT_CLR`.

Bytes exclude the FCS (transmit bytes include the padding to 60). To get the rate on the wire,
add 24 bytes per frame (FCS 4, preamble and start delimiter 8, inter-packet gap 12):

* frame rate in Gb/s = `8 × BYTES / 1e9`
* line rate in Gb/s = `8 × (BYTES + 24 × PKTS) / 1e9`

The core sustains 100 Gb/s line rate in both directions for UDP payloads of 726 bytes and up
(the generator alone for 684 bytes and up); below that the packet rate is limited to about
16.7 million packets per second on transmit and 18.7 million on receive (see
[throughput](description.md#throughput)).

## Latency measurement (1.3.0)

The block measures the latency of frames it transmits in reply to frames it received, with the
IEEE 1588 timestamps of the MRMAC: **latency = TX timestamp − RX timestamp**. The MRMAC takes
both timestamps at the first PCS block of the frame, so the latency runs from the start of the
request at the receive PCS to the start of the reply at the transmit PCS. It includes every
buffer in between and excludes the serdes, PCS and RS-FEC delays. Two banks of statistics are
kept:

* **Bank 0, hardware UDP echo.** With `LAT_CTRL.EN` set, every echo reply is timestamped.
* **Bank 1, software path.** Software sends a reply on UI0 behind a `ZTXT` descriptor that
  carries the receive timestamp of the request (taken from the `ZRXT` descriptor the hardware
  put in front of the request). The echo server's TCP echo does this.

The timestamps are 55-bit values in units of 2⁻⁸ ns (1/256 ns) from a free-running timer that
wraps after about 39 hours; the hardware subtracts them modulo 2⁵⁵ and converts to ns. A result
of 1 s or more is counted as *implausible* and left out of every other statistic.

### `LAT_CTRL` (0x100)

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | `EN` | RW | Timestamp echo replies (bank 0) and `ZTXT` frames with `TS_REQ` (bank 1). |
| 1 | `CLR0` | W | Write 1 to clear bank 0. |
| 2 | `CLR1` | W | Write 1 to clear bank 1. |
| 3 | `SNAP` / `BUSY` | W / R | Write 1 to copy both banks into the snapshot registers. Reads 1 while a command (`CLR0`, `CLR1`, `SNAP`) is still running (about 1 µs), then 0. |
| 8 | `RAW_RX_DESC` | RW | Put a 64-byte `ZRXT` descriptor in front of every frame received on UI0. |
| 9 | `RAW_TX_DESC` | RW | Recognise a `ZTXT` descriptor at the start of UI0 transmit frames (and remove it). |
| 31 | `BUSY` | R | Same as bit 3 on read. |

Bits 1-3 are commands: write them together with the enables you want to keep (for example
`0x309` = snapshot, keeping `EN`, `RAW_RX_DESC` and `RAW_TX_DESC`), then poll until bit 3 reads
0. The banks are also cleared at reset. Changing `LAT_BIN_BASE` or `LAT_BIN_WIDTH` does not
move samples already counted: clear the banks afterwards.

### `LAT_STATUS` (0x104)

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | `STALE` | W1C, sticky | A TX timestamp came back for a frame that is no longer pending. Expected after a MAC transmit reset (link down/up). |
| 1 | `LOST` | W1C, sticky | 64 frames were timestamped while the timestamp of an earlier one never came back. |
| 2 | `OVF` | W1C, sticky | A latency sample was lost because the statistics FIFO was full. |

`LAT_STALE_CNT`, `LAT_LOST_CNT` and `LAT_OVF_CNT` count the same events; `CTRL.STAT_CLR`
zeroes them. The transmit adapter in front of the MRMAC has its own sticky flag, *PTP
underrun*, for a frame that had to be sent without its timestamp request; the block design
routes it to a GPIO input (see [design](design.md)).

### Snapshot registers

Nothing below `0x200` changes on its own: write `SNAP` and wait for `BUSY` to clear, then read.
All values of a snapshot belong to the same set of samples (the histogram adds up to `COUNT`).
Before the first snapshot every register reads 0.

Bank *b* (0 or 1) at `0x200 + 0x40 × b`:

| Offset | Name | Description |
|--------|------|-------------|
| `+0x00` / `+0x04` | `COUNT_LO` / `COUNT_HI` | Number of samples (64-bit) |
| `+0x08` / `+0x0C` | `SUM_LO` / `SUM_HI` | Sum of the latencies, ns (64-bit) |
| `+0x10` / `+0x14` | `SUMSQ_LO` / `SUMSQ_HI` | Sum of the squared latencies, ns² (64-bit, stops at the maximum) |
| `+0x18` | `MIN` | Smallest latency, ns (`0xFFFFFFFF` while `COUNT` is 0) |
| `+0x1C` | `MAX` | Largest latency, ns |
| `+0x20` | `IMPLAUSIBLE` | Results of 1 s or more (not in any other value) |
| `+0x24` | `LAST` | Latest latency, ns |
| `+0x28` | `BIN_BASE` | `LAT_BIN_BASE` when the snapshot was taken |
| `+0x2C` | `BIN_WIDTH` | `LAT_BIN_WIDTH` when the snapshot was taken |

Mean = `SUM / COUNT`; standard deviation = √(`SUMSQ / COUNT` − mean²).

Histogram of bank *b*: 64 bins of 8 bytes at `0x400 + 0x200 × b + 8 × i`, the low 32 bits at
`+0` and the high 16 bits at `+4` (48-bit counters). With x = latency − `LAT_BIN_BASE` and
W = `LAT_BIN_WIDTH`:

| Bin | Holds |
|-----|-------|
| 0 | x < W, including latencies below `LAT_BIN_BASE` |
| 1-47 | i × W ≤ x < (i + 1) × W |
| 48-62 | 48 × W × 2^(i−48) ≤ x < 48 × W × 2^(i−47): each bin twice as wide as the one before |
| 63 | x ≥ 48 × W × 2¹⁵ |

With the defaults (base 0, 64 ns) the linear bins cover 0 to 3.07 µs in 64 ns steps, the
doubling bins go on to 100.7 ms, and bin 63 holds anything longer. For the software path, a
wider `LAT_BIN_WIDTH` (for example 512 ns: linear up to 24.6 µs) gives more resolution in the
linear part.

### `ZRXT` descriptor (UI0 receive, `RAW_RX_DESC`)

With `RAW_RX_DESC` set, every frame on UI0 starts with this 64-byte descriptor, followed by the
unchanged frame. A frame that is dropped because UI0 is too slow is dropped together with its
descriptor.

| Bytes | Content |
|-------|---------|
| 0-3 | Magic `0x5A525854` ("ZRXT" read as a little-endian u32) |
| 4-5 | Length of the frame that follows, in bytes |
| 6-7 | Zero |
| 8-15 | Receive timestamp, u64, units of 2⁻⁸ ns (bits 0-6 are always 0) |
| 16-23 | Zero |
| 24-27 | Parser flags, as in the [socket descriptor](#socket-descriptor-ui2-receive) |
| 28-63 | Zero |

### `ZTXT` descriptor (UI0 transmit, `RAW_TX_DESC`)

With `RAW_TX_DESC` set, a UI0 transmit transfer may start with this 64-byte descriptor. The
hardware removes it and sends the frame that follows. A transfer that does not start with the
magic, or that is not longer than 64 bytes, is sent unchanged.

| Bytes | Content |
|-------|---------|
| 0-3 | Magic `0x5A545854` ("ZTXT" read as a little-endian u32) |
| 4-5 | Zero |
| 6 | Flags: bit 0 `TS_REQ` = timestamp this frame and add its latency to bank 1 (needs `LAT_CTRL.EN`) |
| 7 | Zero |
| 8-15 | Receive timestamp of the request, copied from its `ZRXT` descriptor |
| 16-63 | Zero |

## Socket descriptor (UI2 receive)

Every datagram delivered on the hardware socket (UI2) arrives as **one** DMA transfer: a 64-byte
descriptor followed by exactly the UDP payload (Ethernet padding removed). Fields are
little-endian unless noted.

| Bytes | Field |
|-------|-------|
| 0-3 | Magic `0x5A534B54` ("ZSKT") |
| 4-5 | Payload length in bytes (UDP length − 8) |
| 6-7 | Source UDP port |
| 8-11 | Source IPv4 address, in network byte order (the bytes as on the wire) |
| 12-17 | Source MAC address, in wire order |
| 18-19 | Destination UDP port |
| 20-23 | Destination IPv4 address, in network byte order |
| 24-27 | Parser flags, e.g. `0x80000208` = PARSE_DONE \| UDP \| IPV4 |
| 28-63 | Zero |

The flags are those of the Zircon parser: bit 1 VLAN_S, 2 VLAN_C, 3 IPV4, 4 IPV6, 5 FRAG, 6 ARP,
7 ICMP, 8 TCP, 9 UDP, 16 L3_OPT, 17 L4_OPT, 24 L3_BAD_CKSUM, 25 L4_BAD_LEN, 31 PARSE_DONE.

To reply to the sender, copy its source MAC, IPv4 address and port into `SOCK_REMOTE_MAC_*`,
`SOCK_REMOTE_IP` and `SOCK_REMOTE_PORT`. The socket is *connected*: every payload sent on UI2
goes to the address in those registers.

## Socket transmit (UI2 transmit)

The PS writes **payload only** to the socket's transmit DMA channel, one DMA transfer per
datagram, with no descriptor. The hardware builds the headers:

| Header field | Taken from |
|--------------|------------|
| Ethernet destination / source | `SOCK_REMOTE_MAC_*` / `MAC_*` |
| IPv4 destination / source | `SOCK_REMOTE_IP` / `IPV4` |
| UDP destination / source port | `SOCK_REMOTE_PORT` / `SOCK_LOCAL_PORT` |
| IPv4 TTL | `TTL` |
| IPv4 identification | A 16-bit counter shared by all hardware-built packets |
| IPv4 DSCP/ECN, flags | 0 (the Don't-Fragment bit is never set) |
| IPv4 header checksum, UDP length and checksum | Computed by the hardware |

A payload must be at least 1 byte long, and the resulting frame must fit the MTU of the link
partner (8972 bytes of payload for a 9000-byte jumbo MTU). The socket demo of the echo server
sizes its buffers for that maximum.

## Raw path (UI0)

Frames on UI0 are complete Ethernet frames without the FCS, in both directions. On transmit, the
hardware pads frames shorter than 60 bytes, and the MRMAC appends the FCS. Transmit frames (UI0)
and payloads (UI2) longer than 9618 bytes are dropped and counted in `TX_OVERSIZE_DROP` (see
[transmit path](description.md#transmit-path)).

Software driving the 512-bit AXI DMAs should use **64-byte aligned buffers**. The bare-metal DMA
driver in this repository (`zdma.c`) aligns its receive buffers and copies unaligned transmit
frames into aligned bounce buffers.

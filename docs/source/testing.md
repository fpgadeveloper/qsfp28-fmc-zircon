# Testing

This page describes how to test the design. There are two ways:

* **Loopback test (no host NIC required):** a QSFP28 cable between port 0 and port 1 of the FMC,
  and the hardware UDP generators and checkers of both ports run 2 × 100 Gb/s at full line rate.
  See [Loopback test](#loopback-test-no-host-nic-required).
* **Host test:** port 0 or port 1 cabled to a 100G link partner, and the host-side script checks
  the hardware echo, the hardware socket and the software TCP echo. The rest of this page
  describes what the partner needs, how to load the board, how to run the host-side test script,
  and what results to expect.

## Link partner requirements

The design needs a **100GBASE-R (CAUI-4) link partner that supports RS-FEC**, for example a 100G
NIC in a PC or a 100G switch port:

* **Speed:** 100 Gb/s over four 25.78125 Gb/s lanes. 40G and 4x25G breakout modes will not link.
* **FEC: RS-FEC, clause 91, RS(528,514).** This is the FEC that 100GBASE-CR4 / SR4 / LR4 use.
  A partner in FEC **auto** mode negotiates it, so no FEC configuration is normally needed.
* **Auto-negotiation / link training:** the MRMAC runs neither (clause 73 AN and link training
  are off in this design). Optical modules and active optical cables never use them. Some NICs
  insist on auto-negotiation with direct-attach copper cables; see
  [Troubleshooting](troubleshooting.md#the-link-never-comes-up).
* **Cable or modules:** a QSFP28 100G direct-attach cable (DAC), an active optical cable (AOC),
  or a pair of QSFP28 optical modules with the matching fiber.

### Contrast with the FEC-off designs

Opsero's other 2x QSFP28 FMC reference design (with the AMD MRMAC Ethernet driver and an MCDMA)
runs its 100G ports with **FEC off**. Against that design, a partner must have its FEC *forced*
off (`ethtool --set-fec <if> encoding off`, which needs root). A partner left in FEC auto keeps
trying RS-FEC and the link flaps. This design is the other way around: **RS-FEC is on**, which is
what a partner in auto mode offers by default, so an unmodified host links up. If you move
between the two designs on the same host, set the host's FEC back to `auto` (or to `rs`) for this
one:

```
sudo ethtool --set-fec <if> encoding auto     # or: encoding rs
ethtool --show-fec <if>
```

The bare-metal echo server can also switch its own FEC mode (it tries FEC off every 10 seconds
while the link is down, and the `f` key cycles the modes); see
[FEC mode](echo_server.md#fec-mode).

## Host setup

Give the host's 100G interface an IPv4 address on the same subnet as the board, and optionally a
DHCP server. With NetworkManager, a connection profile in **"shared"** mode does both: it gives
the host port an address such as `192.168.20.1/24` and serves DHCP on the link. The echo server
uses DHCP by default. Without a DHCP server, it falls back to `192.168.20.2/24` after 10
seconds.

For the jumbo-frame tests, the host interface also needs an MTU of 9000
(`sudo ip link set <if> mtu 9000`).

## Load the board

Build the boot image with `./build.sh standalone --target vck190_fmcp1` (see
[Build instructions](build_instructions.md)) and load `Vitis/boot/vck190_fmcp1/BOOT.BIN`
either from a FAT32 microSD card or over JTAG, as described in
[Run the application](echo_server.md#run-the-application). Open the UART console (115200 baud)
and wait for the `Port <n>: IP …` line of the port you cabled: it gives that port's address for
the tests below.

## The host test script: `scripts/zircon_echo_test.py`

`scripts/zircon_echo_test.py` ships with this repository, together with the small
`scripts/echo_test.py` helper it uses for the TCP test. It is the judge for the three services
of the [echo server](echo_server.md), run from a Linux PC on the 100G link. It uses only the
Python 3 standard library and needs **no root** and no raw
sockets:

| Test | What it does | Pass condition |
|------|--------------|----------------|
| `udp` (hardware echo, UI1) | Sends UDP datagrams to port 7, sweeping the payload size from 1 to 1472 bytes (and up to 8972 with `--jumbo`), then a windowed burst of 20000 datagrams for a packets-per-second and round-trip-time figure | Every payload comes back unchanged, from the board's address and port 7, and the burst loss is below `--max-loss` (0.1 %) |
| `tcp` (software echo, UI0) | Opens TCP connections to port 7 and exchanges 1 to 20000-byte messages | Every byte comes back in order |
| `sock` (hardware socket, UI2) | Sends datagrams of various sizes to port 5000 | Every payload comes back unchanged, from port 5000 of the board |

Checksums are judged through the kernel's own counters (`/proc/net/snmp`: UDP `InCsumErrors`, IP
`InHdrErrors`). The kernel drops a datagram with a bad checksum before any socket sees it, so a
wrong hardware checksum shows up both as a lost datagram and as a counter increment. The script
ends with `VERDICT: PASS` (exit code 0) or `VERDICT: FAIL` (exit code 1).

### Usage

```
python3 scripts/zircon_echo_test.py <board-ip> --iface <host-100G-interface>
```

The board address can also be given as the line the echo server prints on its UART, or read
from a saved UART log:

```
python3 scripts/zircon_echo_test.py "Port 0: IP 192.168.20.23 mask 255.255.255.0 gw 192.168.20.1 (DHCP)"
python3 scripts/zircon_echo_test.py --from-log uart.log
python3 scripts/zircon_echo_test.py --port 1 --from-log uart.log
```

Both QSFP ports run the same services. `--port 1` makes the script look for the `Port 1: IP`
line and the port 1 MAC address (`00:0a:35:06:21:a1`) instead of port 0's.

Useful options:

| Option | Meaning |
|--------|---------|
| `--port N` | The QSFP port under test, 0 (default) or 1 |
| `--iface IF` | The host's 100G interface. Without it, the script picks one of its default candidates (`--ifaces`) that has carrier. |
| `--bind ADDR` | The local address to send from (default: the interface's IPv4 address) |
| `--only udp\|tcp\|sock` | Run only this test (repeatable) |
| `--udp-sizes all\|a-b\|a,b,c` | Sizes for the UDP echo sweep (default 1-1472) |
| `--jumbo` | Also sweep jumbo sizes up to 8972 bytes (needs a host MTU of 9000) |
| `--burst N`, `--burst-size B`, `--window W` | Burst length (0 skips it), datagram size and datagrams in flight |
| `--max-loss F` | Tolerated burst loss fraction (default 0.001) |
| `--timeout S`, `--retries N` | Per-datagram timeout and resends before a datagram counts as lost |
| `--ping` | Also run the system `ping` (informational) |
| `--latency` | After the tests, the [latency measurement](#latency-measurement) per size (zircon_nic 1.3.0) |
| `--latency-only` | Only print the board's latency statistics (UDP 5002); no tests, nothing cleared |
| `--lat-sizes a,b,c`, `--lat-count N` | Payload sizes (default 64,512,1024,1472) and exchanges per size and protocol (default 1000) of the latency run |

The TCP test opens its connections with `TCP_NODELAY` and has one message in flight at a time.

The script measures the echo *round trip* from a user-space socket on the host, so its
packets-per-second figure is limited by the host's network stack, not by the hardware echo. It is a
functional test. To load the hardware echo at line rate, use a traffic generator such as the Linux
kernel's `pktgen` or a DPDK-based generator, and compare the board's `RX_ECHO` / `TX_ECHO`
counters with the number of packets sent.

## Expected results

| Check | Expected |
|-------|----------|
| Link | Up at 100 Gb/s within a few seconds of connecting the cable, with RS-FEC aligned (`lane lock 0xf`) |
| FEC codewords | Uncorrectable codewords: 0. Corrected codewords: a slowly growing number is normal on a healthy link. |
| Ping | Replies from the board (lwIP over UI0) |
| UDP echo, all sizes 1-1472 (and 1473-8972 with jumbo) | 100 % echoed, payload unchanged, no checksum errors on the host |
| UDP echo burst | Loss below 0.1 % |
| TCP echo (software, for comparison) | All sizes echoed |
| Socket | 100 % bounced, payload unchanged |
| zircon_nic counters | `RX_ECHO` = `TX_ECHO`, `RX_SOCK` = `TX_SOCK` (for the bounce), `RX_BAD_FRAME` = 0, `RX_L3_BAD_CSUM` = `RX_L4_BAD_CSUM` = 0, `STATUS` = 0 |

## Loopback test (no host NIC required)

The loopback test needs only the board, the FMC and one QSFP28 cable. It runs both ports at
full 100 Gb/s line rate in both directions with hardware traffic, which a host with a
socket-based test cannot do. The generator, the checker and the counters are described in
[Loopback test](echo_server.md#loopback-test).

### Procedure

1. Plug the 2x QSFP28 FMC into **FMCP1** of the VCK190 and connect a **QSFP28 cable between QSFP
   port 0 and QSFP port 1** of the FMC. A 100G direct-attach copper cable (DAC) or an active
   optical cable (AOC) works; both ends use RS-FEC, so no FEC setting is needed.
2. Connect the VCK190's USB-C cable and open the UART console (115200 baud).
3. Load `Vitis/boot/vck190_fmcp1/BOOT.BIN` from the SD card or over JTAG (see
   [Run the application](echo_server.md#run-the-application)).
4. Wait. Both links come up (`Port 0: link up …`, `Port 1: link up …`). No DHCP server answers on a
   port-to-port cable, so after 10 seconds both ports fall back to their static addresses
   (`Port 0: IP 192.168.20.2 …`, `Port 1: IP 192.168.21.2 …`). About 15 seconds after the links
   came up, the application starts the test by itself:
   ```
   LOOPBACK: every port has link and no DHCP server answered in 15 s: assuming a port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)
   LOOPBACK: started, cross-port: port 0 -> port 1 and port 1 -> port 0 (UDP 5001 -> 5001), 1472 B payload, continuous
   ```
   To start it earlier, or after it was stopped, type `l`.
5. Watch the table printed every second: `gen TX pkts` and `chk RX pkts` grow by about 8.1
   million per second on both ports, the error columns stay at 0, and `TX Gb/s` / `RX Gb/s` show
   about 100 Gb/s line rate.
6. About 12 seconds after the start the verdict appears:
   ```
   LOOPBACK: PASS
   ```
   A `LOOPBACK: FAIL <reason>` line means errors, a rate below 90 Gb/s, or a link down for 10
   seconds; see [Expected loopback results](#expected-loopback-results).

The test keeps running until `l` is typed again. Useful variations:

| Command | Test |
|---------|------|
| `p 9000` Enter | Jumbo payloads (9042-byte frames); `p 1472` Enter returns to the default |
| `p 256` Enter | Small payloads: the packet rate limit of the Zircon header path (about 16.7 Mpps transmit, 18.75 Mpps receive) holds the rate below 100 Gb/s. Line rate needs payloads of about 726 bytes and up. |
| `e` | Echo through the loopback: port 0's generator → port 1's hardware UDP echo → port 0's checker (verdict lines start with `LOOPBACK-ECHO:`) |
| `c` | Clear the counters and restart the 10-second verdict |
| `s` | Full status of both ports, including MRMAC and zircon_nic counters |

### Expected loopback results

| Check | Expected |
|-------|----------|
| Links | Both up at 100 Gb/s, RS-FEC aligned (`lane lock 0xf`) |
| `TX Gb/s`, `RX Gb/s` (1472-byte payload) | 99.9 to 100.0 on both ports (8.13 Mpps of 1514-byte frames); `TX pay.` / `RX pay.` about 95.7 |
| `seq err`, `bit err`, `len err` | 0 |
| `gen TX pkts` of one port vs `chk RX pkts` of the other | Equal, apart from the datagrams in flight |
| MRMAC `cw uncorr` (`s`) | 0 |
| Verdict | `LOOPBACK: PASS` about 12 seconds after the start |

If the rate is 0 on one side, check that the cable connects port 0 to port 1 and that both
`Port <n>: link up` lines appeared. With small payloads (below about 726 bytes)
the rate is expected to stay below 100 Gb/s, and the verdict is `FAIL rate`: the transmit header
path of the generator sends at most about 16.7 million packets per second. The receive side
keeps up with that, so the error columns stay at 0 at every payload size (see
[Throughput vs payload size](#throughput-vs-payload-size-v130-port-0--port-1-optical-loopback)).

### Automated check on the bench

The verdict line is designed to be matched by a script watching the UART. With the Opsero bench
tooling (`scripts/bench.py` of the agent workspace; any UART capture that waits for a regular
expression works the same way), load the design and wait for the verdict:

```
python3 scripts/bench.py program vck190 --arch versal \
    --bit repos/qsfp28-fmc-zircon/Vivado/vck190_fmcp1/vck190_fmcp1.runs/impl_1/zircon_wrapper.pdi \
    --elf repos/qsfp28-fmc-zircon/Vitis/vck190_fmcp1_workspace/echo_server/build/echo_server.elf \
    --uart-seconds 45 --expect 'Port 1: link up'
python3 scripts/bench.py uart-test vck190 --until 'LOOPBACK: PASS' --duration 90
```

The automatic start needs no console input. If the board has been running for a while (the
automatic start happens only once after boot), add `--send l` to start the test; do not send it
while a test is already running, since `l` toggles the test off.

## Generator and checker against a host: `scripts/zircon_prbs_tool.py`

`scripts/zircon_prbs_tool.py` is the host side of the 1.2.0 hardware UDP generator and checker.
It uses the Python standard library only and needs no root. It implements the payload
definition in [registers.md](registers.md) (sequence number + xorshift lanes).

* `zircon_prbs_tool.py listen --port 6000 --count 1000 --bind <host IP>` receives datagrams from
  the board's generator, then checks every payload bit, the sequence continuity and the source.
  Point the generator at the host first:
  * `GEN_DST_MAC` = the host port's MAC, `GEN_DST_IP` = its IPv4, `GEN_DST_PORT` = the listening
    port (registers `0x0A0`-`0x0AC`).
  * `GEN_COUNT` = the number of datagrams, then `GEN_CTRL` = `CLR` (write 4), then `EN` (write 1).
  * Without root, the host socket buffer holds only about 100 datagrams, so pace the generator
    (`GEN_GAP`, for example 3,000 cycles = 10 µs per datagram).
* `zircon_prbs_tool.py send <board IP> --count N --len L [--flip-bit SEQ:BIT]` sends datagrams
  with sequence numbers 0..N-1 to `CHK_PORT` (5001). Enable the checker first (`CHK_CTRL` = 4,
  then 1), then compare `CHK_RX_PKTS`, `CHK_SEQ_ERR` and `CHK_BIT_ERR` with what was sent.

## Latency measurement

With zircon_nic 1.3.0 the board measures the latency of its echoes itself, from the MRMAC's
1588 timestamps: RX PCS of the request to TX PCS of the reply, for the hardware UDP echo (bank 0)
and the software TCP echo (bank 1). What is and is not included, the `T` console command and the
UDP 5002 statistics service are described in
[Latency measurement](echo_server.md#latency-measurement). The host script puts the board's
numbers next to its own round-trip times:

```
python3 scripts/zircon_echo_test.py <board-ip> --latency
python3 scripts/zircon_echo_test.py <board-ip> --only udp --burst 0 --udp-sizes 64 --latency --lat-sizes 64,1472 --lat-count 5000
```

After the normal tests (restrict them with `--only`), for every size of `--lat-sizes` the script:

1. clears both banks (`CLR` to UDP 5002), so the numbers belong to this size only;
2. sends `--lat-count` UDP requests to the hardware echo (port 7), one at a time, and times each
   round trip;
3. opens one TCP connection to the software echo (port 7) with `TCP_NODELAY` and exchanges
   `--lat-count` messages of the same size (at most 1460 bytes, one segment), one at a time;
4. reads both banks (`STAT?`) and prints one table per size:

```
Latency, 1472 B UDP / 1460 B TCP payload, 1000 request/response exchanges each, one in flight:
                            count        min       mean        p50        p99      p99.9         max   (ns)
  host RTT, UDP echo         1000     ...
  board HW UDP echo          1000     ...
  host RTT, TCP echo         1000     ...
  board SW TCP echo          1000     ...
  HW hist (ns:count) 768-832:512 832-896:468 896-960:19 1152-1216:1
  SW hist (ns:count) 6144-12288:1000
```

The host rows are exact percentiles of the measured round trips. The board rows come from the
histogram, as on the UART (upper bin edges, capped at the maximum). The histogram lines list
every non-empty bin as `low-high:count`, in ns. The test fails if the service does not answer,
if hardware echoes were answered but bank 0 counted none, or if TCP echoes were answered but
bank 1 counted none (while `RAW_TS_DESC` is on). The board counts every echo on the port, so run
the latency test with no other traffic to the board.

`--latency-only` prints the banks of the port as they are (for example after a test with another
tool), without clearing them.

What to expect: the host round trip includes the host's network stack, both serdes/FEC paths
and the cable twice, so it is much larger than either board number. The hardware echo grows
with the frame size, because every store-and-forward stage waits for the whole frame. The
software echo adds the DMA and lwIP round trip through the processor to the same path.

### Results

#### Hardware UDP echo at 100G (optical loopback, `e` test)

The first table below is from the first 1.3.0 build (f684f59). The final build (d8eda55), which
follows it, gives the same numbers.

Measured on 2026-09-24 (journal from 22:01) with zircon_nic 1.3.0 on the VCK190. Port 0 and port
1 were joined by an optical QSFP28 cable (100GBASE-SR4). In the `e` test, port 0's generator
sends to port 1's hardware UDP echo and port 0's checker verifies the replies. `T 1` then shows
port 1's bank 0: the hardware echo latency from the RX PCS to the TX PCS of port 1's MRMAC.

| payload (frame) | traffic | samples | min | mean | max | stddev | p50 / p99 / p99.9 (bin upper edge) | bins (64 ns wide) |
|---|---|---|---|---|---|---|---|---|
| 64 B (106 B) | 16.7 Mpps, 30 s | 536,350,656 | 478 | 498.0 | 514 | 1.6 | 512 / 512 / 512 | 448-512: 536,347,922; 512-576: 2,734 |
| 1472 B (1514 B) | 100.00 Gb/s line rate, 30 s | 261,542,980 | 811 | 830.8 | 844 | 1.0 | 832 / 844 / 844 | 768-832: 258,673,459; 832-896: 2,869,521 |
| 9000 B (9042 B) | 100.00 Gb/s line rate, 30 s | 44,371,457 | 2972 | 2991.1 | 3005 | 2.3 | 3005 / 3005 / 3005 | 2944-3008: all |
| 1472 B | 1000 datagrams, 1 ms apart | 1000 | 810 | 814.1 | 826 | 1.9 | 826 | 768-832: all |
| 64 B | 1000 datagrams, 1 ms apart | 1000 | 479 | 481.6 | 486 | 1.6 | 486 | 448-512: all |

All values are in ns.

* **Every run was clean.** The checker counted every datagram with 0 sequence, bit or length
  errors. `LAT_STATUS` was 0, stale / lost / overflow were 0, and no delta was implausible. There
  was no `PTP_UNDERRUN` and `STATUS` stayed 0 (no `RX_PACK_STALL` / `RX_PACK_OVF`).
* **The latency is deterministic.** The spread is a few ns at 100G line rate, and line rate adds
  only about 16 ns to the mean of an isolated datagram.
* **It grows with frame size**, at about 0.29 ns per byte, because the path has
  store-and-forward stages.
* **The RX timestamps are good.** The isolated datagrams (1 ms apart) give the same latency as
  back-to-back traffic. RX timestamps that were all zero, or that came from the neighbouring
  frame, would show up there as deltas of milliseconds or as implausible samples.

**Final build (d8eda55, 2026-09-25, journal from 02:36).** This build adds a register stage on the
MRMAC PTP timestamp inputs and re-pipelines the TX tagger; timing margin is +0.039/+0.083 ns. The
numbers match the build above to within 1.3 ns:

| payload | traffic | samples | min | mean | max | stddev | bins (64 ns wide) |
|---|---|---|---|---|---|---|---|
| 1472 B | 100.00 Gb/s line rate, 30 s | 261,483,497 | 812 | 832.1 | 846 | 1.0 | 768-832: 5,803,540; 832-896: 255,679,957 |
| 64 B | 16.7 Mpps, 30 s | 536,316,595 | 474 | 498.0 | 515 | 1.9 | 448-512: 536,308,600; 512-576: 7,995 |
| 1472 B, SD-card boot (2026-09-25 08:17) | 100.00 Gb/s line rate, 30 s | 245,205,879 | 808 | 831.1 | 845 | 1.0 | 768-832: 218,765,018; 832-896: 26,440,861 |
| 9000 B, SD-card boot (2026-09-25 08:18) | 100.00 Gb/s line rate, 30 s | 41,596,876 | 2969 | 2992.0 | 3006 | 2.4 | 2944-3008: all |

All values are in ns. The last two rows are from the v1.3.0 `BOOT.BIN` booted from the SD card
(see [Cross-port loopback and echo-through](#cross-port-loopback-and-echo-through-v130)). On
both ports `LAT_STATUS` was 0, stale / lost / overflow were 0, no delta was implausible and
there was no `PTP_UNDERRUN`.

The 5-minute soak ran from 02:40:41 to 02:45:41: `c` cleared the counters after the link-up,
then `l` ran at 1472 B for 319 s.

* Each direction carried 2,594,728,161 datagrams at 100.00 Gb/s, with 0 sequence, bit or length
  errors.
* Both MRMACs counted 0 corrected and 0 uncorrected RS-FEC codewords and 0 bad FCS.
* `STATUS` and all drop counters were 0.

#### Datapath regression with the 1.3.0 bitstream

The cross-port loopback auto-started and passed after every load (`LOOPBACK: PASS`, 100.00 Gb/s
each way at 1472 B). The full loopback measurements (throughput vs payload size, `l` and `e`
verdicts, a 10-minute soak) were repeated on the final v1.3.0 build and gave the same figures as
1.2.0; see [Measured results](#measured-results).

#### Host-side measurement (final build, 2026-09-25)

Setup: port 0 cabled to the host's Intel E810-C (`ens6f1np1`, DHCP 192.168.21.162), a
loopback plug in port 1, and the final v1.3 build loaded over JTAG (journal from 07:15). The
command was `scripts/zircon_echo_test.py --port 0 --ping --latency --lat-sizes 64,512,1024,1472`,
with 1000 request/response exchanges per size and protocol, one request in flight, and
`TCP_NODELAY` on the host. It gave `VERDICT: PASS`: every normal test passed, and the latency
check passed.

The board columns are the MRMAC-timestamped latency from RX PCS to TX PCS. The host columns are
round-trip times measured by a single Python process, so they include the host's own network
stack twice, the NIC, the modules and the cable.

| payload | host RTT UDP mean / p50 / p99 | board HW UDP echo min / mean / max | host RTT TCP mean / p50 / p99 | board SW TCP echo min / mean / max | SW bank count |
|---|---|---|---|---|---|
| 64 B | 33.9 / 27.7 / 125.9 µs | 477 / 485 / 494 ns | 32.7 / 32.1 / 39.8 µs | 6.01 / 6.79 / 7.86 µs | 1000 |
| 512 B | 29.6 / 29.2 / 37.2 µs | 581 / 590 / 606 ns | 44.2 / 37.0 / 135.0 µs | 7.04 / 7.69 / 8.51 µs | 1000 |
| 1024 B | 33.6 / 32.2 / 50.9 µs | 700 / 712 / 723 ns | 46.7 / 40.6 / 166.4 µs | 8.02 / 8.80 / 9.67 µs | 1000 |
| 1472 B (TCP 1460 B) | 35.7 / 35.1 / 47.3 µs | 809 / 817 / 832 ns | 40.6 / 39.9 / 48.5 µs | 8.95 / 9.70 / 10.82 µs | 1000 |

Histograms, from the script and `T 0`:

* **Hardware bank:** one 64 ns bin per size, e.g. 1472 B: 768–832: 999, 832–896: 1. Standard
  deviation 3.0 ns.
* **Software bank:** 3072–6144: 64 and 6144–12288: 936 at 64 B; all 1000 in 6144–12288 at the
  larger sizes. 1472 B, as `T 0` prints it: `bank 1 software TCP echo: count 1000 min 8953 mean
  9697.9 max 10822 stddev 366.9 ns`.

**Bank 1 counts exactly one sample per TCP exchange** (1000 of 1000 at every size).

**The hardware echo tail at 1472 B:** a 20,000-datagram burst with 64 in flight (108,686
datagrams/s from the host). After `T 0 c`, bank 0 counted 20,000 samples plus 1 from a single
64 B datagram. They split 19,995 in 768–832 ns and 5 in 832–896 ns; max 834 ns, stddev 3.8 ns.
Host load does not reach the board's echo latency.

**Port 1 on the loopback plug:** `L 1` gave `LOOPBACK: PASS` at 100.00 Gb/s with 0 errors, and
port 1's `LAT_STATUS` was 0.

**SD-card boot.** This build's BOOT.BIN was copied to the SD card (AMD's PetaLinux boot image was
booted over JTAG and the file copied from there; `BOOT.BIN.petalinux` was kept). It then booted
from power-on:

* Power-on was at 07:40:34 and `Port 0: IP 192.168.21.162 ... (DHCP)` appeared at 07:40:49.
* `zircon_echo_test.py --port 0 --latency --lat-sizes 1472` then gave `VERDICT: PASS`.

**Two application fixes came out of this run:**

* **The TCP echo never took a TX timestamp** (bank 1 empty, `tx TS_REQ 0`). lwIP defers
  `tcp_output()` for the pcb whose segment it is processing until the receive callback has
  returned. The echo therefore left after the callback had already disarmed the timestamp
  request. The request is now disarmed after `netif->input()` returns for the received frame,
  which includes lwIP's deferred output.
* **Two samples per 1460 B exchange.** lwIP's default 2048-byte TCP window (`TCP_WND`) made
  Linux cut its send MSS to 1024 (`ss`: `mss:1024 snd_wnd:1612`), so each 1460 B request arrived
  as two segments. `Vitis/py/args.json` now sets `lwip220_tcp_wnd` 32768 and
  `lwip220_tcp_snd_buf` 16384, and the host MSS is 1460.

## Measured results

<!-- BENCH-RESULTS -->

The results below are for the final zircon_nic 1.3.0 build (v1.3.0 `BOOT.BIN`, booted from the
VCK190's SD card), measured on 2026-09-25 between 08:13 and 08:31 (journal times). Port 0 and
port 1 of the FMC were joined by an optical QSFP28 patch cable (100GBASE-SR4 modules at both
ends, RS-FEC) and no host was connected. Every 1.2.0 figure that these runs repeat came out the
same to within measurement noise; the 1.2.0 numbers that were not repeated, and the earlier
versions, are under [History](#history-120).

### Auto-start from power-on (v1.3.0, SD card)

The board was power-cycled (`bench.py power vck190 cycle`, plug on at 08:13:22) with the cable
in place and no console input. Times are from power-on, from the host's timestamps of the UART
lines:

| event | time from power-on |
|---|---|
| PLM: boot PDI loaded from SD | 2.7 s |
| Application banner (`QSFP ports: 2 x 100GbE ...`) | 2.7 s |
| `zircon_nic 1.3.0 at ...` (both ports), 1588 timer check passed | 4.7 s |
| `Port 0: link up` and `Port 1: link up` (RS-FEC aligned) | 5.1 s |
| `no DHCP lease after 10 s, falling back to static` (both ports) | 15.2 s |
| `LOOPBACK: every port has link and no DHCP server answered in 15 s ...` | 20.2 s |
| `LOOPBACK: PASS` | 31.2 s |

1.2.0 took 31 s from power-on to `LOOPBACK: PASS` on 2026-09-24 (20:07:14 to 20:07:45, same
SD-card flow): unchanged.

```
Port 0: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xf, FEC_CONFIGURATION_REG1 0x1008)
Port 1: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xf, FEC_CONFIGURATION_REG1 0x1008)
Port 0: IP 192.168.20.2 mask 255.255.255.0 gw 192.168.20.1 (static)
Port 1: IP 192.168.21.2 mask 255.255.255.0 gw 192.168.21.1 (static)
LOOPBACK: every port has link and no DHCP server answered in 15 s: assuming a port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)
LOOPBACK: started, cross-port: port 0 -> port 1 and port 1 -> port 0 (UDP 5001 -> 5001), 1472 B payload, continuous
Port 0: gen/chk 89401554/89401509 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
Port 1: gen/chk 89401580/89401541 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
LOOPBACK: PASS
```

Port 0's MRMAC counted 19 uncorrectable RS-FEC codewords during the link-up, before 5 s on the
status line, and none after that (still 19 at 355 s). This is the link-up transient: the
soak below clears it with `c` first and then counts 0.

### Throughput vs payload size (v1.3.0, port 0 ↔ port 1 optical loopback)

Measured from 08:14:11 to 08:16:27. The cross-port test (`l`, both directions at once) was
running after the auto-start. For each payload size, `p <bytes>` was typed on the console, which
restarts the test with the new size and fresh counters, and the tables were read for 15 s.

* **Line rate and payload rate** are the rate-meter columns of the once-a-second table. They
  had the same value in every table from 6 s to 14 s, on both ports, TX and RX.
* **Packets per second** is the mean increase of `gen TX pkts` from one table to the next over
  the eight 1-second intervals from 6 s to 14 s. The spread across those intervals was at most
  ±17 packets/s. Port 1's generator and the checkers rose by the same amount (means equal to
  within 1 packet/s).
* **Errors** are the `seq err`, `bit err` and `len err` columns: 0 in every table, on both ports.

| UDP payload | Frame (with FCS) | Line rate, each direction | UDP payload rate | Packets/s, each direction | seq / bit / len errors | Verdict |
|---|---|---|---|---|---|---|
| 64 B | 110 B | 17.33 Gb/s | 8.53 Gb/s | 16,666,499 | 0 / 0 / 0 | FAIL rate (packet-rate limit, as expected) |
| 128 B | 174 B | 25.86 Gb/s | 17.06 Gb/s | 16,666,498 | 0 / 0 / 0 | FAIL rate (as expected) |
| 256 B | 302 B | 42.93 Gb/s | 34.13 Gb/s | 16,666,499 | 0 / 0 / 0 | FAIL rate (as expected) |
| 512 B | 558 B | 77.06 Gb/s | 68.26 Gb/s | 16,666,499 | 0 / 0 / 0 | FAIL rate (as expected) |
| 726 B | 772 B | 100.00 Gb/s | 91.66 Gb/s | 15,782,812 | 0 / 0 / 0 | PASS |
| 1024 B | 1070 B | 100.00 Gb/s | 93.94 Gb/s | 11,467,878 | 0 / 0 / 0 | PASS |
| 1472 B | 1518 B | 100.00 Gb/s | 95.70 Gb/s | 8,127,432 | 0 / 0 / 0 | PASS |
| 1500 B | 1546 B | 100.00 Gb/s | 95.78 Gb/s | 7,982,114 | 0 / 0 / 0 | PASS |
| 9000 B (jumbo) | 9046 B | 100.00 Gb/s | 99.27 Gb/s | 1,378,777 | 0 / 0 / 0 | PASS |

* **From 726 bytes up, both directions run at the full 100 Gb/s line rate** with zero errors.
  The packet rates are the theoretical 100GBASE-R frame rates (100 Gb/s / 8 / (frame + 20 B of
  preamble and IPG)) to within 0.001 %.
* **Below 726 bytes the transmit header path sets the rate**: 16,666,499 packets per second at
  every size from 64 to 512 bytes, which is 18 cycles of the 300 MHz core clock per packet
  (300 MHz / 18 = 16.67 Mpps). The receive side kept up with that rate at every size: the
  checkers counted no sequence errors, so every generated datagram arrived and was checked.
  The receive ceiling (18.75 Mpps by design) is above what the generator can offer, so this
  test does not reach it.
* The `FAIL rate` verdicts below 726 bytes only mean that the rate stayed under the 90 Gb/s
  pass threshold of the test; they are the expected result, not a fault.
* The 1500-byte payload makes a 1528-byte IPv4 packet, larger than the standard 1500-byte MTU;
  the hardware path has no MTU limit below 9000 bytes of payload.
* When each size's run was stopped by the next `p`, the summary lines showed each port's
  generator total equal to the other port's checker total (for example, after the 726-byte
  run: `Port 0: gen/chk 239016382/239016385`, `Port 1: gen/chk 239016385/239016382`).
* **Compared with 1.2.0** (2026-09-24, 19:36–19:38, same method): the line and payload rate
  columns are identical at every size, and the packet rates differ by at most 32 packets/s
  (0.0002 %, the resolution of the 1-second table timing).

UART excerpts (the table at 11 s and the verdict for each size), from the board's bench journal:

```
[2026-09-25 08:14:11] >> UART send: 'p 64'
loopback payload: 64 B UDP (110 B frames) - below ~726 B the packet rate limits the throughput
LOOPBACK: RUNNING 11 s (cross-port, 64 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      183300770      183300250        0             0        0    17.33    17.33     8.53     8.53
P1   up   RS(528,514)      183300821      183300315        0             0        0    17.33    17.33     8.53     8.53
LOOPBACK: FAIL rate: port 0 TX 17.33 Gb/s < 90.00 Gb/s line rate for 10 s

[2026-09-25 08:14:26] >> UART send: 'p 128'
loopback payload: 128 B UDP (174 B frames) - below ~726 B the packet rate limits the throughput
LOOPBACK: RUNNING 11 s (cross-port, 128 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      183314176      183313916        0             0        0    25.86    25.86    17.06    17.06
P1   up   RS(528,514)      183314228      183313980        0             0        0    25.86    25.86    17.06    17.06
LOOPBACK: FAIL rate: port 0 TX 25.86 Gb/s < 90.00 Gb/s line rate for 10 s

[2026-09-25 08:14:42] >> UART send: 'p 256'
loopback payload: 256 B UDP (302 B frames) - below ~726 B the packet rate limits the throughput
LOOPBACK: RUNNING 11 s (cross-port, 256 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      183304080      183303949        0             0        0    42.93    42.93    34.13    34.13
P1   up   RS(528,514)      183304132      183304014        0             0        0    42.93    42.93    34.13    34.13
LOOPBACK: FAIL rate: port 0 TX 42.93 Gb/s < 90.00 Gb/s line rate for 10 s

[2026-09-25 08:14:57] >> UART send: 'p 512'
loopback payload: 512 B UDP (558 B frames) - below ~726 B the packet rate limits the throughput
LOOPBACK: RUNNING 11 s (cross-port, 512 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      183304728      183304661        0             0        0    77.06    77.06    68.26    68.26
P1   up   RS(528,514)      183304780      183304727        0             0        0    77.06    77.06    68.26    68.26
LOOPBACK: FAIL rate: port 0 TX 77.06 Gb/s < 90.00 Gb/s line rate for 10 s

[2026-09-25 08:15:12] >> UART send: 'p 726'
loopback payload: 726 B UDP (772 B frames)
LOOPBACK: RUNNING 11 s (cross-port, 726 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      173589164      173589076        0             0        0   100.00   100.00    91.66    91.66
P1   up   RS(528,514)      173589213      173589137        0             0        0   100.00   100.00    91.66    91.66
LOOPBACK: PASS

[2026-09-25 08:15:27] >> UART send: 'p 1024'
loopback payload: 1024 B UDP (1070 B frames)
LOOPBACK: RUNNING 11 s (cross-port, 1024 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)      126129659      126129595        0             0        0   100.00   100.00    93.94    93.94
P1   up   RS(528,514)      126129695      126129639        0             0        0   100.00   100.00    93.94    93.94
LOOPBACK: PASS

[2026-09-25 08:15:42] >> UART send: 'p 1472'
loopback payload: 1472 B UDP (1518 B frames)
LOOPBACK: RUNNING 11 s (cross-port, 1472 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)       89386741       89386696        0             0        0   100.00   100.00    95.70    95.70
P1   up   RS(528,514)       89386766       89386727        0             0        0   100.00   100.00    95.70    95.70
LOOPBACK: PASS

[2026-09-25 08:15:57] >> UART send: 'p 1500'
loopback payload: 1500 B UDP (1546 B frames)
LOOPBACK: RUNNING 11 s (cross-port, 1500 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)       87787837       87787794        0             0        0   100.00   100.00    95.78    95.78
P1   up   RS(528,514)       87787862       87787825        0             0        0   100.00   100.00    95.78    95.78
LOOPBACK: PASS

[2026-09-25 08:16:12] >> UART send: 'p 9000'
loopback payload: 9000 B UDP (9046 B frames)
LOOPBACK: RUNNING 11 s (cross-port, 9000 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)       15164767       15164759        0             0        0   100.00   100.00    99.27    99.27
P1   up   RS(528,514)       15164771       15164764        0             0        0   100.00   100.00    99.27    99.27
LOOPBACK: PASS
```

### Cross-port loopback and echo-through (v1.3.0)

The `l` rows are the runs of the sweep above (and the auto-started run); the checked counts
are from the summary lines printed when each run was stopped, so every datagram in flight had
arrived. The `e` runs followed at 08:17:34 (1472 B) and 08:18:47 (9000 B), 30 s each, with the
latency statistics cleared (`T c`) just before each run and read with `T 1` just after it.

| test | payload | duration | per direction: line / payload rate | datagrams checked (P0 / P1) | seq / bit / len errors | verdict |
|---|---|---|---|---|---|---|
| `l` (auto-start) | 1472 B | 29 s | 100.00 / 95.70 Gb/s | 239,546,475 / 239,546,473 | 0 / 0 / 0 | PASS |
| `l` | 1472 B | 15 s | 100.00 / 95.70 Gb/s | 173,696,525 / 173,696,524 | 0 / 0 / 0 | PASS |
| `l` | 9000 B | 51 s | 100.00 / 99.27 Gb/s | 70,870,125 / 70,870,124 | 0 / 0 / 0 | PASS |
| `l` | 726 B | 15 s | 100.00 / 91.66 Gb/s | 239,016,385 / 239,016,382 | 0 / 0 / 0 | PASS |
| `l` | 512 B | 15 s | 77.06 / 68.26 Gb/s | 252,443,520 / 252,443,518 | 0 / 0 / 0 | FAIL rate (expected: generator packet-rate limit) |
| `e` (port 0 gen → port 1 hardware echo → port 0 chk) | 1472 B | 30 s | 100.00 / 95.70 Gb/s | 245,205,879 | 0 / 0 / 0 | PASS |
| `e` | 9000 B | 30 s | 100.00 / 99.27 Gb/s | 41,596,876 | 0 / 0 / 0 | PASS |

**Hardware echo latency during `e`** (port 1 bank 0, RX PCS → TX PCS of port 1's MRMAC, every
echoed datagram timestamped). 1.2.0 had no latency measurement.

| payload (frame) | samples | min | mean | max | stddev | p50 / p99 / p99.9 (bin upper edge) | bins (64 ns wide) |
|---|---|---|---|---|---|---|---|
| 1472 B (1518 B) | 245,205,879 | 808 | 831.1 | 845 | 1.0 | 832 / 845 / 845 | 768-832: 218,765,018; 832-896: 26,440,861 |
| 9000 B (9046 B) | 41,596,876 | 2969 | 2992.0 | 3006 | 2.4 | 3006 / 3006 / 3006 | 2944-3008: all |

All values in ns. `LAT_STATUS` 0, stale / lost / overflow 0, 0 implausible samples; bank 0 of
port 0 and bank 1 of both ports stayed empty (no other traffic). The sample count equals the
datagrams checked, and port 1's `RX_ECHO` = `TX_ECHO` = 286,802,755 (the sum of both runs) with
`RX_ECHO_DROP` 0. These match the 1.3.0 figures measured over JTAG on 2026-09-24/25 (see
[Hardware UDP echo at 100G](#hardware-udp-echo-at-100g-optical-loopback-e-test)) to within 1.3 ns.

```
[2026-09-25 08:17:34] >> UART send: 'e'
LOOPBACK-ECHO: started, port 0 generator -> port 1 hardware echo (UDP 7) -> port 0 checker (UDP 5001), 1472 B payload, continuous
LOOPBACK-ECHO: PASS
[2026-09-25 08:18:05] >> UART send: 'e'
Port 0: gen/chk 245205879/245205879 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
LOOPBACK-ECHO: stopped after 30 s (console)
[2026-09-25 08:18:05] >> UART send: 'T 1'
LATENCY port 1 (LAT_CTRL 0x00000301 LAT_STATUS 0x00000000, stale 0 lost 0 ovf 0, bins 64 ns from 0 ns; RX PCS -> TX PCS of the MRMAC)
bank 0 hardware UDP echo: count 245205879 min 808 mean 831.1 max 845 stddev 1.0 ns | p50 832 p90 845 p99 845 p99.9 845 ns | implausible 0 last 831 ns
bank 1 software TCP echo: no samples (implausible 0)

[2026-09-25 08:19:17] >> UART send: 'e'
Port 0: gen/chk 41596876/41596876 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
LOOPBACK-ECHO: stopped after 30 s (console)
[2026-09-25 08:19:17] >> UART send: 'T 1'
LATENCY port 1 (LAT_CTRL 0x00000301 LAT_STATUS 0x00000000, stale 0 lost 0 ovf 0, bins 64 ns from 0 ns; RX PCS -> TX PCS of the MRMAC)
bank 0 hardware UDP echo: count 41596876 min 2969 mean 2992.0 max 3006 stddev 2.4 ns | p50 3006 p90 3006 p99 3006 p99.9 3006 ns | implausible 0 last 2992 ns
```

### 10-minute soak (v1.3.0)

`p 1472`, then `c` at 08:19:41 (clears the zircon_nic counters and the application's MRMAC
totals, including the 19 link-up codewords of port 0; `s` then showed 0 everywhere), then `l`
at 08:19:46. The table at 621 s (for comparison with the 621 s of 1.2.0) and the totals when
`l` stopped it at 635 s (08:30:07):

| port | gen TX at 621 s | gen TX / chk RX at stop (635 s) | seq / bit / len errors | rate |
|---|---|---|---|---|
| 0 | 5,047,131,087 | 5,164,570,389 / 5,164,570,390 | 0 / 0 / 0 | 100.00 Gb/s line both ways in every table from 2 s on |
| 1 | 5,047,131,112 | 5,164,570,390 / 5,164,570,389 | 0 / 0 / 0 | 100.00 Gb/s line both ways in every table from 2 s on |

* About 7.60 TB of payload each way, checked bit by bit. `LOOPBACK: PASS` at 11 s, no
  `FAIL` and no link-down line in the 635 s.
* **RS-FEC:** 0 corrected and 0 uncorrected codewords on both MRMACs over the whole soak.
* **MRMAC:** 0 bad FCS. MRMAC RX frames of each port = the other port's generator total =
  this port's checker total, exactly (port 0: 5,164,570,390; port 1: 5,164,570,389). No lwIP
  frame crossed the link during the soak (raw 0).
* **zircon_nic:** `RX_FRAMES` read 869,603,094 (port 0) and 869,603,093 (port 1), which is the
  MRMAC count − 2³² exactly (the 32-bit counters wrapped once). `STATUS` 0, `LAT_STATUS` 0,
  `RX_BAD_FRAME`, `RX_FIFO_DROP`, `RX_L3_BAD_CSUM` / `RX_L4_BAD_CSUM`, `RX_RAW_DROP`,
  `RX_SOCK_DROP`, `RX_ECHO_DROP` and `TX_OVERSIZE_DROP` all 0.
* **Compared with 1.2.0** (621 s soak, 2026-09-24 18:45–18:56): the same result. 1.2.0 stopped
  at 5,049,248,412 datagrams per direction, 1.3.0 counted 5,047,131,112 at its 621 s table
  (the table is printed a fraction of a second before the stop point).

```
LOOPBACK: RUNNING 621 s (cross-port, 1472 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)     5047131087     5047131042        0             0        0   100.00   100.00    95.70    95.70
P1   up   RS(528,514)     5047131112     5047131074        0             0        0   100.00   100.00    95.70    95.70
[2026-09-25 08:30:07] >> UART send: 'l'
Port 0: gen/chk 5164570389/5164570390 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
Port 1: gen/chk 5164570390/5164570389 pkts, 0 seq err, 0 bit err, RX 100.00 Gb/s (TX 100.00 Gb/s, 0 len err)
LOOPBACK: stopped after 635 s (console)
[ 1039 s] P0 link UP FEC RS(528,514) cw corr 0 uncorr 0 | rx 869603094 raw 0 echo 0 sock 0 | tx 869603093 raw 0 echo 0 sock 0 | drop fifo 0 bad 0 csum 0/0 raw 0 sock 0 echo 0 txbig 0 st 0x0
          P0 MRMAC rx pkts 5164570390 good 5164570390 bad FCS 0 | tx pkts 5164570389 good 5164570389
[ 1039 s] P1 link UP FEC RS(528,514) cw corr 0 uncorr 0 | rx 869603093 raw 0 echo 0 sock 0 | tx 869603094 raw 0 echo 0 sock 0 | drop fifo 0 bad 0 csum 0/0 raw 0 sock 0 echo 0 txbig 0 st 0x0
          P1 MRMAC rx pkts 5164570389 good 5164570389 bad FCS 0 | tx pkts 5164570390 good 5164570390
```

The board was left running the v1.3.0 application with the loopback test stopped.

### Port 1 self-loopback on a loopback plug (measured on 1.2.0; not repeated)

This table was measured on 2026-09-24 with zircon_nic 1.2.0 and a passive QSFP28 loopback plug
in port 1 (port 0 cabled to the host E810). It was not repeated for 1.3.0 because the plug was
not fitted for the 1.3.0 measurement run. With 1.3.0 (JTAG load, 2026-09-25 07:35:59), `L 1` at
1472 B on the plug gave `LOOPBACK: PASS` at 100.00 Gb/s with 0 errors
(91,259,616 datagrams in 11 s) and port 1's `LAT_STATUS` 0.

The plug aligns with RS-FEC on. Each run below lasted 12 s (`LOOPBACK: RUNNING`, one table per
second). The rates are the application's rate-meter columns: line rate includes the
preamble/IPG overhead, payload rate is UDP payload only.

| payload | line rate TX = RX | payload rate | checker | verdict |
|---|---|---|---|---|
| 1472 B | 100.00 Gb/s | 95.70 Gb/s | 89,394,893 datagrams, 0 seq / 0 bit / 0 len errors | `LOOPBACK: PASS` |
| 9000 B | 100.00 Gb/s | 99.27 Gb/s | 15,164,623, 0 errors | PASS |
| 726 B | 100.00 Gb/s | 91.66 Gb/s | 173,589,011, 0 errors | PASS |
| 512 B | 77.06 Gb/s | 68.26 Gb/s | 183,314,304, 0 errors | FAIL rate (as expected) |
| 64 B | 17.33 Gb/s | 8.53 Gb/s | 187,128,404, 0 errors | FAIL rate (as expected) |

* **Rate registers read directly** (xsdb, 1472 B): one window was 8,127,485 frames and
  12,305,012,290 bytes in each direction, i.e. 100.001 Gb/s line rate.
* **After the runs**, port 1's `RX_FRAMES` = `TX_FRAMES` = 939,192,648, `STATUS` 0, all drop
  counters 0. Nothing wedged. Port 0's echo tests passed before and after the runs.
* **Same-subnet routing.** With port 1 on 192.168.21.2 (the same subnet as port 0's DHCP lease),
  TCP to port 0 at first timed out: lwIP sent the SYN-ACK out of port 1. The source-routing
  hook fixed it, and `zircon_echo_test.py --port 0` then passed in full.

### History (1.2.0)

The loopback figures of zircon_nic 1.2.0 (2026-09-24) that the 1.3.0 runs above repeat were the
same to within noise, so their tables are not kept here:

* **Throughput vs payload** (19:36–19:38, v1.2.0 `BOOT.BIN` from SD, same cable and method):
  identical line and payload rates at every size; packets/s 16,666,500 (64–512 B),
  15,782,780 (726 B), 11,467,850 (1024 B), 8,127,410 (1472 B), 7,982,090 (1500 B),
  1,378,774 (9000 B); 0 errors.
* **Cross-port and echo-through** (JTAG load, 18:41–18:45): `l` PASS at 1472, 9000 and 726 B,
  FAIL rate at 512 B (77.06 Gb/s), `e` PASS at 1472 and 9000 B, all with 0 errors; port 1
  echoed 106,873,949 datagrams with `RX_ECHO_DROP` 0.
* **Soak** (18:45:38–18:56:00): `l` at 1472 B for 621 s, 5,049,248,412 datagrams per direction,
  0 errors, 0 corrected / 0 uncorrected RS-FEC codewords, 0 bad FCS, all drop counters and
  `STATUS` 0.
* **SD-card boot and auto-start** (20:07:14 power-on, `LOOPBACK: PASS` at 20:07:45): 31 s.

#### Port 0 cabled to a host, port 1 empty (two-port build)

Measured on 2026-09-24. QSFP port 0 was cabled to the Intel E810-C and port 1 had no module.
The design was loaded over JTAG. Both ports came up, and the port without a module did not
disturb port 0:

```
zircon_nic 1.2.0 at 0x800a0000 (port 0)
Port 1: QSFP module NOT present
zircon_nic 1.2.0 at 0x801a0000 (port 1)
Port 0: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xf, FEC_CONFIGURATION_REG1 0x1008)
Port 1: link down: FEC RS(528,514), rx status 0x00000180, block lock 0x00000, FEC aligned 0 lane lock 0x0, local fault
Port 0: IP 192.168.21.162 mask 255.255.255.0 gw 192.168.21.1 (DHCP)
```

* **Port 1 retries without affecting port 0.** (That build still had the automatic FEC fallback;
  it has since been removed.) Port 1 keeps retrying and alternating FEC every
  10 s. Port 0 showed no link drop and 0 corrected or uncorrected codewords over the whole
  session. The loopback test did not auto-start.
* **`zircon_echo_test.py --port 0`: `VERDICT: PASS`.**
  * UDP sweep 1..1472 B intact.
  * UDP burst 20000/20000.
  * TCP echo 100/100.
  * Socket 55/55.
  * Checksum error counters +0.
* **12-byte UDP, 2,000,000 datagrams, window 64:** 2,000,000 echoed (162,949/s), 0 lost.
  * `RX_ECHO` = `TX_ECHO` = 2,021,473.
  * `RX_L4_BAD_CSUM`, `RX_BAD_FRAME`, the drop counters and `STATUS` stayed 0.
  * The MRMAC good-RX count matched `RX_FRAMES` apart from 1 frame. That frame arrived before
    the application cleared its MRMAC totals and was dropped while `CTRL.RX_EN` was still 0
    (`RX_FIFO_DROP` = 1).
* **Rate meters during that burst:** about 163,000 frames/s each way, e.g. `RATE_SEQ` 107:
  RX 163,807 frames / 9,828,420 B and TX 163,807 frames / 9,828,420 B, i.e. 0.110 Gb/s line rate.
* **Generator toward the host:** 1000 × 1000-byte payloads to the E810's port, paced with
  `GEN_GAP` 30,000 and 3,000.
  * The Linux UDP stack accepted all 1000 datagrams in each run (the IP and UDP checksums were
    good), from 192.168.21.162:5001.
  * Sequence numbers 0..999 were contiguous.
  * Every payload bit matched the definition.
  * With `GEN_GAP` = 0 (a 1000-datagram burst at full rate) the host socket buffer dropped
    about a third of them (`RcvbufErrors`). That is a host limit.
* **Checker from the host** (`zircon_prbs_tool.py send`):
  * 10,000 × 1000 B, sequence numbers 0..9999: `CHK_RX_PKTS` = 10,000, `CHK_SEQ_ERR` = 0,
    `CHK_BIT_ERR` = 0.
  * Then 1 datagram with one payload bit flipped: `CHK_BIT_ERR` = 1, `CHK_SEQ_ERR` = 0.
  * Then 100 × 1472 B continuing the sequence: no change.
  * Then a jump to sequence 20000: `CHK_SEQ_ERR` = 1.
  * `RX_L4_BAD_CSUM` = 0 throughout.
* **Not tested here:** the port-to-port loopback (it needs a port 0 ↔ port 1 cable) and jumbo
  frames (host MTU 1500).


### zircon_nic 1.1.0

Measured on 2026-09-24 with the same setup as 1.0.0 below: a VCK190 with the FMC on FMCP1,
QSFP port 0 cabled to an Intel E810-C with automatic FEC, and DHCP from the host on
192.168.21.0/24. The design was loaded over JTAG.

**Link and addressing.** The link came up at 100 Gb/s with RS-FEC on all three cold loads. The
E810 reported `Active FEC encoding: RS`.

```
zircon_nic 1.1.0 at 0x800A0000
MRMAC at 0x80000000 configured: 100GE, FEC RS(528,514) (FEC_CONFIGURATION_REG1 0x00001008)
Port 0: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xF, FEC_CONFIGURATION_REG1 0x1008)
Port 0: IP 192.168.21.162 mask 255.255.255.0 gw 192.168.21.1 (DHCP)
```

**`zircon_echo_test.py` (default options): `VERDICT: PASS` on each of the three cold loads.**

| test | result (first load) |
|---|---|
| ping | 3/3, RTT 64-68 us |
| UDP hardware echo sweep, 1..1472 B | 1472/1472 intact; RTT min 26 us, median 32 us, p99 124 us |
| UDP hardware echo burst, 20000 x 1472 B, window 64 | 20000/20000 |
| TCP software echo | 100/100 intact |
| UDP hardware socket | 55/55 bounced intact |
| host checksum error counters | +0 |

**Small-frame regression** (the 1.0.0 frame-merge case): 12-byte UDP datagrams to port 7.

| run | echoed | lost |
|---|---|---|
| 2,000,000 datagrams, window 64 | 2,000,000 (159,951/s) | 0 |
| 2,000,000 datagrams, window 256 | 1,999,929 | 71; the host counted the same 71 in `RcvbufErrors` (its socket buffer) |

Counters after both runs:

| counter | value |
|---|---|
| MRMAC good RX frames | 4,022,132 |
| zircon_nic `RX_FRAMES` | 4,022,132 |
| `RX_ECHO` = `TX_ECHO` | 4,021,474 |
| `RX_L4_BAD_CSUM` | 0 |
| `RX_BAD_FRAME` | 0 |
| `RX_FIFO_DROP` | 0 |
| `RX_RAW_DROP`, `RX_SOCK_DROP`, `RX_ECHO_DROP` | 0 |
| `STATUS` (incl. `RX_PACK_STALL`/`RX_PACK_OVF`) | 0 |

**Short payloads.** 1 to 17 bytes, 2,000 datagrams per size. The host pads these frames to 60
bytes. All 34,000 were echoed intact.

**Stalled raw path.** For 10 s the Cortex-A72 was halted (xsdb `stop` / `con`), so the raw
receive ring was not serviced. The host was sending two flows at the time:

| flow | result |
|---|---|
| hardware echo burst (3,000,000 × 64 B, window 16) | 3,000,000/3,000,000 echoed, none lost |
| raw flood, about 50,000 datagrams/s to UDP port 9 | 515,645 raw frames dropped and counted in `RX_RAW_DROP` |

Nothing wedged, `STATUS` stayed 0, and the raw path resumed after `con`.

As with 1.0.0, the packet rates here are limited by the host (one Python process using
sockets), not by the FPGA. Jumbo frames were not measured (host MTU 1500).


### zircon_nic 1.0.0 (history)

Measured on 2026-09-24 on a VCK190 with the 2x QSFP28 FMC on FMCP1. QSFP port 0 was cabled
to one port of an Intel E810-C (100G, Linux `ice` driver, FEC left at the driver's automatic
setting, auto-negotiation off). The link partner port was a NetworkManager "shared" connection
serving DHCP on 192.168.21.0/24. The design was loaded over JTAG (PDI + ELF).

**Link.** The link came up at 100 Gb/s with RS-FEC. The E810 reported `Speed: 100000Mb/s`,
`Link detected: yes` and `Active FEC encoding: RS`. The echo server printed:

```
MRMAC at 0x80000000 configured: 100GE, FEC RS(528,514) (FEC_CONFIGURATION_REG1 0x00001008)
Port 0: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xF, FEC_CONFIGURATION_REG1 0x1008)
Port 0: DHCP started
Port 0: IP 192.168.21.162 mask 255.255.255.0 gw 192.168.21.1 (DHCP)
```

FEC_CONFIGURATION_REG1 was A/B tested against the E810 by writing the register with the port
reset asserted:

| FEC_CONFIGURATION_REG1 | MRMAC RX status | E810 active FEC |
|---|---|---|
| 0x1008 (RS(528,514), four-lane PMD; what the application writes) | aligned (0x7) within 0.5 s | RS |
| 0x0008 (RS(528,514), as in AMD's example design) | aligned (0x7) within 0.5-2.5 s | RS |
| 0x0000 (FEC off) | no link in 10 s (local fault) | Off (the E810 reported link up) |

Link-up time after a cold power-on and JTAG load varied between immediate and about 30 s. The
wait comes from the partner: the application's retry and FEC fallback loop brings the link up
as soon as the E810 is ready. No RS-FEC corrected or uncorrected codewords were counted while
idle. Over about 1.5 million frames, 3 uncorrected and 0 corrected codewords were counted.

**`zircon_echo_test.py` (default options): `VERDICT: PASS`.**

| test | result |
|---|---|
| ping (raw path, lwIP) | 3/3, RTT 75-109 us |
| UDP hardware echo sweep, 1..1472 B | 1472/1472 intact; RTT min 34 us, median 48 us, p99 78 us |
| UDP hardware echo burst, 20000 x 1472 B, window 64 | 20000/20000, 107,474 pps (1.27 Gb/s payload each way) |
| TCP software echo, 1/64/1000/1460/20000 B x 20 | 100/100 intact |
| UDP hardware socket, 11 sizes x 5 up to 1472 B | 55/55 bounced intact |
| host UDP/IP checksum error counters | +0 |

zircon_nic counters after the run: `RX_ECHO` = `TX_ECHO`, `RX_SOCK` = `TX_SOCK` = 55,
`RX_BAD_FRAME` = 0, `RX_FIFO_DROP` = 0, `STATUS` = 0.

**Hardware echo bursts** (`--only udp --burst 65536 --window 16`, no datagram lost):

| UDP payload | echoed per second |
|---|---|
| 12 B | 150,634 |
| 64 B | 154,805 |
| 1472 B | 127,291 (1.50 Gb/s payload each way) |

These figures measure the host, not the FPGA. The judge is a single Python process using
ordinary UDP sockets (no root, no packet generator). The board echoed every datagram it
received: `RX_ECHO` = `TX_ECHO` over more than 1.4 million datagrams. The figures are a lower
bound for the hardware echo, not its capacity. Line-rate figures need a hardware traffic
generator.

**Jumbo frames: not measured.** The host port's MTU is 1500 and could not be changed on the
bench host, so `--jumbo` was not run.

**Issue found on the bench (RX width converter; fixed in 1.1.0).** Bursts of small datagrams with 64 or
more in flight lose between 1 datagram in 2,000 and 1 in 11,000. The loss comes in pairs. The raw-path buffers
show the cause: the first 48-byte beat of frame A is followed directly by all of frame B,
delivered as one frame. The second MRMAC beat of A (the one carrying tlast) was lost. The MRMAC
RX client cannot be back-pressured, and `mrmac_rx_axis_adapter` ignores the tready of the
48-to-64-byte `axis_dwidth_converter`. The merged frame fails the UDP checksum rule
(`RX_L4_BAD_CSUM`) and goes to the raw path, where lwIP drops it. The MRMAC counts one more
good frame than zircon_nic per event. `RX_BAD_FRAME` and `RX_FIFO_DROP` stay 0. The fix is in
the RTL (an RX width conversion that never stalls). With a window of 16 in flight, nothing was
lost in 196,608 datagrams.
<!-- /BENCH-RESULTS -->

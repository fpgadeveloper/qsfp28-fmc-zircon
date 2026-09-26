# Stand-alone echo server

The bare-metal application `echo_server` is the only software in the design; there is no Linux
image. It runs on the Versal PS (VCK190) or on a MicroBlaze (KCU116, port 0 only; see
[KCU116 differences](#kcu116-differences)) and is the **control plane**: it brings both 100G ports up,
configures the Zircon hardware and then mostly watches it. **There is no processor in the
datapath** of the UDP echo or of the loopback test.

Both QSFP ports offer the same services, each on its own address (port 0 and port 1 each have
their own MRMAC, zircon_nic, DMAs, MAC address and lwIP network interface):

| Service | Port | Handled by |
|---------|------|------------|
| **UDP echo** (headline demonstration) | UDP 7 | **The hardware** (UI1). The PS never sees these datagrams. |
| **UDP socket demo** | UDP 5000 | The hardware socket (UI2): the payload reaches the PS by DMA without headers, the PS sends it back, the hardware builds the reply headers |
| **TCP echo** (for comparison) | TCP 7 | lwIP in software, over the raw path (UI0) |
| Ping (ICMP echo), ARP, DHCP client | — | lwIP, over the raw path (UI0) |
| **Loopback test** (port 0 ↔ port 1 cable, or a loopback plug) | UDP 5001 | The hardware UDP generator and checker of each port; see [Loopback test](#loopback-test) |
| **Latency statistics** | UDP 5002 | lwIP, over the raw path (UI0): the latency the hardware measured for the UDP and TCP echoes; see [Latency measurement](#latency-measurement) |

TCP and UDP echo use the same port number, 7, but they are completely different paths. A TCP
segment to port 7 is not an IPv4/UDP datagram, so the hardware classifies it as raw and lwIP
answers it. A UDP datagram to port 7 is answered by the hardware before software could see it.

## Source files

The application is in `Vitis/common/src/`. Every setting a user is likely to change is in
`app_config.h`.

| File | Role |
|------|------|
| `main.c` | Bring-up sequence, main loop (lwIP timers, link and address polling, status lines, console keys) |
| `port.c` / `.h` | One QSFP port: all its resources in a `port_t` (MRMAC, GT GPIO, QSFP GPIO, zircon_nic, DMAs, MAC, lwIP netif, address mode and DHCP state, socket demo), its bring-up, link and address handling |
| `loopback.c` / `.h` | The loopback test: hardware generator/checker set-up, the once-a-second table, the PASS/FAIL verdict, auto-start |
| `console.c` / `.h` | Buffered UART output, drained without blocking from the main loop |
| `app_config.h` | Address modes and static addresses, ports, FEC mode, loopback test settings, console verbosity |
| `hw_config.h` | Base addresses of both ports, from the XSA's `xparameters.h`; `NUM_PORTS` |
| `vadj.c` / `.h` | Sets the VCK190's FMC VADJ rail to 1.5 V over the PS I2C (not used on the KCU116, whose VADJ is fixed at 1.8 V) |
| `si5328.c` / `.h` | Programs the FMC's Si5328 to 322.265625 MHz on both outputs (the GT reference clocks of port 0 and port 1) |
| `mac.h` | The MAC interface the rest of the application uses; picks `mrmac.c` (VCK190) or `cmac_taxi.c` (KCU116) at compile time |
| `mrmac.c` / `.h` | GT reset, MRMAC port configuration including RS-FEC, link status, statistics (VCK190) |
| `cmac_taxi.c` | The KCU116 CMAC shim: transceiver reset release, link status, statistics, the shim's timestamp timer |
| `timebase.c` / `.h` | The free-running 64-bit time base of the main loop: the Arm generic timer, or `axi_timer_1` on the MicroBlaze |
| `zircon.c` / `.h` | Driver for the [zircon_nic registers](registers.md) and the socket descriptor |
| `zdma.c` / `.h` | Polled scatter-gather AXI DMA driver with 64-byte aligned buffers |
| `zircon_netif.c` / `.h` | The lwIP network interface on UI0 (`axi_dma_raw`, `axi_dma_raw_1`), one instance per port |
| `sock_demo.c` / `.h` | The UI2 socket demo (`axi_dma_sock`, `axi_dma_sock_1`), one instance per port |
| `tcp_echo.c` / `.h` | A TCP echo server on the lwIP raw API; hands each request's RX timestamp to the netif for the latency measurement |
| `latency.c` / `.h` | [Latency measurement](#latency-measurement): MRMAC 1588 check at bring-up, the `T` report, the status-line summary, the UDP 5002 statistics service |
| `latency_wire.h` | The binary format of the UDP 5002 replies (shared with `scripts/zircon_echo_test.py`) |

The build driver (`Vitis/py/build-vitis.py`, configured by `Vitis/py/args.json`) creates a Vitis
platform from the exported XSA with the `lwip220` (DHCP enabled) and `xiltimer` libraries, builds
the application and packages `BOOT.BIN`. The lwIP options are overridden by
`EmbeddedSw/.../lwipopts.h.in` to force software checksums. Without that override, lwIP would
assume the VCK190's PS Ethernet controller computes checksums, which the zircon_nic raw path does
not do.

Everything is polled, with no interrupts: the DMA rings, the links, the console and the lwIP
timers (paced by the free-running system timer). Console output goes into a RAM buffer that the
main loop drains into the UART only as fast as the UART accepts it, so the once-a-second
loopback table never stalls the DMA service.

The number of ports, `NUM_PORTS`, follows the XSA (2 when it contains `axi_dma_raw_1`). Build with
`-DNUM_PORTS=1` for a port-0-only application.

## Bring-up sequence

`main()` brings the hardware up in this order. Each step depends on the previous one.

1. **VADJ = 1.5 V.** The FMC's I/O (Si5328 I2C bus, QSFP sideband) runs from VADJ. The
   application programs the VCK190's IR38164 regulator through the PS I2C0 bus and its I2C mux,
   so it does not depend on the board's system controller having picked the right voltage.
2. **Si5328 → 322.265625 MHz.** The Si5328 on the FMC runs free from its 114.285 MHz crystal.
   Until it is programmed there is no GT reference clock, and the transceivers cannot finish
   their reset. One programming serves both ports: CKOUT1 drives GBTCLK0 (port 0) and CKOUT2
   drives GBTCLK1 (port 1); the register table enables CKOUT2 (register 10 = 0x00, both outputs
   LVDS, NC2_LS = NC1_LS).
3. **Per port: zircon_nic.** The application checks the `ID` register, then programs the local
   MAC, the echo port (7), the socket port (5000), the TTL (64) and the checker port (5001). The
   datapath stays disabled. A port whose zircon_nic does not answer is disabled; the other port
   still runs.
4. **Per port: GT reset, then MRMAC.** A one-time GT reset through the port's own GT-control GPIO,
   then the MRMAC port configuration: 100G, "wide" SerDes, independent 384-bit AXI-Stream, RS-FEC
   written into `FEC_CONFIGURATION_REG1` while the port is held in reset, a maximum receive frame
   of at least 9600 bytes (9000-byte UDP payloads), FCS insertion and removal, and IEEE 1588
   2-step timestamping (`CONFIGURATION_1588_REG` bit 0 = 0, its reset value). The application
   then checks that the MRMAC's 1588 timer runs (see
   [Latency measurement](#latency-measurement)).
5. **lwIP.** One network interface per port on UI0 is added and brought up.
6. **Socket DMA.** Each port's socket demo arms its receive buffers.
7. **Latency measurement.** Histogram bins, both statistics banks cleared,
   `LAT_CTRL` = `EN | RAW_RX_DESC | RAW_TX_DESC`, and the network interface set to strip receive descriptors.
8. **Datapath on.** `CTRL` = `RX_EN | TX_EN | ECHO_EN | SOCK_EN` on each port.
9. **Services.** The TCP echo server starts on port 7 and the latency statistics service on
   UDP port 5002 (both listen on every address).
10. **Link.** The application waits up to 5 seconds for the links, then enters the main loop.
   While a link is down, the main loop re-runs that port's MRMAC reset every 2 seconds. The Versal
   GTY does not re-align on a link partner that appears after its last reset, so without this
   the cable would have to be connected before power-up.

The detailed register sequences (VADJ, Si5328, GT reset, MRMAC) are in the
[Bring-up notes](notes_bringup.md).

## KCU116 differences

The same application, built from the same sources, runs on the KCU116's MicroBlaze with one port
(port 0). The differences are selected at compile time:

* **Start-up.** The MicroBlaze start-up code leaves the caches off, so `main()` enables the
  instruction and data caches first, then starts the timebase (`axi_timer_1`, both counters
  cascaded into one 64-bit counter at 100 MHz). There is no VADJ step: the KCU116 fixes VADJ at
  1.8 V.
* **Si5328 before the transceivers.** The CMAC shim holds the transceivers and the CMAC in reset
  from power-on (`CTRL.XCVR_RST` = 1). After programming the Si5328 (322.265625 MHz on CKOUT1),
  the application releases that reset, waits for the transmit side to come out of reset, and
  prints the shim's status line (`Port 0: CMAC at 0x44000000 configured: …, FEC RS(528,514)
  (fixed) …`). The Taxi wrapper's transceiver reset sequencer needs the reference clock, so this
  order matters.
* **FEC is fixed** at RS(528,514) by the Taxi CMAC wrapper: `APP_FEC_MODE` is ignored, the `f` key
  prints `FEC fixed on this target`, and the status line shows `cw corr n/a uncorr n/a` (the
  wrapper has no RS-FEC counters).
* **Link retry.** While the link is down, the application pulses the CMAC's receive reset every
  2 seconds, and the Taxi wrapper also resets the CMAC receiver by itself after about 0.83 s
  without alignment.
* **Memory.** The application's code, data and stack live in the MicroBlaze's 256 KB local memory
  (it uses about 83 % of it), so they can be embedded in the bitstream; the lwIP buffers and the
  DMA rings (about 7 MB) are in DDR4.
* **Speed.** The 100 MHz MicroBlaze makes everything that goes through software slower: the TCP
  echo takes about 0.1 to 0.5 ms instead of 7 to 10 µs. The hardware echo, socket headers,
  generator and checker are not affected.
* **UART strings.** The lines the tests look for (`Port 0: link up, 100 Gb/s, FEC RS(528,514)`,
  `Port 0: IP …`, `zircon_nic 1.3.0 at 0x440a0000 (port 0)`) are the same as on the VCK190.

## Building the Vitis workspace

Follow the [build instructions](build_instructions.md#build-vitis-workspace). This command
builds the Vivado project first if needed, then the Vitis workspace, and gathers the boot file:

```
./build.sh standalone --target vck190_fmcp1
```

The result is `Vitis/boot/vck190_fmcp1/BOOT.BIN`, which contains the device image (PDI) and the
application. For the KCU116, `./build.sh standalone --target kcu116` produces
`Vitis/boot/kcu116/zircon_boot.bit`, the bitstream with the application embedded in the
MicroBlaze's local memory (and `./build.sh all --target kcu116` also the QSPI image
`zircon_boot.mcs`).

## Run the application

You need the [2x QSFP28 FMC] on the VCK190's **FMCP1** connector and the VCK190's USB-C cable
connected to your PC for the UART console, and either

* a QSFP28 cable between **QSFP port 0 and QSFP port 1** of the FMC, for the
  [loopback test](#loopback-test) (no other equipment needed), or
* a QSFP28 module or cable in **QSFP port 0 and/or port 1**, connected to an RS-FEC-capable 100G
  link partner (see [Testing](testing.md)).

### From an SD card

1. Copy `Vitis/boot/vck190_fmcp1/BOOT.BIN` to the root of a FAT32-formatted microSD card.
2. Insert the card into the Versal boot microSD slot of the VCK190 (the board has a second
   microSD slot, which belongs to its system controller) and set the boot-mode switch **SW1** to
   SD boot. Refer to the VCK190 user guide (UG1366) for the slot and switch positions.
3. Power on the board. The PLM loads the device image and starts the application.

### Over JTAG

With the boot-mode switch **SW1** set to JTAG, the same `BOOT.BIN` can be loaded with `xsdb`
(part of Vitis):

```
xsdb
xsdb% connect
xsdb% targets -set -filter {name =~ "Versal*"}
xsdb% device program Vitis/boot/vck190_fmcp1/BOOT.BIN
```

Alternatively, open the workspace `Vitis/vck190_fmcp1_workspace` in the Vitis Unified IDE and run
the `echo_server` application on the hardware.

### On the KCU116

Fit the [2x QSFP28 FMC] on the KCU116's **HPC** connector and connect the board's USB-UART and
USB-JTAG ports. Then either load `Vitis/boot/kcu116/zircon_boot.bit` over JTAG, or program
`zircon_boot.mcs` into the QSPI flash once and power-cycle the board: see
[KCU116: bitstream and QSPI flash](build_instructions.md#kcu116-bitstream-and-qspi-flash). The
echo server starts as soon as the FPGA is configured. Only QSFP port 0 is used.

## UART settings

The console is the Versal PS UART0 at **115200 baud**, 8 data bits, no parity, 1 stop bit. The
VCK190's USB-C connection exposes several serial ports; the Versal UART0 is normally the second
one (`/dev/ttyUSB1` on a Linux PC). Use a terminal program such as [Putty] (Windows) or
`picocom` / `minicom` (Linux).

On the KCU116 the console is an AXI UART Lite in the FPGA, also at 115200 8N1, on the board's
USB-UART (a CP2105 with two ports: use the **Enhanced** port, which is usually the second one,
`/dev/ttyUSB1` on a Linux PC).

## Console output

After the Versal boot messages, the application prints its banner and the steps of the bring-up.
This is the start of a boot from the SD card on the bench (2026-09-25), with a QSFP28 cable between
port 0 and port 1 and so no DHCP server on either link. The help text and the repeated status
lines are cut:

```
----- 2x QSFP28 FMC Zircon echo server (VCK190) -----
QSFP ports: 2 x 100GbE, Versal MRMAC (CAUI-4, FEC RS(528,514)) + zircon_nic (Taxi Zircon)
Port 0: address mode dhcp-then-static (10 s)
Port 1: address mode dhcp-then-static (10 s)
VADJ enabled (1.5V)
Si5328 programmed: GT refclk 322.265625 MHz (CKOUT1 port 0, CKOUT2 port 1)
Port 0: MAC 00:0a:35:06:21:a0
Port 0: QSFP module present
zircon_nic 1.3.0 at 0x800a0000 (port 0)
Port 0: MRMAC at 0x80000000 configured: 100GE, FEC RS(528,514) (FEC_CONFIGURATION_REG1 0x00001008), RX max frame 9600 B
Port 0: 1588 timestamping enabled (2-step), CONFIGURATION_1588_REG 0x00000002
Port 0: MRMAC 1588 timer 2.209267557 s, advanced TX 9907899 ns RX 9907898 ns in 9907869 ns of A72 time (systimer samples); increment TX 0x18d3018d302 RX 0x18d3018d302
Port 1: MAC 00:0a:35:06:21:a1
Port 1: QSFP module present
zircon_nic 1.3.0 at 0x801a0000 (port 1)
Port 1: MRMAC at 0x80100000 configured: 100GE, FEC RS(528,514) (FEC_CONFIGURATION_REG1 0x00001008), RX max frame 9600 B
Port 1: 1588 timestamping enabled (2-step), CONFIGURATION_1588_REG 0x00000002
Port 1: MRMAC 1588 timer 2.270005854 s, advanced TX 9907879 ns RX 9907878 ns in 9907909 ns of A72 time (systimer samples); increment TX 0x18d3018d302 RX 0x18d3018d302
Port 0: latency measurement on: bank 0 hardware UDP echo, bank 1 software TCP echo; histogram 64 ns bins from 0 ns ('T' to print)
Port 1: latency measurement on: bank 0 hardware UDP echo, bank 1 software TCP echo; histogram 64 ns bins from 0 ns ('T' to print)
TCP echo server started @ port 7
UDP echo (hardware) on port 7, UDP socket demo (hardware) on port 5000, TCP echo (software) on port 7, latency statistics on UDP port 5002 - on every QSFP port
Keys: h help, s status, z zircon registers, f cycle FEC mode, c clear counters
      ...
Waiting for the 100G links...
Port 0: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xf, FEC_CONFIGURATION_REG1 0x1008)
Port 0: DHCP started
Port 1: link up, 100 Gb/s, FEC RS(528,514) (aligned, lane lock 0xf, FEC_CONFIGURATION_REG1 0x1008)
Port 1: DHCP started
[    5 s] P0 link UP FEC RS(528,514) cw corr 0 uncorr 19 | rx 1 raw 1 echo 0 sock 0 | tx 1 raw 1 echo 0 sock 0 | drop fifo 0 bad 0 csum 0/0 raw 0 sock 0 echo 0 txbig 0 st 0x0
[    5 s] P1 link UP FEC RS(528,514) cw corr 0 uncorr 0 | rx 1 raw 1 echo 0 sock 0 | tx 1 raw 1 echo 0 sock 0 | drop fifo 0 bad 0 csum 0/0 raw 0 sock 0 echo 0 txbig 0 st 0x0
      ...
Port 0: no DHCP lease after 10 s, falling back to static
Port 0: IP 192.168.20.2 mask 255.255.255.0 gw 192.168.20.1 (static)
Port 1: no DHCP lease after 10 s, falling back to static
Port 1: IP 192.168.21.2 mask 255.255.255.0 gw 192.168.21.1 (static)
      ...
LOOPBACK: every port has link and no DHCP server answered in 15 s: assuming a port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)
LOOPBACK: started, cross-port: port 0 -> port 1 and port 1 -> port 0 (UDP 5001 -> 5001), 1472 B payload, continuous
```

With a DHCP server on a link (for example a host NIC that serves addresses), the port prints
`Port <n>: IP <address> ... (DHCP)` instead, and the loopback test is not started. The
uncorrectable codewords of port 0 above (`uncorr 19`) were counted while the link came up: the
count was already 19 in the first status line and did not change in the lines that followed.

After that, a **status line** per port is printed whenever one of its counters changes (at most
once a second), and every 30 seconds as a heartbeat. For example:

```
[   42 s] P0 link UP FEC RS(528,514) cw corr 0 uncorr 0 | rx 118 raw 12 echo 100 sock 6 | tx 118 raw 12 echo 100 sock 6 | drop fifo 0 bad 0 csum 0/0 raw 0 sock 0 echo 0 txbig 0 st 0x0
```

| Field | Meaning |
|-------|---------|
| `P0`, `P1` | The QSFP port |
| `link`, `FEC` | Link state and the FEC mode in use |
| `cw corr` / `uncorr` | RS-FEC codewords corrected / uncorrectable, from the MRMAC statistics. A few corrected codewords are normal; uncorrectable ones mean a bad cable or module. |
| `rx … raw echo sock` | `RX_FRAMES` and the frames routed to each user interface |
| `tx … raw echo sock` | `TX_FRAMES` and the frames built per source |
| `drop fifo`, `bad`, `csum` | `RX_FIFO_DROP`, `RX_BAD_FRAME`, `RX_L3_BAD_CSUM` / `RX_L4_BAD_CSUM` |
| `raw sock echo txbig`, `st` | `RX_RAW_DROP`, `RX_SOCK_DROP`, `RX_ECHO_DROP`, `TX_OVERSIZE_DROP`, `STATUS` |

Once the hardware UDP echo has answered at least one request, the line ends with a summary of its latency (bank 0, see [Latency measurement](#latency-measurement)):
` | hw lat n <count> min <ns> mean <ns> p99 <ns> max <ns> ns`.

While a loopback test runs, its once-a-second table replaces these lines.

A second line appears when one of the software error counters (DMA errors, lwIP errors, socket
errors) is not zero.

### Console keys

| Key | Action |
|-----|--------|
| `h` or `?` | Print the list of keys |
| `s` | Print the full status of every port now, including the MRMAC packet counters, the link diagnostics of a port whose link is down, and the loopback table |
| `z` | Dump the zircon_nic registers and counters of every port, including the generator / checker registers |
| `c` | Clear the zircon_nic counters of every port (`CTRL.STAT_CLR`, which also clears the generator and checker counters) and restart the loopback verdict |
| `f` | Cycle the MRMAC FEC mode of both ports: RS(528,514) → off → RS(544,514) → RS(528,514), resetting the MACs each time (see [FEC mode](#fec-mode)) |
| `l` | Start / stop the cross-port [loopback test](#loopback-test) |
| `e` | Start / stop the echo-through-loopback test |
| `L <port>` Enter | Start or stop the self-loopback test on one port. It needs a QSFP28 loopback plug in that port: the port's generator sends to its own MAC/IP and CHK_PORT, the plug returns the frames to the same port's checker. `L` Enter alone stops it. Same table and PASS/FAIL verdict as `l` |
| `p <bytes>` Enter | Set the UDP payload size of the loopback tests, 8 to 9000 (default 1472); a running test restarts with the new size |
| `i <port> <mode>` Enter | Set the [address mode](#addressing) of a port, applied at once: `dhcp`, `static` or `auto` (DHCP, then the static address). `i` Enter alone shows the mode and address of every port |
| `T` Enter | Print the [latency statistics](#latency-measurement) of every port. `T <port>` Enter: one port only. `T c` Enter (or `T <port> c`): clear them |

## Addressing

Each port has its own IPv4 address and its own **address mode**:

| Mode | Console | Behaviour |
|------|---------|-----------|
| `IP_MODE_DHCP_THEN_STATIC` (default) | `auto` | A DHCP client starts as soon as the link is up. If no lease arrives within 10 seconds (`DHCP_TIMEOUT_MS`), the port uses its static address. |
| `IP_MODE_STATIC` | `static` | No DHCP. The static address is in use from start-up, before the link is up, with no 10-second wait. |
| `IP_MODE_DHCP` | `dhcp` | DHCP only. The client keeps retrying and the port never uses the static address; until a lease arrives it has no address (a reminder is printed every 30 s). |

The static addresses are:

| Port | Static address | Netmask | Gateway | MAC address |
|------|----------------|---------|---------|-------------|
| 0 | `192.168.20.2` | `255.255.255.0` | `192.168.20.1` | `00:0a:35:06:21:a0` |
| 1 | `192.168.21.2` | `255.255.255.0` | `192.168.21.1` | `00:0a:35:06:21:a1` |

**At build time**, set `IP_MODE_DEFAULT` in `app_config.h` to one of the three modes (it applies to
every port; `IP_MODE_DEFAULT_1` overrides it for port 1). The static addresses are
`STATIC_IP_ADDR`, `STATIC_IP_MASK` and `STATIC_IP_GW` for port 0, and the same names with `_1` for
port 1. Every setting can also be passed as a `-D` compiler option. The older
`APP_FORCE_STATIC=1` still works and means `IP_MODE_STATIC`.

**At run time**, type `i`, a port number, a mode and Enter on the console, for example
`i 0 static`. The port changes its addressing at once: `static` applies the static address,
`dhcp` and `auto` release any lease and start DHCP again (straight away if the link is up). `i`
Enter alone shows the mode and address of every port; so does `s`. The change lasts until the
next reset.

If a loopback test is running on that port, `i` stops it, because the port's checker only accepts
datagrams sent to the port's current address:

* With `static`, the test restarts at once with the new address.
* With `dhcp` or `auto`, it stays stopped (`LOOPBACK: stopped after <t> s (address mode of port
  <n> changed)`) until you start it again. In `dhcp` mode, `l` refuses to start while the port has
  no lease (`LOOPBACK: cannot start: port <n> has no IPv4 address …`).

**A host NIC cabled directly to the board** is the most common bench set-up, and there is
usually no DHCP server on that cable. Give the host NIC a static address in the port's subnet
and use the `static` mode on the board, so the port has its address as soon as it boots:

```
sudo ip addr add 192.168.20.1/24 dev <if>     # host NIC cabled to QSFP port 0
```

and build with `IP_MODE_DEFAULT` = `IP_MODE_STATIC` (or type `i 0 static`). The board is then
`192.168.20.2`. For port 1, use `192.168.21.1/24` on the host and `192.168.21.2` on the board. The
default mode works on the same cable too, but the port has no address for its first 10 seconds.

The UART lines of the addressing are:

| UART line | When |
|-----------|------|
| `Port <n>: address mode dhcp-then-static (10 s)`, `… static (no DHCP)`, `… dhcp (no static fallback)` | At start-up, after `i`, and on `s` |
| `Port <n>: DHCP started` | The DHCP client started (link up) |
| `Port <n>: IP a.b.c.d mask m.m.m.m gw g.g.g.g (DHCP)` or `(static)` | The address in use, whenever it is set or changes |
| `Port <n>: no DHCP lease after 10 s, falling back to static` | `auto` mode, no DHCP server |
| `Port <n>: no DHCP lease after <t> s (address mode dhcp, no static fallback: …)` | `dhcp` mode, every 30 s without a lease |
| `Port <n>: no IPv4 address yet (…)` | `i` or `s` while a port has no address |

The application copies the address into the port's zircon_nic `IPV4` register every time it
changes (including after `i`), because the hardware echo, socket and checker only answer
datagrams sent to that address. With no address, the register is 0.

The two ports may share a subnet (for example port 0 leased by DHCP and port 1 on its static
address). The lwIP build uses source-address routing (`LWIP_HOOK_IP4_ROUTE_SRC`, in
`zircon_netif.c`), so each port's software replies (ping, TCP) leave through the port that owns
the address.

The MAC address of port 0 is `APP_MAC_ADDR` in `app_config.h`; port *n* adds *n* to its last
byte.

## FEC mode

On the KCU116 the FEC is fixed at RS(528,514) and cannot be changed (see
[KCU116 differences](#kcu116-differences)); the rest of this section is about the VCK190.

The MRMAC is built with **RS-FEC (clause 91, RS(528,514))**, which is what 100GBASE-CR4, SR4 and
LR4 link partners expect. A partner set to FEC "auto" negotiates it.

The application writes the FEC mode chosen by `APP_FEC_MODE` (default RS(528,514)) into the
MRMAC and keeps it: there is no automatic FEC fallback by default (`FEC_FALLBACK_MS` = 0). A
port-to-port loopback needs both ports in RS-FEC, and a port that had fallen back to FEC off
while waiting would never link to the other. While a link is down the MAC is reset every 2 s,
and a link diagnostic is printed every `LINK_DIAG_MS` (30 s). The `f` key cycles both ports
through RS(528,514), off and RS(544,514) by hand (for a partner forced to FEC off). Setting
`FEC_FALLBACK_MS` to a non-zero value (ms) restores the old automatic alternation between the
chosen mode and FEC off.

```{note}
Switching the FEC off at run time on an MRMAC that was built for RS-FEC is a register write the
MRMAC supports, but this design has not yet been validated with FEC off on the bench. RS-FEC is
the tested configuration.
```

## Example usage

In these examples the board got the address `192.168.20.23`. Run the commands on a PC connected
to the board's 100G port (directly or through a switch).

### Ping

```
ping 192.168.20.23
```

The reply comes from lwIP, over the raw path.

### TCP echo (software)

```
telnet 192.168.20.23 7
```

Everything you type is echoed back by lwIP.

### UDP echo (hardware)

With a netcat that supports UDP (`-u`):

```
echo "hello zircon" | nc -u -w1 192.168.20.23 7
```

The reply is built entirely by the hardware. The status line shows `echo` incrementing in both
`rx` and `tx`, while `raw` does not change.

### UDP socket demo (hardware socket)

```
echo "hello socket" | nc -u -w1 192.168.20.23 5000
```

The datagram arrives at the software as a descriptor and a payload. The application prints the
descriptor of the first 8 datagrams of each port:

```
Port 0: sock connected to peer 192.168.20.1:40123 (aa:bb:cc:dd:ee:ff)
Port 0: sock rx #1 len 13 (dma 77) from 192.168.20.1:40123 aa:bb:cc:dd:ee:ff to 192.168.20.23:5000 flags 0x80000208
```

The first datagram *connects* the socket: the application copies the sender's MAC, IP address
and port into the `SOCK_REMOTE_*` registers. It then writes the payload back to the socket's
transmit channel, and the hardware builds the reply headers from those registers. If a datagram
comes from a different sender, the application re-connects the socket to it, so repeated tests
from new source ports keep working.

For a complete automated test of all three services, see [Testing](testing.md)
(`scripts/zircon_echo_test.py --port 1` tests port 1).

## Loopback test

On the KCU116, which has one port, the tests need a QSFP28 loopback plug in port 0: `L 0` (or
`l`, the same test on a one-port build) runs port 0's generator through the plug into its own
checker at 100 Gb/s line rate, and `e` sends the generator's requests through the plug to port 0's
own hardware echo. In `e` the requests and the replies share port 0's transmit path, so each gets
half of the line, and at small payloads (64 B) the echo drops some requests for lack of transmit
room. Measured results: [Testing](testing.md#loopback-plug-port-0-2026-09-25-19401954).

The loopback test checks both ports at the full 100 Gb/s **without a 100G host**: connect a
QSFP28 cable (DAC, AOC or optical) between **QSFP port 0 and QSFP port 1** of the FMC. Each
port's zircon_nic has a hardware UDP **generator** and **checker** and hardware **rate meters**
([registers](registers.md), DESIGN_SPEC §10); the processor only configures them and prints the
counters.

* The generator sends UDP datagrams back to back. Each payload starts with a 64-bit sequence
  number, followed by a pseudo-random pattern seeded from that number.
* The checker takes every datagram sent to its port (UDP **5001**) in hardware. It checks the
  sequence number (a lost, duplicated or reordered datagram counts one **seq err**), regenerates
  the pattern and counts every differing payload bit (**bit err**), and counts datagrams too
  short to carry a sequence number (**len err**).
* The rate meters count the bytes and frames each port sends and receives per second.

### Test modes

| Key | Mode | Traffic |
|-----|------|---------|
| `l` | Cross-port | Port 0 generator → cable → port 1 checker **and** port 1 generator → cable → port 0 checker at the same time: 2 × 100 Gb/s, full duplex. Each generator addresses the other port's MAC and IP address, UDP 5001 → 5001. |
| `e` | Echo through the loopback | Port 0 generator → cable → port 1 **hardware UDP echo** (port 7) → cable → port 0 checker. The echo swaps addresses and ports, so the generator uses source port 5001 and the reply lands in port 0's checker. This exercises the complete receive-parse → transmit-deparse path of port 1 at line rate. |

Pressing the same key again stops the test. With a one-port build (`NUM_PORTS = 1`) and a QSFP28
loopback plug, `l` and `e` run the same tests with port 0 talking to itself.

**Automatic start.** A customer who has just cabled port 0 to port 1 does not need to type
anything: when both ports have link and neither received a DHCP lease within 15 seconds
(there is no DHCP server on a port-to-port cable, so both fell back to their static addresses),
the application starts the `l` test by itself. If the checkers then receive nothing within
3 seconds, the ports were not cabled to each other, and the test stops again. `l` stops the
test at any time. How the start depends on the [address mode](#addressing):

* `static` on both ports: there is no DHCP to wait for, so the test starts once both links have
  been up for 15 seconds.
* `auto` (the default): as described above; a port that ever got a DHCP lease switches the
  automatic start off until the next reset.
* `dhcp` on either port: no automatic start, because that port has no address without a DHCP
  server. Type `i <port> static` (the automatic start then applies again) or `l` after that.

Set `LOOPBACK_AUTOSTART` in `app_config.h` to 1 to always start when the links are up, or to -1
to never start automatically.

**Payload size.** `p <bytes>` followed by Enter sets the UDP payload size (8 to 9000 bytes,
default 1472; `LOOPBACK_LEN` in `app_config.h`). The Zircon header path builds and parses one
packet every 16 to 18 core cycles (about 16.7 Mpps on transmit and 18.75 Mpps on receive), so
**100 Gb/s line rate needs payloads of about 726 bytes and up**. With smaller payloads the
transmit side is the limit: it sends one packet every 18 core cycles, 16.67 million packets
per second, so the rate stays below 100 Gb/s. The receive side keeps up
with that rate, so there are no sequence errors; the test fails on rate only
(`LOOPBACK: FAIL rate: …`). Jumbo payloads up to 9000 bytes are far from the limit.

### Output

Once a second while a test runs, the application prints a table with fixed columns:

```
LOOPBACK: RUNNING 12 s (cross-port, 1472 B payload)
port link FEC            gen TX pkts    chk RX pkts  seq err       bit err  len err  TX Gb/s  RX Gb/s  TX pay.  RX pay.
P0   up   RS(528,514)       97560012       97559980        0             0        0    99.99    99.99    95.70    95.70
P1   up   RS(528,514)       97560007       97559975        0             0        0    99.99    99.99    95.70    95.70
```

| Column | Meaning |
|--------|---------|
| `gen TX pkts` | Datagrams sent by this port's generator since the start (`GEN_TX_PKTS`) |
| `chk RX pkts` | Datagrams checked by this port's checker (`CHK_RX_PKTS`). In the cross-port mode, P1's checker receives P0's generator and vice versa. |
| `seq err`, `bit err`, `len err` | Checker errors since the start (`CHK_SEQ_ERR`, `CHK_BIT_ERR`, `CHK_LEN_ERR`) |
| `TX Gb/s`, `RX Gb/s` | **Line rate** measured by the port's rate meters over the last second, including the 24 bytes per frame the meters do not see (FCS, preamble and inter-packet gap): 8 × (bytes + 24 × frames). 100 Gb/s is the maximum. |
| `TX pay.`, `RX pay.` | The same traffic without the Ethernet, IPv4 and UDP headers (42 bytes per frame): the UDP payload rate |

The counters are 64-bit totals kept by the application, so they do not wrap during a long run.
The rate meters count every frame on the port, including the few frames of lwIP.

After 10 seconds in which every direction runs at **90 Gb/s or more** (line rate) with **no
errors**, the application prints a summary line per port and the verdict, once:

```
Port 0: gen/chk 97560012/97559980 pkts, 0 seq err, 0 bit err, RX 99.99 Gb/s (TX 99.99 Gb/s, 0 len err)
Port 1: gen/chk 97560007/97559975 pkts, 0 seq err, 0 bit err, RX 99.99 Gb/s (TX 99.99 Gb/s, 0 len err)
LOOPBACK: PASS
```

If errors are counted and 10 seconds pass, or the rate stays below 90 Gb/s (or a link is down) for
10 seconds, it prints the summary and one of:

```
LOOPBACK: FAIL errors (sequence / bit / length errors counted by the checker)
LOOPBACK: FAIL rate: port 1 RX 45.12 Gb/s < 90.00 Gb/s line rate for 10 s
LOOPBACK: FAIL link down
```

The test keeps running after the verdict, so the table can be watched for as long as needed;
`c` clears the counters and restarts the verdict, `l` stops the test. The echo-through-loopback
mode prints the same lines with the prefix `LOOPBACK-ECHO:` instead of `LOOPBACK:` (for example
`LOOPBACK-ECHO: PASS`). The pass threshold and the verdict time are `LOOPBACK_PASS_CGBPS` and
`LOOPBACK_VERDICT_S` in `app_config.h`.

| UART line | When |
|-----------|------|
| `LOOPBACK: every port has link and no DHCP server answered in 15 s: assuming a port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)` | Automatic start |
| `LOOPBACK: every port has had link for 15 s (address mode static): assuming a port 0 <-> port 1 loopback cable, starting the test (type 'l' to stop it)` | Automatic start, both ports in `static` mode |
| `LOOPBACK: cannot start: port <n> has no IPv4 address (type 'i <n> static' or 'i <n> auto' first)` | A port in `dhcp` mode has no lease |
| `LOOPBACK: started, cross-port: port 0 -> port 1 and port 1 -> port 0 (UDP 5001 -> 5001), 1472 B payload, continuous` | Test started (`l` or automatic) |
| `LOOPBACK-ECHO: started, port 0 generator -> port 1 hardware echo (UDP 7) -> port 0 checker (UDP 5001), 1472 B payload, continuous` | Test started (`e`) |
| `LOOPBACK: RUNNING <t> s (<mode>, <n> B payload)` | Every second, followed by the table |
| `Port <n>: gen/chk <tx>/<rx> pkts, <e> seq err, <b> bit err, RX <x> Gb/s (TX <y> Gb/s, <l> len err)` | Summary, before a verdict and when the test stops |
| `LOOPBACK: PASS` | Once, after 10 s at ≥ 90 Gb/s in every direction with zero errors |
| `LOOPBACK: FAIL <reason>` | Once, after 10 s of errors, low rate or link down |
| `LOOPBACK: stopped after <t> s (<why>)` | Test stopped |
| `LOOPBACK: no loopback traffic seen - port 0 and port 1 do not seem to be cabled to each other (type 'l' to run the test anyway)` | An automatic start found no loopback |

For the bench procedure, see [Testing](testing.md#loopback-test-no-host-nic-required).

## Latency measurement

zircon_nic measures how long each echoed frame spends in the board, in hardware, with the
MRMAC's IEEE 1588 timestamps. It measures the hardware UDP echo and the software TCP echo with
the same clock and the same arithmetic, so the two numbers compare directly. On a zircon_nic
older than 1.3.0 (an older device image) the application prints `NOTE: Port <n>: zircon_nic < 1.3.0: no latency
measurement` and everything in this section is absent.

### What is measured

Both MRMACs run 1588 **2-step** timestamping against one shared 55-bit timer (250 MHz, in units
of 2⁻⁸ ns; see [Latency measurement hardware](design.md#latency-measurement-hardware)). A
timestamp marks the **first PCS block of a frame** in the MRMAC. The measured latency of an echo
is therefore:

> TX timestamp of the reply − RX timestamp of the request =
> from the first block of the request leaving the receive PCS to the first block of the reply
> entering the transmit PCS.

* **Included:** everything between the two PCS layers: the MRMAC MAC, the RX packer and FIFO,
  the Zircon parser, the echo or software path, the deparser, the egress FIFO and the 512 → 384-bit
  width converter. These stages are store-and-forward, so the latency grows with the frame size.
* **Excluded:** the serdes, the PCS and the RS-FEC in both directions, the QSFP modules and the
  cable, and of course the host. A host round-trip time includes all of them twice, plus the
  host's own network stack.

Each zircon_nic keeps two **statistics banks**:

| Bank | Name | What is timestamped |
|------|------|---------------------|
| 0 | hardware UDP echo | Every reply of the hardware UDP echo (UDP port 7, UI1). The processor is not involved at all. |
| 1 | software TCP echo | Every raw-path (UI0) frame that software sends with a TX timestamp descriptor (below). The TCP echo attaches one to the first segment of each echo, carrying the RX timestamp of the segment that brought the request. The time includes the raw-path FIFOs, both DMAs, the main loop's polling, lwIP and the copies. |

Per bank the hardware keeps the count, the sum and sum of squares (ns, ns²), the minimum, the
maximum, the last value, a count of **implausible** deltas (1 s or more, for example after a
link reset) that it keeps out of everything else, and a **64-bin histogram**. The histogram
geometry is shared by both banks: bins 0 to 47 are linear, `LAT_BIN_WIDTH` wide (a power of two)
from `LAT_BIN_BASE` (default 64 ns from 0, so 0 to 3072 ns);
bins 48 to 62 double in width (3072 ns to about 100 ms); bin 63 counts everything above. Bin 0
also counts values below the base. The software TCP echo takes about 6 to 11 µs, so it lands
in the doubling bins and its percentiles have a resolution of one octave. To look at it
in detail, build with `LAT_BIN_BASE_NS` / `LAT_BIN_WIDTH_NS` (in `app_config.h`) set to cover it,
for example 4096 and 1024.

The software measurement is exact for request/response traffic: **one request in flight** that
fits in **one TCP segment**, with Nagle off on the host (`TCP_NODELAY`; Nagle is always off on the
board). Then the segment carrying the request and the segment carrying its echo pair up one to
one. If requests are pipelined, coalesced or split into several segments, a sample is only taken
for the echo that leaves while its request is being processed. The application does not
attribute echoes that go out later (for example from lwIP's timers), but a single sample can
then cover more than one request.

On the **KCU116** the timestamps come from the CMAC shim instead of the MRMAC: the same 55-bit
format and the same banks, but taken at the start of the frame at the CMAC's **client**
interface, quantised to 4 ns. The latency there runs from the start of the request at the CMAC
client interface to the start of the reply at the CMAC client interface, so it excludes the
CMAC's own pipeline as well as the serdes, PCS and RS-FEC, and is **not directly comparable**
with the VCK190's figures (see [KCU116 timestamps](design.md#timestamps-on-the-kcu116)). The
`T` report says so in its header (`MAC-client SOF RX -> TX, zircon_cmac_us timestamps`), and the
bring-up check reads the shim's timer (`Port 0: shim timestamp timer …`) instead of the MRMAC's.
The software TCP echo on the 100 MHz MicroBlaze takes about 0.1 to 0.5 ms, so it lands in the
upper doubling bins.

### The `T` command

`T` Enter takes a coherent snapshot of both banks of every port and prints them. `T <port>`
Enter prints one port. `T c` Enter clears both banks of every port (`T <port> c` of one port).
The counter clear `c` does not touch the latency banks.

```
LATENCY port 0 (LAT_CTRL 0x00000301 LAT_STATUS 0x00000000, stale 0 lost 0 ovf 0, bins 64 ns from 0 ns; RX PCS -> TX PCS of the MRMAC)
bank 0 hardware UDP echo: count 1000 min 812 mean 830.4 max 1204 stddev 12.3 ns | p50 832 p90 896 p99 960 p99.9 960 ns | implausible 0 last 828 ns
  bin  ns range                      count
   12  768 - 832                       512
   13  832 - 896                       468
   14  896 - 960                        19
   18  1152 - 1216                       1
bank 1 software TCP echo: count 1000 min 9612 mean 10233.7 max 14448 stddev 512.9 ns | p50 12288 p90 12288 p99 12288 p99.9 12288 ns | implausible 0 last 9950 ns
  bin  ns range                      count
   49  6144 - 12288                   1000
```

```{note}
This listing shows the format. The numbers are illustrative, not measured: see
[Testing](testing.md#latency-measurement) for bench results.
```

| Field | Meaning |
|-------|---------|
| `LAT_CTRL`, `LAT_STATUS` | The latency control and sticky status registers ([registers](registers.md)). `LAT_CTRL` 0x301 = `EN`, `RAW_RX_DESC` (b8) and `RAW_TX_DESC` (b9). `LAT_STATUS` b0 STALE, b1 LOST, b2 OVF. `PTP_UNDERRUN` after `LAT_STATUS` means the TX adapter saw a frame without a timestamp request record (GT-control GPIO CH2 bit 2). |
| `stale`, `lost`, `ovf` | `LAT_STALE_CNT`, `LAT_LOST_CNT`, `LAT_OVF_CNT`: timestamp requests the hardware could not turn into a sample. All 0 in normal operation. |
| `count`, `min`, `mean`, `max`, `stddev` | Over every sample since the last clear, in ns. The standard deviation is computed from the sum of squares. |
| `p50` … `p99.9` | Percentiles from the histogram: the **upper edge of the bin** that holds the percentile, capped at `max`. They are upper bounds with the bin width as resolution. |
| `implausible` | Deltas of 1 s or more, which the hardware counts here and nowhere else |
| `last` | The most recent sample |
| bin table | Every non-empty bin: its number, its range in ns (lower edge included, upper edge excluded; `>= x` for the overflow bin) and its count |

Once the hardware echo has answered at least one request, the port's status line ends with
` | hw lat n <count> min <ns> mean <ns> p99 <ns> max <ns> ns` (bank 0).

At bring-up each port prints the state of its MRMAC's 1588 timer:

```
Port 0: 1588 timestamping enabled (2-step), CONFIGURATION_1588_REG 0x00000002
Port 0: MRMAC 1588 timer 7.154648988 s, advanced TX 9907898 ns RX 9907898 ns in 9907889 ns of A72 time (systimer samples); increment TX 0x18d3018d302 RX 0x18d3018d302
Port 0: latency measurement on: bank 0 hardware UDP echo, bank 1 software TCP echo; histogram 64 ns bins from 0 ns ('T' to print)
```

The "advanced" values should match the A72 time within a few µs. (On the bench they matched
within 10 ns.) They are read from the MRMAC's systimer sample registers
(`MONITOR_{TX,RX}_1588_SAMPLE_SYSTIMER`). The time-of-day registers (`STAT_{TX,RX}_1588_TOD`)
are not used, because their read-back is unreliable: see
[design notes](design_notes.md). If the timer does not advance, the
application requests a timer synchronisation once (`Port <n>: MRMAC 1588 timer not running,
requesting a systimer sync`) and then warns: `Port <n>: WARNING: the MRMAC 1588 timer does not
advance: latency timestamps will be wrong`.

### Statistics service (UDP port 5002)

The same numbers are available over the network, so a host script can read them without the
UART. The service runs in lwIP on every port. Send one datagram:

| Request (ASCII) | Reply |
|-----------------|-------|
| `STAT?` | One 1392-byte binary datagram: a coherent snapshot of both banks of the port that received the request |
| `STAT? <p>` | The same for QSFP port `<p>` |
| `CLR` / `CLR <p>` | Clears both banks of the receiving port (or of port `<p>`); reply `CLR OK` |
| anything else | `ERR` |

The reply is little-endian and packed (`Vitis/common/src/latency_wire.h`, mirrored by
`scripts/zircon_echo_test.py`):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic `0x5A4C4154` ("ZLAT") |
| 4 | 2 | version (1) |
| 6 | 1 | number of banks (2) |
| 7 | 1 | number of bins (64) |
| 8 | 1 | QSFP port |
| 9 | 1 | flags: b0 `EN`, b1 `RAW_TS_DESC`, b2 snapshot did not complete, b3 no latency block in this zircon_nic |
| 10 | 2 | header length (288) |
| 12 | 4 | `LAT_BIN_BASE` (ns) |
| 16 | 4 | `LAT_BIN_WIDTH` (ns) |
| 20 | 4 | zircon_nic `VERSION` |
| 24 | 4 | `LAT_STATUS` |
| 28 | 4 | board time of the snapshot (ms since start-up) |
| 32 | 64 × 4 | lower edge of every bin, ns (bin *i* covers [edge *i*, edge *i*+1); bin 63 has no upper edge) |
| 288 + 552 × *b* | 8, 8, 8 | bank *b*: count, sum (ns), sum of squares (ns²) |
| +24 | 4 × 4 | min, max, implausible, last (ns) |
| +40 | 64 × 8 | histogram counts |

`scripts/zircon_echo_test.py --latency` uses this service; see
[Testing](testing.md#latency-measurement).

### Timestamp descriptors on the raw path

The software measurement uses two 64-byte descriptors on the raw path (UI0). Each fills exactly
the first 512-bit beat of a DMA transfer. `zircon_netif.c` handles them. This is the contract for
anyone who writes their own software for the raw path (all fields little-endian, every byte not
listed is 0):

**RX descriptor.** With `LAT_CTRL.RAW_TS_DESC` = 1, every frame the raw path delivers to
`axi_dma_raw` starts with:

| Bytes | Field |
|-------|-------|
| 0..3 | magic `0x5A525854` ("ZRXT") |
| 4..5 | length of the Ethernet frame that follows (the transfer is 64 bytes longer) |
| 8..15 | RX timestamp of the frame: 55 bits in units of 2⁻⁸ ns; zircon_nic keeps bits 54:7, so bits 6:0 are 0 (0.5 ns resolution) |
| 24..27 | flags |

The descriptor travels in the same FIFO as its frame, so it is dropped together with its frame
on an overflow and never gets out of step. Software must strip it before handing the frame to its
network stack. With `RAW_TS_DESC` = 0 frames arrive exactly as before.

**TX descriptor.** Software can put this descriptor in front of an Ethernet frame it sends
through `axi_dma_raw`, to ask for that frame to be measured:

| Bytes | Field |
|-------|-------|
| 0..3 | magic `0x5A545854` ("ZTXT") |
| 6 | flags: bit 0 `TS_REQ` |
| 8..15 | RX timestamp of the request this frame answers, copied unchanged from its RX descriptor (the hardware uses bits 54:7) |

The hardware removes the descriptor, sends the frame, and with `TS_REQ` adds the frame's TX
timestamp minus the given RX timestamp to **bank 1**. A transfer that does not start with the
magic is sent unchanged, so software that never writes the descriptor behaves as before.

The application's rules (`zircon_netif.c`, `tcp_echo.c`), which a port of it to another stack
should keep:

1. While lwIP processes a received frame, `zircon_netif_cur_rx_ts()` returns its RX timestamp.
2. The TCP echo's receive callback arms that timestamp (`zircon_netif_ts_arm()`) when nothing
   older is waiting to be echoed, writes the echo with `tcp_write()` + `tcp_output()`, and disarms
   when it returns.
3. `low_level_output()` sends the first TCP segment **with payload** that goes out while armed
   behind a ZTXT `TS_REQ` descriptor, and disarms. ARP requests and pure ACKs are sent
   without a descriptor, and so is everything sent outside the callback (retransmissions,
   echoes delayed by a full send buffer).

The raw-path counters of the descriptors are on the second status line (printed by `s`):
`raw timestamp descriptors: rx <n> (missing <n>, length mismatch <n>), tx TS_REQ <n>`.

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
[Putty]: https://www.putty.org

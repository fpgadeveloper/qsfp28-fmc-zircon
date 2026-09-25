# Troubleshooting

## Build failures

1. **Are you using the correct version of Vivado for this version of the repository?**
   This design is built for Vivado / Vitis 2025.2. `Vivado/scripts/build.tcl` checks the
   installed version and refuses to build with any other.

2. **Did you initialise the git submodule?**
   The Zircon and Taxi sources live in the `submodules/taxi` submodule. If that directory is empty
   (a plain `git clone`, or a ZIP download), Vivado stops because it cannot find files such as
   `submodules/taxi/src/zircon/rtl/zircon_ip_rx_parse.sv`. Run `git submodule update --init` in
   the repository and build again.

3. **Do you have the licenses?**
   The XCVC1902 needs **Vivado Enterprise Edition** (or an evaluation license), and the MRMAC
   needs its **no-cost MRMAC license**. Without the MRMAC license, the implementation fails when
   the device image is generated. See the [license requirements](build_instructions.md#license-requirements).

4. **Did you copy/clone the repo into a short directory structure?**
   Windows doesn't cope well with long paths, and Versal projects produce particularly deep
   ones. Clone the repository into a short path such as `C:\projects\`. The build runner checks
   the path length for Versal targets and explains the `subst` workaround if it is too long.

## The link never comes up

The echo server keeps printing `Port <n>: link down: …` lines. Work through these causes in
order: each one hides the ones after it. The two ports are independent, so if only one of them
stays down, the causes shared by both (VADJ, the Si5328) are ruled out.

1. **VADJ is off.** The FMC's clock synthesizer and QSFP sideband are powered from VADJ. The
   echo server prints `VADJ enabled (1.5V)` at start-up, or `WARNING: failed to enable VADJ`.
   If you replace the application with your own software, it must set VADJ too.
   The VCK190 system controller can also set VADJ (its *FMC > Set VADJ* menu); 1.5 V is the
   right value for this card on this board.

2. **The Si5328 is not programmed, so the GT has no reference clock.** Nothing presets the
   Si5328 in hardware. Without it, the GT never finishes its reset, and the echo server prints
   `ERROR: Si5328 programming failed - no GT refclk` or `Port <n>: GT reset-done timeout (no
   refclk?)`. The Si5328 makes the reference clocks of both ports (CKOUT1 for port 0, CKOUT2 for
   port 1). The usual cause is VADJ (item 1), because the Si5328's I2C bus is powered from it.

3. **FEC mismatch.** This design runs **RS-FEC** (clause 91). A partner with FEC forced *off*
   (for example after testing Opsero's FEC-off 2x QSFP28 FMC design on the same host) never
   links. Set the partner back to auto or RS:
   ```
   sudo ethtool --set-fec <if> encoding auto      # or: encoding rs
   ```
   The bare-metal echo server stays in RS-FEC (no automatic fallback since the two-port build). For
   a partner forced to FEC off, press `f` to switch both ports to FEC off. Its link-down line,
   printed every 30 s, shows the FEC state it sees (`FEC aligned 0 lane lock 0x0` means no RS-FEC
   codeword alignment).

4. **Auto-negotiation on the partner.** The MRMAC in this design does not run clause 73
   auto-negotiation or link training. Some NICs insist on auto-negotiation when a direct-attach
   copper cable is fitted. If the partner shows the link as down while the board reports block
   lock, turn auto-negotiation off on the partner (`sudo ethtool -s <if> autoneg off speed 100000`)
   or use an optical module or AOC instead.

5. **The link partner is not 100G CAUI-4.** A 40G port, a 4x25G breakout, or a 25G/SFP loopback
   will not link. The partner must be 100GBASE-R over four lanes.

6. **The QSFP module is held in reset, or missing.** `ResetL` of QSFP port 0 comes from
   `axi_gpio_qsfp0` (port 1: `axi_gpio_qsfp1`), whose output resets to `0x2` (module out of reset,
   high-power mode). If your software writes that GPIO, keep bit 1 (`ResetL`) at 1. The echo
   server prints `Port <n>: QSFP module present` at start-up for each cage that holds a module or
   cable end. A module held in reset keeps its laser off; a passive
   copper cable may still work, which can hide the problem.

7. **The FMC is on the wrong connector.** This target uses **FMCP1**. The card on FMCP2 connects
   to different transceivers and clocks.
8. **The cable is not a 100G QSFP28 cable.** A 40G QSFP+ cable or module, or a breakout cable,
   does not link at 100GBASE-R. This applies to the loopback cable as much as to a host link.

The detailed bring-up sequence is in [Bring-up notes](notes_bringup.md).

## No IP address, or the board does not answer ping

The link is up (`Port <n>: link up, 100 Gb/s, …`), but the board does not answer ping, or it
never prints a `Port <n>: IP …` line. Check the port's **address mode** first: it is printed at
start-up (`Port <n>: address mode …`), and `i` Enter shows the mode and the address in use of
every port (see [Addressing](echo_server.md#addressing)).

1. **A host NIC cabled directly to the board, in the default mode.** There is no DHCP server on
   the cable, so the port has **no address for the first 10 seconds**, then prints
   `Port <n>: no DHCP lease after 10 s, falling back to static` and uses its static address
   (port 0: `192.168.20.2`, port 1: `192.168.21.2`). For this set-up, use the `static` mode
   (`IP_MODE_DEFAULT` = `IP_MODE_STATIC` in `app_config.h`, or type `i 0 static` Enter): the
   address is then there from start-up.
2. **The host NIC is not in the board's subnet.** With the static addresses, give the host NIC
   `192.168.20.1/24` (port 0) or `192.168.21.1/24` (port 1), for example
   `sudo ip addr add 192.168.20.1/24 dev <if>`, or change `STATIC_IP_ADDR` / `STATIC_IP_ADDR_1`.
   A board on its static address cannot be reached from a host on a DHCP-assigned subnet, and
   the other way round.
3. **The port is in the `dhcp` mode.** It never takes the static address, and prints
   `Port <n>: no DHCP lease after <t> s (address mode dhcp, no static fallback: …)` every 30 s
   while no DHCP server answers. Start a DHCP server on the host side, or type `i <port> static`
   or `i <port> auto`.
4. **Ping works but UDP echo does not.** See the next section: the hardware only answers
   datagrams sent to the address in the port's `IPV4` register (`z` key), which the application
   updates on every address change, including after `i`.

## Link up, but traffic does not flow

1. **Look at the counters first.** The echo server's status line, or the `s` and `z` console
   keys:
   * `RX_BAD_FRAME` growing: the MAC is flagging frames as bad (FCS errors, frames too long).
     Check the cable and the FEC counters; uncorrectable codewords mean a bad link.
   * `RX_FIFO_DROP` growing and `STATUS.RX_FIFO_OVF` set: frames arrive faster than the core
     can take them. This is expected with a flood of small frames, below about 726 bytes of UDP
     payload at 100 Gb/s (see [throughput](description.md#throughput)). The control-plane raw path is also much slower
     than the hardware paths: bulk traffic to ports other than 7 and 5000 is not what it is for.
   * `RX_L4_BAD_CSUM` growing: datagrams to the echo or socket port have a wrong UDP checksum.
     They go to the raw path instead.

2. **The hardware echo or socket does not answer.** Both only answer datagrams sent to the
   **local IPv4 address** held in the `IPV4` register. The echo server keeps it in step with
   lwIP's address; the `z` key shows the value in use. Also check that the destination MAC is the board's (a
   datagram sent to the broadcast MAC goes to the raw path) and that the datagram has no VLAN tag
   and no IP options.

3. **The socket demo does not answer.** Check the start-up output for
   `WARNING: socket DMA init failed, socket demo disabled`, and the status line's second line for
   socket errors (`bad desc`, `len err`, `dma err`).

4. **The socket reply goes to the wrong place.** The socket is *connected*: replies go to
   `SOCK_REMOTE_MAC/IP/PORT`. The echo server's demo sets them from each new sender. Custom
   software must write them itself (see [Register map](registers.md#socket-descriptor-ui2-receive)).

## The loopback test never passes

The loopback test needs a QSFP28 cable between **port 0 and port 1** of the FMC (see
[Loopback test](testing.md#loopback-test-no-host-nic-required)). If `LOOPBACK: PASS` never
appears, look for the first of these that applies:

1. **The test never started.** It starts by itself only when *both* ports have link and *neither*
   port has received a DHCP lease, 15 seconds after the second link came up. While either port
   is in the `dhcp` [address mode](echo_server.md#addressing) it does not start at all, and `l`
   reports `LOOPBACK: cannot start: port <n> has no IPv4 address …`: type `i <n> static`. Check that both
   `Port 0: link up` and `Port 1: link up` appeared; if not, see
   [The link never comes up](#the-link-never-comes-up) and check the cable first (a 100G
   QSFP28 DAC or AOC, with one end fully seated in each cage of the same card).
   If a DHCP server answered on either port at any time since power-on (for example, a port was
   connected to a host or a switch before the loopback cable was fitted), the automatic start is
   switched off until the next boot, because the ports are then evidently not cabled to each
   other. Type `l` to start the test by hand. The same applies when `LOOPBACK_AUTOSTART` is -1 in
   `app_config.h`.
2. **`LOOPBACK: cannot start: port <n> has no hardware UDP generator/checker (zircon_nic <
   1.2.0)`.** The device image was built from an older `zircon_nic`. Rebuild the Vivado project
   (`./build.sh clean --target vck190_fmcp1`, then `./build.sh all --target vck190_fmcp1`); the
   start-up line `zircon_nic 1.3.0 at …` confirms the version.
3. **`LOOPBACK: no loopback traffic seen - port 0 and port 1 do not seem to be cabled to each
   other`.** An automatic start saw nothing arrive at either checker within 3 seconds. The two
   links are up, but not to each other: for example, each port is cabled to a different link
   partner. Fit one cable between port 0 and port 1.
4. **`LOOPBACK: FAIL link down`.** A link dropped during the test. Reseat the cable, try another
   one, and check the RS-FEC counters with `s`: uncorrectable codewords (`cw uncorr`) mean a bad
   cable or module.
5. **`LOOPBACK: FAIL rate: …`, with no errors.** The payload is too small for line rate. The
   header path handles about 16.7 million packets per second on transmit and 18.75 million on
   receive, so **100 Gb/s needs UDP payloads of about 726 bytes or more**. Type `p 1472` and
   Enter to return to the default. In the echo-through-loopback test (`e`), port 1's hardware
   echo is in the path too, so the same payload limit applies.
6. **`LOOPBACK: FAIL errors (…)`.**
   * Sequence errors (`seq err`) are not caused by small payloads: below about 726 bytes the
     transmit side limits the rate (16.67 Mpps) and the receive side keeps up, so a small
     payload fails on rate only (item 5). Look at `RX_FIFO_DROP` and `RX_BAD_FRAME` of the
     receiving port (`z` key) and at the FEC counters (`s`).
   * Bit errors (`bit err`) mean payload corruption on the link that the FEC did not correct.
     Try another cable or module.
   * Length errors (`len err`) are datagrams to UDP port 5001 with less than 8 bytes of payload.
     The generators never send those; something else on the link does.
7. **The addresses changed during the test.** Each generator addresses the other port's IPv4
   address as it was when the test started, and each checker accepts only datagrams sent to its
   own port's address. If a port's address changes while the test runs (for example a late DHCP
   lease), stop the test with `l` and start it again. Keep the two ports on **different
   subnets** (the static defaults are 192.168.20.2 and 192.168.21.2): with both ports on the same
   subnet, lwIP may send port 1's ping and TCP replies out of port 0, which breaks the host test
   of port 1.

With the echo-through-loopback test (`e`), the same list applies with the prefix
`LOOPBACK-ECHO:`. There, the traffic also passes through port 1's hardware echo, so check
`RX_ECHO_DROP` of port 1 as well.

## A large frame or socket payload is never sent

The hardware drops any raw frame (UI0) or socket payload (UI2) longer than **9618 bytes** and
counts it in `TX_OVERSIZE_DROP` (`txbig` in the status line). The payload buffer must hold a
whole payload before its header can be built, so the length guards in front of it discard
anything that could not be sent; the rest of the transmit path keeps running. The software in
this repository never sends frames larger than the 9000-byte jumbo MTU; this limit matters only
for custom software.

## Latency statistics

1. **`NOTE: Port <n>: zircon_nic < 1.3.0: no latency measurement`** at start-up, or `T` prints
   `has no latency measurement`: the device image is older than the application. Rebuild the
   Vivado project (see [The loopback test never passes](#the-loopback-test-never-passes), item 2).
2. **`WARNING: the MRMAC 1588 timer does not advance`** at start-up: the timestamps, and so the
   latency figures, are wrong. The application has already requested one timer synchronisation;
   power-cycle the board and report the start-up output if the warning stays.
3. **Bank 0 (hardware UDP echo) has no samples.** Only replies of the hardware echo are counted:
   send UDP datagrams to port 7 of the board's address, or run the `e` test. `c` does not clear
   the banks; `T c` does.
4. **Bank 1 (software TCP echo) has no samples.** It counts TCP echo replies of up to one segment
   (1460 bytes), one per request. Use a TCP client with `TCP_NODELAY` and one request in flight,
   as `scripts/zircon_echo_test.py --latency` does.
5. **`stale` is not 0.** Timestamps came back for frames that were no longer pending, which is
   expected after a link went down and up. Clear the banks (`T c`) and measure again. `lost`,
   `ovf` or `PTP_UNDERRUN` should never appear; please report them.

## Jumbo frames

* The hardware echo, socket, generator and checker handle datagrams up to the 9000-byte jumbo
  MTU. The echo server sets the MRMAC's maximum receive frame length to 9600 bytes and prints it
  at start-up (`RX max frame 9600 B`). The control-plane lwIP
  interface uses a 1500-byte MTU, which only matters for ping and the TCP echo.
* The host's interface must also have an MTU of 9000, and every switch in between must accept
  jumbo frames.
* Jumbo datagrams are handled at full size by the hardware echo and socket; there is no IP
  fragmentation or reassembly in hardware. A *fragmented* UDP datagram goes to the raw path
  (lwIP) and is not echoed.

## Booting the board (Versal)

1. **Nothing happens at power-on (SD card).** The echo server's `BOOT.BIN` must be at the root
   of the **first partition** of the microSD card, formatted FAT32. A bare-metal `BOOT.BIN` there
   boots directly: no other files are needed.
2. **The board boots from the wrong source.** Check the boot-mode switch **SW1** (SD boot or
   JTAG) and that the card is in the Versal's microSD slot, not the system controller's (see the
   VCK190 user guide, UG1366).
3. **No console output.** The VCK190's USB-C connection exposes several serial ports. The Versal
   UART0 is normally the second one (`/dev/ttyUSB1` on Linux), at 115200 baud.

## Licensing questions

The design uses no purchased IP. The MRMAC needs a no-cost license, and the XCVC1902 device needs
Vivado Enterprise Edition. The Taxi library, including Zircon, is licensed under the
**CERN-OHL-S-2.0**, which has consequences for products; see [Licensing](licensing.md).

# 2x QSFP28 FMC Zircon Ethernet

This is the documentation for the Zircon Ethernet reference design for the Opsero
[2x QSFP28 FMC] (OP120). The design puts **two 100 Gigabit Ethernet ports** on the Versal
device, one for each QSFP28 cage of the card. Each port uses its own **Versal Integrated 100G
Multirate Ethernet MAC (MRMAC)** hard block (CAUI-4, 4 x 25.78125 Gb/s GTY lanes, RS-FEC).
Behind each MAC sits its own copy of the open-source **Zircon IP stack** from the [Taxi]
transport library (FPGA Ninja). Zircon parses Ethernet/IPv4/UDP headers on receive and builds
them on transmit, entirely in programmable logic.

**Full 100 Gb/s line rate from 726-byte UDP payloads up.** Below that, the header path sets
the packet rate: about **16.7 million packets per second on transmit and 18.75 million on
receive** per port, because Zircon's 32-bit header parser and deparser spend about 16 to 18
clock cycles of the 300 MHz core clock on each packet. That is roughly two orders of magnitude
more packets per second than a software network stack on one processor core handles, and no processor touches the packets
on these hardware paths. The measured throughput for payloads from 64 to 9000 bytes is in
[Measured throughput](description.md#measured-throughput).

**There is no processor in the datapath.** The datagrams that the hardware UDP echo answers,
and those that the traffic generator sends and the checker verifies, never reach the Versal
processing system (PS); for the hardware UDP socket, the headers are also parsed and built in
logic. Separately, each port has two AXI DMAs to the PS, a control-plane and raw path used to
configure and observe the design: they carry ARP, ICMP (ping), DHCP, the software TCP echo (a
point of comparison) and the socket payloads. The PS runs a bare-metal bring-up and control
application: it powers the FMC, programs the GT reference clocks, brings up both MRMACs with
RS-FEC, configures the Zircon registers and runs a small lwIP stack on the raw path of each
port.

On each port, the received traffic is split three ways, into three *user interfaces* (UI):

| Interface | What it does | Who handles it |
|-----------|--------------|----------------|
| **UI1 hardware UDP echo** (the headline demonstration) | IPv4/UDP datagrams sent to the echo port (default 7) are sent back by the hardware. It swaps and rebuilds the headers and inserts the checksums. The payload is not touched. | Hardware only. The processor never sees these datagrams. |
| **UI2 hardware UDP socket** | A connected UDP socket in hardware. Received datagrams on the socket port (default 5000) reach the PS **payload only**, behind a 64-byte descriptor, through a second AXI DMA. Payloads written by the PS get their Ethernet/IPv4/UDP headers built by the hardware. | Headers: hardware. Payload: the socket demo in the bare-metal application. |
| **UI0 raw** (control plane) | Complete Ethernet frames to and from the PS through an AXI DMA: everything the hardware rules do not claim, such as ARP, ICMP, DHCP and TCP. | The control-plane lwIP stack of the bare-metal application |

Each port also has a **hardware UDP traffic generator and checker** and **rate meters**. The
generator sends datagrams at up to 100 Gb/s line rate, with a sequence
number and a pseudo-random payload. The checker claims datagrams sent to UDP port 5001 and
verifies every one of them, counting lost datagrams and payload bit errors. The rate meters
measure what each port sends and receives every second. The PS only configures them and reads
the counters.

Each port also **measures its own latency** with the IEEE 1588 timestamps of its MRMAC: from the
start of a request at the receive PCS to the start of the reply at the transmit PCS, for every
hardware UDP echo and for every software TCP echo. The hardware keeps the count, minimum, mean,
maximum, standard deviation and a 64-bin histogram of each; the application prints them on the
UART and serves them on UDP port 5002. See [Latency measurement](echo_server.md#latency-measurement).

## Ways to test it

* **Loopback cable (no host needed).** A QSFP28 cable between port 0 and port 1 of the card.
  Each port's generator sends to the other port's checker, so both ports run at the full 100 Gb/s
  line rate in both directions at the same time. The application starts this test by itself when
  it sees the two ports cabled together, and prints `LOOPBACK: PASS` when every direction has run
  at 90 Gb/s or more for 10 seconds with no errors. A second test sends port 0's generator
  through port 1's hardware UDP echo and back, which also measures the echo latency at line
  rate. See [Loopback test](testing.md#loopback-test-no-host-nic-required).
* **Loopback plug.** A QSFP28 loopback plug in one port: that port's generator sends to its own
  checker (console command `L <port>`).
* **Host with a 100G NIC.** Port 0 or port 1 cabled to a 100G link partner, such as a PC with a
  100G NIC. The host-side script `scripts/zircon_echo_test.py` tests the hardware echo, the
  hardware socket and the software TCP echo, and with `--latency` compares the board's latency
  figures with the host's round-trip times. See [Testing](testing.md).

```{important}
**Status: two ports on the VCK190, bare-metal only.** This release targets the
VCK190 with the 2x QSFP28 FMC on FMCP1, using both QSFP28 ports. There is no Linux image; the
design is built with Vivado and Vitis only. Targets for the ZCU106 and the KCU116 are planned but
not yet available. Those boards have no Versal MRMAC, so they need a different MAC.

Zircon is under active development upstream. This design pins Taxi at commit `cc70b27` and
treats Zircon as a set of tested building blocks. The logic that turns them into a working
network interface, the traffic generator and checker and the latency measurement are Opsero's
own MIT-licensed glue.
See [Description](description.md) for an honest account of what comes from where.
```

## Supported boards

{% for group in data.groups %}
{% set designs_in_group = [] %}
{% for design in data.designs %}{% if design.group == group.label and design.publish %}{% set _ = designs_in_group.append(design.label) %}{% endif %}{% endfor %}
{% if designs_in_group | length > 0 %}
### {{ group.name }} boards

| Carrier board | Target design | FMC slot | QSFP28 ports | FEC | Standalone<br>Echo Server |
|---------------|---------------|----------|--------------|-----|-----|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.connector }} | {{ design.ports }}x {{ design.linkspeed }}G | {{ "RS-FEC (CL91)" if design.fec == "rs" else "none" }} | {% if design.baremetal %} ✅ {% else %} ❌ {% endif %} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

## Requirements

To build the design and test it on hardware, you need:

* **Vivado 2025.2, Enterprise edition.** The VCK190's XCVC1902 device is not supported by the
  free Vivado ML Standard Edition. A 30-day evaluation license is available from AMD.
* **The Versal MRMAC license.** It costs nothing, but you have to generate it on the AMD
  licensing site. Without it, the device image cannot be generated.
* **Vitis 2025.2**, for the bare-metal application. Everything builds on Windows or Linux.
* The [2x QSFP28 FMC] (OP120) and a [VCK190] evaluation board.
* For the **loopback test**: one QSFP28 100G cable, direct-attach copper (DAC) or active optical
  (AOC), to connect port 0 to port 1 of the card. Nothing else is needed.
* For the **host test**: a **100G link partner that supports RS-FEC (clause 91)**, such as a 100G
  NIC or switch port, with a matching QSFP28 cable or pair of modules, and a **Linux PC with
  Python 3 on the 100G link** to run the host-side test script `scripts/zircon_echo_test.py`,
  which ships with the repository. See [Testing](testing.md) for the details.

The design itself uses **no purchased IP**. Zircon and Taxi are open source (CERN-OHL-S-2.0).
Everything else in the block design ships with Vivado, apart from the no-cost MRMAC license. See
[Licensing](licensing.md) for what the CERN-OHL-S-2.0 means if you build a product from this
design.

## Contents

```{toctree}
:maxdepth: 2
:caption: User Guide

description
registers
build_instructions
echo_server
testing
troubleshooting
licensing
design_notes
revision_history
```

```{toctree}
:maxdepth: 2
:caption: Reference

design
notes_bringup
```

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
[Taxi]: https://github.com/fpganinja/taxi
[VCK190]: https://www.xilinx.com/vck190

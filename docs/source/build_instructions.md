# Build instructions

## Source code

The source code for the reference design is managed on this Github repository:

* [https://github.com/fpgadeveloper/qsfp28-fmc-zircon](https://github.com/fpgadeveloper/qsfp28-fmc-zircon)

The repository uses a **git submodule** for the Taxi transport library (`submodules/taxi`), so
clone it with its submodules:
```
git clone --recursive https://github.com/fpgadeveloper/qsfp28-fmc-zircon.git
```

If you already have a clone without the submodule (or downloaded the repository as a ZIP, which
does not include submodules), run this inside the repository before building:
```
git submodule update --init
```

The Vivado build cannot find the Zircon and Taxi sources without it.

## License requirements

For the **VCK190** (`vck190_fmcp1`), two licenses are needed:

1. **Vivado Enterprise Edition** (or a 30-day evaluation license). The VCK190's XCVC1902 device is
   not supported by the free Vivado ML Standard Edition.
2. **The Versal Integrated MRMAC license.** It costs nothing, but it must be generated from the
   AMD Xilinx Licensing site and installed. Without it, the implementation fails when the device
   image is generated.

For the **KCU116** (`kcu116`), one license is needed:

1. **The UltraScale+ Integrated 100G Ethernet (CMAC) license.** It also costs nothing and is
   generated from the AMD Xilinx Licensing site. The XCKU5P device itself is supported by the free
   **Vivado ML Standard Edition**.

Zircon, Taxi (including its CMAC wrapper) and the Opsero glue logic are open source and need no
license key. The other IP in the block designs (CIPS, NoC, GT quad, MicroBlaze, DDR4 memory
controller, GT wizard, AXI DMA, width converters, clocking wizards, AXI GPIO, AXI IIC, AXI UART
Lite, AXI timers, SmartConnect) ships with Vivado. See [Licensing](licensing.md).

## Target designs

This repo contains designs that target the supported development boards and their
FMC connectors. The table below lists the target design name, the QSFP28 ports and FEC mode of the
design, the FMC connector on which to connect the mezzanine card and whether the standalone application is
built for it.

{% for group in data.groups %}
    {% set designs_in_group = [] %}
    {% for design in data.designs %}
        {% if design.group == group.label and design.publish %}
            {% set _ = designs_in_group.append(design.label) %}
        {% endif %}
    {% endfor %}
    {% if designs_in_group | length > 0 %}
### {{ group.name }} designs

| Target board        | Target design     | Ports   | FEC | FMC Slot    | Standalone<br> Echo Server | Vivado<br> Edition |
|---------------------|-------------------|---------|-----|-------------|-----|-----|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.ports }}x {{ design.linkspeed }}G | {{ "RS-FEC (CL91)" if design.fec == "rs" else "none" }} | {{ design.connector }} | {% if design.baremetal %} ✅ {% else %} ❌ {% endif %} | {{ "Enterprise" if design.license else "Standard 🆓" }} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

Notes:

1. The Vivado Edition column indicates which designs are supported by the Vivado *Standard* Edition, the
   FREE edition which can be used without a license. Vivado *Enterprise* Edition requires
   a license however a 30-day evaluation license is available from the AMD Xilinx Licensing site.
2. The design is bare-metal only: there is no Linux (PetaLinux or Yocto) flow. Everything builds
   on Windows as well as on Linux.

## Quick start

To build everything for the VCK190 — the Vivado project and device image, then the bare-metal
echo server and its `BOOT.BIN` — and gather the boot files into `bootimages/`, run this from the
root of the repository (use `build.bat` instead of `./build.sh` from a plain Windows prompt):

```
./build.sh all --target vck190_fmcp1
```

For the KCU116, the same command builds the bitstream, the echo server, the bitstream with the
application embedded (`zircon_boot.bit`) and the QSPI flash image (`zircon_boot.mcs`):

```
./build.sh all --target kcu116
```

The sections below describe each stage on its own.

## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository,
on **both Windows and Linux** — the build instructions are the same for the
two operating systems. Each command builds whatever it depends on
automatically, skips anything that is already built, and locates the AMD
tools itself, so there is no need to source the settings scripts beforehand.

On Linux and on Windows (git bash), commands are run with the `build.sh`
shim, which finds a suitable Python 3 automatically (including the
interpreter bundled with the AMD tools). Windows users who prefer not to
use git bash can run the same commands from Command Prompt or PowerShell
using `build.bat` instead — the commands and arguments are otherwise
identical, for example `build.bat xsa --target <target>`.

This repository uses git submodules: clone it with `--recurse-submodules`,
or run `git submodule update --init` in an existing clone, before building
— the Vivado build fails without the submodule sources.

To see the available targets and the state of a build:

```
./build.sh list                       # list the targets and their attributes
./build.sh status --target <target>   # show the per-stage artifact state
./build.sh clean --target <target>    # delete a target's generated outputs
```

### Build Vivado project

This single command creates the Vivado project, generates the bitstream and
exports the hardware to an XSA file:

```
./build.sh xsa --target <target>
```

Valid targets are:
{% for design in data.designs if design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

If you want the Vivado project and block design without generating a
bitstream — for example, to explore or modify the design in the Vivado GUI —
run `./build.sh project --target <target>` instead, then open the project
from `Vivado/<target>/`.

### Build Vitis workspace

This creates the Vitis workspace and compiles the standalone application,
producing the baremetal boot file (`BOOT.BIN` or bit file, depending on the
device family). The Vivado XSA is built first if it does not already exist:

```
./build.sh standalone --target <target>
```

Valid targets for the standalone application are:
{% for design in data.designs if design.baremetal and design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

The workspace is created in `Vitis/<target>_workspace` and the boot files
are gathered in `Vitis/boot/<target>/`: `BOOT.BIN` for the VCK190, and for the KCU116
`zircon_boot.bit`, the bitstream with the echo server embedded in the MicroBlaze's local memory.

### Build everything

This builds everything that the target supports — the Vivado project and XSA
and the standalone application, and for the KCU116 the QSPI flash image — and gathers the boot
images into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all      # every target in the repo
```

## KCU116: bitstream and QSPI flash

The KCU116 has no SD boot for this design and no FSBL: the FPGA configures itself, either over
JTAG or at power-on from its QSPI flash, and the MicroBlaze starts the echo server from its local
memory straight away. `./build.sh all --target kcu116` produces, in `Vitis/boot/kcu116/` and in
`bootimages/qsfp28-fmc-zircon_kcu116_standalone-2025-2.zip`:

| File | What it is |
|------|------------|
| `zircon_boot.bit` | The bitstream with the echo server embedded (`updatemem`). Load it over JTAG. |
| `zircon_boot.mcs` | The same bitstream as a QSPI flash image (128 MB, SPI x4), written by `./build.sh cfgmem --target kcu116` (part of `all`). |
| `zircon_boot.prm` | The address map of the `.mcs`, for Vivado's flash programmer. |

### Load over JTAG

Connect the KCU116's USB-JTAG port, power the board and open the Vivado Hardware Manager: *Open
Target → Auto Connect*, then *Program Device* with `Vitis/boot/kcu116/zircon_boot.bit`. The echo
server starts as soon as the FPGA is configured. From the command line:

```
vivado -mode tcl
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xcku5p*] 0]
set_property PROGRAM.FILE Vitis/boot/kcu116/zircon_boot.bit $dev
program_hw_devices $dev
```

To debug the application instead, program `Vivado/kcu116/kcu116.runs/impl_1/zircon_wrapper.bit`
and run `Vitis/kcu116_workspace/echo_server/build/echo_server.elf` on the MicroBlaze from the
Vitis IDE, or with xsdb (`fpga -f …`, `targets -set -filter {name =~ "MicroBlaze #*"}`, `dow …`,
`con`).

### Program the QSPI flash

The KCU116's configuration flash is a Micron **MT25QU01G** (1 Gb, 128 MB). In the Vivado Hardware
Manager, right-click the `xcku5p` device, choose *Add Configuration Memory Device* and select
**`mt25qu01g-spi-x1_x2_x4`** (not `mt25qu256`, which Vivado rejects for this flash). Then program
it with `zircon_boot.mcs` and `zircon_boot.prm` (erase, program, verify). From the command line,
after the four `open_hw_manager` … `set dev` lines above:

```
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25qu01g-spi-x1_x2_x4}] 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.FILES [list Vitis/boot/kcu116/zircon_boot.mcs] $cfg
set_property PROGRAM.PRM_FILE Vitis/boot/kcu116/zircon_boot.prm $cfg
set_property PROGRAM.ADDRESS_RANGE use_file $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY 1 $cfg
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
program_hw_cfgmem -hw_cfgmem $cfg
```

Programming the 12 MB image takes about five minutes. The board must be set to boot in master
SPI mode (mode pins M[2:0] = 001, the KCU116's default as delivered; see the KCU116 user guide,
UG1239). Power-cycle the board: it configures from the flash and prints the echo server's banner
on the UART within a few seconds.

## Simulating `zircon_nic`

The `zircon_nic` block has a self-checking simulation testbench that runs in the Vivado
simulator (xsim). It needs only Vivado, not the block design:

```
source <Vivado 2025.2 install>/settings64.sh
Vivado/src/hdl/tb/run_xsim.sh
```

The script generates the test vectors with a plain Python packet builder
(`Vivado/src/hdl/tb/gen_vectors.py`), compiles the Zircon and Taxi sources from the submodule
together with the glue logic, and runs `tb_zircon_nic.sv`. It checks every frame byte for byte
(including the hardware-built IPv4 and UDP checksums) and every counter after each test. It
covers the raw path in both directions (including 9000-byte jumbo frames and short-frame
padding), the hardware echo with good and bad checksums, the socket descriptor and socket
transmit, MAC-error drops, back-to-back small frames with and without back-pressure, a receive
overrun, VLAN frames, the RX/TX enables, random back-pressure on every output, the UDP
checksum corner cases and every register. It also covers the hardware UDP generator and checker
(exact generated frames, length clamping, gaps, a clean stop, bit and sequence errors), a
generator → 100G MAC model → checker loopback, the rate meters, a sweep that measures the packet
rate of the transmit and receive paths, and a second build with `GEN_EN` = 0 (no generator or
checker). For the latency measurement it models the MRMAC's 1588 timer and timestamps and checks
every latency sample, the statistics and all histogram bins exactly, the `ZRXT` / `ZTXT`
descriptors, a transmit reset with timestamps outstanding and snapshots taken under traffic.
Two smaller testbenches cover the RX packer (`tb_mrmac_rx_packer.sv`) and the PTP units
(`tb_ptp_units.sv`: the TX adapter's timestamp requests and the 1588 timer). It prints `ALL TESTS PASSED` and exits with status 0 on success.

Both ports of the block design, and both targets, use the same `zircon_nic`, so one testbench
covers them all. For the KCU116, the script also runs `tb_zircon_cmac_us.sv`: the CMAC shim
around Taxi's 100G CMAC wrapper in simulation mode (the testbench models the CMAC), covering its
registers, the transceiver control bus, the receive and transmit timestamps and their clock
crossings, the resets, and `zircon_nic` + shim running the generator → checker loop and the
latency measurement.

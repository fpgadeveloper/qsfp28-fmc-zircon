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

Two licenses are needed to build this design:

1. **Vivado Enterprise Edition** (or a 30-day evaluation license). The VCK190's XCVC1902 device is
   not supported by the free Vivado ML Standard Edition.
2. **The Versal Integrated MRMAC license.** It costs nothing, but it must be generated from the
   AMD Xilinx Licensing site and installed. Without it, the implementation fails when the device
   image is generated.

Zircon, Taxi and the Opsero glue logic are open source and need no license key. The other IP in
the block design (CIPS, NoC, GT quad, AXI DMA, width converters, clocking wizards, AXI GPIO,
AXI IIC, SmartConnect) ships with Vivado.

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
are gathered in `Vitis/boot/<target>/`.

### Build everything

This builds everything that the target supports — the Vivado project and XSA
and the standalone application — and gathers the boot images into
`bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all      # every target in the repo
```

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

Both ports of the block design use the same `zircon_nic`, so one testbench covers both.

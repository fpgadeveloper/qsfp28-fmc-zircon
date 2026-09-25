# Third-party submodules and their licenses

This reference design is published by Opsero under the **MIT license** (see
`../LICENSE`). It depends on one third-party component, brought in as a git
submodule so that the boundary between Opsero's MIT-licensed sources and the
third-party sources is unambiguous:

| submodule | upstream | license |
|-----------|----------|---------|
| `submodules/taxi` | https://github.com/fpganinja/taxi (FPGA Ninja, LLC) | **CERN-OHL-S-2.0** (dual-licensed: CERN Open Hardware Licence v2 Strongly Reciprocal, or a paid commercial license from FPGA Ninja) — a few files are MIT, see below |

Nothing under `submodules/` is modified. Everything outside `submodules/` is
Opsero's and is MIT-licensed, including the glue logic that instantiates the Taxi
modules (`Vivado/src/hdl/zircon_nic.v`, `zircon_nic_core.sv` and the other
`Vivado/src/hdl/*.sv` files), the xsim testbench, the block design, constraints,
software and build scripts.

## What this design uses from Taxi

The IP stack between the 100G MRMAC and the processor is built from the **Zircon**
IP-stack components of the Taxi transport library and Taxi's AXI-Stream
infrastructure. The exact source files pulled into the Vivado project are
enumerated in `../Vivado/scripts/zircon_sources.tcl` (and, identically, in the
xsim runner `../Vivado/src/hdl/tb/run_xsim.sh`); they are, by function:

| function | Taxi module(s) | files | license |
|----------|----------------|-------|---------|
| Zircon RX: header parser (IPv4/IPv6/VLAN/TCP/UDP -> metadata, IPv4 header checksum check) | `zircon_ip_rx_parse` | `src/zircon/rtl/zircon_ip_rx_parse.sv` | CERN-OHL-S-2.0 |
| Zircon length / ones'-complement checksum of a packet stream (RX L4 checksum verification, TX payload sum) | `zircon_ip_len_cksum` | `src/zircon/rtl/zircon_ip_len_cksum.sv` | CERN-OHL-S-2.0 |
| Zircon RX egress CDC to the UI clock (raw and socket channels) | `zircon_ip_rx_egress` | `src/zircon/rtl/zircon_ip_rx_egress.sv` | CERN-OHL-S-2.0 |
| Zircon TX ingress CDC from the UI clock (raw and socket channels) | `zircon_ip_tx_ingress` | `src/zircon/rtl/zircon_ip_tx_ingress.sv` | CERN-OHL-S-2.0 |
| Zircon TX payload buffer + UI arbiter | `zircon_ip_tx_buffer` | `src/zircon/rtl/zircon_ip_tx_buffer.sv` | CERN-OHL-S-2.0 |
| Zircon TX egress: header deparser (Ethernet/IPv4/UDP with checksums), header/payload concatenation, MAC-side frame FIFO | `zircon_ip_tx_egress`, `zircon_ip_tx_deparse` | `src/zircon/rtl/zircon_ip_tx_egress.sv`, `src/zircon/rtl/zircon_ip_tx_deparse.sv` | CERN-OHL-S-2.0 |
| AXI-Stream FIFOs, async (CDC) FIFOs, width adapter, broadcast, concatenation, arbitrated mux | `taxi_axis_fifo`, `taxi_axis_async_fifo`, `taxi_axis_adapter`, `taxi_axis_broadcast`, `taxi_axis_concat`, `taxi_axis_arb_mux` | `src/axis/rtl/` | CERN-OHL-S-2.0 |
| Arbiter / priority encoder (used by `taxi_axis_arb_mux`) | `taxi_arbiter`, `taxi_penc` | `src/prim/rtl/` | CERN-OHL-S-2.0 |
| Reset / signal synchronisers | `taxi_sync_reset`, `taxi_sync_signal` | `src/sync/rtl/` | CERN-OHL-S-2.0 |
| AXI-Stream SystemVerilog interface definition and tie helper | `taxi_axis_if`, `taxi_axis_tie` | `src/axis/rtl/taxi_axis_if.sv`, `src/axis/rtl/taxi_axis_tie.sv` | MIT |
| Vivado timing-constraint scripts for the CDC paths of the modules above | — | `src/axis/syn/vivado/taxi_axis_async_fifo.tcl`, `src/sync/syn/vivado/taxi_sync_reset.tcl`, `src/sync/syn/vivado/taxi_sync_signal.tcl` | CERN-OHL-S-2.0 |

Every file carries an SPDX header stating its own license; the table above was
compiled from those headers at the pinned commit.

What Zircon does not provide at the pinned commit (rule matching and dispatch,
header stripping, the socket descriptor, TX metadata generation, registers and
statistics) is implemented by the MIT glue in `../Vivado/src/hdl/`; see
`../docs/DESIGN_SPEC.md`. The glue also works around a UDP checksum carry issue of
`zircon_ip_tx_deparse` at this commit (see `tx_meta_builder.sv`).

## What the CERN-OHL-S-2.0 means for you

CERN-OHL-S is *strongly reciprocal*: if you distribute a product (including a
bitstream) that contains the Taxi sources or a design derived from them, you
must make the complete source of that design available under the same license
on request, including your modifications. The MIT-licensed parts of this
repository do not change that obligation for the Taxi-derived part of the
design. If that is not acceptable for your product, FPGA Ninja offers a
commercial license for Taxi (info@fpga.ninja) — see the upstream README.

The AMD IP used alongside Taxi in the block design (Versal CIPS, NoC, MRMAC, GT
quad, AXI DMA, AXI-Stream width converters, clocking wizards, processor system
reset, AXI IIC, AXI GPIO, SmartConnect) is provided by AMD under the Vivado tool
license.

## Pinned version

The submodule is pinned to a specific Taxi commit (`cc70b27` at the time of
writing; recorded in this repository's git tree, `git submodule status` prints
it). Update it deliberately — Taxi and in particular Zircon are under active
development, and the Zircon metadata format and module interfaces change.

```
git submodule update --init --recursive
```

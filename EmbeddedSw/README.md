Modified BSP files
==================

Files under this folder overlay the Vitis install's `embeddedsw` tree: the
Vitis build script (`Vitis/py/build-vitis.py`) copies them into a local
embeddedsw repository in the workspace and fills in the rest of each `src` /
`data` folder from the install.

### lwIP modifications

`ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0/contrib/ports/xilinx/include/lwipopts.h.in`
is the stock lwIP 2.2 port options template with one addition at the end:

* Software IP/UDP/TCP/ICMP checksums are forced on. `lwip220.cmake`
  configures the checksum options from the Xilinx MACs it finds in the design
  — on the VCK190 that is the PS GEM, which has full checksum offload — and
  would otherwise switch software checksums off. The bare-metal application's
  lwIP netif runs over the `zircon_nic` raw path (UI0, AXI DMA), which carries
  frames untouched, so every checksum must come from software.

The application does not use the PS GEM's lwIP adapter (`xemacpsif`): it
registers its own netif (`Vitis/common/src/zircon_netif.c`), so the GEM being
present only matters for the checksum defaults above.

The file is pinned to the `lwip220_v1_3` directory name, so it needs
revisiting when the Vitis version bumps the library version.

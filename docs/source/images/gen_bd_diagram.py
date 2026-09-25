#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the block-design (Vivado) diagram for the Opsero 2x QSFP28 FMC Zircon (100G)
reference design docs ("Hardware design" page).

Where zircon-block-diagram.png (gen_block_diagram.py) is the conceptual view, this one
is the block design `zircon` as Vivado/src/bd/bd_versal.tcl builds it: every box is a
real cell (or hierarchy / external port) of the block design and every number a real
property of the built design. Port 0 is drawn in full; port 1 is the same chain on its
own GT quad, MRMAC site, FMC lanes and reference clock and is drawn compact. The shared
cells (clocking, resets, the 1588 system timer, the AXI-Lite SmartConnect with the
M_AXI_LPD address map, the Si5328 I2C) are in the bottom strip; the NoC / DDR4 path is
on the left and the FMC side (GT lanes, GBTCLK0/1, QSFP28 cages, sideband) on the right.

It reuses the palette and drawing helpers of gen_block_diagram.py so that both
diagrams look the same.

The output PNG is written next to this script (i.e. into docs/source/images/):
    zircon-bd-diagram.png

Usage (from anywhere):
    python3 docs/source/images/gen_bd_diagram.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_block_diagram as g                      # noqa: E402  (palette + helpers)
from gen_block_diagram import (box, titled_box, harrow, route,   # noqa: E402
                               refclk_arrow, plt)
from matplotlib.patches import FancyBboxPatch     # noqa: E402

C_PTP = "#7B5AA6"                                 # 1588 system-timer bus (purple)
C_CTRL_LINE = "#8C8C8C"                           # AXI-Lite inside a hierarchy
C_HIER_FILL = "#FAFAFD"                           # qsfp_port<p> hierarchy
C_PORT_EDGE = "#B5B5B5"                           # port 0 / port 1 regions
TXT = g.TXT


def region(ax, x0, y0, x1, y1, label, lab_fs=8.6, fc="none", ec=C_PORT_EDGE,
           ls=(0, (5, 3)), lw=1.2, z=1.1, lab_color="#404040"):
    """Dashed rounded region with a bold label at its top-left corner."""
    ax.add_patch(FancyBboxPatch((x0, y0), x1 - x0, y1 - y0,
                                boxstyle="round,pad=0.0,rounding_size=0.8",
                                fc=fc, ec=ec, lw=lw, ls=ls, zorder=z))
    if label:
        ax.text(x0 + 1.0, y1 - 1.3, label, ha="left", va="center",
                fontsize=lab_fs, weight="bold", color=lab_color, zorder=3)


def small(ax, x, y, s, fs=6.6, ha="center", color="#404040", weight="normal",
          z=4, va="center"):
    ax.text(x, y, s, ha=ha, va=va, fontsize=fs, color=color, zorder=z,
            linespacing=1.25, weight=weight)


def ctrl_arrow(ax, p0, p1, lw=1.2):
    route(ax, [p0, p1], C_CTRL_LINE, lw=lw)


def main():
    fig, ax = plt.subplots(figsize=(19.5, 15.2), dpi=120)
    ax.set_xlim(0, 195)
    ax.set_ylim(0, 152)
    ax.axis("off")

    # ---- vertical plan ------------------------------------------------------
    # shared strip 4-31, port 1 row 33-60.5, port 0 62-142.5, titles above
    rx_y0, rx_y1 = 115.0, 133.0        # port 0 RX row (flows right to left)
    tx_y0, tx_y1 = 97.0, 112.0         # port 0 TX row (flows left to right)
    rx_yc = (rx_y0 + rx_y1) / 2
    tx_yc = (tx_y0 + tx_y1) / 2
    ptp_req_y, ptp_ret_y = 93.8, 89.8  # TX PTP request / timestamp return
    ctl_y0, ctl_y1 = 66.0, 84.0        # port 0 control / reset band
    p1_y0, p1_y1 = 35.0, 57.5          # port 1 boxes

    # columns
    ps_x0, ps_w = 2.0, 16.0
    ps_r = ps_x0 + ps_w
    noc_x, noc_w = 20.5, 4.0
    fab_x0, fab_x1 = 27.0, 156.5
    dma_x, dma_w = 28.5, 11.5
    dma_r = dma_x + dma_w
    zn_x0, zn_x1 = 46.0, 74.0
    hier_x0, hier_x1 = 79.0, 138.0
    in_x0 = 81.0                       # first cell inside the hierarchy
    mr_x0, mr_x1 = 108.0, 134.0
    ptp_x = 136.5                      # timer bus riser
    rc_x0, rc_x1 = 141.0, 154.5        # right column (GT quads, QSFP GPIO/IIC)
    rcx = (rc_x0 + rc_x1) / 2
    rc_w = rc_x1 - rc_x0
    fmc_x0, fmc_x1 = 158.0, 193.5
    cg_x0, cg_x1 = 161.0, 191.0        # items on the FMC
    cgx = (cg_x0 + cg_x1) / 2

    # ---- processing system column: DDR4, CIPS, NoC ---------------------------
    titled_box(ax, ps_x0, 127.0, ps_w, 18.5, g.C_PS_FILL, g.C_PS_EDGE, "DDR4",
               "VCK190 on-board\n\nDDR_LOW0\n0x0_0000_0000, 2 GB\nDDR_LOW1\n"
               "0x8_0000_0000, 6 GB",
               title_fs=10.5, body_fs=6.7, title_dy=2.8, lw=1.3)
    box(ax, ps_x0, 4.0, ps_w, 120.0, g.C_PS_FILL, g.C_PS_EDGE, "", lw=1.3)
    cx = ps_x0 + ps_w / 2
    ax.text(cx, 119.5, "versal_cips_0", ha="center", va="center",
            fontsize=10.2, weight="bold", color=TXT)
    small(ax, cx, 114.0, "Versal PS (CIPS)\nArm Cortex-A72\nbare-metal", fs=7.2,
          color=TXT)
    small(ax, cx, 105.0, "FPD CCI + LPD →\nNoC S00–S05", fs=6.7)
    small(ax, cx, 91.0, "UART0, USB3\n(PMC MIO)", fs=6.7)
    small(ax, cx, 75.0, "pl0_ref_clk 100 MHz\n→ clk_wizard_0,\n   axis_clk_wiz\n\n"
          "pl0_resetn\n→ every proc_sys_reset", fs=6.7)
    small(ax, cx, 48.0,
          "pl_ps_irq ← (level)\n"
          "0 / 1  axi_dma_raw\n2 / 3  axi_dma_sock\n4  axi_iic_qsfp0\n"
          "5  axi_iic_clk\n6 / 7  axi_dma_raw_1\n8 / 9  axi_dma_sock_1\n"
          "10  axi_iic_qsfp1\n(DMA: MM2S / S2MM)", fs=6.6)
    small(ax, cx, 26.5, "M_AXI_LPD", fs=7.2, weight="bold", color=TXT)
    small(ax, cx, 23.2, "100 MHz", fs=6.7)

    box(ax, noc_x, 36.0, noc_w, 109.5, g.C_PS_FILL, g.C_PS_EDGE,
        "axi_noc_0      S06–S17 = DMA masters on aclk6 (100 MHz)  →  MC_0 / MC_1 / MC_2",
        fs=7.4, rot=90, weight="bold", lw=1.3)
    harrow(ax, ps_r, noc_x, 136.0, "", g.C_AXARR_FILL, g.C_AXARR_EDGE,
           bh=1.2, hh=2.2, hl=1.1)
    harrow(ax, ps_r, noc_x, 105.0, "", g.C_AXARR_FILL, g.C_AXARR_EDGE,
           bh=1.2, hh=2.2, hl=1.1)

    # ---- FPGA fabric container ------------------------------------------------
    ax.add_patch(plt.Rectangle((fab_x0, 1.5), fab_x1 - fab_x0, 144.0,
                               fc=g.C_FAB_FILL, ec=g.C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 146.2,
            "Block design  zircon   (Vivado/src/bd/bd_versal.tcl, target vck190_fmcp1)",
            ha="center", va="bottom", fontsize=12.5, weight="bold", color=TXT)

    region(ax, 27.8, 62.0, 155.7, 143.0,
           "Port 0   (QSFP28 port 0, FMC DP0-3)", fc="#F7F7F7")
    region(ax, 27.8, 33.0, 155.7, 60.5,
           "Port 1   (QSFP28 port 1, FMC DP4-7)  —  the same cells as port 0",
           fc="#F7F7F7")

    # ======================= PORT 0 (full detail) =============================
    # AXI DMAs
    titled_box(ax, dma_x, rx_y0, dma_w, rx_y1 - rx_y0, g.C_DMA_FILL, g.C_DMA_EDGE,
               "axi_dma_raw",
               "AXI DMA, SG\n512 b, 100 MHz\n@ 0x8008_0000\n\nSG / MM2S / S2MM\n→ NoC S06–S08\n\n"
               "irq0 / irq1",
               title_fs=8.0, body_fs=6.5, txtcolor="#FFFFFF", title_dy=2.4)
    titled_box(ax, dma_x, 95.0, dma_w, tx_y1 - 95.0, g.C_DMA_FILL, g.C_DMA_EDGE,
               "axi_dma_sock",
               "AXI DMA, SG\n512 b, 100 MHz\n@ 0x8009_0000\n\nSG / MM2S / S2MM\n→ NoC S09–S11\n"
               "irq2 / irq3",
               title_fs=8.0, body_fs=6.5, txtcolor="#FFFFFF", title_dy=2.4)
    for yc in (rx_yc, (95.0 + tx_y1) / 2):
        harrow(ax, noc_x + noc_w, dma_x, yc, "", g.C_AXARR_FILL, g.C_AXARR_EDGE,
               bh=1.3, hh=2.4, hl=1.2)

    # DMA <-> zircon_nic_0 (UI0 raw, UI2 socket: 512-bit AXIS @ 100 MHz)
    harrow(ax, dma_r, zn_x0, rx_yc, "UI0", g.C_AXARR_FILL, g.C_AXARR_EDGE,
           bh=1.6, hh=2.8, hl=1.6, fs=7.0)
    harrow(ax, dma_r, zn_x0, tx_yc, "UI2", g.C_AXARR_FILL, g.C_AXARR_EDGE,
           bh=1.6, hh=2.8, hl=1.6, fs=7.0)

    # zircon_nic_0
    zn_y0, zn_y1 = 87.0, 133.0
    box(ax, zn_x0, zn_y0, zn_x1 - zn_x0, zn_y1 - zn_y0, g.C_MAC_FILL, g.C_MAC_EDGE,
        "", lw=1.6)
    zcx = (zn_x0 + zn_x1) / 2
    ax.text(zcx, zn_y1 - 2.4, "zircon_nic_0", ha="center", va="center",
            fontsize=10.2, weight="bold", color=TXT, zorder=3)
    small(ax, zn_x0 + 0.9, rx_yc - 0.2, "m_axis_raw_rx\ns_axis_raw_tx", fs=6.3,
          ha="left", color=TXT)
    small(ax, zn_x0 + 0.9, tx_yc, "m_axis_sock_rx\ns_axis_sock_tx", fs=6.3,
          ha="left", color=TXT)
    small(ax, zn_x1 - 0.9, rx_yc - 0.2, "s_axis_\nmac_rx", fs=6.3, ha="right",
          color=TXT)
    small(ax, zn_x1 - 0.9, tx_yc, "m_axis_\nmac_tx", fs=6.3, ha="right", color=TXT)
    small(ax, zn_x1 - 0.9, ptp_req_y + 0.1, "m_axis_tx_ptp", fs=6.0, ha="right",
          color=TXT)
    small(ax, zn_x1 - 0.9, ptp_ret_y + 0.1, "tx_ptp_tstamp_*_in", fs=6.0, ha="right",
          color=TXT)
    small(ax, zcx - 1.5, 113.6,
          "module reference zircon_nic\nTaxi Zircon + Opsero glue\n\n"
          "clk  300 MHz  (512 b core)\nui_clk  100 MHz\nmac_rx/tx_clk  390.625 MHz\n\n"
          "s_axi @ 0x800A_0000 (4 KB)",
          fs=6.6, color=TXT)

    # ---- qsfp_port0 hierarchy -------------------------------------------------
    box(ax, hier_x0, 64.0, hier_x1 - hier_x0, 74.5, C_HIER_FILL, g.C_MAC_EDGE, "",
        lw=1.3, ls=(0, (4, 2)))
    ax.text((hier_x0 + hier_x1) / 2, 136.3, "qsfp_port0   (hierarchy)",
            ha="center", va="center", fontsize=9.6, weight="bold", color=TXT,
            zorder=3)

    rp_x1 = 104.0
    titled_box(ax, in_x0, rx_y0, rp_x1 - in_x0, rx_y1 - rx_y0, g.C_MAC_FILL,
               g.C_MAC_EDGE, "rx_packer",
               "module ref mrmac_rx_packer\n6 × 64 b (48 B) → 512 b (64 B)\n"
               "no back-pressure\n(the MRMAC RX has no tready)\n"
               "bad frame → tuser[0]\nRX timestamp [54:7] → tuser[48:1]\n"
               "stat → zircon_nic mac_rx_pack_stat",
               title_fs=8.6, body_fs=6.4, title_dy=2.4)
    dw_x1 = 91.5
    ad_x0 = 93.5
    titled_box(ax, in_x0, tx_y0, dw_x1 - in_x0, tx_y1 - tx_y0, g.C_MAC_FILL,
               g.C_MAC_EDGE, "tx_dwidth",
               "axis_dwidth_\nconverter\n\n64 → 48 B",
               title_fs=7.8, body_fs=6.4, title_dy=2.3)
    titled_box(ax, ad_x0, tx_y0, rp_x1 - ad_x0, tx_y1 - tx_y0, g.C_MAC_FILL,
               g.C_MAC_EDGE, "tx_axis_\nadapter",
               "\n\nmodule ref\n384 b → 6 lanes\nS_AXIS_PTP:\n{1588op, tag}",
               title_fs=7.8, body_fs=6.2, title_dy=3.0)
    harrow(ax, dw_x1, ad_x0, tx_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           double=False, bh=1.0, hh=1.8, hl=1.0)

    # zircon_nic <-> hierarchy (512-bit AXIS @ 390.625 MHz)
    harrow(ax, in_x0, zn_x1, rx_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.7)
    harrow(ax, zn_x1, in_x0, tx_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.7)
    small(ax, (zn_x1 + in_x0) / 2, rx_yc + 4.3, "512 b", fs=6.6)
    small(ax, (zn_x1 + in_x0) / 2, tx_yc + 4.3, "512 b", fs=6.6)

    # TX PTP sideband: request to the adapter, timestamp back from the MRMAC
    adx = (ad_x0 + rp_x1) / 2
    route(ax, [(zn_x1, ptp_req_y), (adx, ptp_req_y), (adx, tx_y0)], C_PTP, lw=1.5)
    small(ax, 90.0, ptp_req_y + 1.3, "{1588op, tag} per frame", fs=5.9,
          color=C_PTP)
    route(ax, [(mr_x0, ptp_ret_y), (zn_x1, ptp_ret_y)], C_PTP, lw=1.5)
    small(ax, 91.0, ptp_ret_y - 1.4, "tx_ptp_tstamp / _tag / _valid (2-step)",
          fs=5.9, color=C_PTP)

    # MRMAC (hard block)
    mr_y0 = 87.0
    titled_box(ax, mr_x0, mr_y0, mr_x1 - mr_x0, rx_y1 - mr_y0, g.C_GT_FILL,
               g.C_GT_EDGE, "mrmac",
               "MRMAC_X0Y0\n\n1x100GE CAUI-4 Wide\nMAC+PCS+FEC\n"
               "RS-FEC RS(528,514), clause 91\n\n384 b non-segmented client\n"
               "tx/rx_axi_clk 390.625 MHz\n\n1588 2-step timestamps\n"
               "tx/rx_ts_clk = ts_clk 250 MHz\n\ns_axi @ 0x8000_0000\n\n"
               "stat_rx_status_0 → LEDs",
               title_fs=9.4, body_fs=6.6, title_dy=2.6)
    harrow(ax, mr_x0, rp_x1, rx_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.5)
    harrow(ax, rp_x1, mr_x0, tx_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.5)
    small(ax, (rp_x1 + mr_x0) / 2, rx_yc + 4.0, "6 lanes\n384 b", fs=6.0)
    small(ax, (rp_x1 + mr_x0) / 2, tx_yc + 4.0, "6 lanes\n384 b", fs=6.0)

    # control band inside the hierarchy
    titled_box(ax, in_x0, ctl_y0, 14.0, ctl_y1 - ctl_y0, g.C_CTRL_FILL,
               g.C_CTRL_EDGE, "axi_smc_lite",
               "S_AXI_LITE\n(axi_smc M00)\n\nM00 → mrmac\nM01 → axi_\ngpio_gt0",
               title_fs=7.6, body_fs=6.3, title_dy=2.3)
    titled_box(ax, 97.0, ctl_y0, 17.5, ctl_y1 - ctl_y0, g.C_CTRL_FILL,
               g.C_CTRL_EDGE, "axi_gpio_gt0",
               "@ 0x8007_0000\nCH1: gt_reset_all, tx / rx\ndatapath resets,\n"
               "b3 → ptp sync_req\nCH2: gt tx / rx reset\ndone, ptp_underrun",
               title_fs=7.6, body_fs=6.2, title_dy=2.3)
    titled_box(ax, 116.5, ctl_y0, mr_x1 - 116.5, ctl_y1 - ctl_y0, g.C_GT_FILL,
               g.C_GT_EDGE, "10 × bufg_gt",
               "gt_quad_base_0\nch*_rx/txoutclk →\nMRMAC core / serdes\n"
               "clocks, GT usrclks\n(per-lane RX, shared TX)",
               title_fs=7.6, body_fs=6.2, title_dy=2.3)
    route(ax, [(in_x0 + 7.0, ctl_y1), (in_x0 + 7.0, 85.6), (mr_x0 + 3.0, 85.6),
               (mr_x0 + 3.0, mr_y0)], C_CTRL_LINE, lw=1.2)
    ctrl_arrow(ax, (in_x0 + 14.0, 72.0), (97.0, 72.0))

    # ---- right column: GT quad, refclk buffer, QSFP GPIO / IIC ----------------
    gt_y0, gt_y1 = 108.0, 133.0
    titled_box(ax, rc_x0, gt_y0, rc_w, gt_y1 - gt_y0, g.C_GT_FILL, g.C_GT_EDGE,
               "gt_quad_base_0",
               "GTY_QUAD_X1Y1\n4 lanes, 80-bit RAW\n25.78125 Gb/s\nLCPLL, integer-N\n\n"
               "APB3 ← axi_apb_\nbridge_0 (AXI\nside not connected)",
               title_fs=7.8, body_fs=6.3, title_dy=2.3)
    gt_mr_y = 121.0
    harrow(ax, mr_x1, rc_x0, gt_mr_y, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           bh=1.3, hh=2.4, hl=1.0)
    small(ax, (mr_x1 + rc_x0) / 2, gt_mr_y + 5.4, "4 × TX/RX\nGT_IP_\nInterface",
          fs=5.6)
    titled_box(ax, rc_x0, 97.5, rc_w, 8.5, g.C_CTRL_FILL, g.C_CTRL_EDGE,
               "axi_gpio_qsfp0", "@ 0x8002_0000  (M04)\nCH1 out, CH2 in",
               title_fs=7.2, body_fs=6.1, title_dy=2.0)
    titled_box(ax, rc_x0, 88.0, rc_w, 8.0, g.C_CTRL_FILL, g.C_CTRL_EDGE,
               "axi_iic_qsfp0", "@ 0x8005_0000  (M05)\nirq4",
               title_fs=7.2, body_fs=6.1, title_dy=2.0)
    titled_box(ax, rc_x0, 76.5, rc_w, 8.5, g.C_CTRL_FILL, g.C_CTRL_EDGE,
               "axi_iic_clk", "shared, @ 0x8004_0000\n(M12), irq5",
               title_fs=7.2, body_fs=6.1, title_dy=2.0)
    titled_box(ax, rc_x0, 66.0, rc_w, 7.5, g.C_GT_FILL, g.C_GT_EDGE,
               "util_ds_buf_0", "IBUFDSGTE",
               title_fs=7.2, body_fs=6.1, title_dy=2.0)
    # util_ds_buf_0 -> gt_quad_base_0 GT_REFCLK0
    rfx = 139.6
    ax.add_line(plt.Line2D([rc_x0, rfx, rfx], [69.2, 69.2, 111.0],
                           color=g.C_REFCLK_LINE, lw=1.7, zorder=3))
    route(ax, [(rfx, 111.0), (rc_x0, 111.0)], g.C_REFCLK_LINE, lw=1.7)
    small(ax, rfx - 0.7, 104.0, "GT_REFCLK0", fs=5.8, color=g.C_REFCLK_LINE,
          weight="bold")
    ax.texts[-1].set_rotation(90)

    # ---- control band: MAC-side resets (port 0) --------------------------------
    titled_box(ax, zn_x0, ctl_y0, zn_x1 - zn_x0, ctl_y1 - ctl_y0, g.C_CLK_FILL,
               g.C_CLK_EDGE, "rst_mac_rx  ·  rst_mac_tx",
               "proc_sys_reset, 390.625 MHz\n"
               "pl0_resetn, axis_clk_wiz/locked,\n"
               "aux_reset_in = AND of port 0\ngt_rx / gt_tx_reset_done_out[3:0]\n"
               "→ rx_packer / tx_dwidth + adapter,\nzircon_nic_0 mac_rx / mac_tx_aresetn",
               title_fs=7.8, body_fs=6.3, title_dy=2.3)
    small(ax, dma_x + dma_w / 2, 75.0,
          "UI0 / UI2:\n512-bit AXIS\n@ 100 MHz\n\nNoC ports\nrequest\n500 MB/s rd\n"
          "+ 500 MB/s wr", fs=6.2)

    # ======================= PORT 1 (compact) ==================================
    d1_h = (p1_y1 - p1_y0 - 1.5) / 2
    raw1_y0 = p1_y0 + d1_h + 1.5
    titled_box(ax, dma_x, raw1_y0, dma_w, d1_h, g.C_DMA_FILL, g.C_DMA_EDGE,
               "axi_dma_raw_1", "@ 0x8018_0000\nNoC S12–S14\nirq6 / irq7",
               title_fs=7.0, body_fs=6.2, txtcolor="#FFFFFF", title_dy=2.1)
    titled_box(ax, dma_x, p1_y0, dma_w, d1_h, g.C_DMA_FILL, g.C_DMA_EDGE,
               "axi_dma_sock_1", "@ 0x8019_0000\nNoC S15–S17\nirq8 / irq9",
               title_fs=7.0, body_fs=6.2, txtcolor="#FFFFFF", title_dy=2.1)
    raw1_yc = raw1_y0 + d1_h / 2
    sock1_yc = p1_y0 + d1_h / 2
    for yc, lab in ((raw1_yc, "UI0"), (sock1_yc, "UI2")):
        harrow(ax, noc_x + noc_w, dma_x, yc, "", g.C_AXARR_FILL, g.C_AXARR_EDGE,
               bh=1.3, hh=2.4, hl=1.2)
        harrow(ax, dma_r, zn_x0, yc, lab, g.C_AXARR_FILL, g.C_AXARR_EDGE,
               bh=1.6, hh=2.8, hl=1.6, fs=7.0)
    titled_box(ax, zn_x0, p1_y0, zn_x1 - zn_x0, p1_y1 - p1_y0, g.C_MAC_FILL,
               g.C_MAC_EDGE, "zircon_nic_1",
               "same module and clocks as zircon_nic_0\n"
               "s_axi @ 0x801A_0000\n\n"
               "MAC side reset by\nrst_mac_rx_1 / rst_mac_tx_1\n"
               "(port 1 GT reset-done)",
               title_fs=10.2, body_fs=6.6, title_dy=2.6, lw=1.6)
    p1_yc = 46.0
    box(ax, hier_x0, 34.2, hier_x1 - hier_x0, 24.3, C_HIER_FILL, g.C_MAC_EDGE, "",
        lw=1.3, ls=(0, (4, 2)))
    ax.text((hier_x0 + hier_x1) / 2, 56.3, "qsfp_port1   (hierarchy)",
            ha="center", va="center", fontsize=9.0, weight="bold", color=TXT,
            zorder=3)
    titled_box(ax, in_x0, 36.0, rp_x1 - in_x0, 18.0, g.C_MAC_FILL, g.C_MAC_EDGE,
               "rx_packer\ntx_dwidth → tx_axis_adapter",
               "\n\n\naxi_smc_lite, axi_gpio_gt1\n@ 0x8017_0000\n10 × bufg_gt",
               title_fs=7.6, body_fs=6.3, title_dy=3.4)
    titled_box(ax, mr_x0, 36.0, mr_x1 - mr_x0, 18.0, g.C_GT_FILL, g.C_GT_EDGE,
               "mrmac",
               "MRMAC_X0Y2\n1x100GE CAUI-4, RS-FEC\n(same configuration)\n"
               "s_axi @ 0x8010_0000",
               title_fs=9.0, body_fs=6.5, title_dy=2.5)
    harrow(ax, zn_x1, in_x0, p1_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.3)
    harrow(ax, rp_x1, mr_x0, p1_yc, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.1)
    titled_box(ax, rc_x0, 46.5, rc_w, 11.0, g.C_GT_FILL, g.C_GT_EDGE,
               "gt_quad_base_1", "GTY_QUAD_X1Y2\nrefclk via\nutil_ds_buf_1",
               title_fs=7.4, body_fs=6.1, title_dy=2.1)
    titled_box(ax, rc_x0, 35.0, rc_w, 10.0, g.C_CTRL_FILL, g.C_CTRL_EDGE,
               "axi_gpio_qsfp1\naxi_iic_qsfp1",
               "\n\n@ 0x8012_0000\n@ 0x8015_0000, irq10",
               title_fs=6.9, body_fs=6.0, title_dy=2.9)
    harrow(ax, mr_x1, rc_x0, 51.0, "", g.C_DPARR_FILL, g.C_DPARR_EDGE,
           bh=1.3, hh=2.4, hl=1.0)

    # ======================= shared strip =======================================
    sh_y0, sh_y1 = 4.0, 31.0
    # axi_smc: the AXI-Lite tree with the M_AXI_LPD address map
    smc_x0, smc_x1 = 28.5, 76.5
    box(ax, smc_x0, sh_y0, smc_x1 - smc_x0, sh_y1 - sh_y0, g.C_CTRL_FILL,
        g.C_CTRL_EDGE, "", lw=1.3)
    ax.text((smc_x0 + smc_x1) / 2, sh_y1 - 2.2,
            "axi_smc   (SmartConnect, 1 SI → 13 MI, 100 MHz)",
            ha="center", va="center", fontsize=8.2, weight="bold", color=TXT,
            zorder=3)
    small(ax, (smc_x0 + smc_x1) / 2, sh_y1 - 5.0,
          "M_AXI_LPD address map (64 KB each, zircon_nic 4 KB)", fs=6.4)
    rows0 = [("M00", "qsfp_port0 → axi_smc_lite:", ""),
             ("", "   mrmac", "0x8000_0000"),
             ("", "   axi_gpio_gt0", "0x8007_0000"),
             ("M01", "axi_dma_raw", "0x8008_0000"),
             ("M02", "axi_dma_sock", "0x8009_0000"),
             ("M03", "zircon_nic_0", "0x800A_0000"),
             ("M04", "axi_gpio_qsfp0", "0x8002_0000"),
             ("M05", "axi_iic_qsfp0", "0x8005_0000")]
    rows1 = [("M06", "qsfp_port1 → axi_smc_lite:", ""),
             ("", "   mrmac", "0x8010_0000"),
             ("", "   axi_gpio_gt1", "0x8017_0000"),
             ("M07", "axi_dma_raw_1", "0x8018_0000"),
             ("M08", "axi_dma_sock_1", "0x8019_0000"),
             ("M09", "zircon_nic_1", "0x801A_0000"),
             ("M10", "axi_gpio_qsfp1", "0x8012_0000"),
             ("M11", "axi_iic_qsfp1", "0x8015_0000")]
    col_w = (smc_x1 - smc_x0 - 2.0) / 2
    for ci, rows in enumerate((rows0, rows1)):
        cx0 = smc_x0 + 1.0 + ci * col_w
        for ri, (mi, cell, addr) in enumerate(rows):
            yy = sh_y1 - 8.0 - ri * 2.1
            small(ax, cx0 + 0.3, yy, mi, fs=6.3, ha="left", color="#606060")
            small(ax, cx0 + 3.6, yy, cell, fs=6.3, ha="left", color=TXT)
            small(ax, cx0 + col_w - 0.8, yy, addr, fs=6.3, ha="right", color=TXT,
                  weight="bold")
    ax.add_line(plt.Line2D([smc_x0 + 1.0 + col_w] * 2, [sh_y1 - 6.8, 7.0],
                           color=g.C_CTRL_EDGE, lw=0.9, zorder=3))
    ax.add_line(plt.Line2D([smc_x0 + 1.0, smc_x1 - 1.0], [7.0, 7.0],
                           color=g.C_CTRL_EDGE, lw=0.9, zorder=3))
    small(ax, smc_x0 + 1.3, 5.4, "M12", fs=6.3, ha="left", color="#606060")
    small(ax, smc_x0 + 4.6, 5.4, "axi_iic_clk  (shared: Si5328 I2C)", fs=6.3,
          ha="left", color=TXT)
    small(ax, smc_x1 - 1.8, 5.4, "0x8004_0000", fs=6.3, ha="right",
          color=TXT, weight="bold")
    # CIPS M_AXI_LPD -> axi_smc
    harrow(ax, ps_r, smc_x0, 20.0, "", g.C_CTRL_FILL, g.C_PS_EDGE, double=False,
           bh=1.5, hh=2.7, hl=1.8)

    # clocking
    ck_x0, ck_x1 = 78.0, 113.0
    titled_box(ax, ck_x0, sh_y0, ck_x1 - ck_x0, sh_y1 - sh_y0, g.C_CLK_FILL,
               g.C_CLK_EDGE, "Clocks   (from versal_cips_0/pl0_ref_clk)", "",
               title_fs=7.9, title_dy=2.2)
    clk_rows = [("clk_wizard_0/clk_100m", "100 MHz",
                 "AXI-Lite, DMAs, NoC aclk6, ui_clk,\nGT APB3, MRMAC s_axi"),
                ("clk_wizard_0/clk_300m", "300 MHz", "zircon_nic clk (core)"),
                ("clk_wizard_0/ts_clk", "250 MHz",
                 "MRMAC tx/rx_ts_clk, ptp_systimer_0"),
                ("axis_clk_wiz/clk_390m625", "390.625 MHz",
                 "MRMAC tx/rx_axi_clk, rx_packer,\ntx_dwidth, tx_axis_adapter, "
                 "zircon_nic\nmac_rx/tx_clk  (both ports)")]
    yy = sh_y1 - 5.3
    for name, f, use in clk_rows:
        small(ax, ck_x0 + 1.0, yy, name, fs=6.4, ha="left", color=TXT,
              weight="bold")
        small(ax, ck_x1 - 1.0, yy, f, fs=6.4, ha="right", color=TXT, weight="bold")
        nl = use.count("\n") + 1
        small(ax, ck_x0 + 2.2, yy - 1.1, use, fs=6.1, ha="left", va="top")
        yy -= 2.2 + 1.3 * nl + 0.4

    # resets
    rs_x0, rs_x1 = 114.5, 134.8
    titled_box(ax, rs_x0, sh_y0, rs_x1 - rs_x0, sh_y1 - sh_y0, g.C_CLK_FILL,
               g.C_CLK_EDGE, "Resets (proc_sys_reset)",
               "rst_100m · rst_300m · rst_ts\npl0_resetn,\nclk_wizard_0/locked\n\n"
               "rst_mac_rx · rst_mac_tx\nrst_mac_rx_1 · rst_mac_tx_1\n"
               "pl0_resetn,\naxis_clk_wiz/locked,\naux = that port's\nGT reset-done",
               title_fs=7.6, body_fs=6.2, title_dy=2.2)

    # 1588 system timer
    pt_x0, pt_x1 = 135.8, 155.2
    titled_box(ax, pt_x0, sh_y0, pt_x1 - pt_x0, sh_y1 - sh_y0, g.C_CLK_FILL,
               g.C_CLK_EDGE, "ptp_systimer_0",
               "module reference, ts_clk\n250 MHz, reset by rst_ts\n\n"
               "55-bit timer, 2⁻⁸ ns units,\n+4 ns per cycle\n\n"
               "→ ctl_tx/rx_ptp_systemtimer\n+ st_sync of both MRMACs\n\n"
               "sync_req ← axi_gpio_gt0\nCH1 bit 3",
               title_fs=7.8, body_fs=6.2, title_dy=2.2)
    # timer bus up to both MRMACs
    ax.add_line(plt.Line2D([ptp_x, ptp_x], [sh_y1, 96.0], color=C_PTP, lw=2.2,
                           zorder=3.5))
    route(ax, [(ptp_x, 96.0), (mr_x1, 96.0)], C_PTP, lw=2.2)
    route(ax, [(ptp_x, 40.0), (mr_x1, 40.0)], C_PTP, lw=2.2)

    # ======================= external: FMC ======================================
    ax.add_patch(plt.Rectangle((fmc_x0, 33.0), fmc_x1 - fmc_x0, 110.0,
                               fc=g.C_FMC_FILL, ec=g.C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 146.2, "External", ha="center", va="bottom",
            fontsize=12, weight="bold", color=TXT)
    ax.text((fmc_x0 + fmc_x1) / 2, 139.3, "2x QSFP28 FMC (OP120)\non FMCP1",
            ha="center", va="center", fontsize=9.4, weight="bold", color=TXT,
            linespacing=1.25)

    # QSFP28 port 0 cage, with the rows lined up with the arrows that reach it
    cg0_y0, cg0_y1 = 86.0, 134.5
    box(ax, cg_x0, cg0_y0, cg_x1 - cg_x0, cg0_y1 - cg0_y0, g.C_CAGE_FILL,
        g.C_FMC_EDGE, "", lw=1.2)
    ax.text(cgx, cg0_y1 - 2.6, "QSFP28 port 0", ha="center", va="center",
            fontsize=8.8, weight="bold", color=TXT, zorder=3)
    lane0_y = 124.5
    small(ax, cgx, lane0_y - 2.2, "qsfp0_gt → FMC DP0-3\n4 × 25.78125 Gb/s",
          fs=6.6, color=TXT)
    small(ax, cgx, 110.5, "LEDs grn_led_qsfp0 /\nred_led_qsfp0 (FMC LA07)\n"
          "← mrmac stat_rx_status_0", fs=6.2, color=TXT)
    small(ax, cgx, 101.7, "modsell / resetl / lpmode_qsfp0\n"
          "modprsl / intl_qsfp0", fs=6.2, color=TXT)
    small(ax, cgx, 92.0, "qsfp0_i2c (FMC LA03)", fs=6.2, color=TXT)
    harrow(ax, rc_x1, cg_x0, lane0_y, "", g.C_LINKARR_FILL, g.C_LINKARR_EDGE,
           bh=1.8, hh=3.1, hl=1.4)
    harrow(ax, rc_x1, cg_x0, 101.7, "", g.C_CTRL_FILL, g.C_PS_EDGE,
           bh=0.9, hh=1.8, hl=1.0)
    harrow(ax, rc_x1, cg_x0, 92.0, "", g.C_CTRL_FILL, g.C_PS_EDGE,
           bh=0.9, hh=1.8, hl=1.0)

    # Si5328
    si_y0, si_y1 = 62.5, 82.5
    titled_box(ax, cg_x0, si_y0, cg_x1 - cg_x0, si_y1 - si_y0, g.C_CLK_FILL,
               g.C_CLK_EDGE, "Si5328  (shared)",
               "322.265625 MHz, LVDS\n\nclk_i2c ← axi_iic_clk\n\n"
               "CKOUT1 → GBTCLK0 → gt_ref_clk_0\n\nCKOUT2 → GBTCLK1 → gt_ref_clk_1",
               title_fs=8.4, body_fs=6.2, title_dy=2.4)
    harrow(ax, rc_x1, cg_x0, 80.2, "", g.C_CTRL_FILL, g.C_PS_EDGE,
           bh=0.9, hh=1.8, hl=1.0)
    refclk_arrow(ax, (cg_x0, 69.2), (rc_x1, 69.2), "GBTCLK0",
                 (157.8, 71.2), fs=5.6, lw=1.7)
    refclk_arrow(ax, (cg_x0, 64.4), (rc_x1, 55.5), "GBTCLK1",
                 (156.6, 62.4), fs=5.6, lw=1.7)

    # QSFP28 port 1 cage
    cg1_y0, cg1_y1 = 35.0, 57.5
    box(ax, cg_x0, cg1_y0, cg_x1 - cg_x0, cg1_y1 - cg1_y0, g.C_CAGE_FILL,
        g.C_FMC_EDGE, "", lw=1.2)
    ax.text(cgx, cg1_y1 - 2.6, "QSFP28 port 1", ha="center", va="center",
            fontsize=8.8, weight="bold", color=TXT, zorder=3)
    small(ax, cgx, 49.0, "qsfp1_gt → FMC DP4-7\n4 × 25.78125 Gb/s", fs=6.6,
          color=TXT)
    small(ax, cgx, 40.2, "sideband GPIO, qsfp1_i2c,\ngrn / red_led_qsfp1", fs=6.2,
          color=TXT)
    harrow(ax, rc_x1, cg_x0, 51.0, "", g.C_LINKARR_FILL, g.C_LINKARR_EDGE,
           bh=1.8, hh=3.1, hl=1.4)
    harrow(ax, rc_x1, cg_x0, 40.0, "", g.C_CTRL_FILL, g.C_PS_EDGE,
           bh=0.9, hh=1.8, hl=1.0)

    # ======================= legend ============================================
    lg_x0, lg_y1 = fmc_x0, 31.0
    ax.text(lg_x0 + 0.5, lg_y1 - 0.8, "Legend", ha="left", va="center",
            fontsize=8.2, weight="bold", color=TXT)
    swatches = [(g.C_PS_FILL, g.C_PS_EDGE, "PS, NoC, DDR4"),
                (g.C_DMA_FILL, g.C_DMA_EDGE, "AXI DMA"),
                (g.C_MAC_FILL, g.C_MAC_EDGE, "datapath logic"),
                (g.C_CTRL_FILL, g.C_CTRL_EDGE, "AXI-Lite peripheral"),
                (g.C_GT_FILL, g.C_GT_EDGE, "hard block / buffer"),
                (g.C_CLK_FILL, g.C_CLK_EDGE, "clock / reset / timer"),
                (g.C_FMC_FILL, g.C_FMC_EDGE, "external (FMC)")]
    for i, (fc, ec, lab) in enumerate(swatches):
        col, row = i % 2, i // 2
        xx = lg_x0 + 0.5 + col * 18.0
        yy = lg_y1 - 4.2 - row * 3.2
        box(ax, xx, yy - 1.0, 3.0, 2.0, fc, ec, "", lw=1.0)
        small(ax, xx + 3.8, yy, lab, fs=6.4, ha="left", color=TXT)
    lines = [(g.C_AXARR_EDGE, "AXI / AXIS @ 100 MHz"),
             (g.C_DPARR_EDGE, "100G datapath (390.625 MHz)"),
             (g.C_LINKARR_EDGE, "4 serial lanes"),
             (g.C_REFCLK_LINE, "GT reference clock"),
             (C_PTP, "1588 timer / timestamps")]
    for i, (c, lab) in enumerate(lines):
        col, row = i % 2, i // 2
        xx = lg_x0 + 0.5 + col * 18.0
        yy = 13.4 - row * 3.2
        ax.add_line(plt.Line2D([xx, xx + 3.0], [yy, yy], color=c, lw=2.6,
                               zorder=3))
        small(ax, xx + 3.8, yy, lab, fs=6.4, ha="left", color=TXT)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "zircon-bd-diagram.png")
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the block diagram for the Opsero 2x QSFP28 FMC Zircon (100G) reference design docs.

The design runs both 100 Gigabit Ethernet ports of the 2x QSFP28 FMC (OP120) on the
VCK190. Per port: QSFP28 cage -> FMC lanes (port 0 DP0-3, port 1 DP4-7) -> one GTY
quad -> a Versal integrated MRMAC (1x100GE CAUI-4, RS-FEC) -> the RX packer / TX
adapter (384 <-> 512 bits @ 390.625 MHz) -> `zircon_nic_<p>` (the Taxi Zircon IP
stack plus Opsero's MIT glue, 512 bits @ 300 MHz). Received traffic is dispatched
four ways: UI1 is a hardware UDP echo that loops back inside zircon_nic, CHK feeds
the hardware UDP checker, UI0 (raw frames) and UI2 (hardware UDP socket) reach DDR4
through two AXI DMAs per port and the NoC. A hardware UDP generator feeds the TX
payload buffer, and rate meters measure each port once per second. Port 0 is drawn
in detail; port 1 is an exact copy and is drawn compact. The external column shows
the two test setups: a 100G link partner, or a loopback cable between the two
QSFP28 cages. The Versal PS (CIPS) is the control plane only.

The output PNG is written next to this script (i.e. into docs/source/images/):
    zircon-block-diagram.png

Usage (from anywhere):
    python3 docs/source/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyBboxPatch, FancyArrowPatch
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_DMA_FILL     = "#808080"; C_DMA_EDGE     = "#404040"   # AXI DMA (dark grey)
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # Taxi / Zircon logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: MRMAC, GTY (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_CAGE_FILL    = "#FFFFFF"                                # QSFP28 cages (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # control-plane caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # data arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # link arrows (pale blue)
C_REFCLK_LINE  = "#C8823C"                                # refclk arrows (orange)
TXT = "#1A1A1A"
# additions for this design: the hardware datapath highlight and the echo loop
C_HW_FILL      = "#FBF7E6"; C_HW_EDGE      = "#D9C27A"   # "no processor" region
C_HW_TXT       = "#8A6D12"
C_DPARR_FILL   = "#D5E6A3"; C_DPARR_EDGE   = "#7F9A2E"   # 100G datapath arrows
C_ECHO         = "#5E8C1E"                                # UI1 echo loop (green)
C_THIN         = "#8FA048"                                # thin AXIS routes
C_MUTED        = "#8C8C8C"                                # unused / notes
C_GEN_FILL     = "#E4F0D0"; C_GEN_EDGE     = "#7F9A2E"   # generator / checker (1.2.0)


def box(ax, x, y, w, h, fc, ec, label, fs=10, rot=0, lw=1.2, weight="normal",
        round_=False, txtcolor=None, ls="-", z=2):
    if round_:
        p = FancyBboxPatch((x + 0.4, y + 0.4), w - 0.8, h - 0.8,
                           boxstyle="round,pad=0.0,rounding_size=1.2",
                           fc=fc, ec=ec, lw=lw, ls=ls, zorder=z)
    else:
        p = plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls, zorder=z)
    ax.add_patch(p)
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, rotation=rot, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.6, ls="-"):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=3)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=3, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=True, bh=2.0, hh=3.4, hl=3.2,
           fs=8.5, lw=1.1, lab_dy=0.0, lab_color=None, weight="normal"):
    """Horizontal block arrow from x0 to x1.

    double=True  : double-headed (requires x0 < x1).
    double=False : single-headed with the head at x1; works in either
                   direction (x1 may be < x0 for a leftward arrow).
    """
    if double:
        pts = [(x0, yc), (x0 + hl, yc + hh), (x0 + hl, yc + bh),
               (x1 - hl, yc + bh), (x1 - hl, yc + hh), (x1, yc),
               (x1 - hl, yc - hh), (x1 - hl, yc - bh),
               (x0 + hl, yc - bh), (x0 + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0   # direction from tail (x0) to head (x1)
        neck = x1 - s * hl              # base of the arrowhead
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=2))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=3, linespacing=1.15,
                weight=weight)


def varrow(ax, xc, y0, y1, fc, ec, double=True, bw=1.4, hw=2.6, hl=2.4, lw=1.1):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc - bw, y0), (xc - bw, neck), (xc - hw, neck), (xc, y1),
               (xc + hw, neck), (xc + bw, neck), (xc + bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=2))


def route(ax, pts, color, lw=1.8):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, zorder=3,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=11, lw=lw, color=color,
                                 zorder=3, shrinkA=0, shrinkB=0))


def refclk_arrow(ax, p0, p1, label, lab_xy, fs=7.8, lw=1.9):
    """Thin single-line arrow (head at p1) for a single clock net, at any angle.

    A reference clock is one net (not a wide bus), so a thin arrow distinguishes
    it from the fat AXI/AXIS/serial-link bus arrows.
    """
    ax.add_patch(FancyArrowPatch(p0, p1, arrowstyle="-|>", mutation_scale=13,
                                 lw=lw, color=C_REFCLK_LINE, zorder=3,
                                 shrinkA=0, shrinkB=0))
    ax.text(lab_xy[0], lab_xy[1], label, ha="center", va="center",
            fontsize=fs, color=C_REFCLK_LINE, zorder=4, weight="bold",
            linespacing=1.2)


def main():
    fig, ax = plt.subplots(figsize=(19.5, 14.8), dpi=120)
    ax.set_xlim(0, 195)
    ax.set_ylim(0, 148)
    ax.axis("off")

    # vertical plan: control/clock strip 5-22, port 1 row 29-55, port 0 60-132
    B0 = 60.0                       # base of zircon_nic_0
    rx_y0, rx_h = B0 + 43, 18       # port 0 RX row (flows right to left)
    tx_y0, tx_h = B0 + 9, 18        # port 0 TX row (flows left to right)
    rx_yc = rx_y0 + rx_h / 2
    tx_yc = tx_y0 + tx_h / 2
    p1_y0, p1_y1 = 29.0, 55.0       # port 1 row
    p1_yc = (p1_y0 + p1_y1) / 2

    # ---- processing system column: DDR4, CIPS, NoC -------------------------
    ps_x0, ps_w = 2, 16
    ps_r = ps_x0 + ps_w
    titled_box(ax, ps_x0, 124, ps_w, 14, C_PS_FILL, C_PS_EDGE, "DDR4",
               "VCK190 on-board\nmemory", title_fs=10.5, body_fs=7.4,
               title_dy=3.4, lw=1.3)
    box(ax, ps_x0, 5, ps_w, 115, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    cx = ps_x0 + ps_w / 2
    ax.text(cx, 113.0, "Versal PS\n(CIPS)", ha="center", va="center",
            fontsize=11.5, weight="bold", color=TXT, linespacing=1.25)
    ax.text(cx, 105.5, "Arm Cortex-A72\nbare-metal echo_server",
            ha="center", va="center", fontsize=7.5, color=TXT, linespacing=1.35)
    ax.text(cx, 99.6, "CONTROL PLANE ONLY", ha="center", va="center",
            fontsize=7.7, weight="bold", color="#404040")
    ax.text(cx, 67.0,
            "Bring-up:\n"
            "PS I2C → VADJ 1.5 V\n"
            "AXI IIC → Si5328\n"
            "per port: GT reset,\nMRMAC + RS-FEC,\n"
            "zircon_nic registers\n\n"
            "lwIP per port over\nUI0 raw: ARP, ICMP,\n"
            "DHCP, software\nTCP echo\n\n"
            "UI2 socket payloads\n\n"
            "Loopback test:\nsets up udp_gen /\nudp_chk, reads the\n"
            "rate meters, prints\nthe 1 s table and\nLOOPBACK: PASS",
            ha="center", va="center", fontsize=7.4, color=TXT, linespacing=1.55)

    # NoC strip between the PS column and the fabric
    noc_x, noc_w = 20.5, 4.0
    box(ax, noc_x, 29, noc_w, 109, C_PS_FILL, C_PS_EDGE,
        "NoC  (axi_noc_0)", fs=8.2, rot=90, weight="bold", lw=1.3)
    harrow(ax, ps_r, noc_x, 131.0, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.2, hh=2.2, hl=1.1)
    harrow(ax, ps_r, noc_x, 108.0, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.2, hh=2.2, hl=1.1)

    # ---- FPGA fabric container ----------------------------------------------
    fab_x0, fab_x1 = 27, 147.5
    ax.add_patch(plt.Rectangle((fab_x0, 3), fab_x1 - fab_x0, 138,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 141.6,
            "Versal PL + integrated blocks  (XCVC1902, VCK190)", ha="center",
            va="bottom", fontsize=13, weight="bold", color=TXT)

    # hardware datapath region (everything the 100G traffic crosses)
    hw_x0, hw_x1, hw_y0, hw_y1 = 44.2, 146.6, 26.8, 139.2
    ax.add_patch(FancyBboxPatch((hw_x0, hw_y0), hw_x1 - hw_x0, hw_y1 - hw_y0,
                                boxstyle="round,pad=0.0,rounding_size=1.0",
                                fc=C_HW_FILL, ec=C_HW_EDGE, lw=1.4, ls=(0, (5, 3)),
                                zorder=1.2))
    ax.text((hw_x0 + hw_x1) / 2, 136.3,
            "HARDWARE DATAPATH  —  100 Gb/s per port, no processor in the path",
            ha="center", va="center", fontsize=10.2, weight="bold",
            color=C_HW_TXT, zorder=3)

    # ---- port 0 AXI DMAs -------------------------------------------------------
    dma_x, dma_w = 28.4, 11.8
    dma_r = dma_x + dma_w
    titled_box(ax, dma_x, rx_y0, dma_w, rx_h, C_DMA_FILL, C_DMA_EDGE,
               "axi_dma_raw",
               "AXI DMA (SG)\nUI0 raw frames\n\nS2MM = RX\nMM2S = TX",
               title_fs=8.0, body_fs=7.1, txtcolor="#FFFFFF", title_dy=2.8)
    titled_box(ax, dma_x, tx_y0, dma_w, tx_h, C_DMA_FILL, C_DMA_EDGE,
               "axi_dma_sock",
               "AXI DMA (SG)\nUI2 socket\n\nS2MM = RX\nMM2S = TX",
               title_fs=8.0, body_fs=7.1, txtcolor="#FFFFFF", title_dy=2.8)
    for yc in (rx_yc, tx_yc):
        harrow(ax, noc_x + noc_w, dma_x, yc, "", C_AXARR_FILL, C_AXARR_EDGE,
               bh=1.4, hh=2.5, hl=1.3)
    ax.text(dma_x + dma_w / 2, (tx_y0 + tx_h + rx_y0) / 2,
            "3x AXI MM each\n(SG / MM2S / S2MM)\n→ NoC → DDR4",
            ha="center", va="center", fontsize=6.6, color="#404040",
            linespacing=1.3, zorder=3)
    ax.text(dma_x + dma_w / 2, rx_y0 + rx_h + 4.2,
            "UI0 / UI2 ports:\n512-bit AXIS @ 100 MHz",
            ha="center", va="center", fontsize=6.6, color="#404040",
            linespacing=1.3, zorder=3)

    # ---- zircon_nic_0 -------------------------------------------------------------
    zn_x0, zn_x1, zn_y0, zn_y1 = 46.2, 108.0, B0, B0 + 72
    box(ax, zn_x0, zn_y0, zn_x1 - zn_x0, zn_y1 - zn_y0, "#F7F7FB", C_MAC_EDGE,
        "", lw=1.6)
    zcx = (zn_x0 + zn_x1) / 2
    ax.text(zcx, zn_y1 - 2.8, "zircon_nic_0   (QSFP28 port 0)", ha="center",
            va="center", fontsize=11, weight="bold", color=TXT, zorder=3)
    ax.text(zcx, zn_y1 - 6.6,
            "Taxi Zircon (unmodified) + Opsero MIT glue  ·  "
            "core: 512 bits @ 300 MHz",
            ha="center", va="center", fontsize=7.5, color=TXT, zorder=3)

    # RX row, right to left: MAC-side FIFO -> two branches -> rx_dispatch
    disp_x, disp_w = 48.0, 22.0
    br_x, br_w = 73.0, 20.0
    rff_x, rff_w = 96.0, 10.0
    titled_box(ax, rff_x, rx_y0, rff_w, rx_h, C_MAC_FILL, C_MAC_EDGE,
               "RX FIFO", "MAC side\nasync, 32 KB\n\ndrops bad\nand overflow\nframes",
               title_fs=8.6, body_fs=6.9, title_dy=2.6)
    titled_box(ax, br_x, rx_y0 + 9.5, br_w, 8.5, C_MAC_FILL, C_MAC_EDGE,
               "B: header parse",
               "hdr_trunc (64 B) → 512→32 b\n→ zircon_ip_rx_parse",
               title_fs=8.0, body_fs=6.8, title_dy=2.0)
    titled_box(ax, br_x, rx_y0, br_w, 8.5, C_MAC_FILL, C_MAC_EDGE,
               "A: length / checksum",
               "zircon_ip_len_cksum\n+ store-and-forward FIFO",
               title_fs=8.0, body_fs=6.8, title_dy=2.0)
    titled_box(ax, disp_x, rx_y0, disp_w, rx_h, C_MAC_FILL, C_MAC_EDGE,
               "rx_dispatch",
               "rules:\nECHO  UDP:7 → UI1 echo\nSOCK  UDP:5000 → UI2\n"
               "CHK   UDP:5001 → udp_chk\nelse RAW → UI0",
               title_fs=8.8, body_fs=6.9, title_dy=2.6)
    harrow(ax, rff_x, br_x + br_w, rx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.2, hh=2.2, hl=1.8)
    harrow(ax, br_x, disp_x + disp_w, rx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.2, hh=2.2, hl=1.8)

    # TX row, left to right: payload buffer -> metadata -> egress
    txb_x, txb_w = 48.0, 30.5
    meta_x, meta_w = 81.5, 11.5
    egr_x, egr_w = 96.0, 10.0
    titled_box(ax, txb_x, tx_y0, txb_w, tx_h, C_MAC_FILL, C_MAC_EDGE,
               "zircon_ip_tx_buffer",
               "4 inputs: UI0 raw, UI2 socket (tx_ingress),\n"
               "UI1 echo payloads, UI3 generator\n\n"
               "32 KB payload RAM\nlength + checksum per payload",
               title_fs=8.2, body_fs=6.8, title_dy=2.6)
    titled_box(ax, meta_x, tx_y0, meta_w, tx_h, C_MAC_FILL, C_MAC_EDGE,
               "tx_meta_\nbuilder",
               "\n128-byte header\nmetadata\nper packet:\nraw / echo /\nsocket / gen\n"
               "+ UDP csum fix",
               title_fs=8.2, body_fs=6.6, title_dy=3.4)
    titled_box(ax, egr_x, tx_y0, egr_w, tx_h, C_MAC_FILL, C_MAC_EDGE,
               "tx_egress",
               "zircon_ip_\ntx_deparse:\nEth + IPv4\n+ UDP,\nchecksums\n\n"
               "TX FIFO,\ntx_mac_out",
               title_fs=8.4, body_fs=6.6, title_dy=2.6)
    harrow(ax, txb_x + txb_w, meta_x, tx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.2, hh=2.2, hl=1.4)
    harrow(ax, meta_x + meta_w, egr_x, tx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.2, hh=2.2, hl=1.4)

    # middle band: UI1 echo, checker, generator, rate meters
    band_y0, band_y1 = tx_y0 + tx_h, rx_y0          # 87 .. 103
    echo_x = disp_x + 3.2
    varrow(ax, echo_x, band_y1, band_y0, C_ECHO, "#3F6012", double=False,
           bw=1.5, hw=2.8, hl=2.3)
    ax.text(echo_x + 4.1, (band_y0 + band_y1) / 2, "UI1 hardware\nUDP echo",
            ha="center", va="center", fontsize=7.4, weight="bold",
            color=C_ECHO, rotation=90, zorder=3, linespacing=1.1)
    # checker, fed by rx_dispatch's CHK route
    chk_x, chk_w, chk_y0, chk_y1 = 58.6, 12.4, band_y0 + 1.5, band_y1 - 4.5
    titled_box(ax, chk_x, chk_y0, chk_w, chk_y1 - chk_y0, C_GEN_FILL, C_GEN_EDGE,
               "udp_chk", "checker\nsequence +\nPRBS bit errors",
               title_fs=8.2, body_fs=6.6, title_dy=2.2)
    varrow(ax, chk_x + chk_w / 2, band_y1, chk_y1, C_GEN_EDGE, C_GEN_EDGE,
           double=False, bw=0.9, hw=1.9, hl=1.6)
    # generator, feeding the TX payload buffer (UI3)
    gen_x, gen_w, gen_y0, gen_y1 = 73.0, 14.5, band_y0 + 4.5, band_y1 - 1.5
    titled_box(ax, gen_x, gen_y0, gen_w, gen_y1 - gen_y0, C_GEN_FILL, C_GEN_EDGE,
               "udp_gen", "generator\nsequence +\nPRBS payload",
               title_fs=8.2, body_fs=6.6, title_dy=2.2)
    varrow(ax, gen_x + 2.6, gen_y0, band_y0, C_GEN_EDGE, C_GEN_EDGE,
           double=False, bw=0.9, hw=1.9, hl=1.6)
    # rate meters (tap RX at the core entry and TX at the MAC)
    rate_x, rate_w = 90.0, 16.0
    titled_box(ax, rate_x, band_y0 + 1.5, rate_w, band_y1 - band_y0 - 3.0,
               C_GEN_FILL, C_GEN_EDGE, "rate_meter",
               "RX / TX bytes and\nframes per 1 s\nwindow (Gb/s)",
               title_fs=8.2, body_fs=6.6, title_dy=2.2)

    # zircon_nic register file
    box(ax, 48, B0 + 1.6, 58, 5.2, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite registers (zircon_regs, 100 MHz): statistics, generator / checker,"
        " rate meters", fs=7.2)

    # ---- DMA <-> zircon_nic UI ports (512-bit AXIS @ 100 MHz) -------------------
    harrow(ax, disp_x, dma_r, rx_y0 + 14.5, "UI0", C_AXARR_FILL, C_AXARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=2.2, fs=7.2)
    harrow(ax, dma_r, txb_x, tx_y0 + 3.5, "UI2", C_AXARR_FILL, C_AXARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=2.2, fs=7.2)
    route(ax, [(dma_r, rx_y0 + 3.0), (42.4, rx_y0 + 3.0), (42.4, tx_y0 + 13.5),
               (txb_x, tx_y0 + 13.5)], C_THIN)
    route(ax, [(disp_x, rx_y0 + 5.5), (44.9, rx_y0 + 5.5), (44.9, tx_y0 + 15.5),
               (dma_r, tx_y0 + 15.5)], C_THIN)

    # ---- port 0 MAC side: adapters, MRMAC, GTY ---------------------------------
    ad_x, ad_w = 112.0, 11.0
    titled_box(ax, ad_x, rx_y0, ad_w, rx_h, C_MAC_FILL, C_MAC_EDGE,
               "RX packer",
               "mrmac_rx_\npacker\n48 → 64 B\nno back-\npressure\n(bad frame\n→ tuser)",
               title_fs=8.4, body_fs=6.7, title_dy=2.6)
    titled_box(ax, ad_x, tx_y0, ad_w, tx_h, C_MAC_FILL, C_MAC_EDGE,
               "TX adapt",
               "dwidth\n64 → 48 B\n+ mrmac_tx_\naxis_adapter",
               title_fs=8.4, body_fs=6.7, title_dy=2.6)
    ax.text(ad_x + ad_w / 2, (band_y0 + band_y1) / 2, "390.625\nMHz",
            ha="center", va="center", fontsize=7.0, color="#404040",
            linespacing=1.2, zorder=3)
    harrow(ax, ad_x, zn_x1, rx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.9)
    harrow(ax, zn_x1, ad_x, tx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.9)
    ax.text((zn_x1 + ad_x) / 2, rx_yc + 4.3, "512b", ha="center", va="center",
            fontsize=7.0, color="#404040", zorder=3)
    ax.text((zn_x1 + ad_x) / 2, tx_yc - 4.3, "512b", ha="center", va="center",
            fontsize=7.0, color="#404040", zorder=3)

    mr_x, mr_w = 125.8, 10.2
    titled_box(ax, mr_x, tx_y0, mr_w, rx_y0 + rx_h - tx_y0, C_GT_FILL, C_GT_EDGE,
               "MRMAC",
               "Versal\nintegrated\n100G MAC\n\nMRMAC_X0Y0\n\n1x100GE\nCAUI-4\n\n"
               "RS-FEC\n(clause 91)\n\nFCS insert\n/ strip",
               title_fs=9.2, body_fs=6.9, title_dy=2.8)
    harrow(ax, mr_x, ad_x + ad_w, rx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.6)
    harrow(ax, ad_x + ad_w, mr_x, tx_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           double=False, bh=1.5, hh=2.7, hl=1.6)
    ax.text((ad_x + ad_w + mr_x) / 2, rx_yc + 4.3, "384b", ha="center",
            va="center", fontsize=6.6, color="#404040", zorder=3)
    ax.text((ad_x + ad_w + mr_x) / 2, tx_yc - 4.3, "384b", ha="center",
            va="center", fontsize=6.6, color="#404040", zorder=3)

    gt_x, gt_w = 138.9, 6.5
    titled_box(ax, gt_x, tx_y0, gt_w, rx_y0 + rx_h - tx_y0, C_GT_FILL, C_GT_EDGE,
               "GTY",
               "quad\nX1Y1\n\n4 lanes\n\n25.78125\nGb/s\neach",
               title_fs=9.2, body_fs=6.9, title_dy=2.8)
    p0_lane_y = (band_y0 + band_y1) / 2 + 3.0
    harrow(ax, mr_x + mr_w, gt_x, p0_lane_y, "", C_DPARR_FILL, C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.1)

    # ---- port 1: an exact copy of port 0 (drawn compact) -------------------------
    p1_h = p1_y1 - p1_y0
    d1_h = (p1_h - 2.0) / 2
    titled_box(ax, dma_x, p1_y0 + d1_h + 2.0, dma_w, d1_h, C_DMA_FILL, C_DMA_EDGE,
               "axi_dma_raw_1", "AXI DMA (SG)\nUI0 raw frames",
               title_fs=7.0, body_fs=6.9, txtcolor="#FFFFFF", title_dy=2.6)
    titled_box(ax, dma_x, p1_y0, dma_w, d1_h, C_DMA_FILL, C_DMA_EDGE,
               "axi_dma_sock_1", "AXI DMA (SG)\nUI2 socket",
               title_fs=7.0, body_fs=6.9, txtcolor="#FFFFFF", title_dy=2.6)
    raw1_yc = p1_y0 + d1_h + 2.0 + d1_h / 2
    sock1_yc = p1_y0 + d1_h / 2
    for yc in (raw1_yc, sock1_yc):
        harrow(ax, noc_x + noc_w, dma_x, yc, "", C_AXARR_FILL, C_AXARR_EDGE,
               bh=1.4, hh=2.5, hl=1.3)
    for yc, lab in ((raw1_yc, "UI0"), (sock1_yc, "UI2")):
        harrow(ax, dma_r, zn_x0, yc, lab, C_AXARR_FILL, C_AXARR_EDGE,
               double=True, bh=1.5, hh=2.7, hl=1.6, fs=7.2)

    titled_box(ax, zn_x0, p1_y0, zn_x1 - zn_x0, p1_h, "#F7F7FB", C_MAC_EDGE,
               "zircon_nic_1   (QSFP28 port 1)",
               "the same core as zircon_nic_0, with its own MAC / IPv4 address and registers:\n"
               "rx_dispatch (RAW / ECHO / SOCK / CHK), UI1 hardware UDP echo,\n"
               "UI0 raw and UI2 socket to its own two AXI DMAs,\n"
               "udp_gen, udp_chk and rate_meter, TX header build (Zircon deparser)",
               title_fs=11, body_fs=7.4, title_dy=3.2, lw=1.6)
    titled_box(ax, ad_x, p1_y0, ad_w, p1_h, C_MAC_FILL, C_MAC_EDGE,
               "RX packer\nTX adapt", "\n\n390.625 MHz\n384b ↔ 512b",
               title_fs=8.2, body_fs=6.7, title_dy=4.2)
    titled_box(ax, mr_x, p1_y0, mr_w, p1_h, C_GT_FILL, C_GT_EDGE,
               "MRMAC", "\nMRMAC_X0Y2\n\n1x100GE\nCAUI-4\nRS-FEC",
               title_fs=9.2, body_fs=6.9, title_dy=2.8)
    titled_box(ax, gt_x, p1_y0, gt_w, p1_h, C_GT_FILL, C_GT_EDGE,
               "GTY", "\nquad\nX1Y2\n\n4 lanes",
               title_fs=9.2, body_fs=6.9, title_dy=2.8)
    harrow(ax, zn_x1, ad_x, p1_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.3)
    harrow(ax, ad_x + ad_w, mr_x, p1_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.1)
    harrow(ax, mr_x + mr_w, gt_x, p1_yc, "", C_DPARR_FILL, C_DPARR_EDGE,
           bh=1.5, hh=2.7, hl=1.1)

    # ---- external: 2x QSFP28 FMC, loopback cable, link partner --------------------
    fmc_x0, fmc_x1 = 150.5, 171.5
    fcx = (fmc_x0 + fmc_x1) / 2
    ax.add_patch(plt.Rectangle((fmc_x0, 27), fmc_x1 - fmc_x0, 114,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text(172.0, 141.6, "External to FPGA", ha="center", va="bottom",
            fontsize=12, weight="bold", color=TXT)
    ax.text(fcx, 135.0, "2x QSFP28 FMC\n(OP120)\non FMCP1", ha="center",
            va="center", fontsize=9.8, weight="bold", color=TXT, linespacing=1.3)
    sub_x, sub_w = 152.5, 17.0
    cage0_y0, cage0_y1 = 80.0, 106.0
    titled_box(ax, sub_x, cage0_y0, sub_w, cage0_y1 - cage0_y0, C_CAGE_FILL,
               C_FMC_EDGE, "QSFP28 port 0",
               "100GBASE-R\n4 × 25.78125 Gb/s\nFMC DP0-3\n\nsideband GPIO +\nmodule I2C\nfrom the PL",
               title_fs=8.8, body_fs=7.0, title_dy=2.8)
    si_y0, si_y1 = 51.5, 74.0
    titled_box(ax, sub_x, si_y0, sub_w, si_y1 - si_y0, C_CLK_FILL, C_CLK_EDGE,
               "Si5328",
               "322.265625 MHz\n\nCKOUT1 → GBTCLK0\n(port 0)\nCKOUT2 → GBTCLK1\n(port 1)\n\n"
               "set by the PS\nover AXI IIC",
               title_fs=8.8, body_fs=6.8, title_dy=2.8)
    cage1_y0, cage1_y1 = 29.0, 47.0
    titled_box(ax, sub_x, cage1_y0, sub_w, cage1_y1 - cage1_y0, C_CAGE_FILL,
               C_FMC_EDGE, "QSFP28 port 1",
               "100GBASE-R\n4 × 25.78125 Gb/s\nFMC DP4-7\n\nsideband GPIO + I2C",
               title_fs=8.8, body_fs=7.0, title_dy=2.8)
    # GTY <-> QSFP28 cages: four serial lanes each
    harrow(ax, gt_x + gt_w, sub_x, p0_lane_y, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=2.0, hh=3.4, hl=1.6)
    ax.text((gt_x + gt_w + sub_x) / 2, p0_lane_y + 5.6, "FMC\nDP0-3",
            ha="center", va="center", fontsize=7.2, color=TXT, zorder=3,
            linespacing=1.15)
    p1_lane_y = (cage1_y0 + cage1_y1) / 2 - 1.0
    harrow(ax, gt_x + gt_w, sub_x, p1_lane_y, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=2.0, hh=3.4, hl=1.6)
    ax.text((gt_x + gt_w + sub_x) / 2, p1_lane_y - 5.4, "FMC\nDP4-7",
            ha="center", va="center", fontsize=7.2, color=TXT, zorder=3,
            linespacing=1.15)
    # Si5328 -> GTY reference clocks
    refclk_arrow(ax, (sub_x, si_y1 - 2.2), (gt_x + gt_w, si_y1 - 2.2), "GBTCLK0",
                 (149.0, si_y1 + 0.4), fs=6.4)
    refclk_arrow(ax, (sub_x, si_y0 + 1.5), (gt_x + gt_w, si_y0 + 1.5), "GBTCLK1",
                 (149.0, si_y0 + 4.0), fs=6.4)

    # test setup B: QSFP28 loopback cable between the two cages
    cab_x = 176.0
    cab0_y, cab1_y = cage0_y0 + 6.0, p1_lane_y
    ax.add_line(Line2D([sub_x + sub_w, cab_x, cab_x, sub_x + sub_w],
                       [cab0_y, cab0_y, cab1_y, cab1_y], color=C_LINKARR_EDGE,
                       lw=5.0, zorder=3, solid_joinstyle="round",
                       solid_capstyle="butt"))
    for yy in (cab0_y, cab1_y):          # connector ends
        ax.add_patch(plt.Rectangle((sub_x + sub_w - 0.2, yy - 1.6), 2.6, 3.2,
                                   fc=C_LINKARR_EDGE, ec=C_LINKARR_EDGE, zorder=4))
    titled_box(ax, 178.0, 49.0, 15.5, 34.0, C_CAGE_FILL, C_LINKARR_EDGE,
               "Test setup B",
               "QSFP28\nloopback cable\n(DAC or AOC)\nport 0 ↔ port 1\n\n"
               "no host needed\n\nudp_gen → udp_chk\nboth directions,\n"
               "2 × 100G\nfull line rate",
               title_fs=8.8, body_fs=7.0, title_dy=2.8, lw=1.3)

    # test setup A: a 100G link partner on either port
    titled_box(ax, fmc_x0, 5, 193.5 - fmc_x0, 17, C_CAGE_FILL, C_LINKARR_EDGE,
               "Test setup A:  100G link partner  (either port)",
               "host NIC or switch with RS-FEC (clause 91)\n"
               "e.g. a PC running zircon_echo_test.py",
               title_fs=8.8, body_fs=7.2, title_dy=3.0, lw=1.3)
    varrow(ax, fcx, 22.0, cage1_y0, C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bw=2.0, hw=3.4, hl=2.0)
    ax.text(fcx + 3.6, 25.0, "QSFP28 cable / modules", ha="left",
            va="center", fontsize=7.0, color=TXT, zorder=3)

    # ---- control plane and clocking strip ------------------------------------
    harrow(ax, ps_r, 30.0, 13.5, "", C_CTRL_FILL, C_PS_EDGE, double=False,
           bh=1.6, hh=2.9, hl=2.0)
    ax.text((ps_r + 28.0) / 2 + 0.6, 19.2, "M_AXI_LPD\n100 MHz", ha="center",
            va="center", fontsize=7.0, color="#404040", linespacing=1.2)
    titled_box(ax, 30.0, 5.0, 60.0, 18.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Control plane: AXI-Lite (axi_smc)",
               "per port: MRMAC · zircon_nic · 2 AXI DMAs · AXI GPIO (GT resets,\n"
               "QSFP sideband) · AXI IIC (QSFP module), port p at 0x8000_0000 + p × 0x10_0000\n"
               "shared: AXI IIC to the Si5328\n"
               "interrupts to the PS: 8 DMA + 3 IIC",
               title_fs=8.8, body_fs=7.2, title_dy=3.0)
    titled_box(ax, 92.5, 5.0, 53.5, 18.0, C_CLK_FILL, C_CLK_EDGE,
               "Clocking (from the CIPS pl0_ref_clk, shared by both ports)",
               "clk_wizard_0:  100 MHz  AXI-Lite, DMAs, UI ports\n"
               "clk_wizard_0:  300 MHz  zircon_nic cores\n"
               "axis_clk_wiz:  390.625 MHz  MRMAC clients, adapters",
               title_fs=8.6, body_fs=7.2, title_dy=3.0)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "zircon-block-diagram.png")
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()

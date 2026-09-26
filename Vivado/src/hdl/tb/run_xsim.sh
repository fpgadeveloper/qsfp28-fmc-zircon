#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# run_xsim.sh - build and run the zircon_nic xsim testbenches (and the KCU116 CMAC shim's).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Usage: Vivado/src/hdl/tb/run_xsim.sh [--gui]
#   Needs Vivado 2025.2 (xvlog/xelab/xsim) on PATH, or VIVADO_SETTINGS pointing at
#   its settings64.sh, and python3. Build products go to $XSIM_BUILD
#   (default: Vivado/src/hdl/tb/build, git-ignored).
# Exit status: 0 when every test passed, 1 otherwise.
#
# The RTL file list mirrors Vivado/scripts/zircon_sources.tcl - keep them in sync.

set -euo pipefail

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDL_DIR="$(cd "$TB_DIR/.." && pwd)"
REPO="$(cd "$HDL_DIR/../../.." && pwd)"
TAXI="$REPO/submodules/taxi/src"
BUILD="${XSIM_BUILD:-$TB_DIR/build}"

if ! command -v xvlog >/dev/null 2>&1; then
    if [[ -n "${VIVADO_SETTINGS:-}" && -f "$VIVADO_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$VIVADO_SETTINGS"
    elif [[ -n "${XILINX_VIVADO:-}" && -f "$XILINX_VIVADO/settings64.sh" ]]; then
        # shellcheck disable=SC1091
        source "$XILINX_VIVADO/settings64.sh"
    else
        echo "ERROR: xvlog not found; source Vivado's settings64.sh or set VIVADO_SETTINGS" >&2
        exit 1
    fi
fi

if [[ ! -f "$TAXI/zircon/rtl/zircon_ip_rx_parse.sv" ]]; then
    echo "ERROR: submodules/taxi is not checked out (git submodule update --init)" >&2
    exit 1
fi

TAXI_SV=(
    "$TAXI/axis/rtl/taxi_axis_if.sv"
    "$TAXI/axis/rtl/taxi_axis_tie.sv"
    "$TAXI/axis/rtl/taxi_axis_fifo.sv"
    "$TAXI/axis/rtl/taxi_axis_async_fifo.sv"
    "$TAXI/axis/rtl/taxi_axis_adapter.sv"
    "$TAXI/axis/rtl/taxi_axis_broadcast.sv"
    "$TAXI/axis/rtl/taxi_axis_concat.sv"
    "$TAXI/axis/rtl/taxi_axis_arb_mux.sv"
    "$TAXI/prim/rtl/taxi_arbiter.sv"
    "$TAXI/prim/rtl/taxi_penc.sv"
    "$TAXI/sync/rtl/taxi_sync_reset.sv"
    "$TAXI/sync/rtl/taxi_sync_signal.sv"
    "$TAXI/zircon/rtl/zircon_ip_len_cksum.sv"
    "$TAXI/zircon/rtl/zircon_ip_rx_parse.sv"
    "$TAXI/zircon/rtl/zircon_ip_rx_egress.sv"
    "$TAXI/zircon/rtl/zircon_ip_tx_ingress.sv"
    "$TAXI/zircon/rtl/zircon_ip_tx_buffer.sv"
    "$TAXI/zircon/rtl/zircon_ip_tx_deparse.sv"
)

GLUE_SV=(
    "$HDL_DIR/zircon_nic_pkg.sv"
    "$HDL_DIR/hdr_trunc.sv"
    "$HDL_DIR/rx_meta_capture.sv"
    "$HDL_DIR/rx_dispatch.sv"
    "$HDL_DIR/tx_meta_builder.sv"
    "$HDL_DIR/tx_len_guard.sv"
    "$HDL_DIR/raw_tx_desc_strip.sv"
    "$HDL_DIR/tx_mac_out.sv"
    "$HDL_DIR/ptp_tx_tagger.sv"
    "$HDL_DIR/latency_stats.sv"
    "$HDL_DIR/zircon_cdc_snapshot.sv"
    "$HDL_DIR/zircon_regs.sv"
    "$HDL_DIR/udp_gen.sv"
    "$HDL_DIR/udp_chk.sv"
    "$HDL_DIR/rate_meter.sv"
    "$HDL_DIR/zircon_nic_core.sv"
)

mkdir -p "$BUILD"
cd "$BUILD"

echo "== generating vectors"
python3 "$TB_DIR/gen_vectors.py" "$BUILD"
python3 "$TB_DIR/gen_vectors.py" "$BUILD" --gen0

echo "== xvlog"
# --relax: zircon_ip_rx_parse.sv uses pkt_data_reg before its declaration
# (VRFC 10-3380); xsim rejects that in strict mode, Vivado synthesis accepts it.
xvlog --relax -sv "${TAXI_SV[@]}" "${GLUE_SV[@]}" "$TB_DIR/tb_zircon_nic.sv" > xvlog.log 2>&1 \
    || { grep -E "ERROR|WARNING" xvlog.log; echo "FAIL: xvlog"; exit 1; }
xvlog "$HDL_DIR/zircon_nic.v" >> xvlog.log 2>&1 || { grep -E "ERROR" xvlog.log; echo "FAIL: xvlog"; exit 1; }
grep -E "^WARNING" xvlog.log || true

echo "== xelab"
xelab --relax --timescale 1ns/1ps -debug typical tb_zircon_nic -s tb_zircon_nic > xelab.log 2>&1 \
    || { grep -E "ERROR" xelab.log; echo "FAIL: xelab"; exit 1; }
grep -E "^WARNING" xelab.log | grep -v "XSIM 43-3431\|XSIM 43-4099" || true
# the same testbench against a GEN_EN = 0 build (no generator / checker)
xelab --relax --timescale 1ns/1ps -debug typical tb_zircon_nic -generic_top "GEN_EN=0" -s tb_zircon_nic_gen0 \
    > xelab_gen0.log 2>&1 || { grep -E "ERROR" xelab_gen0.log; echo "FAIL: xelab (GEN_EN=0)"; exit 1; }

echo "== xsim"
if [[ "${1:-}" == "--gui" ]]; then
    exec xsim tb_zircon_nic -gui -testplusarg "vectors=$BUILD/vectors.txt"
fi
xsim tb_zircon_nic -R -testplusarg "vectors=$BUILD/vectors.txt" -log xsim.log > /dev/null 2>&1 || true
echo "== xsim (GEN_EN = 0 build)"
xsim tb_zircon_nic_gen0 -R -testplusarg "vectors=$BUILD/vectors_gen0.txt" -log xsim_gen0.log > /dev/null 2>&1 || true

# ---- unit testbench: MRMAC RX client packer (mrmac_rx_packer.v) ----
echo "== xsim (mrmac_rx_packer unit test)"
: > xsim_rxpath.log
xvlog -work rxpath "$HDL_DIR/mrmac_rx_packer.v" > xvlog_rxpath.log 2>&1 \
    || { grep -E "ERROR" xvlog_rxpath.log; echo "FAIL: xvlog (rx packer)"; exit 1; }
xvlog -work rxpath -sv "$TB_DIR/tb_mrmac_rx_packer.sv" >> xvlog_rxpath.log 2>&1 \
    || { grep -E "ERROR" xvlog_rxpath.log; echo "FAIL: xvlog (rx packer)"; exit 1; }
grep -E "^WARNING" xvlog_rxpath.log || true
xelab -L rxpath --timescale 1ns/1ps -debug typical rxpath.tb_mrmac_rx_packer -s tb_mrmac_rx_packer \
    > xelab_rxpath.log 2>&1 || { grep -E "ERROR" xelab_rxpath.log; echo "FAIL: xelab (rx packer)"; exit 1; }
xsim tb_mrmac_rx_packer -R -log xsim_rxpath.log > /dev/null 2>&1 || true

# ---- unit testbench: PTP helpers (mrmac_tx_axis_adapter PTP sideband, ptp_systimer) ----
echo "== xsim (PTP units: TX adapter sideband, systimer)"
: > xsim_ptp.log
xvlog -work ptpu "$HDL_DIR/mrmac_axis_adapter.v" "$HDL_DIR/ptp_systimer.v" > xvlog_ptp.log 2>&1 \
    || { grep -E "ERROR" xvlog_ptp.log; echo "FAIL: xvlog (ptp units)"; exit 1; }
xvlog -work ptpu -sv "$TB_DIR/tb_ptp_units.sv" >> xvlog_ptp.log 2>&1 \
    || { grep -E "ERROR" xvlog_ptp.log; echo "FAIL: xvlog (ptp units)"; exit 1; }
xelab -L ptpu --timescale 1ns/1ps -debug typical ptpu.tb_ptp_units -s tb_ptp_units \
    > xelab_ptp.log 2>&1 || { grep -E "ERROR" xelab_ptp.log; echo "FAIL: xelab (ptp units)"; exit 1; }
xsim tb_ptp_units -R -log xsim_ptp.log > /dev/null 2>&1 || true

# ---- shim testbench: KCU116 CMAC shim (zircon_cmac_us) + zircon_nic ----
# Taxi's taxi_eth_mac_100g_us with SIM = 1 (no GT / CMAC IP; the TB drives the GT user
# clocks and the wrapper's CMAC client interfaces hierarchically). Sources come from the
# Taxi .f lists (expanded here, lib/taxi symlinks resolved), compiled into library cmacu.
echo "== xsim (zircon_cmac_us shim + zircon_nic)"
: > xsim_cmac.log
declare -A CMAC_SEEN=()
CMAC_FILES=()
cmac_add() {
    local p; p="$(realpath "$1")"
    [[ -n "${CMAC_SEEN[$p]:-}" ]] && return 0
    CMAC_SEEN[$p]=1
    CMAC_FILES+=("$p")
}
cmac_expand_f() {
    local f; f="$(realpath "$1")"
    [[ -n "${CMAC_SEEN[$f]:-}" ]] && return 0
    CMAC_SEEN[$f]=1
    local d line; d="$(dirname "$f")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == *.f ]]; then cmac_expand_f "$d/$line"; else cmac_add "$d/$line"; fi
    done < "$f"
}
# interfaces first; taxi_eth_phy_10g_usxgmii_an.sv (unused by the 100G wrapper) does not
# compile in xsim (VRFC 10-3400), so it is left out
cmac_add "$TAXI/axis/rtl/taxi_axis_if.sv"
cmac_add "$TAXI/axi/rtl/taxi_axil_if.sv"
cmac_add "$TAXI/apb/rtl/taxi_apb_if.sv"
CMAC_SEEN[$(realpath "$TAXI/eth/rtl/taxi_eth_phy_10g_usxgmii_an.sv")]=1
for f in "${TAXI_SV[@]}"; do cmac_add "$f"; done
cmac_expand_f "$TAXI/eth/rtl/us/taxi_eth_mac_100g_us.f"
cmac_add "$TAXI/axi/rtl/taxi_axil_apb_adapter.sv"
for f in "${GLUE_SV[@]}"; do cmac_add "$f"; done
cmac_add "$HDL_DIR/ts_gray_sync.sv"
cmac_add "$HDL_DIR/zircon_cmac_us_core.sv"
xvlog --relax -work cmacu -sv "${CMAC_FILES[@]}" "$TB_DIR/tb_zircon_cmac_us.sv" > xvlog_cmac.log 2>&1 \
    || { grep -E "ERROR" xvlog_cmac.log; echo "FAIL: xvlog (cmac shim)"; exit 1; }
xvlog -work cmacu "$HDL_DIR/zircon_nic.v" "$HDL_DIR/zircon_cmac_us.v" >> xvlog_cmac.log 2>&1 \
    || { grep -E "ERROR" xvlog_cmac.log; echo "FAIL: xvlog (cmac shim)"; exit 1; }
xelab -L cmacu --relax --timescale 1ns/1ps -debug typical cmacu.tb_zircon_cmac_us -s tb_zircon_cmac_us \
    > xelab_cmac.log 2>&1 || { grep -E "ERROR" xelab_cmac.log; echo "FAIL: xelab (cmac shim)"; exit 1; }
xsim tb_zircon_cmac_us -R -log xsim_cmac.log > /dev/null 2>&1 || true

sed -i 's/^PASS: test /PASS: test gen0 /; s/^FAIL: test /FAIL: test gen0 /' xsim_gen0.log
grep -hE "^(PASS|FAIL):|ERROR|subsequence check|count check|prefix check|lossy phase|RATE |  rate_|  rx_100G|  0x" \
    xsim.log xsim_gen0.log xsim_rxpath.log xsim_ptp.log xsim_cmac.log || true
grep -hE "^  (LAT bank|PTP records|coherence|after_mac|  mode 1|[0-9]+ frames, )" xsim.log xsim_ptp.log || true
grep -hE "^  (TX_CLK_KHZ|RX_CLK_KHZ|RX event lag|TX event lag|loop delta|gen->chk|echo latency|ts_gray_sync)" xsim_cmac.log || true
n_pass=$(cat xsim.log xsim_gen0.log xsim_rxpath.log xsim_ptp.log xsim_cmac.log | grep -c "^PASS:" || true)
n_fail=$(cat xsim.log xsim_gen0.log xsim_rxpath.log xsim_ptp.log xsim_cmac.log | grep -c "^FAIL:" || true)
echo "SUMMARY: $n_pass passed, $n_fail failed"
if grep -q "^ALL TESTS PASSED" xsim.log && grep -q "^ALL TESTS PASSED" xsim_gen0.log && \
   grep -q "^ALL TESTS PASSED" xsim_rxpath.log && grep -q "^ALL TESTS PASSED" xsim_ptp.log && \
   grep -q "^ALL TESTS PASSED" xsim_cmac.log && [[ "$n_fail" == 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "TESTS FAILED"
echo "xsim logs: $BUILD/xsim.log $BUILD/xsim_gen0.log $BUILD/xsim_rxpath.log $BUILD/xsim_ptp.log $BUILD/xsim_cmac.log"
exit 1

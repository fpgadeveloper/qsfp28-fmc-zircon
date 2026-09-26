/* SPDX-License-Identifier: MIT
 *
 * cmac_taxi.c - UltraScale+ CMAC (Taxi taxi_eth_mac_100g_us) behind the
 *               zircon_cmac_us shim: the HW_MAC_CMAC backend of mac.h
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * The shim (Vivado/src/hdl/zircon_cmac_us.v) wraps Taxi's 100G CMAC wrapper:
 * 4 x 25.78 Gb/s GTY (CAUI-4) + CMACE4 with RS(528,514) hard-wired on. Its
 * AXI-Lite register block (docs/DESIGN_SPEC.md section 6c, 125 MHz ctrl_clk):
 *
 *   0x000 ID        "CMAC" 0x434D4143
 *   0x004 VERSION   0x00010000
 *   0x008 CTRL      b0 XCVR_RST (resets to 1: GT + CMAC held until software
 *                   releases it once the Si5328 runs), b1 RX_RST, b2 TX_RST
 *                   (levels, Taxi rx_rst_in / tx_rst_in), b4 TX_EN, b5 RX_EN
 *   0x00C STATUS    b0 RX_STATUS (aligned) b1 RX_BLOCK_LOCK b2 RX_HIGH_BER
 *                   b3 TX_RST_OUT b4 RX_RST_OUT b5 GTPOWERGOOD
 *                   b6 TX_CLK_ALIVE b7 RX_CLK_ALIVE
 *   0x010 STICKY    W1C: b0 LINK_LOST b1 PTP_UNDERRUN b2 TS_RECORD_OVF
 *   0x020/0x024     TS_NOW_LO/HI (reading LO latches HI)
 *   0x028 TS_INCR   1024 (2^-8 ns per 250 MHz ts_clk cycle = 4 ns)
 *   0x030..0x044    32-bit wrapping counters: RX_GOOD_PKTS, RX_BAD_FCS,
 *                   RX_ERR_FRAMES, TX_GOOD_PKTS, TX_FRAMES, TX_TS_RET
 *   0x048/0x04C     TX_CLK_KHZ / RX_CLK_KHZ (measured against ctrl_clk)
 *   0x4_0000..      Taxi GT APB (16-bit registers, not used here; they
 *                   answer SLVERR while CTRL.XCVR_RST is set and for 32
 *                   ctrl_clk cycles after it clears)
 * TX_CLK_KHZ / RX_CLK_KHZ refresh every 1 ms; the counters are never reset
 * by hardware (mac_tick() keeps deltas).
 *
 * Bring-up (after the Si5328 provides the 322.265625 MHz GT refclk):
 * CTRL = XCVR_RST | TX_EN | RX_EN, 10 ms, clear XCVR_RST, wait for
 * STATUS.TX_RST_OUT = 0. The link is STATUS.RX_STATUS. While it is down
 * port.c calls mac_port_init() every LINK_RETRY_MS, which pulses CTRL.RX_RST
 * (the Taxi wrapper additionally resets the CMAC RX by itself after ~0.83 s
 * without rx_status).
 *
 * Only built for HW_MAC_CMAC targets (hw_config.h); empty otherwise.
 */
#include "hw_config.h"

#if defined(HW_MAC_CMAC)

#include "xil_io.h"
#include "sleep.h"
#include "console.h"
#include "mac.h"

#define CMAC_ID_VALUE           0x434D4143u    /* "CMAC" */

#define CMAC_REG_ID             0x000
#define CMAC_REG_VERSION        0x004
#define CMAC_REG_CTRL           0x008
#define CMAC_REG_STATUS         0x00C
#define CMAC_REG_STICKY         0x010
#define CMAC_REG_TS_NOW_LO      0x020
#define CMAC_REG_TS_NOW_HI      0x024
#define CMAC_REG_TS_INCR        0x028
#define CMAC_REG_RX_GOOD_PKTS   0x030
#define CMAC_REG_RX_BAD_FCS     0x034
#define CMAC_REG_RX_ERR_FRAMES  0x038
#define CMAC_REG_TX_GOOD_PKTS   0x03C
#define CMAC_REG_TX_FRAMES      0x040
#define CMAC_REG_TX_TS_RET      0x044
#define CMAC_REG_TX_CLK_KHZ     0x048
#define CMAC_REG_RX_CLK_KHZ     0x04C

/* CTRL */
#define CMAC_CTRL_XCVR_RST      (1u << 0)
#define CMAC_CTRL_RX_RST        (1u << 1)
#define CMAC_CTRL_TX_RST        (1u << 2)
#define CMAC_CTRL_TX_EN         (1u << 4)
#define CMAC_CTRL_RX_EN         (1u << 5)

/* STATUS */
#define CMAC_ST_RX_STATUS       (1u << 0)
#define CMAC_ST_RX_BLOCK_LOCK   (1u << 1)
#define CMAC_ST_RX_HIGH_BER     (1u << 2)
#define CMAC_ST_TX_RST_OUT      (1u << 3)
#define CMAC_ST_RX_RST_OUT      (1u << 4)
#define CMAC_ST_GTPOWERGOOD     (1u << 5)
#define CMAC_ST_TX_CLK_ALIVE    (1u << 6)
#define CMAC_ST_RX_CLK_ALIVE    (1u << 7)

/* STICKY (write 1 to clear) */
#define CMAC_STICKY_LINK_LOST   (1u << 0)
#define CMAC_STICKY_PTP_UNDERRUN (1u << 1)
#define CMAC_STICKY_TS_REC_OVF  (1u << 2)

#define CMAC_TS_MASK            ((1ULL << 55) - 1)

/* XCVR_RST hold time and how long the TX side may take to leave reset */
#ifndef CMAC_XCVR_RST_HOLD_MS
#define CMAC_XCVR_RST_HOLD_MS   10
#endif
#ifndef CMAC_TX_RST_TIMEOUT_MS
#define CMAC_TX_RST_TIMEOUT_MS  100
#endif
/* Width of the CTRL.RX_RST pulse of a link retry */
#define CMAC_RX_RST_PULSE_US    1000

static inline u32 rd(UINTPTR base, u32 off)         { return Xil_In32(base + off); }
static inline void wr(UINTPTR base, u32 off, u32 v) { Xil_Out32(base + off, v); }

/* Last raw value of every 32-bit counter, per shim (so a cleared
 * mac_stats_t keeps counting from "now") */
typedef struct {
	UINTPTR base;
	u32 rx_good, rx_bad_fcs, rx_err, tx_good, tx_frames, tx_ts_ret;
} cmac_baseline_t;

static cmac_baseline_t baselines[HW_NUM_PORTS];

static cmac_baseline_t *baseline_of(UINTPTR base)
{
	int i;

	for (i = 0; i < HW_NUM_PORTS; i++) {
		if (baselines[i].base == base)
			return &baselines[i];
	}
	for (i = 0; i < HW_NUM_PORTS; i++) {
		if (baselines[i].base == 0) {
			baselines[i].base = base;
			return &baselines[i];
		}
	}
	return &baselines[0];
}

static void baseline_take(UINTPTR base)
{
	cmac_baseline_t *b = baseline_of(base);

	b->rx_good = rd(base, CMAC_REG_RX_GOOD_PKTS);
	b->rx_bad_fcs = rd(base, CMAC_REG_RX_BAD_FCS);
	b->rx_err = rd(base, CMAC_REG_RX_ERR_FRAMES);
	b->tx_good = rd(base, CMAC_REG_TX_GOOD_PKTS);
	b->tx_frames = rd(base, CMAC_REG_TX_FRAMES);
	b->tx_ts_ret = rd(base, CMAC_REG_TX_TS_RET);
}

int mac_hw_reset(const hw_port_t *hw)
{
	UINTPTR base = hw->mac;
	u32 id = rd(base, CMAC_REG_ID), st = 0;
	int ms;

	if (id != CMAC_ID_VALUE) {
		con_printf("cmac: no zircon_cmac_us shim at 0x%08lx (ID 0x%08lx, expected 0x%08lx)\r\n",
			   (unsigned long)base, (unsigned long)id, (unsigned long)CMAC_ID_VALUE);
		return -1;
	}

	/* Hold the GT + CMAC in reset with the refclk now running, then let
	 * the Taxi reset sequencer bring the transceivers up */
	wr(base, CMAC_REG_CTRL, CMAC_CTRL_XCVR_RST | CMAC_CTRL_TX_EN | CMAC_CTRL_RX_EN);
	usleep(CMAC_XCVR_RST_HOLD_MS * 1000);
	wr(base, CMAC_REG_CTRL, CMAC_CTRL_TX_EN | CMAC_CTRL_RX_EN);

	for (ms = 0; ms < CMAC_TX_RST_TIMEOUT_MS; ms++) {
		st = rd(base, CMAC_REG_STATUS);
		if (!(st & CMAC_ST_TX_RST_OUT))
			break;
		usleep(1000);
	}
	if (st & CMAC_ST_TX_RST_OUT) {
		con_printf("cmac: TX still in reset after %d ms (STATUS 0x%02lx, GTPOWERGOOD %d, "
			   "tx_clk %lu kHz, rx_clk %lu kHz; expected 322265)\r\n",
			   CMAC_TX_RST_TIMEOUT_MS, (unsigned long)st,
			   !!(st & CMAC_ST_GTPOWERGOOD),
			   (unsigned long)rd(base, CMAC_REG_TX_CLK_KHZ),
			   (unsigned long)rd(base, CMAC_REG_RX_CLK_KHZ));
		return -1;
	}
	/* bring-up leaves LINK_LOST etc. set: start clean */
	wr(base, CMAC_REG_STICKY, 0xFFFFFFFFu);
	return 0;
}

void mac_port_init(const hw_port_t *hw, mac_fec_t fec)
{
	UINTPTR base = hw->mac;
	u32 ctrl = (rd(base, CMAC_REG_CTRL) | CMAC_CTRL_TX_EN | CMAC_CTRL_RX_EN) &
		   ~(CMAC_CTRL_RX_RST | CMAC_CTRL_TX_RST);

	(void)fec;   /* RS(528,514) is fixed in the Taxi wrapper */
	wr(base, CMAC_REG_CTRL, ctrl | CMAC_CTRL_RX_RST);
	usleep(CMAC_RX_RST_PULSE_US);
	wr(base, CMAC_REG_CTRL, ctrl);
	baseline_take(base);
}

int mac_link_up(const hw_port_t *hw)
{
	return !!(rd(hw->mac, CMAC_REG_STATUS) & CMAC_ST_RX_STATUS);
}

void mac_get_state(const hw_port_t *hw, mac_state_t *st)
{
	UINTPTR base = hw->mac;

	st->ctrl = rd(base, CMAC_REG_CTRL);
	st->status = rd(base, CMAC_REG_STATUS);
	st->sticky = rd(base, CMAC_REG_STICKY);
	st->tx_khz = rd(base, CMAC_REG_TX_CLK_KHZ);
	st->rx_khz = rd(base, CMAC_REG_RX_CLK_KHZ);
	st->link_up = !!(st->status & CMAC_ST_RX_STATUS);
	st->block_lock = !!(st->status & CMAC_ST_RX_BLOCK_LOCK);
	st->hi_ber = !!(st->status & CMAC_ST_RX_HIGH_BER);
	st->tx_rst = !!(st->status & CMAC_ST_TX_RST_OUT);
	st->rx_rst = !!(st->status & CMAC_ST_RX_RST_OUT);
	st->gtpowergood = !!(st->status & CMAC_ST_GTPOWERGOOD);
	st->tx_clk_alive = !!(st->status & CMAC_ST_TX_CLK_ALIVE);
	st->rx_clk_alive = !!(st->status & CMAC_ST_RX_CLK_ALIVE);
}

mac_fec_t mac_get_fec(const hw_port_t *hw)
{
	(void)hw;
	return MAC_FEC_RS528;
}

const char *mac_fec_name(mac_fec_t fec)
{
	switch (fec) {
	case MAC_FEC_OFF:
		return "off";
	case MAC_FEC_RS528:
		return "RS(528,514)";
	case MAC_FEC_RS544:
		return "RS(544,514)";
	case MAC_FEC_KEEP:
	default:
		return "as configured";
	}
}

/* The counters wrap at 2^32: the unsigned difference to the previous read
 * is the interval's count as long as mac_tick() runs more often than every
 * ~40 s at 100G line rate with 64-byte frames (it runs with every status
 * line, at most 30 s apart) */
void mac_tick(const hw_port_t *hw, mac_stats_t *t)
{
	UINTPTR base = hw->mac;
	cmac_baseline_t *b = baseline_of(base);
	u32 rx_good = rd(base, CMAC_REG_RX_GOOD_PKTS);
	u32 rx_bad_fcs = rd(base, CMAC_REG_RX_BAD_FCS);
	u32 rx_err = rd(base, CMAC_REG_RX_ERR_FRAMES);
	u32 tx_good = rd(base, CMAC_REG_TX_GOOD_PKTS);
	u32 tx_frames = rd(base, CMAC_REG_TX_FRAMES);
	u32 tx_ts_ret = rd(base, CMAC_REG_TX_TS_RET);
	u32 d_good = rx_good - b->rx_good, d_err = rx_err - b->rx_err;

	t->rx_good_packets += d_good;
	t->rx_err_frames += d_err;
	t->rx_packets += (u64)d_good + d_err;     /* the CMAC delivers every frame */
	t->rx_bad_fcs += (u32)(rx_bad_fcs - b->rx_bad_fcs);
	t->tx_good_packets += (u32)(tx_good - b->tx_good);
	t->tx_packets += (u32)(tx_frames - b->tx_frames);
	t->tx_ts_returned += (u32)(tx_ts_ret - b->tx_ts_ret);

	b->rx_good = rx_good;
	b->rx_bad_fcs = rx_bad_fcs;
	b->rx_err = rx_err;
	b->tx_good = tx_good;
	b->tx_frames = tx_frames;
	b->tx_ts_ret = tx_ts_ret;
}

int mac_ptp_underrun(const hw_port_t *hw)
{
	return !!(rd(hw->mac, CMAC_REG_STICKY) & CMAC_STICKY_PTP_UNDERRUN);
}

u64 mac_ts_now(const hw_port_t *hw)
{
	u32 lo = rd(hw->mac, CMAC_REG_TS_NOW_LO);   /* latches HI */
	u32 hi = rd(hw->mac, CMAC_REG_TS_NOW_HI);

	return (((u64)hi << 32) | lo) & CMAC_TS_MASK;
}

u32 mac_ts_incr(const hw_port_t *hw)
{
	return rd(hw->mac, CMAC_REG_TS_INCR);
}

void mac_print_config(int n, const hw_port_t *hw)
{
	UINTPTR base = hw->mac;
	u32 ver = rd(base, CMAC_REG_VERSION);

	con_printf("Port %d: CMAC at 0x%08lx configured: 100GE CAUI-4 (Taxi taxi_eth_mac_100g_us, shim "
		   "%lu.%lu), FEC RS(528,514) (fixed), CTRL 0x%02lx STATUS 0x%02lx, tx_clk %lu kHz "
		   "rx_clk %lu kHz\r\n", n, (unsigned long)base,
		   (unsigned long)(ver >> 16), (unsigned long)(ver & 0xFFFF),
		   (unsigned long)rd(base, CMAC_REG_CTRL), (unsigned long)rd(base, CMAC_REG_STATUS),
		   (unsigned long)rd(base, CMAC_REG_TX_CLK_KHZ),
		   (unsigned long)rd(base, CMAC_REG_RX_CLK_KHZ));
}

/* The bench keys on this exact line */
void mac_print_link_up(int n, const hw_port_t *hw)
{
	(void)hw;
	con_printf("Port %d: link up, 100 Gb/s, FEC RS(528,514)\r\n", n);
}

void mac_print_link_diag(int n, const hw_port_t *hw)
{
	mac_state_t st;

	mac_get_state(hw, &st);
	con_printf("Port %d: link down: FEC RS(528,514), CMAC STATUS 0x%02lx (block lock %d%s%s%s%s%s), "
		   "sticky 0x%lx, tx_clk %lu kHz rx_clk %lu kHz\r\n",
		   n, (unsigned long)st.status, st.block_lock,
		   st.hi_ber ? ", hi BER" : "",
		   st.tx_rst ? ", TX in reset" : "",
		   st.rx_rst ? ", RX in reset" : "",
		   st.gtpowergood ? "" : ", no GTPOWERGOOD",
		   st.rx_clk_alive ? "" : ", no rx_clk",
		   (unsigned long)st.sticky, (unsigned long)st.tx_khz, (unsigned long)st.rx_khz);
}

#endif /* HW_MAC_CMAC */

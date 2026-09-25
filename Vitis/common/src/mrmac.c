/* SPDX-License-Identifier: MIT
 *
 * mrmac.c - Bare-metal Versal MRMAC (1x100GE CAUI-4, RS-FEC) bring-up
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Port of the 2x QSFP28 FMC echo_server's mrmac.c, plus RS-FEC.
 *
 * There is no embeddedsw driver for the Versal MRMAC hard block, so this
 * module drives its registers directly. The offsets and bit fields are those
 * of the MRMAC IP's register map (PG314; also the IP-XACT memory map shipped
 * with the mrmac_v3_2 IP), the reset/MODE sequence replicates the Linux
 * xilinx_axienet driver's MRMAC support at max-speed = 100000. The MRMAC runs
 * as 1x100GE, so only the port-0 register page (offset 0) is used and
 * port_base is the MRMAC's s_axi base address.
 *
 * Bring-up:
 *   1. one-time GT reset through the GT-control AXI GPIO (channel 1: bit0 =
 *      gt_reset_all, bit1/bit2 = TX/RX datapath resets; channel 2: bit0/bit1
 *      = TX/RX reset-done), then a TX and an RX datapath reset pulse.
 *   2. assert the MAC's TX/RX serdes + core resets (RESET_REG_0, 0x004)
 *   3. MODE_REG_0 (0x008): DATA_RATE = 100G, AXIS client = independent
 *      384-bit, serdes width = 100G "Wide", TICK_REG_MODE_SEL (stats latched
 *      by TICK_REG writes)
 *   4. FEC_CONFIGURATION_REG1_0 (0x0D0): FEC mode (see below)
 *   5. CONFIGURATION_RX_MTU (0x014): CTL_RX_MAX_PACKET_LEN raised to at least
 *      MRMAC_RX_MAX_PACKET_LEN (9600, the IP default) so 9000-byte UDP
 *      payloads (9046-byte frames) are accepted whatever the BD configured
 *   6. release the resets
 *   7. CONFIGURATION_TX_REG1 (0x00C) = 0xC03: enable + FCS insertion, IPG 12
 *      (the register's reset value and AMD's example design; writing just
 *      0x3 would zero CTL_TX_IPG_VALUE),
 *      CONFIGURATION_RX_REG1 (0x010) = 0x33: enable + FCS deletion + SFD and
 *      preamble checks (reset value / AMD example; 0x3 would disable the
 *      checks)
 *   8. TICK_REG (0x02C) = 1 so the statistics start clean
 *   (4b. CONFIGURATION_1588_REG (0x040): CTL_TX_PTP_1STEP_ENABLE (b0) = 0,
 *   i.e. 2-step timestamping, which is also its reset value; SAT_ENABLE
 *   (b2:1) and RSFEC_COMP_EN (b3, 0: no RS-FEC compensation, a constant
 *   offset that does not matter for latency) are left at their reset values.
 *   Which frames are timestamped is chosen per frame on the PTP pins by the
 *   TX adapter / zircon_nic.)
 *
 * FEC_CONFIGURATION_REG1_0 (0x0D0) fields:
 *   [3:0]  ctl_fec_mode            [4] ctl_rx_fec_bypass_indication
 *   [5]    ctl_rx_fec_bypass_correction
 *   [6]    ctl_rx_fec_transcode_clause49  [7] ctl_rx_fec_alignment_bypass
 *   [8]    ctl_tx_fec_transcode_bypass    [9] ctl_rx_fec_transcode_bypass
 *   [10]   ctl_rx_fec_cdc_bypass_01       [11] ctl_rx_fec_errind_mode
 *   [12]   ctl_tx_fec_four_lane_pmd
 * The values below are the ones Vivado 2025.2's mrmac_v3_2 generates for a
 * 1x100GE CAUI-4 Wide MAC+PCS+FEC port (read back from the IP's generated
 * wrapper attributes, CTL_FEC_MODE_0 / CTL_TX_FEC_FOUR_LANE_PMD):
 *   FEC Disabled (Bypass)                  : mode 0x0, four_lane_pmd 0
 *   100G (IEEE 802.3) RS(528,514)  [CL91]   : mode 0x8, four_lane_pmd 1
 *   100G (IEEE P802.3cd CL91) RS(544,514)  : mode 0xA, four_lane_pmd 1
 * All bypass/transcode bits are 0 in every case.
 *
 * Link state: RX block lock + RX status good (latched, write-1-to-clear,
 * then read the live state), as the source design. With RS-FEC the MRMAC
 * additionally reports FEC alignment / lane lock in STAT_RX_FEC_*_STATUS.
 */
#include <stdio.h>
#include "console.h"
#include "xil_io.h"
#include "xgpio.h"
#include "sleep.h"
#include "mrmac.h"

/* Register offsets (port-0 page) */
#define MRMAC_REV_OFFSET            0x0000
#define MRMAC_RESET_OFFSET          0x0004
#define MRMAC_MODE_OFFSET           0x0008
#define MRMAC_CONFIG_TX_OFFSET      0x000C
#define MRMAC_CONFIG_RX_OFFSET      0x0010
#define MRMAC_RX_MTU_OFFSET         0x0014
#define MRMAC_TICK_OFFSET           0x002C
#define MRMAC_FEC_CFG1_OFFSET       0x00D0
#define MRMAC_1588_CFG_OFFSET       0x0040
#define MRMAC_TX_1588_SAMPLE_ST     0x0268    /* LSB, MSB at +4 (bits 22:0) */
#define MRMAC_TX_1588_INCR_ST       0x0270    /* LSB, MSB at +4 (bits 17:0) */
#define MRMAC_RX_1588_SAMPLE_ST     0x0278
#define MRMAC_RX_1588_INCR_ST       0x0280
#define MRMAC_STAT_TX_1588_TOD      0x07A8    /* LSB, MSB at +4 (55 bits)   */
#define MRMAC_STAT_RX_1588_TOD      0x07B0
#define MRMAC_TX_STS_OFFSET         0x0740
#define MRMAC_RX_STS_OFFSET         0x0744
#define MRMAC_RX_RT_STS_OFFSET      0x074C
#define MRMAC_STATRX_BLKLCK_OFFSET  0x0754
#define MRMAC_RX_FEC_STS_OFFSET     0x0784
#define MRMAC_RX_FEC_RT_STS_OFFSET  0x0788
#define MRMAC_STAT_READY_OFFSET     0x07D8

/* 48-bit statistics counters: LSB word, MSB word (+4, bits 15:0) */
#define MRMAC_STAT_TX_TOTAL_PKTS    0x0818
#define MRMAC_STAT_TX_GOOD_PKTS     0x0820
#define MRMAC_STAT_RX_TOTAL_PKTS    0x0E30
#define MRMAC_STAT_RX_GOOD_PKTS     0x0E38
#define MRMAC_STAT_RX_BAD_FCS       0x0EE8
#define MRMAC_STAT_RX_FEC_CORR_CW   0x0D90
#define MRMAC_STAT_RX_FEC_UNCORR_CW 0x0DB0

/* RESET_REG_0 */
#define MRMAC_RX_SERDES_RST_MASK    (0xF << 0)
#define MRMAC_TX_SERDES_RST_MASK    (1 << 4)
#define MRMAC_RX_RST_MASK           (1 << 5)
#define MRMAC_TX_RST_MASK           (1 << 6)
#define MRMAC_ALL_RST_MASK          (MRMAC_RX_SERDES_RST_MASK | MRMAC_TX_SERDES_RST_MASK | \
				     MRMAC_RX_RST_MASK | MRMAC_TX_RST_MASK)

/* MODE_REG_0, 100G values */
#define MRMAC_CTL_DATA_RATE_MASK    0x7
#define MRMAC_CTL_DATA_RATE_100G    4
#define MRMAC_CTL_AXIS_CFG_MASK     (0x7 << 9)
#define MRMAC_CTL_AXIS_CFG_SHIFT    9
#define MRMAC_CTL_AXIS_CFG_100G_IND_384   5
#define MRMAC_CTL_SERDES_WIDTH_MASK  (0x7 << 4)
#define MRMAC_CTL_SERDES_WIDTH_SHIFT 4
#define MRMAC_CTL_SERDES_WIDTH_100G_WIDE  6
#define MRMAC_CTL_RATE_CFG_MASK     (MRMAC_CTL_DATA_RATE_MASK | \
				     MRMAC_CTL_AXIS_CFG_MASK | \
				     MRMAC_CTL_SERDES_WIDTH_MASK)
#define MRMAC_CTL_PM_TICK_MASK      (1u << 30)

/* FEC_CONFIGURATION_REG1_0 */
#define MRMAC_FEC_MODE_MASK         0xF
#define MRMAC_FEC_FOUR_LANE_PMD     (1u << 12)
#define MRMAC_FEC_CFG1_MASK         0x1FFF        /* all defined bits */
#define MRMAC_FEC_CFG1_OFF          0x0000
#define MRMAC_FEC_CFG1_RS528        (0x8 | MRMAC_FEC_FOUR_LANE_PMD)
#define MRMAC_FEC_CFG1_RS544        (0xA | MRMAC_FEC_FOUR_LANE_PMD)

/* CONFIGURATION_TX_REG1 / CONFIGURATION_RX_REG1 */
#define MRMAC_TX_EN_MASK            (1 << 0)
#define MRMAC_TX_INS_FCS_MASK       (1 << 1)
#define MRMAC_TX_IPG_SHIFT          8
#define MRMAC_TX_IPG_MASK           (0xF << MRMAC_TX_IPG_SHIFT)
#define MRMAC_TX_IPG_DEFAULT        12
#define MRMAC_RX_EN_MASK            (1 << 0)
#define MRMAC_RX_DEL_FCS_MASK       (1 << 1)
#define MRMAC_RX_CHECK_SFD_MASK     (1 << 4)
#define MRMAC_RX_CHECK_PREAMBLE_MASK (1 << 5)
/* = 0xC03 / 0x33, the values AMD's mrmac_exdes_test.c writes */
#define MRMAC_CONFIG_TX_VALUE       (MRMAC_TX_EN_MASK | MRMAC_TX_INS_FCS_MASK | \
				     (MRMAC_TX_IPG_DEFAULT << MRMAC_TX_IPG_SHIFT))
#define MRMAC_CONFIG_RX_VALUE       (MRMAC_RX_EN_MASK | MRMAC_RX_DEL_FCS_MASK | \
				     MRMAC_RX_CHECK_SFD_MASK | MRMAC_RX_CHECK_PREAMBLE_MASK)

/* CONFIGURATION_RX_MTU: [7:0] CTL_RX_MIN_PACKET_LEN, [30:16] CTL_RX_MAX_PACKET_LEN */
#define MRMAC_RX_MAX_LEN_SHIFT      16
#define MRMAC_RX_MAX_LEN_MASK       (0x7FFFu << MRMAC_RX_MAX_LEN_SHIFT)

/* STAT_RX_STATUS_REG1 / STAT_RX_RT_STATUS_REG1 */
#define MRMAC_RX_STATUS_MASK        (1 << 0)
#define MRMAC_RX_BLOCK_LOCK_MASK    (1 << 1)
#define MRMAC_RX_ALIGNED_MASK       (1 << 2)
#define MRMAC_RX_HI_BER_MASK        (1 << 5)
#define MRMAC_RX_REMOTE_FAULT_MASK  (1 << 6)
#define MRMAC_RX_LOCAL_FAULT_MASK   (1 << 7)

/* STAT_RX_FEC_(RT_)STATUS_REG */
#define MRMAC_FEC_ALIGNED_MASK      (1 << 0)
#define MRMAC_FEC_HI_SER_MASK       (1 << 1)
#define MRMAC_FEC_LANE_LOCK_SHIFT   4
#define MRMAC_FEC_LANE_LOCK_MASK    (0xF << 4)

#define MRMAC_STS_ALL_MASK          0xFFFFFFFF
#define MRMAC_RX_BLKLCK_MASK        (1 << 0)
#define MRMAC_TICK_TRIGGER          (1 << 0)

/* CONFIGURATION_1588_REG */
#define MRMAC_1588_1STEP_ENABLE     (1u << 0)

/* GT-control GPIO: channel 1 outputs (5 bits), channel 2 inputs (2 bits) */
#define GT_CTRL_RESET_ALL           (1 << 0)
#define GT_CTRL_RESET_TX_DPATH      (1 << 1)
#define GT_CTRL_RESET_RX_DPATH      (1 << 2)
#define GT_DONE_TX                  (1 << 0)
#define GT_DONE_RX                  (1 << 1)
#define GT_CTRL_PTP_SYNC_REQ        (1 << 3)   /* port 0's GPIO only (1.3) */
#define GT_GPIO_DATA2_OFFSET        0x8        /* AXI GPIO CH2 data         */

static inline u32 rd(UINTPTR base, u32 off)         { return Xil_In32(base + off); }
static inline void wr(UINTPTR base, u32 off, u32 v) { Xil_Out32(base + off, v); }

static u64 rd48(UINTPTR base, u32 off)
{
	u32 lo = rd(base, off);
	u32 hi = rd(base, off + 4) & 0xFFFF;

	return ((u64)hi << 32) | lo;
}

/*
 * One-time GT bring-up through the port's GT-control GPIO: pulse
 * gt_reset_all, wait for TX+RX reset-done, then pulse the TX and RX
 * datapath resets (Linux axienet_mrmac_gt_reset order). As per PG314 the
 * all-lane GT reset must only be issued once after power-on; the MAC
 * core/serdes reset (mrmac_port_init) is what gets repeated to re-attempt
 * lock. Returns 0 on success, -1 if reset-done did not assert.
 */
int mrmac_gt_reset(UINTPTR gpio_base)
{
	XGpio gpio;
	XGpio_Config *cfg;
	u32 done = 0;
	int timeout = 100; /* x 10ms */

	cfg = XGpio_LookupConfig(gpio_base);
	if (cfg == NULL)
		return -1;
	XGpio_CfgInitialize(&gpio, cfg, cfg->BaseAddress);

	/* Pulse gt_reset_all */
	XGpio_DiscreteWrite(&gpio, 1, GT_CTRL_RESET_ALL);
	usleep(1000);
	XGpio_DiscreteWrite(&gpio, 1, 0);

	/* Wait for tx/rx reset done */
	do {
		done = XGpio_DiscreteRead(&gpio, 2);
		if ((done & (GT_DONE_TX | GT_DONE_RX)) == (GT_DONE_TX | GT_DONE_RX))
			break;
		usleep(10000);
	} while (--timeout);
	if (!timeout) {
		con_printf("mrmac: GT reset-done timeout (done=0x%02x)\r\n",
			   (unsigned)done);
		return -1;
	}

	/* TX then RX datapath reset pulses, 1ms apart (as the Linux driver) */
	XGpio_DiscreteWrite(&gpio, 1, GT_CTRL_RESET_TX_DPATH);
	usleep(1000);
	XGpio_DiscreteWrite(&gpio, 1, 0);
	usleep(1000);
	XGpio_DiscreteWrite(&gpio, 1, GT_CTRL_RESET_RX_DPATH);
	usleep(1000);
	XGpio_DiscreteWrite(&gpio, 1, 0);
	usleep(1000);

	return 0;
}

static u32 fec_cfg1_value(mrmac_fec_t fec)
{
	switch (fec) {
	case MRMAC_FEC_RS528:
		return MRMAC_FEC_CFG1_RS528;
	case MRMAC_FEC_RS544:
		return MRMAC_FEC_CFG1_RS544;
	case MRMAC_FEC_OFF:
	default:
		return MRMAC_FEC_CFG1_OFF;
	}
}

/*
 * Reset and configure the MRMAC for 100G (axienet_mrmac_reset equivalent)
 * with the requested FEC mode. MRMAC_FEC_KEEP leaves the FEC configuration
 * the block design gave the hard block untouched.
 */
void mrmac_port_init(UINTPTR port_base, mrmac_fec_t fec)
{
	u32 val, reg;

	/* Assert serdes + core resets */
	val = rd(port_base, MRMAC_RESET_OFFSET);
	val |= MRMAC_ALL_RST_MASK;
	wr(port_base, MRMAC_RESET_OFFSET, val);
	usleep(1000);

	/* Rate / AXIS configuration / serdes width: 100G, IND 384-bit, Wide */
	reg = rd(port_base, MRMAC_MODE_OFFSET);
	reg &= ~MRMAC_CTL_RATE_CFG_MASK;
	reg |= MRMAC_CTL_DATA_RATE_100G;
	reg |= (MRMAC_CTL_AXIS_CFG_100G_IND_384 << MRMAC_CTL_AXIS_CFG_SHIFT);
	reg |= (MRMAC_CTL_SERDES_WIDTH_100G_WIDE << MRMAC_CTL_SERDES_WIDTH_SHIFT);
	reg |= MRMAC_CTL_PM_TICK_MASK;
	wr(port_base, MRMAC_MODE_OFFSET, reg);

	/* FEC mode, programmed while the core is held in reset */
	if (fec != MRMAC_FEC_KEEP) {
		reg = rd(port_base, MRMAC_FEC_CFG1_OFFSET);
		reg &= ~MRMAC_FEC_CFG1_MASK;
		reg |= fec_cfg1_value(fec);
		wr(port_base, MRMAC_FEC_CFG1_OFFSET, reg);
	}

	/* 2-step timestamping (1-step off); a no-op when the MRMAC was built
	 * without timestamping */
	reg = rd(port_base, MRMAC_1588_CFG_OFFSET);
	if (reg & MRMAC_1588_1STEP_ENABLE)
		wr(port_base, MRMAC_1588_CFG_OFFSET, reg & ~MRMAC_1588_1STEP_ENABLE);

	/* Receive jumbo frames up to MRMAC_RX_MAX_PACKET_LEN (never lower it) */
	reg = rd(port_base, MRMAC_RX_MTU_OFFSET);
	if (((reg & MRMAC_RX_MAX_LEN_MASK) >> MRMAC_RX_MAX_LEN_SHIFT) < MRMAC_RX_MAX_PACKET_LEN) {
		reg &= ~MRMAC_RX_MAX_LEN_MASK;
		reg |= (u32)MRMAC_RX_MAX_PACKET_LEN << MRMAC_RX_MAX_LEN_SHIFT;
		wr(port_base, MRMAC_RX_MTU_OFFSET, reg);
	}

	/* Release resets */
	val = rd(port_base, MRMAC_RESET_OFFSET);
	val &= ~MRMAC_ALL_RST_MASK;
	wr(port_base, MRMAC_RESET_OFFSET, val);

	/* Enable TX (insert FCS, IPG 12) and RX (delete FCS, check SFD and
	 * preamble). Written whole, not OR-ed: 0x3 alone zeroes the TX IPG. */
	wr(port_base, MRMAC_CONFIG_TX_OFFSET, MRMAC_CONFIG_TX_VALUE);
	wr(port_base, MRMAC_CONFIG_RX_OFFSET, MRMAC_CONFIG_RX_VALUE);

	/* Latch the statistics counters once so the next tick starts clean */
	wr(port_base, MRMAC_TICK_OFFSET, MRMAC_TICK_TRIGGER);
}

static u64 rd_split(UINTPTR base, u32 off, u32 msb_mask)
{
	u32 lo = rd(base, off);
	u32 hi = rd(base, off + 4) & msb_mask;

	return ((u64)hi << 32) | lo;
}

void mrmac_1588_read(UINTPTR port_base, mrmac_1588_t *t)
{
	t->cfg = rd(port_base, MRMAC_1588_CFG_OFFSET);
	t->tx_tod = rd_split(port_base, MRMAC_STAT_TX_1588_TOD, 0x7FFFFF);
	t->rx_tod = rd_split(port_base, MRMAC_STAT_RX_1588_TOD, 0x7FFFFF);
	t->tx_sample = rd_split(port_base, MRMAC_TX_1588_SAMPLE_ST, 0x7FFFFF);
	t->rx_sample = rd_split(port_base, MRMAC_RX_1588_SAMPLE_ST, 0x7FFFFF);
	t->tx_incr = rd_split(port_base, MRMAC_TX_1588_INCR_ST, 0x3FFFF);
	t->rx_incr = rd_split(port_base, MRMAC_RX_1588_INCR_ST, 0x3FFFF);
}

void mrmac_tick_only(UINTPTR port_base)
{
	int i;

	wr(port_base, MRMAC_TICK_OFFSET, MRMAC_TICK_TRIGGER);
	for (i = 0; i < 1000; i++) {
		if ((rd(port_base, MRMAC_STAT_READY_OFFSET) & 0x3) == 0x3)
			break;
		usleep(10);
	}
}

void mrmac_ptp_sync_req(UINTPTR gpio_base)
{
	XGpio gpio;
	XGpio_Config *cfg = XGpio_LookupConfig(gpio_base);

	if (cfg == NULL)
		return;
	XGpio_CfgInitialize(&gpio, cfg, cfg->BaseAddress);
	/* the reset bits are 0 outside mrmac_gt_reset() */
	XGpio_DiscreteWrite(&gpio, 1, GT_CTRL_PTP_SYNC_REQ);
	usleep(10);
	XGpio_DiscreteWrite(&gpio, 1, 0);
}

u32 mrmac_gt_gpio_in(UINTPTR gpio_base)
{
	return gpio_base ? Xil_In32(gpio_base + GT_GPIO_DATA2_OFFSET) : 0;
}

u32 mrmac_fec_cfg_raw(UINTPTR port_base)
{
	return rd(port_base, MRMAC_FEC_CFG1_OFFSET);
}

u32 mrmac_rx_max_len(UINTPTR port_base)
{
	return (rd(port_base, MRMAC_RX_MTU_OFFSET) & MRMAC_RX_MAX_LEN_MASK) >> MRMAC_RX_MAX_LEN_SHIFT;
}

/*
 * Return 1 if the port has RX block lock AND RX status good (link up).
 * The status registers are latched: write-1-to-clear, then read the live
 * state. (Same test as the source design.)
 */
int mrmac_port_link_up(UINTPTR port_base)
{
	u32 blklck, rxsts;

	wr(port_base, MRMAC_STATRX_BLKLCK_OFFSET, MRMAC_STS_ALL_MASK);
	blklck = rd(port_base, MRMAC_STATRX_BLKLCK_OFFSET);
	if (!(blklck & MRMAC_RX_BLKLCK_MASK))
		return 0;

	wr(port_base, MRMAC_RX_STS_OFFSET, MRMAC_STS_ALL_MASK);
	rxsts = rd(port_base, MRMAC_RX_STS_OFFSET);
	return !!(rxsts & MRMAC_RX_STATUS_MASK);
}

mrmac_fec_t mrmac_get_fec(UINTPTR port_base)
{
	u32 mode = rd(port_base, MRMAC_FEC_CFG1_OFFSET) & MRMAC_FEC_MODE_MASK;

	switch (mode) {
	case 0x0:
		return MRMAC_FEC_OFF;
	case 0x8:
		return MRMAC_FEC_RS528;
	case 0xA:
		return MRMAC_FEC_RS544;
	default:
		return MRMAC_FEC_KEEP; /* some other (non-100G) code */
	}
}

const char *mrmac_fec_name(mrmac_fec_t fec)
{
	switch (fec) {
	case MRMAC_FEC_OFF:
		return "off";
	case MRMAC_FEC_RS528:
		return "RS(528,514)";
	case MRMAC_FEC_RS544:
		return "RS(544,514)";
	case MRMAC_FEC_KEEP:
	default:
		return "as configured";
	}
}

/* Real-time status snapshot (does not disturb the latched registers) */
void mrmac_get_state(UINTPTR port_base, mrmac_state_t *st)
{
	st->rx_status = rd(port_base, MRMAC_RX_RT_STS_OFFSET);
	st->blk_lock = rd(port_base, MRMAC_STATRX_BLKLCK_OFFSET);
	st->fec_cfg = rd(port_base, MRMAC_FEC_CFG1_OFFSET);
	st->fec_status = rd(port_base, MRMAC_RX_FEC_RT_STS_OFFSET);
	st->link_up = !!(st->rx_status & MRMAC_RX_STATUS_MASK);
	st->fec_aligned = !!(st->fec_status & MRMAC_FEC_ALIGNED_MASK);
	st->fec_lane_lock = (st->fec_status & MRMAC_FEC_LANE_LOCK_MASK) >> MRMAC_FEC_LANE_LOCK_SHIFT;
	st->hi_ber = !!(st->rx_status & MRMAC_RX_HI_BER_MASK);
	st->remote_fault = !!(st->rx_status & MRMAC_RX_REMOTE_FAULT_MASK);
	st->local_fault = !!(st->rx_status & MRMAC_RX_LOCAL_FAULT_MASK);
}

/* Latch the statistics, wait for STAT_STATISTICS_READY (both halves, as
 * AMD's example does; the registers read 0 when read straight after the
 * tick) and add the interval to the caller's totals. In TICK_REG mode
 * (MODE_REG.TICK_REG_MODE_SEL = 1) each TICK_REG write copies the counts
 * accumulated since the PREVIOUS tick into the readable registers (measured on
 * the VCK190: the registers hold the per-interval delta, not a running total),
 * so the totals are kept in software, one mrmac_stats_t per port. */
void mrmac_tick(UINTPTR port_base, mrmac_stats_t *t)
{
	int i;

	wr(port_base, MRMAC_TICK_OFFSET, MRMAC_TICK_TRIGGER);
	for (i = 0; i < 1000; i++) {
		if ((rd(port_base, MRMAC_STAT_READY_OFFSET) & 0x3) == 0x3)
			break;
		usleep(10);
	}
	t->rx_packets += rd48(port_base, MRMAC_STAT_RX_TOTAL_PKTS);
	t->rx_good_packets += rd48(port_base, MRMAC_STAT_RX_GOOD_PKTS);
	t->rx_bad_fcs += rd48(port_base, MRMAC_STAT_RX_BAD_FCS);
	t->tx_packets += rd48(port_base, MRMAC_STAT_TX_TOTAL_PKTS);
	t->tx_good_packets += rd48(port_base, MRMAC_STAT_TX_GOOD_PKTS);
	t->fec_corrected_cw += rd48(port_base, MRMAC_STAT_RX_FEC_CORR_CW);
	t->fec_uncorrected_cw += rd48(port_base, MRMAC_STAT_RX_FEC_UNCORR_CW);
}

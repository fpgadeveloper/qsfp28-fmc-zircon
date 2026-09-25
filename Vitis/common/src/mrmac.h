/* SPDX-License-Identifier: MIT
 *
 * mrmac.h - Bare-metal Versal MRMAC (1x100GE CAUI-4, RS-FEC) bring-up
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef MRMAC_H_
#define MRMAC_H_

#include "xil_types.h"

/* FEC operating modes (see mrmac.c for the register values) */
typedef enum {
	MRMAC_FEC_KEEP = -1,   /* leave FEC_CONFIGURATION_REG1 as configured */
	MRMAC_FEC_OFF = 0,     /* FEC bypassed                               */
	MRMAC_FEC_RS528 = 1,   /* clause 91 RS(528,514) "KR4"                */
	MRMAC_FEC_RS544 = 2,   /* RS(544,514) "KP4"                          */
} mrmac_fec_t;

/* Snapshot of the port's real-time state */
typedef struct {
	u32 rx_status;      /* STAT_RX_RT_STATUS_REG1 (0x74C)                 */
	u32 blk_lock;       /* STAT_RX_BLOCK_LOCK_REG, one bit per PCS lane   */
	u32 fec_cfg;        /* FEC_CONFIGURATION_REG1 (0xD0)                  */
	u32 fec_status;     /* STAT_RX_FEC_RT_STATUS_REG (0x788)              */
	int link_up;        /* rx status (aligned) - see mrmac_port_link_up() */
	int fec_aligned;    /* RS-FEC codeword alignment                      */
	int fec_lane_lock;  /* 4-bit FEC lane lock mask                       */
	int hi_ber;
	int remote_fault;
	int local_fault;
} mrmac_state_t;

/* Statistics totals, accumulated by mrmac_tick() (one per port; zero it to clear) */
typedef struct {
	u64 rx_packets, rx_good_packets, rx_bad_fcs;
	u64 tx_packets, tx_good_packets;
	u64 fec_corrected_cw, fec_uncorrected_cw;
} mrmac_stats_t;

int  mrmac_gt_reset(UINTPTR gpio_base);
void mrmac_port_init(UINTPTR port_base, mrmac_fec_t fec);
int  mrmac_port_link_up(UINTPTR port_base);
void mrmac_get_state(UINTPTR port_base, mrmac_state_t *st);
mrmac_fec_t mrmac_get_fec(UINTPTR port_base);
const char *mrmac_fec_name(mrmac_fec_t fec);
/* Latch the port's statistics and add the interval since the previous tick
 * (or mrmac_port_init) to *totals */
void mrmac_tick(UINTPTR port_base, mrmac_stats_t *totals);
u32  mrmac_fec_cfg_raw(UINTPTR port_base);   /* FEC_CONFIGURATION_REG1 read-back */
u32  mrmac_rx_max_len(UINTPTR port_base);    /* CTL_RX_MAX_PACKET_LEN read-back  */

/* IEEE 1588 timestamping (zircon_nic 1.3.0 latency measurement). The PTP
 * ports and the 250 MHz ts_clk systimer are wired in the block design
 * (docs/source/design.md "Latency measurement hardware"); 2-step is chosen per
 * frame on the PTP pins, and the power-up register values already give 2-step
 * timestamps. mrmac_port_init() makes sure CTL_TX_PTP_1STEP_ENABLE is 0 and
 * leaves every offset / latency-adjust register at its reset value 0. */
typedef struct {
	u32 cfg;                   /* CONFIGURATION_1588_REG (0x040)             */
	u64 tx_tod, rx_tod;        /* STAT_{TX,RX}_1588_TOD, 55 bits, 2^-8 ns     */
	u64 tx_sample, rx_sample;  /* MONITOR_*_1588_SAMPLE_SYSTIMER, 55 bits     */
	u64 tx_incr, rx_incr;      /* MONITOR_*_1588_INCR_SYSTIMER, raw 50 bits   */
} mrmac_1588_t;

void mrmac_1588_read(UINTPTR port_base, mrmac_1588_t *t);
/* Latch the statistics (TICK_REG) without accumulating them: also refreshes
 * the 1588 status registers. Only for bring-up checks. */
void mrmac_tick_only(UINTPTR port_base);
/* One extra st_sync of the shared ptp_systimer (port 0's GT-control GPIO,
 * CH1 bit 3, 0 -> 1 -> 0) */
void mrmac_ptp_sync_req(UINTPTR gpio_base);
/* GT-control GPIO CH2 inputs: b0 TX reset done, b1 RX reset done, b2 (1.3)
 * TX adapter ptp_underrun (sticky until TX reset) */
u32  mrmac_gt_gpio_in(UINTPTR gpio_base);
#define MRMAC_GT_IN_PTP_UNDERRUN    (1u << 2)

/* Largest frame (with FCS) the MRMAC receiver accepts: a 9000-byte UDP
 * payload makes a 9046-byte frame; 9600 is the IP's default */
#define MRMAC_RX_MAX_PACKET_LEN     9600

#endif /* MRMAC_H_ */

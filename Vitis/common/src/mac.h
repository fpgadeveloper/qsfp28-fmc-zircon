/* SPDX-License-Identifier: MIT
 *
 * mac.h - the 100G MAC of one QSFP28 port, independent of the MAC family
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * The rest of the application (port.c, main.c, latency.c, loopback.c) talks
 * to the MAC only through this header. Two backends, chosen at compile time
 * by hw_config.h:
 *
 *   Versal MRMAC (default)   mrmac.c: GT reset through the port's GT-control
 *                            GPIO, MRMAC 100G CAUI-4 with a selectable FEC,
 *                            IEEE 1588 timestamps in the hard MAC.
 *                            The mac_* calls below are thin inline wrappers
 *                            around the unchanged mrmac_* API.
 *   UltraScale+ CMAC         cmac_taxi.c (HW_MAC_CMAC, the MicroBlaze
 *                            targets, kcu116): Taxi's taxi_eth_mac_100g_us
 *                            behind the zircon_cmac_us shim (register map in
 *                            docs/DESIGN_SPEC.md section 6c). RS(528,514) is
 *                            fixed in the Taxi wrapper; timestamps are taken
 *                            by the shim at the MAC-client interface.
 *
 * Every call takes the port's hw_port_t (hw_config.h), so a backend can use
 * whichever of its resources it needs (the MRMAC also needs gpio_gt).
 */
#ifndef MAC_H
#define MAC_H

#include "xil_types.h"
#include "hw_config.h"

#if !defined(HW_MAC_CMAC)
/* ======================================================================== */
/* Versal MRMAC                                                               */
/* ======================================================================== */
#include "mrmac.h"

typedef mrmac_fec_t   mac_fec_t;
typedef mrmac_state_t mac_state_t;
typedef mrmac_stats_t mac_stats_t;

#define MAC_FEC_KEEP   MRMAC_FEC_KEEP
#define MAC_FEC_OFF    MRMAC_FEC_OFF
#define MAC_FEC_RS528  MRMAC_FEC_RS528
#define MAC_FEC_RS544  MRMAC_FEC_RS544

#define MAC_NAME                "MRMAC"
#define MAC_SUPPORTS_FEC_CHANGE 1

/* One-time GT bring-up (0 on success) */
static inline int mac_hw_reset(const hw_port_t *hw) { return mrmac_gt_reset(hw->gpio_gt); }
/* (Re)configure the MAC for 100G with the given FEC; also the link retry */
static inline void mac_port_init(const hw_port_t *hw, mac_fec_t fec) { mrmac_port_init(hw->mac, fec); }
static inline int mac_link_up(const hw_port_t *hw) { return mrmac_port_link_up(hw->mac); }
static inline void mac_get_state(const hw_port_t *hw, mac_state_t *st) { mrmac_get_state(hw->mac, st); }
static inline mac_fec_t mac_get_fec(const hw_port_t *hw) { return mrmac_get_fec(hw->mac); }
static inline const char *mac_fec_name(mac_fec_t fec) { return mrmac_fec_name(fec); }
/* Add the statistics since the previous tick to *totals */
static inline void mac_tick(const hw_port_t *hw, mac_stats_t *totals) { mrmac_tick(hw->mac, totals); }
/* TX timestamp path lost a PTP record (sticky) */
static inline int mac_ptp_underrun(const hw_port_t *hw)
{
	return (mrmac_gt_gpio_in(hw->gpio_gt) & MRMAC_GT_IN_PTP_UNDERRUN) != 0;
}
static inline int mac_supports_fec_change(void) { return 1; }

#else /* HW_MAC_CMAC */
/* ======================================================================== */
/* UltraScale+ CMAC through Taxi taxi_eth_mac_100g_us + zircon_cmac_us shim  */
/* ======================================================================== */

/* Same names and values as mrmac_fec_t, so APP_FEC_MODE / -DAPP_FEC_MODE
 * spelled with the MRMAC_ names keep compiling. Only RS(528,514) exists. */
typedef enum {
	MAC_FEC_KEEP = -1,
	MAC_FEC_OFF = 0,
	MAC_FEC_RS528 = 1,
	MAC_FEC_RS544 = 2,
} mac_fec_t;
#define MRMAC_FEC_KEEP   MAC_FEC_KEEP
#define MRMAC_FEC_OFF    MAC_FEC_OFF
#define MRMAC_FEC_RS528  MAC_FEC_RS528
#define MRMAC_FEC_RS544  MAC_FEC_RS544

#define MAC_NAME                "CMAC"
#define MAC_SUPPORTS_FEC_CHANGE 0

/* Shim STATUS / STICKY / CTRL snapshot */
typedef struct {
	u32 ctrl;           /* CTRL   (0x008)                                  */
	u32 status;         /* STATUS (0x00C)                                  */
	u32 sticky;         /* STICKY (0x010)                                  */
	u32 tx_khz, rx_khz; /* TX_CLK_KHZ / RX_CLK_KHZ (0x048 / 0x04C)         */
	int link_up;        /* STATUS.RX_STATUS (CMAC RX aligned)              */
	int block_lock;     /* STATUS.RX_BLOCK_LOCK                            */
	int hi_ber;         /* STATUS.RX_HIGH_BER                              */
	int tx_rst, rx_rst; /* STATUS.TX_RST_OUT / RX_RST_OUT (Taxi resets)    */
	int gtpowergood;    /* STATUS.GTPOWERGOOD                              */
	int tx_clk_alive, rx_clk_alive;
} mac_state_t;

/* Totals accumulated by mac_tick() from the shim's 32-bit counters. The
 * Taxi wrapper exposes no RS-FEC counters: the fec_* fields stay 0. */
typedef struct {
	u64 rx_packets, rx_good_packets, rx_bad_fcs;
	u64 tx_packets, tx_good_packets;
	u64 fec_corrected_cw, fec_uncorrected_cw;
	u64 rx_err_frames, tx_ts_returned;
} mac_stats_t;

/* Shim ID check, CTRL.XCVR_RST released (the Si5328 must already be
 * running: the Taxi GT reset sequencer needs the reference clock), then
 * wait for the TX side to come out of reset. 0 on success. */
int  mac_hw_reset(const hw_port_t *hw);
/* TX/RX enabled, CMAC RX datapath reset pulse (CTRL.RX_RST), statistics
 * baseline. The FEC argument is ignored (RS(528,514) is fixed). Also the
 * link retry while the link is down. */
void mac_port_init(const hw_port_t *hw, mac_fec_t fec);
int  mac_link_up(const hw_port_t *hw);
void mac_get_state(const hw_port_t *hw, mac_state_t *st);
mac_fec_t mac_get_fec(const hw_port_t *hw);
const char *mac_fec_name(mac_fec_t fec);
void mac_tick(const hw_port_t *hw, mac_stats_t *totals);
int  mac_ptp_underrun(const hw_port_t *hw);
static inline int mac_supports_fec_change(void) { return 0; }

/* Shim timestamp timer (TS_NOW, 55 bits, 2^-8 ns) */
u64  mac_ts_now(const hw_port_t *hw);
u32  mac_ts_incr(const hw_port_t *hw);
/* Console lines: the "configured" line after bring-up, "link up" and the
 * link-down diagnostic */
void mac_print_config(int n, const hw_port_t *hw);
void mac_print_link_up(int n, const hw_port_t *hw);
void mac_print_link_diag(int n, const hw_port_t *hw);

#endif /* HW_MAC_CMAC */

#endif /* MAC_H */

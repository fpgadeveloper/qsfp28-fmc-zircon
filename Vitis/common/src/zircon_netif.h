/* SPDX-License-Identifier: MIT
 *
 * zircon_netif.h - lwIP 2.2 netif over the zircon_nic raw path (UI0, axi_dma_raw)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Usage (raw API, NO_SYS=1):
 *
 *   static zircon_netif_config cfg = { .index = port, .dma_base = DMA_RAW_0_BASEADDR,
 *                                      .dma_name = "axi_dma_raw", .hwaddr = {...} };
 *   netif_add(&netif, &ip, &mask, &gw, &cfg, zircon_netif_init, ethernet_input);
 *   netif_set_up(&netif);
 *   ... main loop:
 *   zircon_netif_poll(&netif);            -- RX to lwIP, TX reclaim
 *   netif_set_link_up/down(&netif)        -- from the MRMAC link state
 */
#ifndef ZIRCON_NETIF_H
#define ZIRCON_NETIF_H

#include "lwip/netif.h"
#include "lwip/err.h"
#include "xil_types.h"

/* One instance per QSFP port (ZNETIF_MAX_INSTANCES = NUM_PORTS) */
typedef struct {
	int index;           /* instance (= port number), 0..NUM_PORTS-1             */
	UINTPTR dma_base;    /* axi_dma_raw register base (XAxiDma_LookupConfig key) */
	const char *dma_name;
	u8 hwaddr[6];        /* MAC address                                          */
} zircon_netif_config;

typedef struct {
	u32 rx_frames, rx_input_err, rx_nobuf, rx_err, rx_split;
	u32 tx_queued, tx_done, tx_busy, dma_err;
	/* timestamp descriptors: RX frames with a ZRXT descriptor, RX frames
	 * without one while expected, descriptor length != frame length, TX
	 * frames sent with a ZTXT TS_REQ descriptor */
	u32 rx_ts_frames, rx_ts_missing, rx_ts_len_err, tx_ts_req;
} zircon_netif_stats;

/* netif init callback for netif_add(); netif->state must point at a
 * zircon_netif_config. On return netif->state points at the driver instance. */
err_t zircon_netif_init(struct netif *netif);

/* Deliver received frames to netif->input and reclaim sent descriptors.
 * Returns the number of frames delivered. Call from the main loop. */
int zircon_netif_poll(struct netif *netif);

/* Recover the DMA after an error (call about once a second). */
void zircon_netif_check(struct netif *netif);

void zircon_netif_get_stats(struct netif *netif, zircon_netif_stats *s);

/* ---- latency measurement (zircon_nic 1.3.0; see zircon_netif.c) ---- */
/* rx = 1: received transfers start with a ZRXT descriptor (set together with
 * LAT_CTRL.RAW_TS_DESC); tx = 1: this netif may send ZTXT descriptors */
void zircon_netif_set_ts_desc(struct netif *netif, int rx, int tx);
/* Inside an lwIP callback run for a received frame: 1 and its MRMAC RX
 * timestamp (55 bits, 2^-8 ns) if the frame carried one, else 0 */
int  zircon_netif_cur_rx_ts(u64 *ts);
/* Attach rx_ts (TS_REQ) to the next TCP segment with payload sent, once */
void zircon_netif_ts_arm(u64 rx_ts);
void zircon_netif_ts_disarm(void);

#endif /* ZIRCON_NETIF_H */

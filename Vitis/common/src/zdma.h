/* SPDX-License-Identifier: MIT
 *
 * zdma.h - polled scatter-gather AXI DMA channel pair with private buffers
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * One zdma_t drives one AXI DMA (v7.1, SG mode): S2MM (receive) with a ring
 * of fixed receive buffers that are re-posted as soon as the callback has
 * consumed them, and MM2S (transmit) with one bounce buffer per TX BD, so
 * every frame goes out as a single SOF|EOF descriptor from a 64-byte aligned
 * buffer. That keeps the 512-bit AXI DMAs of the zircon design happy whether
 * or not their Data Realignment Engines are enabled.
 *
 * Everything is polled from the main loop: no DMA interrupts are used.
 */
#ifndef ZDMA_H
#define ZDMA_H

#include "xil_types.h"
#include "xaxidma.h"

/* Buffer alignment: the stream is 512 bits wide (64 bytes) and the A72
 * cache line is 64 bytes. */
#define ZDMA_BUF_ALIGN 64

typedef void (*zdma_rx_cb_t)(void *arg, u8 *data, u32 len);

typedef struct {
	const char *name;
	UINTPTR base;
	XAxiDma dma;
	XAxiDma_Config *cfg;

	u8 *rx_bufs;       /* n_rx buffers of rx_len bytes, 64-byte aligned  */
	u32 n_rx, rx_len;
	u8 *tx_bufs;       /* n_tx buffers of tx_len bytes, 64-byte aligned  */
	u32 n_tx, tx_len;
	u32 tx_head;       /* next bounce buffer to hand out                 */

	u8 *rx_bdspace, *tx_bdspace;
	int ok;

	/* statistics */
	u32 rx_frames, rx_bytes_lo, rx_err, rx_split;
	u32 tx_frames, tx_busy, dma_err;
} zdma_t;

/* Initialise the DMA at 'base' (XAxiDma_LookupConfig key) in SG mode, create
 * both rings (n_rx / n_tx BDs, at most ZDMA_MAX_BDS each) and post every
 * receive buffer. Returns 0 on success. */
#define ZDMA_MAX_BDS 256
int zdma_init(zdma_t *d, const char *name, UINTPTR base,
	      u8 *rx_bufs, u32 n_rx, u32 rx_len,
	      u8 *tx_bufs, u32 n_tx, u32 tx_len);

/* Process up to 'budget' completed receive descriptors: each complete
 * single-buffer frame is passed to cb(arg, data, len) (data valid only during
 * the call), then the buffer is re-posted. Returns the number processed. */
int zdma_rx_poll(zdma_t *d, zdma_rx_cb_t cb, void *arg, int budget);

/* Reclaim completed transmit descriptors. */
void zdma_tx_reclaim(zdma_t *d);

/* Get the next free transmit bounce buffer (tx_len bytes), or NULL if every
 * TX descriptor is still in flight. Fill it, then call zdma_tx_send(). */
u8 *zdma_tx_buf(zdma_t *d);
int zdma_tx_send(zdma_t *d, u32 len);

/* Check the DMA status registers for errors; on an error, reset the engine
 * and rebuild both rings. Returns 1 if a recovery was done. */
int zdma_check(zdma_t *d);

#endif /* ZDMA_H */

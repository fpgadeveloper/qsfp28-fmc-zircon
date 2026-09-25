/* SPDX-License-Identifier: MIT
 *
 * zdma.c - polled scatter-gather AXI DMA channel pair with private buffers
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Ring handling follows the AMD lwIP port's AXI DMA adapter
 * (contrib/ports/xilinx/netif/xaxiemacif_dma.c) and the ethernet-fmc-taxi-eth
 * taxi_macif.c it was ported from, but without interrupts and with the frame
 * buffers owned by this module.
 *
 * Cache handling (Cortex-A72, the DMAs reach DDR through the NoC without
 * coherency):
 *   - the BD rings live in one 2 MB block remapped Normal Non-cacheable,
 *     inner shareable with Xil_SetTlbAttributes(), so the AXI DMA driver's
 *     BD cache macros are no-ops (xaxidma_bd.h, __aarch64__);
 *   - receive buffers are flushed (clean + invalidate) before they are handed
 *     to the DMA and invalidated again after the DMA wrote them, since the
 *     core may have speculatively refilled lines in between;
 *   - transmit bounce buffers are flushed after the CPU filled them.
 *   Every buffer is 64-byte aligned and a multiple of 64 bytes long, so no
 *   maintenance operation ever touches a neighbouring object.
 */
#include <string.h>

#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_mmu.h"
#include "console.h"
#include "xpseudo_asm.h"
#include "xstatus.h"

#include "zdma.h"

#define BD_ALIGNMENT   (XAXIDMA_BD_MINIMUM_ALIGNMENT * 2)
#define BD_SPACE_SIZE  0x200000        /* one 2 MB MMU block            */
#define BD_RING_SPACE  0x10000         /* 64 KB per ring (256 x 128 B)  */

static u8 bd_space[BD_SPACE_SIZE] __attribute__((aligned(BD_SPACE_SIZE)));
static u32 bd_space_used;
static int bd_space_mapped;

static u8 *bd_ring_alloc(void)
{
	u8 *p;

	if (!bd_space_mapped) {
		Xil_SetTlbAttributes((UINTPTR)bd_space, NORM_NONCACHE | INNER_SHAREABLE);
		dsb();
		bd_space_mapped = 1;
	}
	if (bd_space_used + BD_RING_SPACE > BD_SPACE_SIZE)
		return NULL;
	p = &bd_space[bd_space_used];
	bd_space_used += BD_RING_SPACE;
	return p;
}

static inline u8 *rx_buf(zdma_t *d, u32 i) { return d->rx_bufs + (UINTPTR)i * d->rx_len; }
static inline u8 *tx_buf(zdma_t *d, u32 i) { return d->tx_bufs + (UINTPTR)i * d->tx_len; }

/* Hand 'n' buffers (pointers in bufs[]) to the S2MM ring */
static int post_rx(zdma_t *d, u8 *const *bufs, int n)
{
	XAxiDma_BdRing *ring = XAxiDma_GetRxRing(&d->dma);
	XAxiDma_Bd *bdset, *bd;
	int i;

	if (n <= 0)
		return 0;
	if (XAxiDma_BdRingAlloc(ring, n, &bdset) != XST_SUCCESS)
		return -1;
	for (i = 0, bd = bdset; i < n; i++) {
		XAxiDma_BdSetBufAddr(bd, (UINTPTR)bufs[i]);
		/* clear status except COMPLETE, which BdRingToHw clears */
		XAxiDma_BdWrite(bd, XAXIDMA_BD_STS_OFFSET,
				XAxiDma_BdGetSts(bd) & XAXIDMA_BD_STS_COMPLETE_MASK);
		XAxiDma_BdSetLength(bd, d->rx_len, ring->MaxTransferLen);
		XAxiDma_BdSetCtrl(bd, 0);
		XAxiDma_BdSetId(bd, (UINTPTR)bufs[i]);
		Xil_DCacheFlushRange((UINTPTR)bufs[i], d->rx_len);
		bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(ring, bd);
	}
	dsb();
	if (XAxiDma_BdRingToHw(ring, n, bdset) != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(ring, n, bdset);
		return -1;
	}
	return 0;
}

/* (Re)initialise the engine and both rings; used by init and recovery */
static int zdma_setup(zdma_t *d)
{
	XAxiDma_BdRing *rxring, *txring;
	XAxiDma_Bd bdtemplate;
	u8 *bufs[ZDMA_MAX_BDS];
	u32 i, maxlen;

	d->ok = 0;
	if (XAxiDma_CfgInitialize(&d->dma, d->cfg) != XST_SUCCESS) {
		con_printf("%s: XAxiDma_CfgInitialize failed\r\n", d->name);
		return -1;
	}
	if (!XAxiDma_HasSg(&d->dma)) {
		con_printf("%s: AXI DMA is not in scatter-gather mode\r\n", d->name);
		return -1;
	}
	rxring = XAxiDma_GetRxRing(&d->dma);
	txring = XAxiDma_GetTxRing(&d->dma);

	maxlen = rxring->MaxTransferLen < txring->MaxTransferLen ?
		 rxring->MaxTransferLen : txring->MaxTransferLen;
	if (d->rx_len > maxlen || d->tx_len > maxlen) {
		con_printf("%s: buffer length %u/%u exceeds the DMA's max transfer %u\r\n",
			   d->name, d->rx_len, d->tx_len, maxlen);
		return -1;
	}

	XAxiDma_BdClear(&bdtemplate);
	if (XAxiDma_BdRingCreate(rxring, (UINTPTR)d->rx_bdspace, (UINTPTR)d->rx_bdspace,
				 BD_ALIGNMENT, d->n_rx) != XST_SUCCESS ||
	    XAxiDma_BdRingClone(rxring, &bdtemplate) != XST_SUCCESS) {
		con_printf("%s: RX BD ring setup failed\r\n", d->name);
		return -1;
	}
	if (XAxiDma_BdRingCreate(txring, (UINTPTR)d->tx_bdspace, (UINTPTR)d->tx_bdspace,
				 BD_ALIGNMENT, d->n_tx) != XST_SUCCESS ||
	    XAxiDma_BdRingClone(txring, &bdtemplate) != XST_SUCCESS) {
		con_printf("%s: TX BD ring setup failed\r\n", d->name);
		return -1;
	}
	d->tx_head = 0;

	for (i = 0; i < d->n_rx; i++)
		bufs[i] = rx_buf(d, i);
	if (post_rx(d, bufs, d->n_rx) != 0) {
		con_printf("%s: could not post the receive buffers\r\n", d->name);
		return -1;
	}

	/* polled: no interrupts, no coalescing needed */
	XAxiDma_BdRingIntDisable(txring, XAXIDMA_IRQ_ALL_MASK);
	XAxiDma_BdRingIntDisable(rxring, XAXIDMA_IRQ_ALL_MASK);
	if (XAxiDma_BdRingStart(txring) != XST_SUCCESS ||
	    XAxiDma_BdRingStart(rxring) != XST_SUCCESS) {
		con_printf("%s: failed to start the DMA rings\r\n", d->name);
		return -1;
	}
	d->ok = 1;
	return 0;
}

int zdma_init(zdma_t *d, const char *name, UINTPTR base,
	      u8 *rx_bufs, u32 n_rx, u32 rx_len,
	      u8 *tx_bufs, u32 n_tx, u32 tx_len)
{
	memset(d, 0, sizeof(*d));
	d->name = name;
	d->base = base;
	d->rx_bufs = rx_bufs;
	d->n_rx = n_rx;
	d->rx_len = rx_len;
	d->tx_bufs = tx_bufs;
	d->n_tx = n_tx;
	d->tx_len = tx_len;

	if (n_rx == 0 || n_rx > ZDMA_MAX_BDS || n_tx == 0 || n_tx > ZDMA_MAX_BDS ||
	    ((UINTPTR)rx_bufs % ZDMA_BUF_ALIGN) || ((UINTPTR)tx_bufs % ZDMA_BUF_ALIGN) ||
	    (rx_len % ZDMA_BUF_ALIGN) || (tx_len % ZDMA_BUF_ALIGN)) {
		con_printf("%s: bad buffer geometry\r\n", name);
		return -1;
	}
	d->cfg = XAxiDma_LookupConfig(base);
	if (d->cfg == NULL) {
		con_printf("%s: no AXI DMA at 0x%08lx in xaxidma_g.c\r\n", name, (unsigned long)base);
		return -1;
	}
	d->rx_bdspace = bd_ring_alloc();
	d->tx_bdspace = bd_ring_alloc();
	if (d->rx_bdspace == NULL || d->tx_bdspace == NULL) {
		con_printf("%s: out of BD space\r\n", name);
		return -1;
	}
	return zdma_setup(d);
}

int zdma_rx_poll(zdma_t *d, zdma_rx_cb_t cb, void *arg, int budget)
{
	XAxiDma_BdRing *ring = XAxiDma_GetRxRing(&d->dma);
	XAxiDma_Bd *bdset, *bd;
	u8 *bufs[ZDMA_MAX_BDS];
	u32 sts, len;
	int n, i;

	if (!d->ok)
		return 0;
	if (budget <= 0 || budget > ZDMA_MAX_BDS)
		budget = ZDMA_MAX_BDS;
	n = XAxiDma_BdRingFromHw(ring, budget, &bdset);
	if (n <= 0)
		return 0;

	for (i = 0, bd = bdset; i < n; i++) {
		u8 *buf = (u8 *)(UINTPTR)XAxiDma_BdGetId(bd);

		sts = XAxiDma_BdGetSts(bd);
		len = XAxiDma_BdGetActualLength(bd, ring->MaxTransferLen);
		bufs[i] = buf;
		if ((sts & XAXIDMA_BD_STS_ALL_ERR_MASK) || len == 0 || len > d->rx_len) {
			d->rx_err++;
		} else if ((sts & (XAXIDMA_BD_STS_RXSOF_MASK | XAXIDMA_BD_STS_RXEOF_MASK)) !=
			   (XAXIDMA_BD_STS_RXSOF_MASK | XAXIDMA_BD_STS_RXEOF_MASK)) {
			/* a frame larger than one buffer: dropped piecewise */
			d->rx_split++;
		} else {
			/* the core may hold stale (speculatively fetched) lines */
			Xil_DCacheInvalidateRange((UINTPTR)buf,
						  (len + ZDMA_BUF_ALIGN - 1) & ~(ZDMA_BUF_ALIGN - 1));
			d->rx_frames++;
			d->rx_bytes_lo += len;
			cb(arg, buf, len);
		}
		bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(ring, bd);
	}
	XAxiDma_BdRingFree(ring, n, bdset);
	if (post_rx(d, bufs, n) != 0)
		con_printf("%s: failed to re-post %d receive buffers\r\n", d->name, n);
	return n;
}

void zdma_tx_reclaim(zdma_t *d)
{
	XAxiDma_BdRing *ring = XAxiDma_GetTxRing(&d->dma);
	XAxiDma_Bd *bdset;
	int n;

	if (!d->ok)
		return;
	n = XAxiDma_BdRingFromHw(ring, XAXIDMA_ALL_BDS, &bdset);
	if (n > 0) {
		d->tx_frames += n;
		XAxiDma_BdRingFree(ring, n, bdset);
	}
}

u8 *zdma_tx_buf(zdma_t *d)
{
	XAxiDma_BdRing *ring = XAxiDma_GetTxRing(&d->dma);

	if (!d->ok)
		return NULL;
	if (XAxiDma_BdRingGetFreeCnt(ring) == 0)
		zdma_tx_reclaim(d);
	if (XAxiDma_BdRingGetFreeCnt(ring) == 0) {
		d->tx_busy++;
		return NULL;
	}
	/* BDs complete in order, so with a free BD the oldest buffer is free */
	return tx_buf(d, d->tx_head);
}

int zdma_tx_send(zdma_t *d, u32 len)
{
	XAxiDma_BdRing *ring = XAxiDma_GetTxRing(&d->dma);
	XAxiDma_Bd *bd;
	u8 *buf = tx_buf(d, d->tx_head);

	if (!d->ok || len == 0 || len > d->tx_len)
		return -1;
	if (XAxiDma_BdRingAlloc(ring, 1, &bd) != XST_SUCCESS)
		return -1;
	Xil_DCacheFlushRange((UINTPTR)buf, len);
	XAxiDma_BdSetBufAddr(bd, (UINTPTR)buf);
	XAxiDma_BdSetLength(bd, len, ring->MaxTransferLen);
	XAxiDma_BdSetCtrl(bd, XAXIDMA_BD_CTRL_TXSOF_MASK | XAXIDMA_BD_CTRL_TXEOF_MASK);
	XAxiDma_BdSetId(bd, (UINTPTR)buf);
	dsb();
	if (XAxiDma_BdRingToHw(ring, 1, bd) != XST_SUCCESS) {
		XAxiDma_BdRingUnAlloc(ring, 1, bd);
		return -1;
	}
	d->tx_head = (d->tx_head + 1) % d->n_tx;
	return 0;
}

int zdma_check(zdma_t *d)
{
	u32 tx_sr, rx_sr;

	if (d->cfg == NULL || !d->ok)
		return 0;   /* never came up: nothing to recover */
	tx_sr = XAxiDma_ReadReg(d->base + XAXIDMA_TX_OFFSET, XAXIDMA_SR_OFFSET);
	rx_sr = XAxiDma_ReadReg(d->base + XAXIDMA_RX_OFFSET, XAXIDMA_SR_OFFSET);
	if (!((tx_sr | rx_sr) & XAXIDMA_ERR_ALL_MASK))
		return 0;

	d->dma_err++;
	con_printf("%s: AXI DMA error (MM2S SR 0x%08x, S2MM SR 0x%08x), resetting\r\n",
		   d->name, tx_sr, rx_sr);
	zdma_setup(d);
	return 1;
}

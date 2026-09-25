/* SPDX-License-Identifier: MIT
 *
 * sock_demo.h - hardware UDP socket demo (zircon UI2, axi_dma_sock)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef SOCK_DEMO_H
#define SOCK_DEMO_H

#include "xil_types.h"
#include "zircon.h"

typedef struct {
	u32 rx_datagrams, rx_bad_desc, rx_len_err;
	u32 tx_datagrams, tx_busy, tx_zero_len;
	u32 peer_changes;
	u32 dma_err;
} sock_demo_stats_t;

/* One instance per QSFP port */
typedef struct sock_demo sock_demo_t;

/* Set up port 'port's socket DMA and post its receive buffers. The zircon
 * registers (SOCK_LOCAL_PORT, CTRL.SOCK_EN) are programmed by the caller.
 * Returns the instance, or NULL on failure. */
sock_demo_t *sock_demo_init(int port, zircon_t *z, UINTPTR dma_base, const char *dma_name);
/* Bounce every received datagram back through the socket TX channel. */
void sock_demo_poll(sock_demo_t *sd);
/* Recover the DMA after an error (call about once a second). */
void sock_demo_check(sock_demo_t *sd);
/* Statistics (all zero for a NULL instance) */
void sock_demo_get_stats(const sock_demo_t *sd, sock_demo_stats_t *s);

#endif /* SOCK_DEMO_H */

/* SPDX-License-Identifier: MIT
 *
 * console.h - buffered, non-blocking UART console output
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * xil_printf() writes every character synchronously: a 600-character status
 * table at 115200 baud would stall the main loop (and with it the raw-path
 * and socket DMAs) for ~50 ms. con_printf() formats into a RAM ring instead,
 * and con_poll(), called from the main loop, moves characters into the UART
 * TX FIFO only while the FIFO has room, so printing never blocks the loop.
 *
 * Before con_set_async(1) (i.e. during bring-up) and whenever the ring is
 * full, output is written synchronously, so nothing is ever lost and the
 * order of the messages is always preserved.
 */
#ifndef CONSOLE_H
#define CONSOLE_H

#include "xil_types.h"

#define CON_RING_SIZE   16384        /* power of two */

void con_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void con_set_async(int on);
/* Drain as much of the ring as the UART TX FIFO accepts right now. */
void con_poll(void);
/* Drain everything (blocking). */
void con_flush(void);
/* Non-blocking read of one received character; returns -1 if none. */
int  con_getc(void);

#endif /* CONSOLE_H */

/* SPDX-License-Identifier: MIT
 *
 * console.c - buffered, non-blocking UART console output (see console.h)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * UART backends, picked from the BSP's STDOUT: the Versal PS UART (PL011,
 * xuartpsv), or on MicroBlaze targets an AXI UART Lite (xuartlite). Anything
 * else falls back to the BSP's blocking outbyte() and has no input.
 */
#include <stdarg.h>
#include <stdio.h>

#include "xparameters.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "console.h"

#if defined(STDOUT_BASEADDRESS) && __has_include("xuartpsv_hw.h")
#include "xuartpsv_hw.h"
#define CON_UARTPSV 1
#else
#define CON_UARTPSV 0
#endif

#if !CON_UARTPSV && defined(__MICROBLAZE__) && defined(STDOUT_BASEADDRESS) && \
    __has_include("xuartlite_l.h")
#include "xuartlite_l.h"
#define CON_UARTLITE 1
#else
#define CON_UARTLITE 0
#endif

static char ring[CON_RING_SIZE];
static u32 head, tail;          /* head: next write, tail: next read (free-running) */
static int async_on;

static inline u32 ring_used(void) { return head - tail; }

static int tx_full(void)
{
#if CON_UARTPSV
	return XUartPsv_IsTransmitFull(STDOUT_BASEADDRESS);
#elif CON_UARTLITE
	return XUartLite_IsTransmitFull(STDOUT_BASEADDRESS);
#else
	return 0;
#endif
}

static void tx_byte(char c)
{
#if CON_UARTPSV
	Xil_Out32(STDOUT_BASEADDRESS + XUARTPSV_UARTDR_OFFSET, (u32)(u8)c);
#elif CON_UARTLITE
	/* tx_full() said there is room: write the FIFO without waiting */
	XUartLite_WriteReg(STDOUT_BASEADDRESS, XUL_TX_FIFO_OFFSET, (u32)(u8)c);
#else
	outbyte(c);
#endif
}

void con_poll(void)
{
	while (ring_used() && !tx_full()) {
		tx_byte(ring[tail & (CON_RING_SIZE - 1)]);
		tail++;
	}
}

void con_flush(void)
{
	while (ring_used())
		con_poll();
}

void con_set_async(int on)
{
	if (!on)
		con_flush();
	async_on = on;
}

void con_printf(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	int n, i;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n >= (int)sizeof(buf))
		n = sizeof(buf) - 1;
	for (i = 0; i < n; i++) {
		while (ring_used() >= CON_RING_SIZE)
			con_poll();              /* ring full: wait for the UART */
		ring[head & (CON_RING_SIZE - 1)] = buf[i];
		head++;
	}
	if (!async_on)
		con_flush();
	else
		con_poll();
}

int con_getc(void)
{
#if CON_UARTPSV && defined(STDIN_BASEADDRESS)
	if (!XUartPsv_IsReceiveData(STDIN_BASEADDRESS))
		return -1;
	return (int)(XUartPsv_ReadReg(STDIN_BASEADDRESS, XUARTPSV_UARTDR_OFFSET) & 0xFF);
#elif CON_UARTLITE && defined(STDIN_BASEADDRESS)
	if (XUartLite_IsReceiveEmpty(STDIN_BASEADDRESS))
		return -1;
	return (int)(XUartLite_ReadReg(STDIN_BASEADDRESS, XUL_RX_FIFO_OFFSET) & 0xFF);
#else
	return -1;
#endif
}

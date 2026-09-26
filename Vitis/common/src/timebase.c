/* SPDX-License-Identifier: MIT
 *
 * timebase.c - free-running 64-bit application time base (see timebase.h)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * AXI Timer (PG079) cascade mode: TCSR0.CASC = 1 makes counter 1 the upper
 * 32 bits of counter 0; TCSR0 alone controls the pair. Both load registers
 * are 0 and the counters are loaded from them once, then counting up in
 * generate mode without auto-reload: the 64-bit count does not wrap in the
 * life of the board (5800 years at 100 MHz).
 */
#include "xil_io.h"
#include "timebase.h"

#if defined(TIMEBASE_BASEADDR)

#define TMR_TCSR0   0x00
#define TMR_TLR0    0x04
#define TMR_TCR0    0x08
#define TMR_TCSR1   0x10
#define TMR_TLR1    0x14
#define TMR_TCR1    0x18

#define TCSR_LOAD   (1u << 5)
#define TCSR_ENT    (1u << 7)
#define TCSR_CASC   (1u << 11)

void timebase_init(void)
{
	UINTPTR b = TIMEBASE_BASEADDR;

	Xil_Out32(b + TMR_TCSR0, 0);
	Xil_Out32(b + TMR_TCSR1, 0);
	Xil_Out32(b + TMR_TLR0, 0);
	Xil_Out32(b + TMR_TLR1, 0);
	/* copy the load registers into both counters */
	Xil_Out32(b + TMR_TCSR0, TCSR_LOAD);
	Xil_Out32(b + TMR_TCSR1, TCSR_LOAD);
	Xil_Out32(b + TMR_TCSR1, 0);
	/* cascade, count up, generate mode, no auto-reload, no interrupt */
	Xil_Out32(b + TMR_TCSR0, TCSR_CASC);
	Xil_Out32(b + TMR_TCSR0, TCSR_CASC | TCSR_ENT);
}

u64 tb_now(void)
{
	UINTPTR b = TIMEBASE_BASEADDR;
	u32 hi, lo, hi2;

	hi = Xil_In32(b + TMR_TCR1);
	lo = Xil_In32(b + TMR_TCR0);
	hi2 = Xil_In32(b + TMR_TCR1);
	if (hi2 != hi)                     /* the low word wrapped in between */
		lo = Xil_In32(b + TMR_TCR0);
	return ((u64)hi2 << 32) | lo;
}

/* The main loop reads the time on every pass: keep a running millisecond
 * count so that each call is one 32-bit (hardware) division instead of a
 * 64-bit libgcc one. No interrupts use it, so no locking. */
u32 timebase_ms(void)
{
	static u64 base_tick;
	static u32 base_ms;
	const u32 per_ms = (u32)(TB_HZ / 1000);
	u64 d = tb_now() - base_tick;
	u32 q;

	if (d >> 32)
		q = (u32)(d / per_ms);
	else
		q = (u32)d / per_ms;
	base_ms += q;
	base_tick += (u64)q * per_ms;
	return base_ms;
}

#else /* Arm generic timer via XTime */

u32 timebase_ms(void)
{
	return (u32)(tb_now() / (TB_HZ / 1000));
}

#endif

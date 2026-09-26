/* SPDX-License-Identifier: MIT
 *
 * timebase.h - free-running 64-bit application time base
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * The polled main loop paces lwIP's timers, link polling and the status
 * lines from one monotonic counter:
 *   - Arm (Versal): the generic timer through xiltimer's XTime_GetTime(),
 *     TB_HZ = COUNTS_PER_SECOND (as before this header existed);
 *   - MicroBlaze: axi_timer_1 with both 32-bit counters cascaded into one
 *     64-bit up-counter (hw_config.h TIMEBASE_BASEADDR / TIMEBASE_HZ).
 *     xiltimer's XTime on an AXI timer is only 32 bits (43 s at 100 MHz),
 *     and axi_timer_0 is xiltimer's usleep()/sleep() timer.
 * timebase_init() must run before the first tb_now() (main() calls it
 * first thing); it is a no-op on Arm.
 */
#ifndef TIMEBASE_H
#define TIMEBASE_H

#include "xil_types.h"
#include "hw_config.h"

#if defined(TIMEBASE_BASEADDR)

#define TB_HZ ((u64)TIMEBASE_HZ)
void timebase_init(void);
u64  tb_now(void);

#else

#include "xiltimer.h"
#ifndef COUNTS_PER_SECOND
#define COUNTS_PER_SECOND XPAR_CPU_TIMESTAMP_CLK_FREQ
#endif
#define TB_HZ COUNTS_PER_SECOND
static inline void timebase_init(void) {}
static inline u64 tb_now(void)
{
	XTime t;

	XTime_GetTime(&t);
	return (u64)t;
}

#endif

/* Milliseconds since start-up, wrapping at 2^32 */
u32 timebase_ms(void);

#endif /* TIMEBASE_H */

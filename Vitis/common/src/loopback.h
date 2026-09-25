/* SPDX-License-Identifier: MIT
 *
 * loopback.h - 100G loopback test with the zircon_nic hardware UDP
 *              generator / checker (docs/DESIGN_SPEC.md section 10)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef LOOPBACK_H
#define LOOPBACK_H

#include "xil_types.h"

typedef enum {
	LB_OFF = 0,
	LB_CROSS,     /* 'l': gen p -> cable -> chk of the other port, both ways  */
	LB_ECHO,      /* 'e': gen 0 -> cable -> port 1 hardware echo -> chk 0      */
	LB_SELF,      /* 'L <n>': gen n -> loopback plug on port n -> chk n        */
} lb_mode_t;

void      lb_init(void);
/* Start a test (stops a running one first); returns 0 on success */
int       lb_start(lb_mode_t mode, u32 now, int autostarted);
/* Port used by LB_SELF (set before lb_start(LB_SELF, ...)) */
void      lb_set_self_port(int port);
int       lb_self_port(void);
/* Is port p used by the running test (generator, checker or echo)? */
int       lb_port_involved(int p);
void      lb_stop(u32 now, const char *why);
lb_mode_t lb_mode(void);
const char *lb_mode_name(lb_mode_t mode);
/* Payload bytes (8..9000); restarts a running test */
int       lb_set_len(u32 len, u32 now);
u32       lb_get_len(void);
/* Counters cleared by the caller (CTRL.STAT_CLR): restart the statistics
 * and the verdict window of a running test */
void      lb_clear(u32 now);
/* Call from the main loop: rate meters, 1-s table, verdict, auto-start */
void      lb_poll(u32 now);
/* Print the per-port table now (console 's') */
void      lb_print_table(u32 now);
/* The user took control: no auto-start any more */
void      lb_cancel_autostart(void);

#endif /* LOOPBACK_H */

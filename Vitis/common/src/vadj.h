/* SPDX-License-Identifier: MIT
 *
 * vadj.h - VADJ enable for Versal boards
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Ported unchanged from the 2x QSFP28 FMC reference design (echo_server).
 */

#ifndef VADJ_H
#define VADJ_H

typedef enum {
	VADJ_1V5,
	VADJ_1V2,
} vadj_voltage_t;

int vadj_enable(vadj_voltage_t voltage);

#endif

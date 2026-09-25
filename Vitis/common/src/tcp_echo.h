/* SPDX-License-Identifier: MIT
 *
 * tcp_echo.h - lwIP raw-API TCP echo server (software path)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef TCP_ECHO_H
#define TCP_ECHO_H

#include "lwip/arch.h"
#include "xil_types.h"

int  tcp_echo_start(u16_t port);
void tcp_echo_get_stats(u32 *connections, u32 *active);

#endif /* TCP_ECHO_H */

/* SPDX-License-Identifier: MIT
 *
 * latency.h - latency measurement (zircon_nic 1.3.0): MRMAC 1588 bring-up
 *             check, the 'T' console report, the status-line summary and the
 *             UDP statistics service (latency_wire.h)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#ifndef LATENCY_H
#define LATENCY_H

#include "xil_types.h"

struct port;

/* LAT_RAW_TS_DESC_DEFAULT (app_config.h) = 1: the software TCP echo is
 * measured (bank 1) from start-up */

/* After the MRMAC of the port is configured: print the 1588 state and a
 * systimer rate check (once, at bring-up) */
void lat_print_1588(struct port *p);
/* Program the latency block of a port (bins, clear, LAT_CTRL) and the netif's
 * descriptor handling; call after the netif exists, before the datapath opens */
void lat_port_init(struct port *p);

/* Console 'T' line: "" (report), "c" (clear), "<port>", "<port> c" */
void lat_cmd(const char *args);
/* Clear both banks of a port */
void lat_clear(struct port *p);
/* Short hardware-echo summary for the status line into buf (empty if the
 * bank has no samples); returns the length */
int  lat_status_summary(struct port *p, char *buf, int size);

/* Start the UDP statistics service (LAT_WIRE_UDP_PORT); 0 on success */
int  lat_service_start(void);

#endif /* LATENCY_H */

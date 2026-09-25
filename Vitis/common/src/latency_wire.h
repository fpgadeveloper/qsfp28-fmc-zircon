/* SPDX-License-Identifier: MIT
 *
 * latency_wire.h - wire format of the latency statistics service (UDP 5002)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * The echo server answers on UDP port LAT_WIRE_UDP_PORT (lwIP, raw path) on
 * every QSFP port:
 *
 *   request "STAT?"      -> one datagram: lat_wire_hdr_t followed by nbanks
 *                           lat_wire_bank_t (LAT_WIRE_REPLY_LEN bytes), the
 *                           statistics of the port that received the request
 *   request "STAT? <p>"  -> the same for QSFP port <p>
 *   request "CLR"        -> zero both banks of the receiving port (or of
 *                           port <p> with "CLR <p>"); reply "CLR OK"
 *   anything else        -> reply "ERR"
 *
 * Requests are ASCII, optionally followed by '\n'. All reply fields are
 * little-endian and the structures are packed. Bank 0 is the hardware UDP
 * echo, bank 1 the software (TCP) echo; values are nanoseconds (sumsq ns^2).
 * Histogram bin i covers [bin_lo_ns[i], bin_lo_ns[i + 1]); the last bin is
 * the overflow bin (no upper edge). Bin 0 also holds every delta below
 * bin_lo_ns[1] - bin_width_ns.
 *
 * scripts/zircon_echo_test.py mirrors these structures (LAT_HDR_FMT /
 * LAT_BANK_FMT): change both together and bump LAT_WIRE_VERSION.
 */
#ifndef LATENCY_WIRE_H
#define LATENCY_WIRE_H

#include "xil_types.h"

#define LAT_WIRE_UDP_PORT      5002
#define LAT_WIRE_MAGIC         0x5A4C4154u   /* "ZLAT" */
#define LAT_WIRE_VERSION       1
#define LAT_WIRE_NBANKS        2
#define LAT_WIRE_NBINS         64

/* lat_wire_hdr_t.flags */
#define LAT_WIRE_F_EN          (1u << 0)     /* LAT_CTRL.EN                     */
#define LAT_WIRE_F_RAW_TS_DESC (1u << 1)     /* LAT_CTRL.RAW_TS_DESC            */
#define LAT_WIRE_F_SNAP_FAIL   (1u << 2)     /* LAT_CTRL.SNAP did not complete  */
#define LAT_WIRE_F_NO_LAT      (1u << 3)     /* the core has no latency block   */

typedef struct __attribute__((packed)) {
	u32 magic;              /*  0: LAT_WIRE_MAGIC                          */
	u16 version;            /*  4: LAT_WIRE_VERSION                        */
	u8  nbanks;             /*  6: LAT_WIRE_NBANKS                         */
	u8  nbins;              /*  7: LAT_WIRE_NBINS                          */
	u8  port;               /*  8: QSFP port of these statistics           */
	u8  flags;              /*  9: LAT_WIRE_F_*                            */
	u16 hdr_len;            /* 10: sizeof(lat_wire_hdr_t)                  */
	u32 bin_base_ns;        /* 12: LAT_BIN_BASE                            */
	u32 bin_width_ns;       /* 16: LAT_BIN_WIDTH                           */
	u32 zircon_version;     /* 20: VERSION                                 */
	u32 lat_status;         /* 24: LAT_STATUS                              */
	u32 uptime_ms;          /* 28: board time of the snapshot              */
	u32 bin_lo_ns[LAT_WIRE_NBINS];   /* 32: lower edge of each bin, ns
					   (0xFFFFFFFF = beyond 32 bits)   */
} lat_wire_hdr_t;               /* 288 bytes */

typedef struct __attribute__((packed)) {
	u64 count;              /*  0: samples                                 */
	u64 sum_ns;             /*  8                                          */
	u64 sumsq_ns2;          /* 16                                          */
	u32 min_ns;             /* 24: meaningless when count = 0              */
	u32 max_ns;             /* 28                                          */
	u32 implausible;        /* 32: deltas rejected by the hardware         */
	u32 last_ns;            /* 36: the most recent delta                   */
	u64 bins[LAT_WIRE_NBINS];   /* 40: histogram counts                    */
} lat_wire_bank_t;              /* 552 bytes */

#define LAT_WIRE_REPLY_LEN (sizeof(lat_wire_hdr_t) + LAT_WIRE_NBANKS * sizeof(lat_wire_bank_t))

_Static_assert(sizeof(lat_wire_hdr_t) == 288, "lat_wire_hdr_t layout");
_Static_assert(sizeof(lat_wire_bank_t) == 552, "lat_wire_bank_t layout");
_Static_assert(LAT_WIRE_REPLY_LEN <= 1472, "the reply must fit one 1500-MTU datagram");

#endif /* LATENCY_WIRE_H */

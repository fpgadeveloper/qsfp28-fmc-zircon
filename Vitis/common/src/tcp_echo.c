/* SPDX-License-Identifier: MIT
 *
 * tcp_echo.c - lwIP raw-API TCP echo server (software path, port 7)
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Same service as the AMD lwip_echo_server template's echo.c, written so that
 * it never loses data: received bytes are queued per connection and written
 * back as send-buffer space allows (on receive, on 'sent' and on 'poll'), and
 * acknowledged to the peer (tcp_recved) only once they have been queued for
 * transmission, so the receive window throttles a sender that is faster than
 * the echo.
 *
 * Latency measurement (zircon_nic 1.3.0): when a segment arrives with an
 * MRMAC RX timestamp and nothing older is waiting to be echoed, its rx_ts is
 * armed in the netif for the duration of the receive callback, so the first
 * TCP segment with payload that the callback sends - the echo of this request
 * - carries a ZTXT descriptor, and the hardware adds its TX-minus-RX time to
 * latency bank 1. Data echoed later (from 'sent' / 'poll', or behind older
 * data) is never attributed. The measurement is exact for request/response
 * traffic with one request in flight that fits one segment (TCP_NODELAY on
 * the host; Nagle is off here).
 */
#include <string.h>

#include "lwip/mem.h"
#include "lwip/tcp.h"
#include "lwip/pbuf.h"
#include "console.h"
#include "zircon_netif.h"
#include "tcp_echo.h"

typedef struct {
	struct tcp_pcb *pcb;
	struct pbuf *pending;   /* received, not yet written back */
	int closing;
} echo_conn_t;

static u32 n_conns, n_active;

/* Returns ERR_ABRT if the pcb had to be aborted (callers inside an lwIP
 * callback must then return ERR_ABRT). */
static err_t echo_close(echo_conn_t *c)
{
	struct tcp_pcb *pcb = c->pcb;

	tcp_arg(pcb, NULL);
	tcp_recv(pcb, NULL);
	tcp_sent(pcb, NULL);
	tcp_poll(pcb, NULL, 0);
	tcp_err(pcb, NULL);
	if (c->pending)
		pbuf_free(c->pending);
	mem_free(c);
	n_active--;
	if (tcp_close(pcb) != ERR_OK) {
		tcp_abort(pcb);
		return ERR_ABRT;
	}
	return ERR_OK;
}

/* Write as much of the pending data as the send buffer takes. Closes the
 * connection once a remote close has been seen and everything is echoed;
 * returns ERR_ABRT if that close aborted the pcb (c is freed either way). */
static err_t echo_flush(echo_conn_t *c)
{
	struct tcp_pcb *pcb = c->pcb;
	int wrote = 0;

	while (c->pending != NULL) {
		struct pbuf *q = c->pending;
		u16_t space = tcp_sndbuf(pcb);
		u16_t chunk = q->len;
		err_t err;

		if (space == 0 || tcp_sndqueuelen(pcb) >= TCP_SND_QUEUELEN)
			break;
		if (chunk > space)
			chunk = space;
		err = tcp_write(pcb, q->payload, chunk, TCP_WRITE_FLAG_COPY);
		if (err == ERR_MEM)
			break;
		if (err != ERR_OK) {
			con_printf("tcp echo: tcp_write error %d\r\n", err);
			break;
		}
		wrote = 1;
		tcp_recved(pcb, chunk);
		/* drop the bytes just written from the head of the queue */
		c->pending = pbuf_free_header(q, chunk);
	}
	if (wrote)
		tcp_output(pcb);
	if (c->closing && c->pending == NULL)
		return echo_close(c);
	return ERR_OK;
}

static err_t echo_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
	echo_conn_t *c = (echo_conn_t *)arg;
	u64 rx_ts;
	err_t ret;

	if (p == NULL) {
		/* remote closed: finish echoing what we have, then close */
		c->closing = 1;
		return echo_flush(c);
	}
	if (err != ERR_OK) {
		pbuf_free(p);
		return err;
	}
	if (c->pending == NULL) {
		/* nothing older queued: the echo of this segment goes out first */
		if (pcb->unsent == NULL && zircon_netif_cur_rx_ts(&rx_ts))
			zircon_netif_ts_arm(rx_ts);
		c->pending = p;
	} else {
		pbuf_cat(c->pending, p);
	}
	ret = echo_flush(c);
	/* Not disarmed here: lwIP defers tcp_output() for the pcb whose segment
	 * it is processing (tcp_input_pcb) until this callback has returned, so
	 * the echo leaves only after echo_recv(). zircon_netif disarms once the
	 * received frame has been fully processed (end of its rx_frame()). */
	return ret;
}

static err_t echo_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
	LWIP_UNUSED_ARG(pcb);
	LWIP_UNUSED_ARG(len);
	return echo_flush((echo_conn_t *)arg);
}

static err_t echo_poll(void *arg, struct tcp_pcb *pcb)
{
	LWIP_UNUSED_ARG(pcb);
	if (arg != NULL)
		return echo_flush((echo_conn_t *)arg);
	return ERR_OK;
}

static void echo_err(void *arg, err_t err)
{
	echo_conn_t *c = (echo_conn_t *)arg;

	LWIP_UNUSED_ARG(err);
	/* the pcb is already gone */
	if (c != NULL) {
		if (c->pending)
			pbuf_free(c->pending);
		mem_free(c);
		n_active--;
	}
}

static err_t echo_accept(void *arg, struct tcp_pcb *pcb, err_t err)
{
	echo_conn_t *c;

	LWIP_UNUSED_ARG(arg);
	if (err != ERR_OK || pcb == NULL)
		return ERR_VAL;
	c = (echo_conn_t *)mem_malloc(sizeof(*c));
	if (c == NULL)
		return ERR_MEM;
	memset(c, 0, sizeof(*c));
	c->pcb = pcb;
	n_conns++;
	n_active++;
	tcp_arg(pcb, c);
	tcp_recv(pcb, echo_recv);
	tcp_sent(pcb, echo_sent);
	tcp_poll(pcb, echo_poll, 2);
	tcp_err(pcb, echo_err);
	tcp_nagle_disable(pcb);
	return ERR_OK;
}

int tcp_echo_start(u16_t port)
{
	struct tcp_pcb *pcb;
	err_t err;

	pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
	if (pcb == NULL) {
		con_printf("tcp echo: out of memory for the PCB\r\n");
		return -1;
	}
	err = tcp_bind(pcb, IP_ANY_TYPE, port);
	if (err != ERR_OK) {
		con_printf("tcp echo: unable to bind to port %d: err = %d\r\n", port, err);
		return -2;
	}
	pcb = tcp_listen(pcb);
	if (pcb == NULL) {
		con_printf("tcp echo: out of memory in tcp_listen\r\n");
		return -3;
	}
	tcp_accept(pcb, echo_accept);
	con_printf("TCP echo server started @ port %d\r\n", port);
	return 0;
}

void tcp_echo_get_stats(u32 *connections, u32 *active)
{
	if (connections)
		*connections = n_conns;
	if (active)
		*active = n_active;
}

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * netd: the network service. The TCP/IP stack is lwIP (third_party/lwip),
 * the card an NE2000 (ne2k.c), both in this process: a frame is a function
 * call, not an IPC exchange. Programs talk to it over typed IPC, protocol
 * "net/1" (mynos-lib/ocaml/net.mli, which is its definition: the case
 * numbers below follow it).
 *
 * One thread calls lwIP (its raw API, NO_SYS): the main loop. Another
 * thread waits for connections on the service's port, receives each
 * request and queues it with its channel; a third waits for the card's
 * interrupt. The main loop wakes on a request, an interrupt, or every
 * 100 ms, reads the frames the card received, runs lwIP's timers, and
 * handles the requests. A request that has to wait (Recv, Accept,
 * Connect, Ping, Resolve) keeps its channel open, and gets its reply from
 * the lwIP callback that ends the wait.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <mynos.h>
#include <mynos_wire.h>

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "lwip/tcp.h"
#include "lwip/raw.h"
#include "lwip/dns.h"
#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "lwip/inet_chksum.h"
#include "lwip/prot/icmp.h"
#include "lwip/prot/ip4.h"
#include "netif/ethernet.h"
#include "ne2k.h"

#define SERVICE     "net"
#define PROTOCOL    "net/1"
#define NE2K_IOBASE 0x300
#define NE2K_IRQ    9         /* QEMU's ne2k_isa: tools/run-qemu.sh */
#define WAKE_MS     100       /* the loop runs at least this often */
#define MAXSOCK     64
#define MAXBACKLOG  8
#define MAXRECV     16384
#define MAXPING     8
#define DHCP_WAIT   5000      /* ms, then a static address (QEMU's) */

/* lwIP's clock (NO_SYS) */
u32_t sys_now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (u32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

/* ---------------------------------------------------------------- replies */

static void send_reply(int ch, wire_writer * w) {
  if (w->error) {
    wire_writer_free(w);
    wire_writer_init(w);
    wire_reply_error(w, "netd: out of memory");
  }
  mynos_send(ch, w->buf, w->len, 0);
  mynos_freeChannel(ch);
  wire_writer_free(w);
}

static void reply_error(int ch, const char * message) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_error(&w, message);
  send_reply(ch, &w);
}

static void reply_int(int ch, long long v) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, v);
  send_reply(ch, &w);
}

static void reply_string(int ch, const void * s, unsigned int n) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_string(&w, s, n);
  send_reply(ch, &w);
}

static void reply_unit(int ch) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  send_reply(ch, &w);
}

static const char * err_text(err_t e) {
  switch (e) {
  case ERR_RST: return "connection reset";
  case ERR_ABRT: return "connection aborted";
  case ERR_CLSD: return "connection closed";
  case ERR_CONN: return "not connected";
  case ERR_TIMEOUT: return "timeout";
  case ERR_RTE: return "no route to host";
  case ERR_USE: return "address in use";
  case ERR_MEM: return "out of memory";
  default: {
    static char text[24];
    sprintf(text, "lwIP error %d", (int)e);
    return text;
  }
  }
}

/* ---------------------------------------------------------------- the card */

static struct netif netif;
static unsigned char mac[6];

static err_t linkoutput(struct netif * n, struct pbuf * p) {
  static unsigned char frame[NE2K_BUFSIZE];
  (void)n;
  if (p->tot_len > NE2K_MAXFRAME) return ERR_IF;
  pbuf_copy_partial(p, frame, p->tot_len, 0);
  return ne2k_send(frame, p->tot_len) ? ERR_IF : ERR_OK;
}

static err_t netif_setup(struct netif * n) {
  n->name[0] = 'e';
  n->name[1] = '0';
  n->output = etharp_output;
  n->linkoutput = linkoutput;
  n->mtu = 1500;
  n->hwaddr_len = 6;
  memcpy(n->hwaddr, mac, 6);
  n->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
  return ERR_OK;
}

/* the frames the card received, to lwIP */
static void poll_card(void) {
  static unsigned char frame[NE2K_BUFSIZE];
  int len;
  while ((len = ne2k_recv(frame)) != 0) {
    struct pbuf * p;
    if (len < 0) continue;
    p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) continue;
    pbuf_take(p, frame, (u16_t)len);
    if (netif.input(p, &netif) != ERR_OK) pbuf_free(p);
  }
}

/* the address: by DHCP, else QEMU's user network's after DHCP_WAIT */
static int ready = 0;
static u32_t started;

static void status_changed(struct netif * n) {
  if (!ip4_addr_isany_val(*netif_ip4_addr(n)) && !ready) {
    ready = 1;
    mynos_log("netd: address %s\n", ip4addr_ntoa(netif_ip4_addr(n)));
  }
}

static void check_address(void) {
  ip4_addr_t a, m, g, d;
  if (ready || sys_now() - started < DHCP_WAIT) return;
  mynos_log("netd: no DHCP answer, using 10.0.2.15\n");
  dhcp_release_and_stop(&netif);
  IP4_ADDR(&a, 10, 0, 2, 15);
  IP4_ADDR(&m, 255, 255, 255, 0);
  IP4_ADDR(&g, 10, 0, 2, 2);
  IP4_ADDR(&d, 10, 0, 2, 3);
  netif_set_addr(&netif, &a, &m, &g);
  dns_setserver(0, &d);
  ready = 1;
}

/* ---------------------------------------------------------------- sockets */

enum { S_FREE, S_CONNECTING, S_OPEN, S_LISTEN };
enum { W_NONE, W_CONNECT, W_RECV, W_ACCEPT };

struct sock {
  int state;
  struct tcp_pcb * pcb;         /* NULL once lwIP freed it (an error) */
  struct pbuf * rx;             /* received, not read yet */
  int eof;
  err_t err;
  /* a request waiting for something to come: Connect, Recv, Accept */
  int rx_ch, rx_kind, rx_max;
  u32_t timeout, rx_deadline;   /* Set_timeout (ms, 0: none) for Recv, Accept */
  /* a Send waiting for room in the send buffer */
  int tx_ch;
  char * tx;
  unsigned int tx_len, tx_off;
  /* a listener: connections not accepted yet */
  int backlog[MAXBACKLOG], nbacklog;
  ip_addr_t peer;
  u16_t peer_port;
};

static struct sock socks[MAXSOCK];

static void start_wait(struct sock * s);

static int alloc_sock(void) {
  int i;
  for (i = 0; i < MAXSOCK; i++)
    if (socks[i].state == S_FREE) {
      memset(&socks[i], 0, sizeof socks[i]);
      socks[i].rx_ch = socks[i].tx_ch = -1;
      return i;
    }
  return -1;
}

static struct sock * get_sock(long long id) {
  if (id < 0 || id >= MAXSOCK || socks[id].state == S_FREE) return NULL;
  return &socks[id];
}

#define ID(s) ((int)((s) - socks))
#define ARG(i) ((void *)(intptr_t)(i))
#define IDX(arg) ((int)(intptr_t)(arg))

static void reply_accept(int ch, struct sock * c) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, ID(c));
  wire_put_cstring(&w, ipaddr_ntoa(&c->peer));
  wire_put_int(&w, c->peer_port);
  send_reply(ch, &w);
}

/* a waiting Recv: data, the end, or the error */
static void serve_recv(struct sock * s) {
  if (s->rx_kind != W_RECV) return;
  if (s->rx) {
    unsigned int n = s->rx->tot_len;
    char * buf;
    if (n > (unsigned int)s->rx_max) n = s->rx_max;
    buf = malloc(n);
    if (buf == NULL) return;              /* try again later */
    pbuf_copy_partial(s->rx, buf, (u16_t)n, 0);
    s->rx = pbuf_free_header(s->rx, (u16_t)n);
    if (s->pcb) tcp_recved(s->pcb, (u16_t)n);
    reply_string(s->rx_ch, buf, n);
    free(buf);
  } else if (s->eof) {
    reply_string(s->rx_ch, "", 0);
  } else if (s->err != ERR_OK) {
    reply_error(s->rx_ch, err_text(s->err));
  } else
    return;                               /* nothing yet: keep waiting */
  s->rx_kind = W_NONE;
  s->rx_ch = -1;
}

/* a waiting Send: as much as fits in the send buffer */
static void serve_send(struct sock * s) {
  if (s->tx_ch < 0) return;
  if (s->pcb == NULL || s->err != ERR_OK) {
    reply_error(s->tx_ch, err_text(s->err != ERR_OK ? s->err : ERR_CLSD));
  } else {
    while (s->tx_off < s->tx_len) {
      unsigned int n = s->tx_len - s->tx_off, room = tcp_sndbuf(s->pcb);
      err_t e;
      if (n > room) n = room;
      if (n > 0xFFFF) n = 0xFFFF;
      if (n == 0) break;
      e = tcp_write(s->pcb, s->tx + s->tx_off, (u16_t)n, TCP_WRITE_FLAG_COPY);
      if (e == ERR_MEM) break;
      if (e != ERR_OK) { reply_error(s->tx_ch, err_text(e)); goto done; }
      s->tx_off += n;
    }
    tcp_output(s->pcb);
    if (s->tx_off < s->tx_len) return;    /* the rest when acknowledged */
    reply_int(s->tx_ch, s->tx_len);
  }
done:
  free(s->tx);
  s->tx = NULL;
  s->tx_ch = -1;
}

static err_t on_recv(void * arg, struct tcp_pcb * pcb, struct pbuf * p, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  (void)pcb;
  if (p == NULL) s->eof = 1;
  else if (err != ERR_OK) { pbuf_free(p); return err; }
  else if (s->rx) pbuf_cat(s->rx, p);
  else s->rx = p;
  serve_recv(s);
  return ERR_OK;
}

static err_t on_sent(void * arg, struct tcp_pcb * pcb, u16_t len) {
  (void)pcb; (void)len;
  serve_send(&socks[IDX(arg)]);
  return ERR_OK;
}

/* lwIP freed the pcb */
static void on_err(void * arg, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  s->pcb = NULL;
  s->err = err;
  if (s->rx_kind == W_CONNECT) {
    reply_error(s->rx_ch, err_text(err));
    s->state = S_FREE;                    /* the client never had it */
    return;
  }
  serve_recv(s);
  serve_send(s);
}

static void setup_pcb(struct tcp_pcb * pcb, int id) {
  tcp_arg(pcb, ARG(id));
  tcp_recv(pcb, on_recv);
  tcp_sent(pcb, on_sent);
  tcp_err(pcb, on_err);
}

static err_t on_connected(void * arg, struct tcp_pcb * pcb, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  (void)pcb; (void)err;
  s->state = S_OPEN;
  reply_int(s->rx_ch, ID(s));
  s->rx_kind = W_NONE;
  s->rx_ch = -1;
  return ERR_OK;
}

static err_t on_accept(void * arg, struct tcp_pcb * pcb, err_t err) {
  struct sock * l = &socks[IDX(arg)];
  struct sock * c;
  int id;
  if (err != ERR_OK || pcb == NULL) return ERR_VAL;
  if (l->rx_kind != W_ACCEPT && l->nbacklog == MAXBACKLOG) {
    tcp_abort(pcb);
    return ERR_ABRT;
  }
  if ((id = alloc_sock()) < 0) { tcp_abort(pcb); return ERR_ABRT; }
  c = &socks[id];
  c->state = S_OPEN;
  c->pcb = pcb;
  ip_addr_copy(c->peer, pcb->remote_ip);
  c->peer_port = pcb->remote_port;
  setup_pcb(pcb, id);
  if (l->rx_kind == W_ACCEPT) {
    reply_accept(l->rx_ch, c);
    l->rx_kind = W_NONE;
    l->rx_ch = -1;
  } else
    l->backlog[l->nbacklog++] = id;
  return ERR_OK;
}

static void close_sock(struct sock * s) {
  int i;
  if (s->pcb) {
    tcp_arg(s->pcb, NULL);
    if (s->state == S_LISTEN) tcp_accept(s->pcb, NULL);
    else {
      tcp_recv(s->pcb, NULL);
      tcp_sent(s->pcb, NULL);
      tcp_err(s->pcb, NULL);
    }
    if (tcp_close(s->pcb) != ERR_OK) tcp_abort(s->pcb);
  }
  if (s->rx) pbuf_free(s->rx);
  if (s->rx_ch >= 0) reply_error(s->rx_ch, "socket closed");
  if (s->tx_ch >= 0) reply_error(s->tx_ch, "socket closed");
  free(s->tx);
  for (i = 0; i < s->nbacklog; i++) close_sock(&socks[s->backlog[i]]);
  s->state = S_FREE;
}

/* ---------------------------------------------------------------- ping */

#define PING_ID 0x4D59           /* "MY" */

struct ping { int ch; u16_t seq; u32_t start, deadline; };
static struct ping pings[MAXPING];
static int nping = 0;
static u16_t ping_seq = 0;
static struct raw_pcb * icmp_pcb;

static void ping_done(int i, const char * error) {
  if (error) reply_error(pings[i].ch, error);
  else reply_int(pings[i].ch, sys_now() - pings[i].start);
  pings[i] = pings[--nping];
}

static u8_t on_icmp(void * arg, struct raw_pcb * pcb, struct pbuf * p,
                    const ip_addr_t * addr) {
  struct icmp_echo_hdr echo;
  struct ip_hdr ip;
  int i;
  (void)arg; (void)pcb; (void)addr;
  if (p->tot_len < sizeof ip) return 0;
  pbuf_copy_partial(p, &ip, sizeof ip, 0);
  if (p->tot_len < IPH_HL_BYTES(&ip) + sizeof echo) return 0;
  pbuf_copy_partial(p, &echo, sizeof echo, IPH_HL_BYTES(&ip));
  if (echo.type != ICMP_ER || echo.id != PP_HTONS(PING_ID)) return 0;
  for (i = 0; i < nping; i++)
    if (pings[i].seq == lwip_ntohs(echo.seqno)) {
      ping_done(i, NULL);
      break;
    }
  pbuf_free(p);
  return 1;                               /* eaten */
}

static void do_ping(int ch, const char * host, long long timeout) {
  ip_addr_t addr;
  struct pbuf * p;
  struct icmp_echo_hdr * echo;
  unsigned int i, size = sizeof(struct icmp_echo_hdr) + 32;

  if (!ipaddr_aton(host, &addr)) { reply_error(ch, "not an address"); return; }
  if (nping == MAXPING) { reply_error(ch, "too many pings"); return; }
  p = pbuf_alloc(PBUF_IP, (u16_t)size, PBUF_RAM);
  if (p == NULL) { reply_error(ch, "out of memory"); return; }
  echo = p->payload;
  ICMPH_TYPE_SET(echo, ICMP_ECHO);
  ICMPH_CODE_SET(echo, 0);
  echo->id = PP_HTONS(PING_ID);
  echo->seqno = lwip_htons(++ping_seq);
  for (i = sizeof *echo; i < size; i++) ((char *)echo)[i] = (char)i;
  echo->chksum = 0;
  echo->chksum = inet_chksum(echo, (u16_t)size);
  pings[nping].ch = ch;
  pings[nping].seq = ping_seq;
  pings[nping].start = sys_now();
  pings[nping].deadline = sys_now() + (timeout > 0 ? (u32_t)timeout : 1000);
  nping++;
  raw_sendto(icmp_pcb, p, &addr);
  pbuf_free(p);
}

static void ping_timeouts(void) {
  int i;
  for (i = 0; i < nping; i++)
    if ((s32_t)(sys_now() - pings[i].deadline) >= 0) {
      ping_done(i, "timeout");
      i--;
    }
}

/* ---------------------------------------------------------------- DNS */

static void on_resolved(const char * name, const ip_addr_t * addr, void * arg) {
  (void)name;
  if (addr == NULL) reply_error(IDX(arg), "host not found");
  else {
    const char * a = ipaddr_ntoa(addr);
    reply_string(IDX(arg), a, strlen(a));
  }
}

static void do_resolve(int ch, const char * name) {
  ip_addr_t addr;
  err_t e = dns_gethostbyname(name, &addr, on_resolved, ARG(ch));
  if (e == ERR_OK) on_resolved(name, &addr, ARG(ch));
  else if (e != ERR_INPROGRESS) reply_error(ch, "cannot resolve");
}

/* ---------------------------------------------------------------- requests */

static void do_config(int ch) {
  wire_writer w;
  char m[18];
  sprintf(m, "%02x:%02x:%02x:%02x:%02x:%02x",
          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_cstring(&w, m);
  wire_put_cstring(&w, ip4addr_ntoa(netif_ip4_addr(&netif)));
  wire_put_cstring(&w, ip4addr_ntoa(netif_ip4_netmask(&netif)));
  wire_put_cstring(&w, ip4addr_ntoa(netif_ip4_gw(&netif)));
  wire_put_cstring(&w, ipaddr_ntoa(dns_getserver(0)));
  send_reply(ch, &w);
}

static void do_connect(int ch, const char * host, long long port) {
  ip_addr_t addr;
  struct sock * s;
  int id;
  err_t e;
  if (!ipaddr_aton(host, &addr)) { reply_error(ch, "not an address"); return; }
  if (port <= 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if ((id = alloc_sock()) < 0) { reply_error(ch, "too many sockets"); return; }
  s = &socks[id];
  if ((s->pcb = tcp_new()) == NULL) { reply_error(ch, "out of memory"); return; }
  s->state = S_CONNECTING;
  s->rx_kind = W_CONNECT;
  s->rx_ch = ch;
  ip_addr_copy(s->peer, addr);
  s->peer_port = (u16_t)port;
  setup_pcb(s->pcb, id);
  e = tcp_connect(s->pcb, &addr, (u16_t)port, on_connected);
  if (e != ERR_OK) {
    tcp_abort(s->pcb);                    /* calls on_err: replies, frees */
    if (s->state != S_FREE) { s->state = S_FREE; reply_error(ch, err_text(e)); }
  }
}

static void do_listen(int ch, long long port) {
  struct tcp_pcb * pcb, * lpcb;
  struct sock * s;
  int id;
  err_t e;
  if (port <= 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if ((id = alloc_sock()) < 0) { reply_error(ch, "too many sockets"); return; }
  if ((pcb = tcp_new()) == NULL) { reply_error(ch, "out of memory"); return; }
  if ((e = tcp_bind(pcb, IP_ANY_TYPE, (u16_t)port)) != ERR_OK) {
    tcp_close(pcb);
    reply_error(ch, err_text(e));
    return;
  }
  if ((lpcb = tcp_listen(pcb)) == NULL) {
    tcp_close(pcb);
    reply_error(ch, "out of memory");
    return;
  }
  s = &socks[id];
  s->state = S_LISTEN;
  s->pcb = lpcb;
  tcp_arg(lpcb, ARG(id));
  tcp_accept(lpcb, on_accept);
  reply_int(ch, id);
}

static void do_accept(int ch, long long id) {
  struct sock * l = get_sock(id);
  int i;
  if (l == NULL || l->state != S_LISTEN) { reply_error(ch, "not a listening socket"); return; }
  if (l->rx_ch >= 0) { reply_error(ch, "an Accept is already waiting"); return; }
  if (l->nbacklog > 0) {
    reply_accept(ch, &socks[l->backlog[0]]);
    for (i = 1; i < l->nbacklog; i++) l->backlog[i - 1] = l->backlog[i];
    l->nbacklog--;
    return;
  }
  l->rx_kind = W_ACCEPT;
  l->rx_ch = ch;
  start_wait(l);
}

static void do_send(int ch, long long id, const char * data, unsigned int n) {
  struct sock * s = get_sock(id);
  if (s == NULL || s->state != S_OPEN) { reply_error(ch, "not a connected socket"); return; }
  if (s->tx_ch >= 0) { reply_error(ch, "a Send is already waiting"); return; }
  if ((s->tx = malloc(n ? n : 1)) == NULL) { reply_error(ch, "out of memory"); return; }
  memcpy(s->tx, data, n);
  s->tx_len = n;
  s->tx_off = 0;
  s->tx_ch = ch;
  serve_send(s);
}

static void do_recv(int ch, long long id, long long max) {
  struct sock * s = get_sock(id);
  if (s == NULL || s->state != S_OPEN) { reply_error(ch, "not a connected socket"); return; }
  if (s->rx_ch >= 0) { reply_error(ch, "a Recv is already waiting"); return; }
  if (max < 1) { reply_error(ch, "bad size"); return; }
  s->rx_kind = W_RECV;
  s->rx_ch = ch;
  s->rx_max = max > MAXRECV ? MAXRECV : (int)max;
  start_wait(s);
  serve_recv(s);
}

/* a Recv or Accept starts waiting */
static void start_wait(struct sock * s) {
  s->rx_deadline = s->timeout ? sys_now() + s->timeout : 0;
}

/* the ones that waited too long */
static void socket_timeouts(void) {
  int i;
  for (i = 0; i < MAXSOCK; i++) {
    struct sock * s = &socks[i];
    if (s->state != S_FREE && s->rx_ch >= 0 &&
        (s->rx_kind == W_RECV || s->rx_kind == W_ACCEPT) && s->rx_deadline &&
        (s32_t)(sys_now() - s->rx_deadline) >= 0) {
      reply_error(s->rx_ch, "timeout");
      s->rx_ch = -1;
      s->rx_kind = W_NONE;
    }
  }
}

static void do_set_timeout(int ch, long long id, long long ms) {
  struct sock * s = get_sock(id);
  if (s == NULL) { reply_error(ch, "not a socket"); return; }
  if (ms < 0 || ms > 86400000) { reply_error(ch, "bad timeout"); return; }
  s->timeout = (u32_t)ms;
  reply_unit(ch);
}

static void do_close(int ch, long long id) {
  struct sock * s = get_sock(id);
  if (s == NULL) { reply_error(ch, "not a socket"); return; }
  close_sock(s);
  reply_unit(ch);
}

static void handle(int ch, const char * msg, unsigned int len) {
  wire_reader r;
  char a[256];
  long long kind, x, y;
  const char * data;
  unsigned int n;

  wire_reader_init(&r, msg, len);
  if (wire_check_protocol(&r, PROTOCOL) < 0) {
    reply_error(ch, "protocol: netd speaks " PROTOCOL);
    return;
  }
#define END() if (!wire_at_end(&r)) { reply_error(ch, "malformed request"); return; }
  kind = wire_get_int(&r);
  switch (kind) {
  case 0: END(); do_config(ch); break;
  case 1: wire_get_cstring(&r, a, sizeof a); x = wire_get_int(&r); END();
    do_ping(ch, a, x); break;
  case 2: wire_get_cstring(&r, a, sizeof a); END(); do_resolve(ch, a); break;
  case 3: wire_get_cstring(&r, a, sizeof a); x = wire_get_int(&r); END();
    do_connect(ch, a, x); break;
  case 4: x = wire_get_int(&r); END(); do_listen(ch, x); break;
  case 5: x = wire_get_int(&r); END(); do_accept(ch, x); break;
  case 6: x = wire_get_int(&r); data = wire_get_string(&r, &n); END();
    do_send(ch, x, data, n); break;
  case 7: x = wire_get_int(&r); y = wire_get_int(&r); END();
    do_recv(ch, x, y); break;
  case 8: x = wire_get_int(&r); END(); do_close(ch, x); break;
  case 9: x = wire_get_int(&r); y = wire_get_int(&r); END();
    do_set_timeout(ch, x, y); break;
  default: reply_error(ch, "unknown request"); break;
  }
#undef END
}

/* ---------------------------------------------------------------- the loop */

struct request {
  int ch;
  char * msg;
  unsigned int len;
  struct request * next;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static struct request * queue, ** queue_end = &queue;
static int interrupted = 0;

/* the card's interrupts: wake the main loop */
static void * irq_thread(void * arg) {
  int sem = IDX(arg);
  for (;;) {
    if (mynos_P(sem) < 0) return NULL;
    pthread_mutex_lock(&lock);
    interrupted = 1;
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
  }
  return NULL;
}

/* the requests: received here, handled by the main loop */
static void * listener(void * arg) {
  int port = IDX(arg);
  for (;;) {
    mynos_msg_t * m;
    struct request * r;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    /* a client that connects and sends nothing must not stop us */
    if (mynos_recv(ch, &m, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    r = malloc(sizeof *r);
    if (r) r->msg = malloc(m->size ? m->size : 1);
    if (r == NULL || r->msg == NULL) {
      free(r);
      mynos_freeMsg(&m);
      mynos_freeChannel(ch);
      continue;
    }
    memcpy(r->msg, m->start, m->size);
    r->len = m->size;
    r->ch = ch;
    r->next = NULL;
    mynos_freeMsg(&m);
    pthread_mutex_lock(&lock);
    *queue_end = r;
    queue_end = &r->next;
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
  }
  return NULL;
}

int main(void) {
  pthread_t t;
  int port;

  if (ne2k_init(NE2K_IOBASE, mac) < 0) {
    mynos_log("netd: no NE2000 card at 0x%x\n", NE2K_IOBASE);
    return 1;
  }
  mynos_log("netd: NE2000 at 0x%x, %02x:%02x:%02x:%02x:%02x:%02x\n",
            NE2K_IOBASE, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

  lwip_init();
  netif_add(&netif, IP4_ADDR_ANY4, IP4_ADDR_ANY4, IP4_ADDR_ANY4, NULL,
            netif_setup, ethernet_input);
  netif_set_default(&netif);
  netif_set_status_callback(&netif, status_changed);
  netif_set_up(&netif);
  netif_set_link_up(&netif);
  started = sys_now();
  dhcp_start(&netif);

  {
    int sem = mynos_driverRegister("ne2k", NE2K_IRQ, NULL, NULL);
    if (sem < 0)
      mynos_log("netd: no IRQ %d (%d): polling every %d ms\n", NE2K_IRQ, sem, WAKE_MS);
    else {
      mynos_enableIrq(NE2K_IRQ);
      pthread_create(&t, NULL, irq_thread, ARG(sem));
    }
  }

  icmp_pcb = raw_new(IP_PROTO_ICMP);
  raw_recv(icmp_pcb, on_icmp, NULL);
  raw_bind(icmp_pcb, IP_ADDR_ANY);

  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("netd: cannot register (%d)\n", port);
    return 1;
  }
  pthread_create(&t, NULL, listener, ARG(port));

  for (;;) {
    struct request * r = NULL;
    struct timespec until;

    pthread_mutex_lock(&lock);
    if ((queue == NULL || !ready) && !interrupted) {
      clock_gettime(CLOCK_REALTIME, &until);
      until.tv_nsec += WAKE_MS * 1000000L;
      if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
      pthread_cond_timedwait(&wake, &lock, &until);
    }
    if (ready) {                          /* requests wait for an address */
      r = queue;
      queue = NULL;
      queue_end = &queue;
    }
    interrupted = 0;
    pthread_mutex_unlock(&lock);

    poll_card();
    sys_check_timeouts();
    check_address();
    ping_timeouts();
    socket_timeouts();
    while (r) {
      struct request * next = r->next;
      handle(r->ch, r->msg, r->len);
      poll_card();
      free(r->msg);
      free(r);
      r = next;
    }
  }
}

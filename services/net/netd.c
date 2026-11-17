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
 *
 * Sockets (TCP, TLS, UDP) belong to the process that made them, known
 * from the request's channel (mynos_channelPeer); once a second, the
 * sockets of processes that ended are closed
 * (doc/decisions/identity-and-permissions.md).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <mynos.h>
#include <mynos_wire.h>

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "lwip/tcp.h"
#include "lwip/altcp.h"
#include "lwip/altcp_tcp.h"
#include "lwip/altcp_tls.h"
#include "lwip/raw.h"
#include "lwip/udp.h"
#include "lwip/dns.h"
#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "lwip/inet_chksum.h"
#include "lwip/prot/icmp.h"
#include "lwip/prot/ip4.h"
#include "netif/ethernet.h"
#include "ne2k.h"

#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"
#include "psa/crypto.h"

#define SERVICE     "net"
#define PROTOCOL    "net/1"
#define NE2K_IOBASE 0x300
#define NE2K_IRQ    9         /* QEMU's ne2k_isa: tools/run-qemu.sh */
#define WAKE_MS     100       /* the loop runs at least this often */
#define MAXSOCK     64
#define MAXBACKLOG  8
#define MAXRECV     16384
#define MAXPING     8
#define MAXDGRAMS   32        /* datagrams kept per UDP socket */
#define MAXDGRAM    8192      /* bytes in a datagram sent */
#define OWNER_CHECK 1000      /* ms between checks of the owners */
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

enum { S_FREE, S_CONNECTING, S_OPEN, S_LISTEN, S_UDP };
enum { W_NONE, W_CONNECT, W_RECV, W_ACCEPT, W_RECVFROM };

/* a datagram received, not read yet */
struct dgram {
  struct pbuf * p;
  ip_addr_t addr;
  u16_t port;
  struct dgram * next;
};

struct sock {
  int state;
  int owner;                    /* the pid of the process that made it */
  int rx_caller;                /* who waits in Accept: the new socket's owner */
  struct altcp_pcb * pcb;       /* NULL once lwIP freed it (an error) */
  int tls;                      /* TLS over TCP (Connect_tls) */
  char host[256];               /* Connect_tls: the server's name */
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
  /* UDP */
  struct udp_pcb * udp;
  struct dgram * dgrams;
  int ndgrams;
};

static struct sock socks[MAXSOCK];

static void start_wait(struct sock * s);

/* the pid of the process whose request is being handled (channelPeer of
   its channel, taken by the listener thread) */
static int current_caller = -1;

/* a free socket, the current caller's */
static int alloc_sock(void) {
  int i;
  for (i = 0; i < MAXSOCK; i++)
    if (socks[i].state == S_FREE) {
      memset(&socks[i], 0, sizeof socks[i]);
      socks[i].rx_ch = socks[i].tx_ch = -1;
      socks[i].owner = current_caller;
      return i;
    }
  return -1;
}

/* a socket of the caller's (doc/decisions/identity-and-permissions.md): NULL
   and an error message if there is none of that number, or it is another
   process's */
static const char * sock_error;

static struct sock * get_sock(long long id, int caller) {
  if (id < 0 || id >= MAXSOCK || socks[id].state == S_FREE) {
    sock_error = "not a socket";
    return NULL;
  }
  if (socks[id].owner != caller) {
    sock_error = "not your socket";
    return NULL;
  }
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
    if (s->pcb) altcp_recved(s->pcb, (u16_t)n);
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
      unsigned int n = s->tx_len - s->tx_off, room = altcp_sndbuf(s->pcb);
      err_t e;
      if (n > room) n = room;
      if (n > 0xFFFF) n = 0xFFFF;
      if (n == 0) break;
      e = altcp_write(s->pcb, s->tx + s->tx_off, (u16_t)n, TCP_WRITE_FLAG_COPY);
      if (e == ERR_MEM) break;
      if (e != ERR_OK) { reply_error(s->tx_ch, err_text(e)); goto done; }
      s->tx_off += n;
    }
    altcp_output(s->pcb);
    if (s->tx_off < s->tx_len) return;    /* the rest when acknowledged */
    reply_int(s->tx_ch, s->tx_len);
  }
done:
  free(s->tx);
  s->tx = NULL;
  s->tx_ch = -1;
}

static err_t on_recv(void * arg, struct altcp_pcb * pcb, struct pbuf * p, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  (void)pcb;
  if (p == NULL) s->eof = 1;
  else if (err != ERR_OK) { pbuf_free(p); return err; }
  else if (s->rx) pbuf_cat(s->rx, p);
  else s->rx = p;
  serve_recv(s);
  return ERR_OK;
}

static err_t on_sent(void * arg, struct altcp_pcb * pcb, u16_t len) {
  (void)pcb; (void)len;
  serve_send(&socks[IDX(arg)]);
  return ERR_OK;
}

/* ---------------------------------------------------------------- TLS */

/* altcp_tls_mbedtls.c (MyNOS's change): why the last handshake failed */
extern int altcp_mbedtls_handshake_error;
extern uint32_t altcp_mbedtls_verify_result;

static const char * tls_error(err_t err) {
  static char text[400];
  char info[300], * p;
  int e = altcp_mbedtls_handshake_error;
  uint32_t v = altcp_mbedtls_verify_result;
  altcp_mbedtls_handshake_error = 0;
  altcp_mbedtls_verify_result = 0;
  if (e == 0) return err_text(err);       /* TCP's, not TLS's */
  if (e == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED && v != 0 && v != (uint32_t)-1) {
    /* one line per reason: joined */
    mbedtls_x509_crt_verify_info(info, sizeof info, "", v);
    for (p = info; *p; p++) if (*p == '\n') *p = p[1] ? ';' : 0;
    snprintf(text, sizeof text, "TLS: bad certificate: %s", info);
  } else {
    mbedtls_strerror(e, info, sizeof info);
    snprintf(text, sizeof text, "TLS: %s", info);
  }
  return text;
}

/* lwIP freed the pcb */
static void on_err(void * arg, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  s->pcb = NULL;
  s->err = err;
  if (s->rx_kind == W_CONNECT) {
    reply_error(s->rx_ch, s->tls ? tls_error(err) : err_text(err));
    s->state = S_FREE;                    /* the client never had it */
    return;
  }
  serve_recv(s);
  serve_send(s);
}

static void setup_pcb(struct altcp_pcb * pcb, int id) {
  altcp_arg(pcb, ARG(id));
  altcp_recv(pcb, on_recv);
  altcp_sent(pcb, on_sent);
  altcp_err(pcb, on_err);
}

static err_t on_connected(void * arg, struct altcp_pcb * pcb, err_t err) {
  struct sock * s = &socks[IDX(arg)];
  (void)pcb; (void)err;
  s->state = S_OPEN;
  reply_int(s->rx_ch, ID(s));
  s->rx_kind = W_NONE;
  s->rx_ch = -1;
  return ERR_OK;
}

static err_t on_accept(void * arg, struct altcp_pcb * pcb, err_t err) {
  struct sock * l = &socks[IDX(arg)];
  struct sock * c;
  int id;
  if (err != ERR_OK || pcb == NULL) return ERR_VAL;
  if (l->rx_kind != W_ACCEPT && l->nbacklog == MAXBACKLOG) {
    altcp_abort(pcb);
    return ERR_ABRT;
  }
  if ((id = alloc_sock()) < 0) { altcp_abort(pcb); return ERR_ABRT; }
  c = &socks[id];
  c->state = S_OPEN;
  c->pcb = pcb;
  /* the process that accepts it; until then, the listener's */
  c->owner = l->rx_kind == W_ACCEPT ? l->rx_caller : l->owner;
  altcp_get_tcp_addrinfo(pcb, 0, &c->peer, &c->peer_port);
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
    altcp_arg(s->pcb, NULL);
    if (s->state == S_LISTEN) altcp_accept(s->pcb, NULL);
    else {
      altcp_recv(s->pcb, NULL);
      altcp_sent(s->pcb, NULL);
      altcp_err(s->pcb, NULL);
    }
    if (altcp_close(s->pcb) != ERR_OK) altcp_abort(s->pcb);
  }
  if (s->udp) udp_remove(s->udp);
  while (s->dgrams) {
    struct dgram * d = s->dgrams;
    s->dgrams = d->next;
    pbuf_free(d->p);
    free(d);
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
  if ((s->pcb = altcp_tcp_new()) == NULL) { reply_error(ch, "out of memory"); return; }
  s->state = S_CONNECTING;
  s->rx_kind = W_CONNECT;
  s->rx_ch = ch;
  ip_addr_copy(s->peer, addr);
  s->peer_port = (u16_t)port;
  setup_pcb(s->pcb, id);
  e = altcp_connect(s->pcb, &addr, (u16_t)port, on_connected);
  if (e != ERR_OK) {
    altcp_abort(s->pcb);                    /* calls on_err: replies, frees */
    if (s->state != S_FREE) { s->state = S_FREE; reply_error(ch, err_text(e)); }
  }
}

/* The authorities netd trusts: the system's list (Mozilla's, on the RAM
   disk) and the user's own, if any. Read at the first Connect_tls. */
#define CA_SYSTEM "/cacert.pem"
#define CA_USER   "/disk/ca.pem"

static struct altcp_tls_config * tls_conf;

/* a file at the end of buf (NUL-terminated) */
static char * append_file(const char * path, char * buf, size_t * len) {
  int fd = open(path, O_RDONLY);
  ssize_t n;
  if (fd < 0) return buf;
  for (;;) {
    char * b = realloc(buf, *len + 4096 + 1);
    if (b == NULL) break;
    buf = b;
    if ((n = read(fd, buf + *len, 4096)) <= 0) break;
    *len += n;
  }
  close(fd);
  if (buf) buf[*len] = 0;
  return buf;
}

static struct altcp_tls_config * tls_config(void) {
  size_t len = 0;
  char * pem;
  if (tls_conf) return tls_conf;
  pem = append_file(CA_SYSTEM, NULL, &len);
  pem = append_file(CA_USER, pem, &len);
  if (pem == NULL || len == 0) { free(pem); return NULL; }
  tls_conf = altcp_tls_create_config_client((const u8_t *)pem, len + 1);
  mynos_log("netd: TLS: %u KB of trusted certificates%s\n",
            (unsigned)(len / 1024), tls_conf ? "" : ", not usable");
  free(pem);
  return tls_conf;
}

/* the server's address is known: connect, the handshake follows */
static void tls_start(struct sock * s, const ip_addr_t * addr) {
  int ch = s->rx_ch;
  err_t e;
  s->pcb = altcp_tls_new(tls_conf, IPADDR_TYPE_V4);
  if (s->pcb == NULL) { s->state = S_FREE; reply_error(ch, "out of memory"); return; }
  /* the name for the server (SNI) and for checking its certificate */
  if (mbedtls_ssl_set_hostname(altcp_tls_context(s->pcb), s->host) != 0) {
    altcp_abort(s->pcb);
    s->state = S_FREE;
    reply_error(ch, "TLS: bad host name");
    return;
  }
  ip_addr_copy(s->peer, *addr);
  setup_pcb(s->pcb, ID(s));
  e = altcp_connect(s->pcb, addr, s->peer_port, on_connected);
  if (e != ERR_OK) {
    altcp_abort(s->pcb);                  /* calls on_err: replies, frees */
    if (s->state != S_FREE) { s->state = S_FREE; reply_error(ch, err_text(e)); }
  }
}

static void on_tls_resolved(const char * name, const ip_addr_t * addr, void * arg) {
  struct sock * s = &socks[IDX(arg)];
  (void)name;
  if (addr) tls_start(s, addr);
  else { s->state = S_FREE; reply_error(s->rx_ch, "host not found"); }
}

static void do_connect_tls(int ch, const char * host, long long port) {
  ip_addr_t addr;
  struct sock * s;
  int id;
  err_t e;
  if (port <= 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if (strlen(host) >= sizeof s->host) { reply_error(ch, "host name too long"); return; }
  if (tls_config() == NULL) {
    reply_error(ch, "TLS: no trusted certificates (" CA_SYSTEM ", " CA_USER ")");
    return;
  }
  if ((id = alloc_sock()) < 0) { reply_error(ch, "too many sockets"); return; }
  s = &socks[id];
  s->state = S_CONNECTING;
  s->rx_kind = W_CONNECT;
  s->rx_ch = ch;
  s->tls = 1;
  s->peer_port = (u16_t)port;
  strcpy(s->host, host);
  e = dns_gethostbyname(host, &addr, on_tls_resolved, ARG(id));
  if (e == ERR_OK) tls_start(s, &addr);
  else if (e != ERR_INPROGRESS) { s->state = S_FREE; reply_error(ch, "cannot resolve"); }
}

static void do_listen(int ch, long long port) {
  struct altcp_pcb * pcb, * lpcb;
  struct sock * s;
  int id;
  err_t e;
  if (port <= 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if ((id = alloc_sock()) < 0) { reply_error(ch, "too many sockets"); return; }
  if ((pcb = altcp_tcp_new()) == NULL) { reply_error(ch, "out of memory"); return; }
  if ((e = altcp_bind(pcb, IP_ANY_TYPE, (u16_t)port)) != ERR_OK) {
    altcp_close(pcb);
    reply_error(ch, err_text(e));
    return;
  }
  if ((lpcb = altcp_listen(pcb)) == NULL) {
    altcp_close(pcb);
    reply_error(ch, "out of memory");
    return;
  }
  s = &socks[id];
  s->state = S_LISTEN;
  s->pcb = lpcb;
  altcp_arg(lpcb, ARG(id));
  altcp_accept(lpcb, on_accept);
  reply_int(ch, id);
}

static void do_accept(int ch, long long id) {
  struct sock * l = get_sock(id, current_caller);
  int i;
  if (l == NULL) { reply_error(ch, sock_error); return; }
  if (l->state != S_LISTEN) { reply_error(ch, "not a listening socket"); return; }
  if (l->rx_ch >= 0) { reply_error(ch, "an Accept is already waiting"); return; }
  if (l->nbacklog > 0) {
    socks[l->backlog[0]].owner = current_caller;
    reply_accept(ch, &socks[l->backlog[0]]);
    for (i = 1; i < l->nbacklog; i++) l->backlog[i - 1] = l->backlog[i];
    l->nbacklog--;
    return;
  }
  l->rx_kind = W_ACCEPT;
  l->rx_ch = ch;
  l->rx_caller = current_caller;
  start_wait(l);
}

static void do_send(int ch, long long id, const char * data, unsigned int n) {
  struct sock * s = get_sock(id, current_caller);
  if (s == NULL) { reply_error(ch, sock_error); return; }
  if (s->state != S_OPEN) { reply_error(ch, "not a connected socket"); return; }
  if (s->tx_ch >= 0) { reply_error(ch, "a Send is already waiting"); return; }
  if ((s->tx = malloc(n ? n : 1)) == NULL) { reply_error(ch, "out of memory"); return; }
  memcpy(s->tx, data, n);
  s->tx_len = n;
  s->tx_off = 0;
  s->tx_ch = ch;
  serve_send(s);
}

static void do_recv(int ch, long long id, long long max) {
  struct sock * s = get_sock(id, current_caller);
  if (s == NULL) { reply_error(ch, sock_error); return; }
  if (s->state != S_OPEN) { reply_error(ch, "not a connected socket"); return; }
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
        (s->rx_kind == W_RECV || s->rx_kind == W_ACCEPT ||
         s->rx_kind == W_RECVFROM) && s->rx_deadline &&
        (s32_t)(sys_now() - s->rx_deadline) >= 0) {
      reply_error(s->rx_ch, "timeout");
      s->rx_ch = -1;
      s->rx_kind = W_NONE;
    }
  }
}

static void do_set_timeout(int ch, long long id, long long ms) {
  struct sock * s = get_sock(id, current_caller);
  if (s == NULL) { reply_error(ch, sock_error); return; }
  if (ms < 0 || ms > 86400000) { reply_error(ch, "bad timeout"); return; }
  s->timeout = (u32_t)ms;
  reply_unit(ch);
}

static void do_close(int ch, long long id) {
  struct sock * s = get_sock(id, current_caller);
  if (s == NULL) { reply_error(ch, sock_error); return; }
  close_sock(s);
  reply_unit(ch);
}

/* the sockets of processes that ended: closed (their listening ports are
   free again). Every OWNER_CHECK ms, one processInfo per owner. */
static void owner_checks(void) {
  static u32_t last = 0;
  int i, j;
  if (sys_now() - last < OWNER_CHECK) return;
  last = sys_now();
  for (i = 0; i < MAXSOCK; i++) {
    int owner = socks[i].owner, info;
    if (socks[i].state == S_FREE || socks[i].owner < 0) continue;
    /* the owner's first socket: check it once, close all its sockets */
    for (j = 0; j < i; j++)
      if (socks[j].state != S_FREE && socks[j].owner == owner) break;
    if (j < i) continue;
    info = mynos_processInfo(owner);
    if (info >= 0 && (info & MYNOS_PROC_ALIVE)) continue;
    for (j = i; j < MAXSOCK; j++)
      if (socks[j].state != S_FREE && socks[j].owner == owner) {
        /* a listener's backlog goes with it */
        close_sock(&socks[j]);
      }
  }
}

/* ---------------------------------------------------------------- UDP */

static void reply_datagram(int ch, struct dgram * d, int max) {
  wire_writer w;
  unsigned int n = d->p->tot_len;
  char * buf;
  if (n > (unsigned int)max) n = max;            /* the rest is lost */
  if ((buf = malloc(n ? n : 1)) == NULL) { reply_error(ch, "out of memory"); return; }
  pbuf_copy_partial(d->p, buf, (u16_t)n, 0);
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_cstring(&w, ipaddr_ntoa(&d->addr));
  wire_put_int(&w, d->port);
  wire_put_string(&w, buf, n);
  send_reply(ch, &w);
  free(buf);
}

/* a waiting Recv_from: the first datagram */
static void serve_recvfrom(struct sock * s) {
  struct dgram * d = s->dgrams;
  if (s->rx_kind != W_RECVFROM || d == NULL) return;
  s->dgrams = d->next;
  s->ndgrams--;
  reply_datagram(s->rx_ch, d, s->rx_max);
  pbuf_free(d->p);
  free(d);
  s->rx_kind = W_NONE;
  s->rx_ch = -1;
}

static void on_udp(void * arg, struct udp_pcb * pcb, struct pbuf * p,
                   const ip_addr_t * addr, u16_t port) {
  struct sock * s = &socks[IDX(arg)];
  struct dgram * d, ** last;
  (void)pcb;
  if (s->ndgrams == MAXDGRAMS || (d = malloc(sizeof *d)) == NULL) {
    pbuf_free(p);                         /* full: dropped, as UDP may */
    return;
  }
  d->p = p;
  ip_addr_copy(d->addr, *addr);
  d->port = port;
  d->next = NULL;
  for (last = &s->dgrams; *last; last = &(*last)->next) ;
  *last = d;
  s->ndgrams++;
  serve_recvfrom(s);
}

static void do_udp_bind(int ch, long long port) {
  struct sock * s;
  int id;
  err_t e;
  if (port < 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if ((id = alloc_sock()) < 0) { reply_error(ch, "too many sockets"); return; }
  s = &socks[id];
  if ((s->udp = udp_new()) == NULL) { reply_error(ch, "out of memory"); return; }
  if ((e = udp_bind(s->udp, IP_ANY_TYPE, (u16_t)port)) != ERR_OK) {
    udp_remove(s->udp);
    s->udp = NULL;
    reply_error(ch, err_text(e));
    return;
  }
  s->state = S_UDP;
  udp_recv(s->udp, on_udp, ARG(id));
  reply_int(ch, id);
}

static void do_send_to(int ch, long long id, const char * host, long long port,
                       const char * data, unsigned int n) {
  struct sock * s = get_sock(id, current_caller);
  ip_addr_t addr;
  struct pbuf * p;
  err_t e;
  if (s == NULL) { reply_error(ch, sock_error); return; }
  if (s->state != S_UDP) { reply_error(ch, "not a UDP socket"); return; }
  if (!ipaddr_aton(host, &addr)) { reply_error(ch, "not an address"); return; }
  if (port <= 0 || port > 65535) { reply_error(ch, "bad port"); return; }
  if (n > MAXDGRAM) { reply_error(ch, "datagram too large"); return; }
  if ((p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)n, PBUF_RAM)) == NULL) {
    reply_error(ch, "out of memory");
    return;
  }
  pbuf_take(p, data, (u16_t)n);
  e = udp_sendto(s->udp, p, &addr, (u16_t)port);
  pbuf_free(p);
  if (e != ERR_OK) reply_error(ch, err_text(e));
  else reply_int(ch, n);
}

static void do_recv_from(int ch, long long id, long long max) {
  struct sock * s = get_sock(id, current_caller);
  if (s == NULL) { reply_error(ch, sock_error); return; }
  if (s->state != S_UDP) { reply_error(ch, "not a UDP socket"); return; }
  if (s->rx_ch >= 0) { reply_error(ch, "a Recv_from is already waiting"); return; }
  if (max < 1) { reply_error(ch, "bad size"); return; }
  s->rx_kind = W_RECVFROM;
  s->rx_ch = ch;
  s->rx_max = max > MAXRECV ? MAXRECV : (int)max;
  start_wait(s);
  serve_recvfrom(s);
}

/* the description of "net/1", for Ipc.describe (doc/decisions/llm.md):
   the same as Net.Protocol.requests (mynos-lib/ocaml/net.ml), which the
   network test checks; the case of each request is its index */
static const wire_request_doc requests[] = {
  { 1, "config", "U", "(mac:S,address:S,(netmask:S,gateway:S,dns:S))",
    "The network's configuration (by DHCP)." },
  { 1, "ping", "(address:S,timeout_ms:I)", "I",
    "Ping an address (IPv4, dotted): the round trip time in ms." },
  { 1, "resolve", "name:S", "S", "A host name's IPv4 address (DNS)." },
  { 0, "connect", "(address:S,port:I)", "I",
    "A TCP connection to an address and port: its socket." },
  { 0, "listen", "port:I", "I", "Listen on a TCP port: a listening socket." },
  { 0, "accept", "socket:I", "(socket:I,address:S,port:I)",
    "Wait for a connection on a listening socket: its socket, and the "
    "peer's address and port." },
  { 0, "send", "(socket:I,data:S)", "I",
    "Send all of these bytes on a socket: their number." },
  { 0, "recv", "(socket:I,max:I)", "S",
    "Receive at most max bytes (up to 16384) from a socket; empty at the "
    "end. Waits." },
  { 0, "close", "socket:I", "U", "Close a socket." },
  { 0, "set_timeout", "(socket:I,ms:I)", "U",
    "A recv or accept on this socket that waits longer than ms fails with "
    "\"timeout\" (0: wait forever)." },
  { 0, "connect_tls", "(host:S,port:I)", "I",
    "A TCP connection with TLS to a host (a name, or an address) and port, "
    "the server's certificate checked: its socket. send and recv then "
    "carry the clear bytes." },
  { 0, "udp_bind", "port:I", "I", "A UDP socket on a port (0: any)." },
  { 0, "send_to", "((socket:I,address:S),(port:I,data:S))", "I",
    "Send one UDP datagram: its size." },
  { 0, "recv_from", "(socket:I,max:I)", "(address:S,port:I,data:S)",
    "Receive one UDP datagram (at most max bytes): the sender's address "
    "and port, and the data. Waits." },
};

static void describe(int ch) {
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, PROTOCOL,
    "The network (TCP/IP over the NE2000 card; netd, in C): addresses, DNS, "
    "TCP connections (also with TLS) and listening sockets, UDP. Sockets "
    "are numbers and belong to the process that made them.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(ch, &w);
}

static void handle(int ch, int caller, const char * msg, unsigned int len) {
  wire_reader r;
  char a[256];
  long long kind, x, y;
  const char * data;
  unsigned int n;

  current_caller = caller;
  wire_reader_init(&r, msg, len);
  {
    unsigned int n;
    const char * id = wire_get_string(&r, &n);
    if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n)
        && wire_at_end(&r)) {
      describe(ch);
      return;
    }
    if (r.error || n != strlen(PROTOCOL) || memcmp(id, PROTOCOL, n)) {
      reply_error(ch, "protocol: netd speaks " PROTOCOL);
      return;
    }
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
  case 10: wire_get_cstring(&r, a, sizeof a); x = wire_get_int(&r); END();
    do_connect_tls(ch, a, x); break;
  case 11: x = wire_get_int(&r); END(); do_udp_bind(ch, x); break;
  case 12: x = wire_get_int(&r); wire_get_cstring(&r, a, sizeof a);
    y = wire_get_int(&r); data = wire_get_string(&r, &n); END();
    do_send_to(ch, x, a, y, data, n); break;
  case 13: x = wire_get_int(&r); y = wire_get_int(&r); END();
    do_recv_from(ch, x, y); break;
  default: reply_error(ch, "unknown request"); break;
  }
#undef END
}

/* ---------------------------------------------------------------- the loop */

struct request {
  int ch;
  int caller;                   /* the pid at the other end */
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
    r->caller = mynos_channelPeer(ch);
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

  /* mbedTLS's cryptography (PSA): its random numbers come from the
     kernel's (getrandom) */
  if (psa_crypto_init() != PSA_SUCCESS)
    mynos_log("netd: no cryptography: TLS will fail\n");

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
    owner_checks();
    while (r) {
      struct request * next = r->next;
      handle(r->ch, r->caller, r->msg, r->len);
      poll_card();
      free(r->msg);
      free(r);
      r = next;
    }
  }
}

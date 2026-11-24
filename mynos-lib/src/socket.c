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
 * BSD sockets for C programs (mynos-t9l), over the network service netd
 * (protocol net/1: services/net/netd.c), as fileio.c puts files over the
 * file services. They replace the C library's at static link time (the
 * kernel has no socket calls).
 *
 * IPv4 only (AF_INET): TCP (SOCK_STREAM) and UDP (SOCK_DGRAM). A socket is
 * a descriptor from SOCK_FD_BASE (fdhooks.h); read, write and close work on
 * it too. Its netd socket is made when it is needed: by connect, listen or
 * accept for TCP, by bind or the first datagram for UDP.
 *
 * Each call is one request on a channel of its own, so a thread can wait
 * in recv while another sends on the same socket (netd keeps one waiting
 * Recv and one Send per socket).
 *
 * poll and select (fileio.c) ask netd's Poll, which answers as soon as
 * one of the sockets is ready. A non-blocking socket (O_NONBLOCK,
 * SOCK_NONBLOCK, MSG_DONTWAIT) asks it first, with no wait, and gives
 * EAGAIN when the call would wait; its connect still waits for the
 * connection (and returns 0, never EINPROGRESS).
 *
 * Not here: a half close (net/1 has none: shutdown(SHUT_WR) fails);
 * options other than the timeouts (others are accepted and do nothing); a
 * bind to one address (a socket listens on all). Sockets belong to the
 * process that made them: a child after fork cannot use its parent's.
 */

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <mynos.h>
#include <mynos_wire.h>
#include "fdhooks.h"

#define NET "net/1"
enum { N_CONFIG = 0, N_RESOLVE = 2, N_CONNECT = 3, N_LISTEN = 4,
       N_ACCEPT = 5, N_SEND = 6, N_RECV = 7, N_CLOSE = 8, N_TIMEOUT = 9,
       N_UDP_BIND = 11, N_SEND_TO = 12, N_RECV_FROM = 13, N_POLL = 14 };

/* netd's Poll flags */
#define P_IN   1
#define P_OUT  2
#define P_HUP  4
#define P_ERR  8
#define P_NVAL 16

#define MAXRECV  16384          /* netd's most per Recv */
#define MAXSEND  32768          /* our most per Send */

struct msock {
  int used;
  int type;                     /* SOCK_STREAM or SOCK_DGRAM */
  int id;                       /* netd's socket, -1 for none yet */
  int port;                     /* bound to (0: none) */
  int listening;
  int rd_shut;                  /* shutdown(SHUT_RD): reads give 0 */
  int has_peer;
  struct sockaddr_in peer;
  int timeout_ms;               /* SO_RCVTIMEO (0: none) */
  char * peeked;                /* bytes MSG_PEEK read, still to be read */
  size_t npeeked;
  int nonblock;                 /* O_NONBLOCK */
};

static struct msock socks[SOCK_FD_MAX];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int net_port = -1;

/* ---- net/1 ---- */

static void net_start(wire_writer * w, int kind)
{
  wire_writer_init(w);
  wire_put_cstring(w, NET);
  wire_put_int(w, kind);
}

/* netd's error messages as errno values */
static int net_errno(const char * m, unsigned int n)
{
  static const struct { const char * text; int err; } map[] = {
    { "connection refused", ECONNREFUSED }, { "timeout", ETIMEDOUT },
    { "connection reset", ECONNRESET }, { "connection aborted", ECONNABORTED },
    { "connection closed", EPIPE }, { "socket closed", EPIPE },
    { "not connected", ENOTCONN }, { "not a connected socket", ENOTCONN },
    { "no route to host", EHOSTUNREACH }, { "address in use", EADDRINUSE },
    { "out of memory", ENOMEM }, { "too many sockets", EMFILE },
    { "bad port", EINVAL }, { "not an address", EINVAL },
    { "datagram too large", EMSGSIZE }, { "host not found", EHOSTUNREACH },
    { "not your socket", EBADF }, { "not a socket", EBADF },
  };
  unsigned int i;
  for (i = 0; i < sizeof map / sizeof map[0]; i++)
    if (strlen(map[i].text) == n && !memcmp(map[i].text, m, n))
      return map[i].err;
  return EIO;
}

/* one request to netd on a channel of its own: 0 and the reply (r reads
   its value, the caller frees *msg), or -1 with errno set */
static int net_call(wire_writer * w, wire_reader * r, mynos_msg_t ** msg)
{
  int ch = -1, tries, failed;
  for (tries = 0; tries < 2; tries++) {
    if (net_port < 0) net_port = mynos_registryLookUp((char *)"net");
    if (net_port < 0) break;
    if ((ch = mynos_connectToPort(net_port)) >= 0) break;
    net_port = -1;                       /* netd restarted: look it up again */
  }
  if (net_port < 0) { wire_writer_free(w); errno = ENETDOWN; return -1; }
  if (w->error || mynos_send(ch, w->buf, w->len, 0) < 0 ||
      mynos_recv(ch, msg, 0, 0) < 0) {
    failed = w->error ? ENOMEM : ENETDOWN;
    mynos_freeChannel(ch);
    wire_writer_free(w);
    errno = failed;
    return -1;
  }
  mynos_freeChannel(ch);
  wire_writer_free(w);
  wire_reader_init(r, (*msg)->start, (*msg)->size);
  if (wire_get_int(r) != 0) {
    unsigned int n;
    const char * m = wire_get_string(r, &n);
    errno = r->error ? EIO : net_errno(m, n);
    mynos_freeMsg(msg);
    return -1;
  }
  return 0;
}

/* a request whose reply is an int, or -1 */
static long long net_int(wire_writer * w)
{
  wire_reader r;
  mynos_msg_t * msg;
  long long v;
  if (net_call(w, &r, &msg) < 0) return -1;
  v = wire_get_int(&r);
  if (r.error) { errno = EIO; v = -1; }
  mynos_freeMsg(&msg);
  return v;
}

/* a request whose reply is unit */
static int net_unit(wire_writer * w)
{
  wire_reader r;
  mynos_msg_t * msg;
  if (net_call(w, &r, &msg) < 0) return -1;
  mynos_freeMsg(&msg);
  return 0;
}

static int net_set_timeout(int id, int ms)
{
  wire_writer w;
  net_start(&w, N_TIMEOUT);
  wire_put_int(&w, id);
  wire_put_int(&w, ms);
  return net_unit(&w);
}

static void net_close(int id)
{
  wire_writer w;
  int saved = errno;
  net_start(&w, N_CLOSE);
  wire_put_int(&w, id);
  net_unit(&w);
  errno = saved;
}

/* netd's Poll: the flags of n of its sockets, as soon as one is ready or
   after timeout_ms (negative: no limit); 0, or -1 */
static int net_poll(const int * ids, const int * events, int n,
                    int timeout_ms, int * flags)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  int i;
  net_start(&w, N_POLL);
  wire_put_int(&w, n);
  for (i = 0; i < n; i++) { wire_put_int(&w, ids[i]); wire_put_int(&w, events[i]); }
  wire_put_int(&w, timeout_ms);
  if (net_call(&w, &r, &msg) < 0) return -1;
  if (wire_get_int(&r) != n) r.error = 1;
  for (i = 0; i < n; i++) flags[i] = (int)wire_get_int(&r);
  mynos_freeMsg(&msg);
  if (r.error) { errno = EIO; return -1; }
  return 0;
}

/* whether a call on a non-blocking socket would wait: EAGAIN then */
static int would_wait(int id, int want)
{
  int f;
  if (net_poll(&id, &want, 1, 0, &f) < 0) return 0;     /* let the call say */
  if (f & (want | P_HUP | P_ERR | P_NVAL)) return 0;
  errno = EAGAIN;
  return 1;
}

/* ---- addresses ---- */

static int to_sin(const struct sockaddr * a, socklen_t len,
                  struct sockaddr_in * sin)
{
  if (a == NULL || len < sizeof(struct sockaddr_in)) { errno = EINVAL; return -1; }
  memcpy(sin, a, sizeof *sin);
  if (sin->sin_family != AF_INET) { errno = EAFNOSUPPORT; return -1; }
  return 0;
}

static void put_sin(struct sockaddr * a, socklen_t * len,
                    const struct sockaddr_in * sin)
{
  if (a == NULL || len == NULL) return;
  memcpy(a, sin, *len < sizeof *sin ? *len : sizeof *sin);
  *len = sizeof *sin;
}

static int make_sin(const char * dotted, int port, struct sockaddr_in * sin)
{
  memset(sin, 0, sizeof *sin);
  sin->sin_family = AF_INET;
  sin->sin_port = htons(port);
  return inet_pton(AF_INET, dotted, &sin->sin_addr) == 1 ? 0 : -1;
}

/* ---- the descriptors ---- */

static int s_owns(int fd)
{
  return fd >= SOCK_FD_BASE && fd < SOCK_FD_BASE + SOCK_FD_MAX &&
         socks[fd - SOCK_FD_BASE].used;
}

/* the socket of a descriptor, or NULL with errno set */
static struct msock * sock_of(int fd)
{
  if (fd >= 0 && fd < SOCK_FD_BASE + SOCK_FD_MAX && fd >= SOCK_FD_BASE &&
      socks[fd - SOCK_FD_BASE].used)
    return &socks[fd - SOCK_FD_BASE];
  errno = (fd >= 0 && fd < SOCK_FD_BASE) ? ENOTSOCK : EBADF;
  return NULL;
}

static ssize_t s_read(int fd, void * buf, size_t count);
static ssize_t s_write(int fd, const void * buf, size_t count);
static int s_close(int fd);
static int s_fstat(int fd, struct stat * st);
static int s_poll(const int * fds, const short * events, int n,
                  int timeout_ms, short * revents);
static int s_fcntl(int fd, int cmd, long arg);

static const struct mynos_sock_ops ops = {
  s_owns, s_read, s_write, s_close, s_fstat, s_poll, s_fcntl
};

/* a free descriptor with its socket, or -1 */
static int new_sock(int type, int id)
{
  int i;
  pthread_mutex_lock(&lock);
  for (i = 0; i < SOCK_FD_MAX && socks[i].used; i++) ;
  if (i < SOCK_FD_MAX) {
    memset(&socks[i], 0, sizeof socks[i]);
    socks[i].used = 1;
    socks[i].type = type;
    socks[i].id = id;
  }
  pthread_mutex_unlock(&lock);
  if (i == SOCK_FD_MAX) { errno = EMFILE; return -1; }
  __mynos_sock_ops = &ops;
  return SOCK_FD_BASE + i;
}

int socket(int domain, int type, int protocol)
{
  int t = type & ~(SOCK_CLOEXEC | SOCK_NONBLOCK), fd;
  if (domain != AF_INET) { errno = EAFNOSUPPORT; return -1; }
  if (t != SOCK_STREAM && t != SOCK_DGRAM) { errno = ESOCKTNOSUPPORT; return -1; }
  if (protocol != 0 &&
      protocol != (t == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP)) {
    errno = EPROTONOSUPPORT;
    return -1;
  }
  if ((fd = new_sock(t, -1)) >= 0 && (type & SOCK_NONBLOCK))
    socks[fd - SOCK_FD_BASE].nonblock = 1;
  return fd;
}

/* the netd socket is new: the timeout asked before applies to it */
static int adopt(struct msock * s, long long id)
{
  if (id < 0) return -1;
  s->id = (int)id;
  if (s->timeout_ms) net_set_timeout(s->id, s->timeout_ms);
  return 0;
}

/* a UDP socket's netd socket, bound to s->port (0: any) */
static int udp_open(struct msock * s)
{
  wire_writer w;
  if (s->id >= 0) return 0;
  net_start(&w, N_UDP_BIND);
  wire_put_int(&w, s->port);
  return adopt(s, net_int(&w));
}

int bind(int fd, const struct sockaddr * a, socklen_t len)
{
  struct msock * s = sock_of(fd);
  struct sockaddr_in sin;
  if (s == NULL || to_sin(a, len, &sin) < 0) return -1;
  if (s->port || s->id >= 0) { errno = EINVAL; return -1; }
  s->port = ntohs(sin.sin_port);
  if (s->type == SOCK_DGRAM && udp_open(s) < 0) { s->port = 0; return -1; }
  return 0;
}

int listen(int fd, int backlog)
{
  struct msock * s = sock_of(fd);
  wire_writer w;
  (void)backlog;                          /* netd keeps its own */
  if (s == NULL) return -1;
  if (s->type != SOCK_STREAM) { errno = EOPNOTSUPP; return -1; }
  if (s->listening) return 0;
  if (s->id >= 0 || s->port == 0) { errno = EINVAL; return -1; }
  net_start(&w, N_LISTEN);
  wire_put_int(&w, s->port);
  if (adopt(s, net_int(&w)) < 0) {
    if (errno == EIO) errno = EADDRINUSE;
    return -1;
  }
  s->listening = 1;
  return 0;
}

int accept4(int fd, struct sockaddr * a, socklen_t * len, int flags)
{
  struct msock * s = sock_of(fd);
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  char addr[64];
  long long id, port;
  int nfd;
  if (s == NULL) return -1;
  if (!s->listening) { errno = EINVAL; return -1; }
  if (s->nonblock && would_wait(s->id, P_IN)) return -1;
  net_start(&w, N_ACCEPT);
  wire_put_int(&w, s->id);
  if (net_call(&w, &r, &msg) < 0) {
    if (errno == ETIMEDOUT) errno = EAGAIN;      /* SO_RCVTIMEO */
    return -1;
  }
  id = wire_get_int(&r);
  wire_get_cstring(&r, addr, sizeof addr);
  port = wire_get_int(&r);
  mynos_freeMsg(&msg);
  if (r.error) { errno = EIO; return -1; }
  if ((nfd = new_sock(SOCK_STREAM, (int)id)) < 0) { net_close((int)id); return -1; }
  s = &socks[nfd - SOCK_FD_BASE];
  s->nonblock = (flags & SOCK_NONBLOCK) != 0;
  s->has_peer = make_sin(addr, (int)port, &s->peer) == 0;
  if (s->has_peer) put_sin(a, len, &s->peer);
  return nfd;
}

int accept(int fd, struct sockaddr * a, socklen_t * len)
{
  return accept4(fd, a, len, 0);
}

int connect(int fd, const struct sockaddr * a, socklen_t len)
{
  struct msock * s = sock_of(fd);
  struct sockaddr_in sin;
  wire_writer w;
  char dotted[INET_ADDRSTRLEN];
  if (s == NULL) return -1;
  if (s->type == SOCK_DGRAM && a && len >= sizeof(sa_family_t) &&
      a->sa_family == AF_UNSPEC) {
    s->has_peer = 0;                      /* dissolve the association */
    return 0;
  }
  if (to_sin(a, len, &sin) < 0) return -1;
  if (s->type == SOCK_DGRAM) {            /* the default destination */
    s->peer = sin;
    s->has_peer = 1;
    return 0;
  }
  if (s->listening) { errno = EINVAL; return -1; }
  if (s->id >= 0) { errno = EISCONN; return -1; }
  inet_ntop(AF_INET, &sin.sin_addr, dotted, sizeof dotted);
  net_start(&w, N_CONNECT);
  wire_put_cstring(&w, dotted);
  wire_put_int(&w, ntohs(sin.sin_port));
  if (adopt(s, net_int(&w)) < 0) return -1;
  s->peer = sin;
  s->has_peer = 1;
  return 0;
}

/* ---- data ---- */

static ssize_t tcp_send(struct msock * s, const char * buf, size_t len)
{
  size_t done = 0;
  if (s->id < 0 || s->listening) { errno = ENOTCONN; return -1; }
  if (len == 0) return 0;
  while (done < len) {
    size_t n = len - done > MAXSEND ? MAXSEND : len - done;
    wire_writer w;
    long long sent;
    net_start(&w, N_SEND);
    wire_put_int(&w, s->id);
    wire_put_string(&w, buf + done, n);
    if ((sent = net_int(&w)) < 0) return done ? (ssize_t)done : -1;
    done += sent;
  }
  return done;
}

static ssize_t udp_send(struct msock * s, const char * buf, size_t len,
                        const struct sockaddr_in * to)
{
  wire_writer w;
  char dotted[INET_ADDRSTRLEN];
  if (udp_open(s) < 0) return -1;
  inet_ntop(AF_INET, &to->sin_addr, dotted, sizeof dotted);
  net_start(&w, N_SEND_TO);
  wire_put_int(&w, s->id);
  wire_put_cstring(&w, dotted);
  wire_put_int(&w, ntohs(to->sin_port));
  wire_put_string(&w, buf, len);
  return net_int(&w);
}

ssize_t sendto(int fd, const void * buf, size_t len, int flags,
               const struct sockaddr * a, socklen_t alen)
{
  struct msock * s = sock_of(fd);
  struct sockaddr_in to;
  if (s == NULL) return -1;
  if (s->type == SOCK_STREAM) {
    if ((s->nonblock || (flags & MSG_DONTWAIT)) && s->id >= 0 && !s->listening &&
        len > 0 && would_wait(s->id, P_OUT))
      return -1;
    return tcp_send(s, buf, len);
  }
  if (a != NULL) {
    if (to_sin(a, alen, &to) < 0) return -1;
  } else if (s->has_peer) {
    to = s->peer;
  } else {
    errno = EDESTADDRREQ;
    return -1;
  }
  return udp_send(s, buf, len, &to);
}

ssize_t send(int fd, const void * buf, size_t len, int flags)
{
  return sendto(fd, buf, len, flags, NULL, 0);
}

/* one Recv: at most len bytes, 0 at the end of the stream */
static ssize_t tcp_recv(struct msock * s, char * buf, size_t len)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  const char * data;
  unsigned int n;
  if (s->npeeked) {
    n = len < s->npeeked ? len : s->npeeked;
    memcpy(buf, s->peeked, n);
    memmove(s->peeked, s->peeked + n, s->npeeked - n);
    s->npeeked -= n;
    return n;
  }
  net_start(&w, N_RECV);
  wire_put_int(&w, s->id);
  wire_put_int(&w, len > MAXRECV ? MAXRECV : len);
  if (net_call(&w, &r, &msg) < 0) {
    if (errno == ETIMEDOUT) errno = EAGAIN;      /* SO_RCVTIMEO */
    if (errno == EPIPE) return 0;                /* closed: the end */
    return -1;
  }
  data = wire_get_string(&r, &n);
  if (r.error) { mynos_freeMsg(&msg); errno = EIO; return -1; }
  if (n > len) n = len;
  memcpy(buf, data, n);
  mynos_freeMsg(&msg);
  return n;
}

/* MSG_PEEK: read, and keep what was read for the next reads */
static ssize_t tcp_peek(struct msock * s, char * buf, size_t len)
{
  if (s->npeeked == 0) {
    char tmp[MAXRECV];
    ssize_t n = tcp_recv(s, tmp, len > MAXRECV ? MAXRECV : len);
    char * p;
    if (n <= 0) return n;
    if ((p = malloc(n)) == NULL) { errno = ENOMEM; return -1; }
    memcpy(p, tmp, n);
    free(s->peeked);
    s->peeked = p;
    s->npeeked = n;
  }
  if (len > s->npeeked) len = s->npeeked;
  memcpy(buf, s->peeked, len);
  return len;
}

ssize_t recvfrom(int fd, void * buf, size_t len, int flags,
                 struct sockaddr * a, socklen_t * alen)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  if (s->type == SOCK_STREAM) {
    size_t done = 0;
    ssize_t n;
    if (s->id < 0 || s->listening) { errno = ENOTCONN; return -1; }
    if (s->rd_shut || len == 0) return 0;
    if ((s->nonblock || (flags & MSG_DONTWAIT)) && !s->npeeked &&
        would_wait(s->id, P_IN))
      return -1;
    if (flags & MSG_PEEK) n = tcp_peek(s, buf, len);
    else do {                             /* MSG_WAITALL: all of it */
      n = tcp_recv(s, (char *)buf + done, len - done);
      if (n > 0) done += n;
    } while ((flags & MSG_WAITALL) && n > 0 && done < len);
    if (!(flags & MSG_PEEK) && done) n = done;
    if (n >= 0 && s->has_peer) put_sin(a, alen, &s->peer);
    return n;
  } else {
    wire_writer w;
    wire_reader r;
    mynos_msg_t * msg;
    char addr[64];
    const char * data;
    unsigned int n;
    long long port;
    struct sockaddr_in from;
    if (udp_open(s) < 0) return -1;
    if (flags & MSG_PEEK) { errno = EOPNOTSUPP; return -1; }
    if ((s->nonblock || (flags & MSG_DONTWAIT)) && would_wait(s->id, P_IN))
      return -1;
    net_start(&w, N_RECV_FROM);
    wire_put_int(&w, s->id);
    wire_put_int(&w, len ? (len > MAXRECV ? MAXRECV : len) : 1);
    if (net_call(&w, &r, &msg) < 0) {
      if (errno == ETIMEDOUT) errno = EAGAIN;
      return -1;
    }
    wire_get_cstring(&r, addr, sizeof addr);
    port = wire_get_int(&r);
    data = wire_get_string(&r, &n);
    if (r.error) { mynos_freeMsg(&msg); errno = EIO; return -1; }
    if (n > len) n = len;                 /* the rest of the datagram is lost */
    memcpy(buf, data, n);
    mynos_freeMsg(&msg);
    if (make_sin(addr, (int)port, &from) == 0) put_sin(a, alen, &from);
    return n;
  }
}

ssize_t recv(int fd, void * buf, size_t len, int flags)
{
  return recvfrom(fd, buf, len, flags, NULL, NULL);
}

/* sendmsg and recvmsg: one buffer, the rest copied through it */
ssize_t sendmsg(int fd, const struct msghdr * m, int flags)
{
  size_t total = 0, off = 0;
  char * buf;
  ssize_t n;
  int i;
  for (i = 0; i < (int)m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
  if ((buf = malloc(total ? total : 1)) == NULL) { errno = ENOMEM; return -1; }
  for (i = 0; i < (int)m->msg_iovlen; i++) {
    memcpy(buf + off, m->msg_iov[i].iov_base, m->msg_iov[i].iov_len);
    off += m->msg_iov[i].iov_len;
  }
  n = sendto(fd, buf, total, flags, m->msg_name, m->msg_namelen);
  free(buf);
  return n;
}

ssize_t recvmsg(int fd, struct msghdr * m, int flags)
{
  size_t total = 0, off = 0;
  char * buf;
  ssize_t n;
  int i;
  socklen_t alen = m->msg_namelen;
  for (i = 0; i < (int)m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
  if ((buf = malloc(total ? total : 1)) == NULL) { errno = ENOMEM; return -1; }
  n = recvfrom(fd, buf, total, flags, m->msg_name, m->msg_name ? &alen : NULL);
  for (i = 0; n > 0 && i < (int)m->msg_iovlen && off < (size_t)n; i++) {
    size_t k = m->msg_iov[i].iov_len;
    if (k > (size_t)n - off) k = n - off;
    memcpy(m->msg_iov[i].iov_base, buf + off, k);
    off += k;
  }
  free(buf);
  if (m->msg_name) m->msg_namelen = alen;
  m->msg_controllen = 0;
  m->msg_flags = 0;
  return n;
}

/* read, write and close on a socket (fileio.c) */
static ssize_t s_read(int fd, void * buf, size_t count)
{
  return recvfrom(fd, buf, count, 0, NULL, NULL);
}

static ssize_t s_write(int fd, const void * buf, size_t count)
{
  return sendto(fd, buf, count, 0, NULL, 0);
}

static int s_close(int fd)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  if (s->id >= 0) net_close(s->id);
  free(s->peeked);
  pthread_mutex_lock(&lock);
  s->used = 0;
  pthread_mutex_unlock(&lock);
  return 0;
}

static int s_fstat(int fd, struct stat * st)
{
  if (sock_of(fd) == NULL) return -1;
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFSOCK | 0777;
  st->st_nlink = 1;
  st->st_blksize = 4096;
  return 0;
}

/* poll on sockets (fileio.c's poll): what is known here, then netd's
   Poll for the rest */
static int s_poll(const int * fds, const short * events, int n,
                  int timeout_ms, short * revents)
{
  int ids[SOCK_FD_MAX * 2], want[SOCK_FD_MAX * 2], which[SOCK_FD_MAX * 2];
  int flags[SOCK_FD_MAX * 2];
  short mask;
  int i, k = 0, count = 0;
  for (i = 0; i < n; i++) {
    struct msock * s = s_owns(fds[i]) ? &socks[fds[i] - SOCK_FD_BASE] : NULL;
    mask = events[i] | POLLHUP | POLLERR | POLLNVAL;
    revents[i] = 0;
    if (s == NULL) revents[i] = POLLNVAL;
    else if (s->npeeked || s->rd_shut) revents[i] = POLLIN | POLLRDNORM;
    else if (s->id < 0)                   /* not connected, or unbound UDP */
      revents[i] = s->type == SOCK_DGRAM ? POLLOUT | POLLWRNORM : POLLOUT | POLLHUP;
    else if (k < (int)(sizeof ids / sizeof ids[0])) {
      ids[k] = s->id;
      want[k] = ((events[i] & (POLLIN | POLLRDNORM)) ? P_IN : 0) |
                ((events[i] & (POLLOUT | POLLWRNORM)) ? P_OUT : 0);
      which[k++] = i;
    }
    revents[i] &= mask;
    if (revents[i]) count++;
  }
  if (k > 0) {
    if (net_poll(ids, want, k, count ? 0 : timeout_ms, flags) < 0) return -1;
    for (i = 0; i < k; i++) {
      short e = 0;
      if (flags[i] & P_IN) e |= POLLIN | POLLRDNORM;
      if (flags[i] & P_OUT) e |= POLLOUT | POLLWRNORM;
      if (flags[i] & P_HUP) e |= POLLHUP;
      if (flags[i] & P_ERR) e |= POLLERR;
      if (flags[i] & P_NVAL) e |= POLLNVAL;
      e &= events[which[i]] | POLLHUP | POLLERR | POLLNVAL;
      revents[which[i]] = e;
      if (e) count++;
    }
  }
  return count;
}

static int s_fcntl(int fd, int cmd, long arg)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  switch (cmd) {
  case F_GETFL: return O_RDWR | (s->nonblock ? O_NONBLOCK : 0);
  case F_SETFL: s->nonblock = (arg & O_NONBLOCK) != 0; return 0;
  case F_GETFD: case F_SETFD: return 0;
  default: errno = EINVAL; return -1;
  }
}

/* no half close in net/1: SHUT_RD stops the reads here, SHUT_RDWR closes
   the connection, SHUT_WR is refused */
int shutdown(int fd, int how)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  if (s->type == SOCK_STREAM && (s->id < 0 || s->listening)) {
    errno = ENOTCONN;
    return -1;
  }
  switch (how) {
  case SHUT_RD: s->rd_shut = 1; return 0;
  case SHUT_RDWR:
    if (s->id >= 0) net_close(s->id);
    s->id = -1;
    s->rd_shut = 1;
    return 0;
  case SHUT_WR: errno = EOPNOTSUPP; return -1;
  default: errno = EINVAL; return -1;
  }
}

/* ---- options ---- */

int setsockopt(int fd, int level, int name, const void * v, socklen_t len)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  if (level == SOL_SOCKET && name == SO_RCVTIMEO) {
    const struct timeval * tv = v;
    if (len < sizeof *tv) { errno = EINVAL; return -1; }
    s->timeout_ms = tv->tv_sec * 1000 + (tv->tv_usec + 999) / 1000;
    if (s->id >= 0) return net_set_timeout(s->id, s->timeout_ms);
    return 0;
  }
  if (level == SOL_SOCKET &&
      (name == SO_SNDTIMEO || name == SO_REUSEADDR || name == SO_KEEPALIVE ||
       name == SO_BROADCAST || name == SO_LINGER || name == SO_RCVBUF ||
       name == SO_SNDBUF || name == SO_REUSEPORT))
    return 0;                             /* accepted, nothing to do */
  if (level == IPPROTO_TCP && name == TCP_NODELAY) return 0;
  errno = ENOPROTOOPT;
  return -1;
}

int getsockopt(int fd, int level, int name, void * v, socklen_t * len)
{
  struct msock * s = sock_of(fd);
  int i;
  if (s == NULL) return -1;
  if (level == SOL_SOCKET && name == SO_RCVTIMEO && *len >= sizeof(struct timeval)) {
    struct timeval tv;
    tv.tv_sec = s->timeout_ms / 1000;
    tv.tv_usec = (s->timeout_ms % 1000) * 1000;
    memcpy(v, &tv, sizeof tv);
    *len = sizeof tv;
    return 0;
  }
  if (level != SOL_SOCKET || (name != SO_ERROR && name != SO_TYPE) ||
      *len < sizeof(int)) {
    errno = ENOPROTOOPT;
    return -1;
  }
  i = name == SO_TYPE ? s->type : 0;
  memcpy(v, &i, sizeof i);
  *len = sizeof i;
  return 0;
}

int getpeername(int fd, struct sockaddr * a, socklen_t * len)
{
  struct msock * s = sock_of(fd);
  if (s == NULL) return -1;
  if (!s->has_peer || (s->type == SOCK_STREAM && s->id < 0)) {
    errno = ENOTCONN;
    return -1;
  }
  put_sin(a, len, &s->peer);
  return 0;
}

/* our address (netd's configuration), and the port bound if any */
int getsockname(int fd, struct sockaddr * a, socklen_t * len)
{
  struct msock * s = sock_of(fd);
  struct sockaddr_in sin;
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  char mac[64], addr[64];
  if (s == NULL) return -1;
  make_sin("0.0.0.0", s->port, &sin);
  if (s->id >= 0 && !s->listening && s->type == SOCK_STREAM) {
    net_start(&w, N_CONFIG);
    if (net_call(&w, &r, &msg) == 0) {
      wire_get_cstring(&r, mac, sizeof mac);
      wire_get_cstring(&r, addr, sizeof addr);
      if (!r.error) make_sin(addr, s->port, &sin);
      mynos_freeMsg(&msg);
    }
  }
  put_sin(a, len, &sin);
  return 0;
}

/* ---- names ---- */

/* a host's IPv4 address: dotted, "localhost", or a name netd resolves
   (DNS); 0, or an EAI_ code */
static int lookup(const char * host, int numeric_only, struct in_addr * out)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  char dotted[64];
  if (inet_pton(AF_INET, host, out) == 1) return 0;
  if (numeric_only) return EAI_NONAME;
  if (!strcmp(host, "localhost")) {
    out->s_addr = htonl(INADDR_LOOPBACK);
    return 0;
  }
  net_start(&w, N_RESOLVE);
  wire_put_cstring(&w, host);
  if (net_call(&w, &r, &msg) < 0)
    return errno == EHOSTUNREACH ? EAI_NONAME : EAI_AGAIN;
  wire_get_cstring(&r, dotted, sizeof dotted);
  mynos_freeMsg(&msg);
  if (r.error || inet_pton(AF_INET, dotted, out) != 1) return EAI_FAIL;
  return 0;
}

/* a service's port: a number, or one of the usual names; -1 if unknown */
static int service_port(const char * service, int numeric_only)
{
  static const struct { const char * name; int port; } names[] = {
    { "ftp", 21 }, { "ssh", 22 }, { "telnet", 23 }, { "smtp", 25 },
    { "domain", 53 }, { "http", 80 }, { "pop3", 110 }, { "ntp", 123 },
    { "imap", 143 }, { "https", 443 }, { "imaps", 993 }, { "pop3s", 995 },
  };
  char * end;
  long p;
  unsigned int i;
  if (service == NULL) return 0;
  p = strtol(service, &end, 10);
  if (*service && !*end) return p >= 0 && p <= 65535 ? (int)p : -1;
  if (numeric_only) return -1;
  for (i = 0; i < sizeof names / sizeof names[0]; i++)
    if (!strcmp(service, names[i].name)) return names[i].port;
  return -1;
}

/* each result one block: the addrinfo, its address, its name */
struct ai_block {
  struct addrinfo ai;
  struct sockaddr_in sin;
  char name[];
};

int getaddrinfo(const char * node, const char * service,
                const struct addrinfo * hints, struct addrinfo ** res)
{
  int family = hints ? hints->ai_family : AF_UNSPEC;
  int socktype = hints ? hints->ai_socktype : 0;
  int flags = hints ? hints->ai_flags : 0;
  int types[2], ntypes = 0, port, err, i;
  struct in_addr addr;
  struct addrinfo * head = NULL, ** tail = &head;

  if (node == NULL && service == NULL) return EAI_NONAME;
  if (family != AF_UNSPEC && family != AF_INET) return EAI_FAMILY;
  if (socktype != 0 && socktype != SOCK_STREAM && socktype != SOCK_DGRAM)
    return EAI_SOCKTYPE;
  if ((port = service_port(service, flags & AI_NUMERICSERV)) < 0)
    return EAI_SERVICE;
  if (node == NULL)
    addr.s_addr = htonl(flags & AI_PASSIVE ? INADDR_ANY : INADDR_LOOPBACK);
  else if ((err = lookup(node, flags & AI_NUMERICHOST, &addr)) != 0)
    return err;
  if (socktype) types[ntypes++] = socktype;
  else { types[ntypes++] = SOCK_STREAM; types[ntypes++] = SOCK_DGRAM; }

  for (i = 0; i < ntypes; i++) {
    const char * cname = (flags & AI_CANONNAME) && node ? node : NULL;
    struct ai_block * b = calloc(1, sizeof *b + (cname ? strlen(cname) + 1 : 0));
    if (b == NULL) { freeaddrinfo(head); return EAI_MEMORY; }
    b->sin.sin_family = AF_INET;
    b->sin.sin_port = htons(port);
    b->sin.sin_addr = addr;
    b->ai.ai_family = AF_INET;
    b->ai.ai_socktype = types[i];
    b->ai.ai_protocol = types[i] == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP;
    b->ai.ai_addrlen = sizeof b->sin;
    b->ai.ai_addr = (struct sockaddr *)&b->sin;
    if (cname) { strcpy(b->name, cname); b->ai.ai_canonname = b->name; }
    *tail = &b->ai;
    tail = &b->ai.ai_next;
  }
  *res = head;
  return 0;
}

void freeaddrinfo(struct addrinfo * ai)
{
  while (ai) {
    struct addrinfo * next = ai->ai_next;
    free(ai);                             /* the block it begins */
    ai = next;
  }
}

/* the old interface: one address, in a static entry */
struct hostent * gethostbyname(const char * name)
{
  static struct hostent h;
  static struct in_addr addr;
  static char * addrs[2], * aliases[1], hname[256];
  if (lookup(name, 0, &addr) != 0) { h_errno = HOST_NOT_FOUND; return NULL; }
  strncpy(hname, name, sizeof hname - 1);
  addrs[0] = (char *)&addr;
  addrs[1] = NULL;
  aliases[0] = NULL;
  h.h_name = hname;
  h.h_aliases = aliases;
  h.h_addrtype = AF_INET;
  h.h_length = sizeof addr;
  h.h_addr_list = addrs;
  return &h;
}

/*
 * http: and https: for NetSurf on MyNOS (mynos-1g0), through MyNOS's
 * network service, netd (protocol net/1: services/net/netd.c). netd
 * does TCP and TLS (the server's certificate checked); this fetcher
 * speaks HTTP/1.1 over its sockets.
 *
 * Each fetch has a thread, which makes the connection, sends the request
 * and reads the reply, blocking in netd's calls; it queues what it reads
 * (the status, each header, data, the end or an error). NetSurf's poll,
 * on its own thread, takes the queue and calls the fetch's callbacks: as
 * curl's fetcher does, a 304 is "not modified", a 3xx with a Location a
 * redirect, a non-2xx an error when only 2xx was wanted.
 *
 * Not done: authentication (401), multipart POST with files, gzip (the
 * request asks for identity), keeping connections open.
 *
 * The MyNOS calls are weak: on Linux this fetcher does not register.
 */

#define _GNU_SOURCE             /* strcasestr */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
#include <time.h>
#include <libwapcaplet/libwapcaplet.h>

#include "utils/nsurl.h"
#include "utils/corestrings.h"
#include "utils/log.h"
#include "utils/ring.h"
#include "utils/messages.h"
#include "utils/useragent.h"
#include "content/urldb.h"
#include "content/fetch.h"
#include "content/fetchers.h"

#include <mynos.h>
#include <mynos_wire.h>
#include <mynos_registry.h>

#pragma weak mynos_send
#pragma weak mynos_recv
#pragma weak mynos_freeMsg
#pragma weak mynos_freeChannel
#pragma weak mynos_connectToPort
#pragma weak mynos_registryLookUp
#pragma weak wire_writer_init
#pragma weak wire_writer_free
#pragma weak wire_put_int
#pragma weak wire_put_cstring
#pragma weak wire_put_string
#pragma weak wire_reader_init
#pragma weak wire_get_int
#pragma weak wire_get_string
#pragma weak mynos_log

nserror fetch_mynos_http_register(void);

/* ---- net/1 ---- */

#define NET "net/1"
enum { N_RESOLVE = 2, N_CONNECT = 3, N_SEND = 6, N_RECV = 7, N_CLOSE = 8,
       N_TIMEOUT = 9, N_CONNECT_TLS = 10 };

static int net_port = -1;

static void net_start(wire_writer *w, int kind)
{
	wire_writer_init(w);
	wire_put_cstring(w, NET);
	wire_put_int(w, kind);
}

/* a call to netd: 0 and the reply in *msg (r reads its value), or -1
   and the error in err */
static int net_call(wire_writer *w, wire_reader *r, mynos_msg_t **msg,
		    char *err, size_t errlen)
{
	int ch = mynos_connectToPort(net_port), ret = -1;
	if (ch < 0) {
		snprintf(err, errlen, "no network service");
		wire_writer_free(w);
		return -1;
	}
	if (mynos_send(ch, w->buf, w->len, 0) >= 0 &&
	    mynos_recv(ch, msg, 0, 0) >= 0) {
		wire_reader_init(r, (*msg)->start, (*msg)->size);
		if (wire_get_int(r) == 0) {
			ret = 0;
		} else {
			unsigned int n;
			const char *e = wire_get_string(r, &n);
			snprintf(err, errlen, "%.*s", (int)n, e ? e : "error");
			mynos_freeMsg(msg);
		}
	} else {
		snprintf(err, errlen, "the network service did not answer");
	}
	mynos_freeChannel(ch);
	wire_writer_free(w);
	return ret;
}

/* a call whose reply is an int (a socket, a count): it, or -1 */
static long long net_int(wire_writer *w, char *err, size_t errlen)
{
	wire_reader r;
	mynos_msg_t *msg;
	long long v;
	if (net_call(w, &r, &msg, err, errlen) < 0) return -1;
	v = wire_get_int(&r);
	mynos_freeMsg(&msg);
	return v;
}

/* ---- the fetches ---- */

enum { I_CODE, I_HEADER, I_END_HEADERS, I_DATA, I_DONE, I_ERROR };

struct item {
	struct item *next;
	int type;
	long code;
	size_t len;
	char buf[];
};

struct mhttp {
	struct fetch *parent;
	nsurl *url;
	bool only_2xx;
	bool post;
	char *host;
	int port;
	bool tls;
	char *request;
	size_t request_len;

	pthread_mutex_t lock;
	struct item *head, *tail;     /* from the thread, under lock */
	bool worker_done, freed;      /* under lock */
	volatile bool aborted;
	bool locked;                  /* in a callback (re-entrant poll) */
	bool started;

	long http_code;
	char *location;
	struct item *error;           /* the error delivered, kept until the end */

	struct mhttp *r_next, *r_prev;
};

static struct mhttp *ring = NULL;

static void push(struct mhttp *c, int type, long code, const void *buf, size_t len)
{
	struct item *it = malloc(sizeof *it + len + 1);
	if (it == NULL) return;
	it->next = NULL;
	it->type = type;
	it->code = code;
	it->len = len;
	if (len) memcpy(it->buf, buf, len);
	it->buf[len] = '\0';
	pthread_mutex_lock(&c->lock);
	if (c->tail) c->tail->next = it; else c->head = it;
	c->tail = it;
	pthread_mutex_unlock(&c->lock);
}

static void free_context(struct mhttp *c)
{
	struct item *it = c->head, *next;
	for (; it != NULL; it = next) { next = it->next; free(it); }
	nsurl_unref(c->url);
	free(c->host);
	free(c->request);
	free(c->location);
	free(c->error);
	pthread_mutex_destroy(&c->lock);
	free(c);
}

/* ---- the thread: the connection, the request, the reply ---- */

#define CHUNK 16384

static int sock_send(int s, const char *p, size_t n, char *err, size_t errlen)
{
	while (n > 0) {
		wire_writer w;
		size_t k = n > CHUNK ? CHUNK : n;
		net_start(&w, N_SEND);
		wire_put_int(&w, s);
		wire_put_string(&w, p, k);
		if (net_int(&w, err, errlen) < 0) return -1;
		p += k;
		n -= k;
	}
	return 0;
}

/* the reply's bytes as they come: the status line and headers parsed
   here, the body (chunked or not) passed on */
struct reader {
	struct mhttp *c;
	char *hbuf;                 /* the headers, until their end */
	size_t hlen, hcap;
	bool in_body;
	bool chunked;
	long long remaining;        /* Content-Length left, or -1 */
	long long chunk_left;       /* chunked: bytes of this chunk left */
	int chunk_state;            /* 0 size line, 1 data, 2 CRLF after, 3 trailer */
	char line[64];
	size_t line_len;
	bool done;
	bool no_body;
	bool has_length;            /* a Content-Length */
	bool conn_close;            /* the server closes: HTTP/1.0, Connection: close */
};

static void header_line(struct reader *rd, char *l)
{
	if (strncasecmp(l, "Transfer-Encoding:", 18) == 0 && strstr(l + 18, "chunked"))
		rd->chunked = true;
	else if (strncasecmp(l, "Content-Length:", 15) == 0) {
		rd->remaining = atoll(l + 15);
		rd->has_length = true;
	} else if (strncasecmp(l, "Connection:", 11) == 0 && strcasestr(l + 11, "close"))
		rd->conn_close = true;
	push(rd->c, I_HEADER, 0, l, strlen(l));
}

/* the headers, complete in hbuf: their lines */
static void headers_done(struct reader *rd)
{
	char *p = rd->hbuf, *eol;
	long code = 0;
	bool first = true;
	rd->hbuf[rd->hlen] = '\0';
	while ((eol = strstr(p, "\r\n")) != NULL) {
		*eol = '\0';
		if (first) {
			const char *sp = strchr(p, ' ');
			code = sp ? atol(sp + 1) : 0;
			if (strncmp(p, "HTTP/1.0", 8) == 0) rd->conn_close = true;
			push(rd->c, I_CODE, code, NULL, 0);
			first = false;
		} else if (*p != '\0') {
			header_line(rd, p);
		}
		p = eol + 2;
	}
	push(rd->c, I_END_HEADERS, code, NULL, 0);
	rd->in_body = true;
	if (code == 204 || code == 304 || (code >= 100 && code < 200))
		rd->no_body = true;
	if (rd->no_body || rd->remaining == 0) rd->done = true;
}

static void body(struct reader *rd, const char *p, size_t n)
{
	if (!rd->chunked) {
		if (rd->remaining >= 0 && (long long)n > rd->remaining) n = rd->remaining;
		if (n) push(rd->c, I_DATA, 0, p, n);
		if (rd->remaining >= 0) {
			rd->remaining -= n;
			if (rd->remaining == 0) rd->done = true;
		}
		return;
	}
	while (n > 0 && !rd->done) {
		switch (rd->chunk_state) {
		case 0: case 2: case 3: {     /* a line: size, the CRLF after data, trailer */
			char ch = *p++; n--;
			if (ch == '\n') {
				rd->line[rd->line_len] = '\0';
				if (rd->chunk_state == 0) {
					rd->chunk_left = strtoll(rd->line, NULL, 16);
					rd->chunk_state = rd->chunk_left > 0 ? 1 : 3;
				} else if (rd->chunk_state == 2) {
					rd->chunk_state = 0;
				} else if (rd->line_len == 0 ||
					   (rd->line_len == 1 && rd->line[0] == '\r')) {
					rd->done = true;      /* the empty line after the trailer */
				}
				rd->line_len = 0;
			} else if (rd->line_len < sizeof rd->line - 1) {
				rd->line[rd->line_len++] = ch;
			}
			break;
		}
		case 1: {
			size_t k = (long long)n < rd->chunk_left ? n : (size_t)rd->chunk_left;
			push(rd->c, I_DATA, 0, p, k);
			p += k; n -= k;
			rd->chunk_left -= k;
			if (rd->chunk_left == 0) rd->chunk_state = 2;
			break;
		}
		}
	}
}

static void feed(struct reader *rd, const char *p, size_t n)
{
	if (!rd->in_body) {
		size_t i;
		for (i = 0; i < n; i++) {
			char *end;
			if (rd->hlen + 1 >= rd->hcap) {
				char *b = realloc(rd->hbuf, rd->hcap = rd->hcap ? rd->hcap * 2 : 4096);
				if (b == NULL) return;
				rd->hbuf = b;
			}
			rd->hbuf[rd->hlen++] = p[i];
			rd->hbuf[rd->hlen] = '\0';
			if (rd->hlen >= 4 && (end = strstr(rd->hbuf + rd->hlen - 4, "\r\n\r\n")) != NULL) {
				rd->hlen -= 2;         /* keep one CRLF: each line ends with one */
				headers_done(rd);
				body(rd, p + i + 1, n - i - 1);
				return;
			}
		}
		return;
	}
	body(rd, p, n);
}

static double now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

/* ---- connections kept open, by server ----
 *
 * At most PER_SERVER connections to a server (host, port, TLS) at once:
 * a fetch takes one left open by an earlier fetch, or opens one if there
 * are fewer, or waits. A reply whose end is known (a length, chunked, no
 * body) leaves its connection open for the next; one the server closes,
 * or read to its end, closes it. netd does one TLS handshake at a time:
 * each one saved is time saved for all the fetches. */

#define PER_SERVER 4
#define MAX_OPEN 12             /* in all: netd's TLS connections are few */
#define IDLE_MS 20000           /* an open connection idle longer is closed */

struct conn {
	long long sock;
	double since;
	struct conn *next;
};

struct server {
	char *host;
	int port;
	bool tls;
	int open;                   /* connections, in use or idle */
	struct conn *idle;
	struct server *next;
};

static pthread_mutex_t pool_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pool_cond = PTHREAD_COND_INITIALIZER;
static struct server *servers = NULL;
static int total_open = 0;      /* connections, in use or idle, all servers */

static struct server *server_of(struct mhttp *c)
{
	struct server *sv;
	for (sv = servers; sv != NULL; sv = sv->next)
		if (sv->port == c->port && sv->tls == c->tls && strcmp(sv->host, c->host) == 0)
			return sv;
	sv = calloc(1, sizeof *sv);
	if (sv == NULL) return NULL;
	sv->host = strdup(c->host);
	sv->port = c->port;
	sv->tls = c->tls;
	sv->next = servers;
	servers = sv;
	return sv;
}

static void sock_close(long long s)
{
	wire_writer w;
	char e[64];
	net_start(&w, N_CLOSE);
	wire_put_int(&w, s);
	net_int(&w, e, sizeof e);
}

/* a new connection to c's server: its socket, or -1 */
static long long open_conn(struct mhttp *c, char *err, size_t errlen)
{
	wire_writer w;
	long long s = -1;
	if (c->tls) {
		net_start(&w, N_CONNECT_TLS);
		wire_put_cstring(&w, c->host);
		wire_put_int(&w, c->port);
		s = net_int(&w, err, errlen);
	} else {
		wire_reader r;
		mynos_msg_t *msg;
		char addr[64];
		net_start(&w, N_RESOLVE);
		wire_put_cstring(&w, c->host);
		if (net_call(&w, &r, &msg, err, errlen) == 0) {
			unsigned int n;
			const char *a = wire_get_string(&r, &n);
			snprintf(addr, sizeof addr, "%.*s", (int)n, a ? a : "");
			mynos_freeMsg(&msg);
			net_start(&w, N_CONNECT);
			wire_put_cstring(&w, addr);
			wire_put_int(&w, c->port);
			s = net_int(&w, err, errlen);
		}
	}
	if (s >= 0) {
		char e[64];
		net_start(&w, N_TIMEOUT);
		wire_put_int(&w, s);
		wire_put_int(&w, 30000);
		net_int(&w, e, sizeof e);
	}
	return s;
}

/* idle connections closed (under pool_lock): those idle longer than
   IDLE_MS, or, with oldest, the oldest one of all; true if one was */
static bool close_idle(bool oldest)
{
	struct server *sv, *osv = NULL;
	struct conn **kp, **okp = NULL;
	bool closed = false;
	double now = now_ms();
	for (sv = servers; sv != NULL; sv = sv->next) {
		for (kp = &sv->idle; *kp != NULL; ) {
			struct conn *k = *kp;
			if (now - k->since >= IDLE_MS) {
				*kp = k->next;
				sock_close(k->sock);
				free(k);
				sv->open--;
				total_open--;
				closed = true;
				continue;
			}
			if (okp == NULL || k->since < (*okp)->since) { okp = kp; osv = sv; }
			kp = &k->next;
		}
	}
	if (oldest && !closed && okp != NULL) {
		struct conn *k = *okp;
		*okp = k->next;
		sock_close(k->sock);
		free(k);
		osv->open--;
		total_open--;
		closed = true;
	}
	return closed;
}

/* a connection for c: one left open (*reused), or a new one */
static long long acquire(struct mhttp *c, bool *reused, char *err, size_t errlen)
{
	struct server *sv;
	long long s;
	pthread_mutex_lock(&pool_lock);
	sv = server_of(c);
	if (sv == NULL) {
		pthread_mutex_unlock(&pool_lock);
		snprintf(err, errlen, "out of memory");
		return -1;
	}
	close_idle(false);
	for (;;) {
		if (sv->idle != NULL) {
			struct conn *k = sv->idle;
			sv->idle = k->next;
			s = k->sock;
			free(k);
			pthread_mutex_unlock(&pool_lock);
			*reused = true;
			return s;
		}
		if (c->aborted) break;
		if (sv->open < PER_SERVER) {
			if (total_open < MAX_OPEN) break;
			if (close_idle(true)) continue;   /* room made: another server's */
		}
		pthread_cond_wait(&pool_cond, &pool_lock);
	}
	sv->open++;
	total_open++;
	pthread_mutex_unlock(&pool_lock);
	*reused = false;
	if (c->aborted) s = -1;
	else s = open_conn(c, err, errlen);
	if (s < 0) {
		pthread_mutex_lock(&pool_lock);
		sv->open--;
		total_open--;
		pthread_cond_broadcast(&pool_cond);
		pthread_mutex_unlock(&pool_lock);
	}
	return s;
}

/* a connection given back: kept open for the next, or closed */
static void release(struct mhttp *c, long long s, bool keep)
{
	struct server *sv;
	struct conn *k = keep ? malloc(sizeof *k) : NULL;
	pthread_mutex_lock(&pool_lock);
	sv = server_of(c);
	if (k != NULL && sv != NULL) {
		k->sock = s;
		k->since = now_ms();
		k->next = sv->idle;
		sv->idle = k;
	} else if (sv != NULL) {
		sv->open--;
		total_open--;
	}
	pthread_cond_broadcast(&pool_cond);
	pthread_mutex_unlock(&pool_lock);
	if (k == NULL) sock_close(s);
}

/* the request on socket s, the reply read into rd: 0 when it ended */
static int exchange(struct mhttp *c, long long s, struct reader *rd,
		    size_t *bytes, double *t_sent, double *t_first,
		    char *err, size_t errlen)
{
	wire_writer w;
	if (sock_send((int)s, c->request, c->request_len, err, errlen) < 0) return -1;
	*t_sent = now_ms();
	while (!c->aborted && !rd->done) {
		wire_reader r;
		mynos_msg_t *msg;
		unsigned int n;
		const char *d;
		net_start(&w, N_RECV);
		wire_put_int(&w, s);
		wire_put_int(&w, CHUNK);
		if (net_call(&w, &r, &msg, err, errlen) < 0) return -1;
		d = wire_get_string(&r, &n);
		if (d == NULL || n == 0) {          /* the server closed */
			mynos_freeMsg(&msg);
			rd->conn_close = true;
			if (rd->in_body && !rd->chunked) { rd->done = true; return 0; }
			snprintf(err, errlen, "the connection closed early");
			return -1;
		}
		if (*t_first == 0) *t_first = now_ms();
		*bytes += n;
		feed(rd, d, n);
		mynos_freeMsg(&msg);
	}
	return rd->done ? 0 : -1;
}

static void *worker(void *arg)
{
	struct mhttp *c = arg;
	char err[200] = "";
	struct reader rd;
	bool free_now, reused = false;
	long long s;
	int attempt;
	double t0 = now_ms(), t_conn = 0, t_sent = 0, t_first = 0;
	size_t bytes = 0;

	memset(&rd, 0, sizeof rd);
	for (attempt = 0; attempt < 2; attempt++) {
		int r;
		memset(&rd, 0, sizeof rd);
		rd.c = c;
		rd.remaining = -1;
		err[0] = '\0';
		s = acquire(c, &reused, err, sizeof err);
		t_conn = now_ms();
		if (s < 0) break;
		r = c->aborted ? -1 : exchange(c, s, &rd, &bytes, &t_sent, &t_first, err, sizeof err);
		if (r == 0) {
			bool keep = !rd.conn_close &&
				(rd.no_body || rd.chunked || rd.has_length);
			release(c, s, keep);
			break;
		}
		release(c, s, false);
		/* a connection kept open that the server had closed meanwhile:
		   once more on a new one, if nothing came and it may be sent
		   again */
		if (!(reused && bytes == 0 && !c->post && !c->aborted)) break;
		free(rd.hbuf);
		rd.hbuf = NULL;
	}

	if (rd.done) push(c, I_DONE, 0, NULL, 0);
	else if (!c->aborted) push(c, I_ERROR, 0, err[0] ? err : "fetch failed", strlen(err[0] ? err : "fetch failed"));
	if (getenv("NSFB_DEBUG") != NULL && mynos_log != NULL)
		mynos_log("nsfb time: %s %s:%d%s start %.0f connect %.0f send %.0f first %.0f end %.0f bytes %u\n",
			  c->tls ? "tls" : "tcp", c->host, c->port, reused ? " reused" : "", t0,
			  t_conn - t0, t_sent ? t_sent - t_conn : 0,
			  t_first ? t_first - t_sent : 0, now_ms() - t0, (unsigned)bytes);
	if (!rd.done && getenv("NSFB_DEBUG") != NULL && mynos_log != NULL)
		mynos_log("nsfb http: %s:%d: %s%s\n", c->host, c->port,
			  c->aborted ? "aborted " : "", err[0] ? err : "fetch failed");
	free(rd.hbuf);

	pthread_mutex_lock(&c->lock);
	c->worker_done = true;
	free_now = c->freed;
	pthread_mutex_unlock(&c->lock);
	if (free_now) free_context(c);
	return NULL;
}

/* ---- NetSurf's side ---- */

struct buf { char *p; size_t len, cap; };

static void put(struct buf *b, const char *s, size_t n)
{
	if (b->len + n + 1 > b->cap) {
		size_t cap = (b->len + n + 1) * 2;
		char *q = realloc(b->p, cap);
		if (q == NULL) return;
		b->p = q;
		b->cap = cap;
	}
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = '\0';
}

static void puts_(struct buf *b, const char *s) { put(b, s, strlen(s)); }

/* multipart/form-data: the fields as text (a file field sends its name) */
static void multipart(struct buf *body, const struct fetch_multipart_data *m,
		      const char *boundary)
{
	for (; m != NULL; m = m->next) {
		puts_(body, "--"); puts_(body, boundary); puts_(body, "\r\n");
		puts_(body, "Content-Disposition: form-data; name=\"");
		puts_(body, m->name); puts_(body, "\"");
		if (m->file) {
			puts_(body, "; filename=\""); puts_(body, m->value);
			puts_(body, "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
		} else {
			puts_(body, "\r\n\r\n"); puts_(body, m->value);
		}
		puts_(body, "\r\n");
	}
	puts_(body, "--"); puts_(body, boundary); puts_(body, "--\r\n");
}

static void *mhttp_setup(struct fetch *parent, nsurl *url, bool only_2xx,
			 bool downgrade_tls, const char *post_urlenc,
			 const struct fetch_multipart_data *post_multipart,
			 const char **headers)
{
	struct mhttp *c = calloc(1, sizeof *c);
	lwc_string *host, *port;
	char *path = NULL, *cookie;
	size_t path_len = 0;
	struct buf req = { NULL, 0, 0 }, body = { NULL, 0, 0 };
	char line[512];
	(void)downgrade_tls;

	if (c == NULL) return NULL;
	c->parent = parent;
	c->url = nsurl_ref(url);
	c->only_2xx = only_2xx;
	c->tls = nsurl_get_scheme_type(url) == NSURL_SCHEME_HTTPS;
	c->port = c->tls ? 443 : 80;
	pthread_mutex_init(&c->lock, NULL);

	host = nsurl_get_component(url, NSURL_HOST);
	c->host = strdup(host ? lwc_string_data(host) : "");
	if (host) lwc_string_unref(host);
	port = nsurl_get_component(url, NSURL_PORT);
	if (port) {
		c->port = atoi(lwc_string_data(port));
		lwc_string_unref(port);
	}
	if (nsurl_get(url, NSURL_PATH | NSURL_QUERY, &path, &path_len) != NSERROR_OK) {
		free_context(c);
		return NULL;
	}

	if (post_urlenc != NULL) {
		c->post = true;
		puts_(&body, post_urlenc);
	} else if (post_multipart != NULL) {
		c->post = true;
		multipart(&body, post_multipart, "----MyNOSNetSurfBoundary7d1");
	}

	puts_(&req, c->post ? "POST " : "GET ");
	put(&req, path_len ? path : "/", path_len ? path_len : 1);
	puts_(&req, " HTTP/1.1\r\nHost: ");
	puts_(&req, c->host);
	if (c->port != (c->tls ? 443 : 80)) {
		snprintf(line, sizeof line, ":%d", c->port);
		puts_(&req, line);
	}
	puts_(&req, "\r\nUser-Agent: ");
	puts_(&req, user_agent_string());
	puts_(&req, "\r\nAccept-Encoding: identity\r\n");
	cookie = urldb_get_cookie(url, true);
	if (cookie != NULL) {
		puts_(&req, "Cookie: ");
		puts_(&req, cookie);
		puts_(&req, "\r\n");
		free(cookie);
	}
	for (; headers != NULL && *headers != NULL; headers++) {
		puts_(&req, *headers);
		puts_(&req, "\r\n");
	}
	if (c->post) {
		puts_(&req, post_urlenc != NULL ?
		      "Content-Type: application/x-www-form-urlencoded\r\n" :
		      "Content-Type: multipart/form-data; boundary=----MyNOSNetSurfBoundary7d1\r\n");
		snprintf(line, sizeof line, "Content-Length: %zu\r\n", body.len);
		puts_(&req, line);
	}
	puts_(&req, "\r\n");
	if (body.len) put(&req, body.p, body.len);
	free(body.p);
	free(path);
	if (req.p == NULL) {
		free_context(c);
		return NULL;
	}
	c->request = req.p;
	c->request_len = req.len;

	RING_INSERT(ring, c);
	return c;
}

static bool mhttp_start(void *ctx)
{
	struct mhttp *c = ctx;
	pthread_t t;
	pthread_attr_t a;
	pthread_attr_init(&a);
	pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
	if (pthread_create(&t, &a, worker, c) != 0) {
		pthread_attr_destroy(&a);
		return false;
	}
	pthread_attr_destroy(&a);
	c->started = true;
	return true;
}

static void mhttp_abort(void *ctx)
{
	/* the poll ends it, and the thread stops at its next step */
	((struct mhttp *)ctx)->aborted = true;
}

static void mhttp_free(void *ctx)
{
	struct mhttp *c = ctx;
	bool free_now;
	pthread_mutex_lock(&c->lock);
	c->freed = true;
	free_now = c->worker_done || !c->started;
	pthread_mutex_unlock(&c->lock);
	if (free_now) free_context(c);
}

static void send_msg(struct mhttp *c, fetch_msg *msg)
{
	c->locked = true;
	fetch_send_callback(msg, c->parent);
	c->locked = false;
}

/* the reply's headers are all there: what they make of the fetch */
static bool after_headers(struct mhttp *c)
{
	fetch_msg msg;
	long code = c->http_code;
	if (code == 304 && !c->post) {
		msg.type = FETCH_NOTMODIFIED;
		send_msg(c, &msg);
		return true;
	}
	if (code >= 300 && code < 400 && c->location != NULL) {
		msg.type = FETCH_REDIRECT;
		msg.data.redirect = c->location;
		send_msg(c, &msg);
		return true;
	}
	if (c->only_2xx && (code < 200 || code > 299)) {
		msg.type = FETCH_ERROR;
		msg.data.error = messages_get("Not2xx");
		send_msg(c, &msg);
		return true;
	}
	return false;
}

/* one item from the thread: true when the fetch is over */
static bool deliver(struct mhttp *c, struct item *it)
{
	fetch_msg msg;
	switch (it->type) {
	case I_CODE:
		c->http_code = it->code;
		fetch_set_http_code(c->parent, it->code);
		return false;
	case I_HEADER:
		if (strncasecmp(it->buf, "Location:", 9) == 0) {
			const char *v = it->buf + 9;
			while (*v == ' ' || *v == '\t') v++;
			free(c->location);
			c->location = strdup(v);
		} else if (strncasecmp(it->buf, "Set-Cookie:", 11) == 0) {
			const char *v = it->buf + 11;
			while (*v == ' ' || *v == '\t') v++;
			fetch_set_cookie(c->parent, v);
		}
		msg.type = FETCH_HEADER;
		msg.data.header_or_data.buf = (const uint8_t *)it->buf;
		msg.data.header_or_data.len = it->len;
		send_msg(c, &msg);
		return false;
	case I_END_HEADERS:
		return after_headers(c);
	case I_DATA:
		msg.type = FETCH_DATA;
		msg.data.header_or_data.buf = (const uint8_t *)it->buf;
		msg.data.header_or_data.len = it->len;
		send_msg(c, &msg);
		return false;
	case I_DONE:
		msg.type = FETCH_FINISHED;
		send_msg(c, &msg);
		return true;
	default:
		msg.type = FETCH_ERROR;
		msg.data.error = it->buf;
		send_msg(c, &msg);
		return true;
	}
}

static void mhttp_poll(lwc_string *scheme)
{
	struct mhttp *c, *save = NULL;
	(void)scheme;

	while (ring != NULL) {
		struct item *items, *it, *next;
		bool over = false;
		c = ring;
		RING_REMOVE(ring, c);
		if (c->locked) {
			RING_INSERT(save, c);
			continue;
		}
		pthread_mutex_lock(&c->lock);
		items = c->head;
		c->head = c->tail = NULL;
		pthread_mutex_unlock(&c->lock);
		for (it = items; it != NULL; it = next) {
			next = it->next;
			if (!over && !c->aborted) over = deliver(c, it);
			if (it->type == I_ERROR && c->error == NULL) c->error = it;
			else free(it);
		}
		if (over) c->aborted = true;       /* the thread stops too */
		if (over || c->aborted) {
			fetch_remove_from_queues(c->parent);
			fetch_free(c->parent);      /* calls mhttp_free */
		} else {
			RING_INSERT(save, c);
		}
	}
	ring = save;
}

static bool mhttp_initialise(lwc_string *scheme)
{
	(void)scheme;
	if (net_port < 0) net_port = mynos_registryLookUp((char *)"net");
	return true;
}

static void mhttp_finalise(lwc_string *scheme) { (void)scheme; }

static bool mhttp_acceptable(const nsurl *url) { (void)url; return true; }

nserror fetch_mynos_http_register(void)
{
	const struct fetcher_operation_table ops = {
		.initialise = mhttp_initialise,
		.acceptable = mhttp_acceptable,
		.setup = mhttp_setup,
		.start = mhttp_start,
		.abort = mhttp_abort,
		.free = mhttp_free,
		.poll = mhttp_poll,
		.finalise = mhttp_finalise
	};
	nserror e;
	if (mynos_connectToPort == NULL) return NSERROR_OK;     /* not MyNOS */
	e = fetcher_add(lwc_string_ref(corestring_lwc_http), &ops);
	if (e != NSERROR_OK) return e;
	return fetcher_add(lwc_string_ref(corestring_lwc_https), &ops);
}

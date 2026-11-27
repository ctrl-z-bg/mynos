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
 * A Raspberry Pi's Wi-Fi as netd's card (btq.9, doc/decisions/wifi.md):
 * wifid drives the chip and joins the network; its frames come here over
 * IPC. wifi/1: on "wifi" 0 the MAC address, 1 send a frame; on "wifirx" 3
 * receive (the frames waiting, or those within a second, each a 16-bit
 * length and its bytes). A thread of ours waits on "wifirx" and keeps the
 * frames for wifi_recv, waking netd's main loop as an interrupt would.
 */

#include <string.h>
#include <pthread.h>
#include <mynos.h>
#include <mynos_wire.h>
#include "wifinet.h"
#include "ne2k.h"

#define QLEN 64
static unsigned char q[QLEN][NE2K_BUFSIZE];
static int qlen[QLEN], qhead, qn;
static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;
static void (*wake_main)(void);
static int wifi_port = -1, rx_port = -1;

/* a request to port: its reply's reader (the message in *m), or -1 */
static int request(int port, wire_writer * w, mynos_msg_t ** m, wire_reader * r, int ms)
{
  int ch, st;
  if (w->error || port < 0) return -1;
  ch = mynos_connectToPort(port);
  if (ch < 0) return -1;
  if (mynos_send(ch, w->buf, w->len, 0) < 0 || mynos_recv(ch, m, 0, ms) < 0) {
    mynos_freeChannel(ch);
    return -1;
  }
  mynos_freeChannel(ch);
  wire_reader_init(r, (*m)->start, (*m)->size);
  st = (int)wire_get_int(r);
  if (r->error || st != 0) { mynos_freeMsg(m); return -1; }
  return 0;
}

static void * receiver(void * arg)
{
  (void)arg;
  for (;;) {
    wire_writer w;
    wire_reader r;
    mynos_msg_t * m;
    const unsigned char * p;
    unsigned int n, i;
    int got = 0;
    wire_writer_init(&w);
    wire_put_cstring(&w, "wifi/1");
    wire_put_int(&w, 3);
    wire_put_int(&w, 1000);
    if (request(rx_port, &w, &m, &r, 3000) < 0) {
      wire_writer_free(&w);
      mynos_sleep(100000);
      continue;
    }
    wire_writer_free(&w);
    p = (const unsigned char *)wire_get_string(&r, &n);
    pthread_mutex_lock(&qlock);
    for (i = 0; !r.error && i + 2 <= n; ) {
      unsigned int l = p[i] | p[i + 1] << 8;
      if (i + 2 + l > n) break;
      if (qn < QLEN && l <= NE2K_BUFSIZE) {
        int j = (qhead + qn) % QLEN;
        memcpy(q[j], p + i + 2, l);
        qlen[j] = (int)l;
        qn++;
        got = 1;
      }
      i += 2 + l;
    }
    pthread_mutex_unlock(&qlock);
    mynos_freeMsg(&m);
    if (got && wake_main) wake_main();
  }
  return NULL;
}

int wifi_init(unsigned char mac[6], int wait_s, void (*wake)(void))
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * m;
  const char * s;
  unsigned int n;
  pthread_t t;
  int i;
  for (i = 0; i < wait_s * 10; i++) {
    wifi_port = mynos_registryLookUp("wifi");
    rx_port = mynos_registryLookUp("wifirx");
    if (wifi_port >= 0 && rx_port >= 0) break;
    mynos_sleep(100000);
  }
  if (wifi_port < 0 || rx_port < 0) return -1;
  wire_writer_init(&w);
  wire_put_cstring(&w, "wifi/1");
  wire_put_int(&w, 0);
  if (request(wifi_port, &w, &m, &r, 2000) < 0) { wire_writer_free(&w); return -1; }
  wire_writer_free(&w);
  s = wire_get_string(&r, &n);
  if (r.error || n != 6) { mynos_freeMsg(&m); return -1; }
  memcpy(mac, s, 6);
  mynos_freeMsg(&m);
  wake_main = wake;
  pthread_create(&t, NULL, receiver, NULL);
  return 0;
}

int wifi_send(const void * frame, unsigned int len)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * m;
  int e;
  wire_writer_init(&w);
  wire_put_cstring(&w, "wifi/1");
  wire_put_int(&w, 1);
  wire_put_string(&w, frame, len);
  e = request(wifi_port, &w, &m, &r, 1000);
  wire_writer_free(&w);
  if (e < 0) return -1;
  mynos_freeMsg(&m);
  return 0;
}

int wifi_recv(void * buf)
{
  int n = 0;
  pthread_mutex_lock(&qlock);
  if (qn) {
    n = qlen[qhead];
    memcpy(buf, q[qhead], (size_t)n);
    qhead = (qhead + 1) % QLEN;
    qn--;
  }
  pthread_mutex_unlock(&qlock);
  return n;
}

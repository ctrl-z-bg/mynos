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
 * wifid: the Wi-Fi of a Raspberry Pi 4, 400 or CM4 (btq.9, doc/decisions/
 * wifi.md): a Cypress (now Infineon/Synaptics) FullMAC chip, CYW43455 or
 * CYW43456 (chip 0x4345, revision 6 or 9), on SDIO (sdio.c). FullMAC: the
 * chip's own ARM runs the 802.11 stack and WPA2; the host loads its
 * firmware and talks to it.
 *
 * As Linux's brcmfmac does (its register names kept), here so far:
 *   1. the board: a Pi 4, 400 or CM4 only (its revision code: on a Pi 3
 *      the same controller is the SD card's);
 *   2. the SDIO card (sdio_init), the chip's backplane clock (ALP), its
 *      id from the chipcommon core;
 *   3. its cores, from the enumeration ROM (EROM): chipcommon, the SDIO
 *      device core, the ARM Cortex-R4 and its RAM (TCM, from 0x198000),
 *      the 802.11 core;
 *   4. the ARM halted, the firmware written at the RAM's base, the NVRAM
 *      (the board's settings, /disk/wifi's .txt made into "key=value\0"s
 *      and a length token) at its end, the reset vector at 0, the ARM
 *      released;
 *   5. the fast clock (HT), function 2 (the frames) enabled: the
 *      firmware runs;
 *   6. SDPCM, the frames' protocol over function 2 (a 12-byte header:
 *      length, its complement, a sequence number, a channel: 0 control,
 *      1 events, 2 data), and BCDC on channel 0, the firmware's
 *      commands: "ver" (its version) and "cur_etheraddr" (its MAC
 *      address) asked and logged.
 * Next (btq.9): the CLM (the radio's rules), a scan, joining with WPA2
 * (the firmware's own supplicant), the frames to netd.
 *
 * The firmware's files (Synaptics's licence: redistributed in binary
 * form for use with its chips only) are not in MyNOS: make-sd-raspi.sh
 * puts them on the card, in /disk/wifi.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <mynos.h>
#include <mynos_wire.h>
#include "sdio.h"
#include "wpa.h"

#define WIFI_DIR "/disk/wifi/"

/* ---- the chip's cores ---- */

#define CHIPCOMMON 0x18000000u
#define CORE_CC    0x800
#define CORE_D11   0x812
#define CORE_SDIO  0x829
#define CORE_CR4   0x83E

struct core { unsigned int id, base, wrap; };
static struct core cores[32];
static int ncores;

static struct core * core(unsigned int id)
{
  int i;
  for (i = 0; i < ncores; i++) if (cores[i].id == id) return &cores[i];
  return NULL;
}

static unsigned int rd(unsigned int addr)
{
  unsigned int v = 0xFFFFFFFF;
  if (bp_read32(addr, &v) < 0) mynos_log("wifid: backplane read %08x failed\n", addr);
  return v;
}

static void wr(unsigned int addr, unsigned int v)
{
  if (bp_write32(addr, v) < 0) mynos_log("wifid: backplane write %08x failed\n", addr);
}

/* the EROM's descriptors (brcmfmac's chip.c, DMP_*) */
#define DESC_TYPE(V)     ((V) & 0xF)
#define DESC_COMPONENT   1
#define DESC_MASTER_PORT 3
#define DESC_ADDRESS     5
#define DESC_GT32        8
#define DESC_EOT         0xF

static unsigned int desc(unsigned int * at, int * type)
{
  unsigned int v = rd(*at);
  *at += 4;
  if (type) {
    *type = (int)DESC_TYPE(v);
    if ((*type & ~DESC_GT32) == DESC_ADDRESS) *type = DESC_ADDRESS;
  }
  return v;
}

/* a component's register base and wrapper: 0, or -1 */
static int regaddr(unsigned int * at, unsigned int * base, unsigned int * wrap)
{
  int type, wraptype, sztype, stype;
  unsigned int v;
  *base = *wrap = 0;
  v = desc(at, &type);
  if (type == DESC_MASTER_PORT) wraptype = 3;      /* a master wrapper */
  else if (type == DESC_ADDRESS) { *at -= 4; wraptype = 2; }   /* a slave one */
  else { *at -= 4; return -1; }
  do {
    do {
      v = desc(at, &type);
      if (type == DESC_EOT) { *at -= 4; return -1; }
    } while (type != DESC_ADDRESS && type != DESC_COMPONENT);
    if (type == DESC_COMPONENT) { *at -= 4; return 0; }
    if (v & DESC_GT32) desc(at, NULL);
    sztype = (int)(v >> 4) & 3;
    if (sztype == 3) {
      unsigned int sz = desc(at, NULL);
      if (sz & DESC_GT32) desc(at, NULL);
    }
    if (sztype != 0 && sztype != 1) continue;     /* 4 KB or 8 KB regions only */
    stype = (int)(v >> 6) & 3;
    if (*base == 0 && stype == 0) *base = v & 0xFFFFF000u;
    if (*wrap == 0 && stype == wraptype) *wrap = v & 0xFFFFF000u;
  } while (*base == 0 || *wrap == 0);
  return 0;
}

static void erom_scan(void)
{
  unsigned int at = rd(CHIPCOMMON + 0xFC), v, id, base, wrap;
  int type = 0, n = 0;
  while (type != DESC_EOT && n++ < 1024) {
    v = desc(&at, &type);
    if (!(v & 1) || type != DESC_COMPONENT) continue;
    id = (v >> 8) & 0xFFF;
    v = desc(&at, &type);
    if (DESC_TYPE(v) != DESC_COMPONENT) break;
    if (((v >> 14) & 0x1F) + ((v >> 19) & 0x1F) == 0) continue;   /* no wrappers */
    if (regaddr(&at, &base, &wrap) < 0) continue;
    if (ncores < 32) {
      cores[ncores].id = id;
      cores[ncores].base = base;
      cores[ncores].wrap = wrap;
      ncores++;
    }
  }
}

/* a core's reset, through its wrapper (BCMA_IOCTL 0x408, BCMA_RESET_CTL
   0x800): disabled (prereset, reset: its IOCTL's bits then), then out of
   reset (postreset) */
#define IOCTL_CLK 1
#define IOCTL_FGC 2

static void core_disable(struct core * c, unsigned int prereset, unsigned int reset)
{
  int i;
  if (!(rd(c->wrap + 0x800) & 1)) {
    wr(c->wrap + 0x408, prereset | IOCTL_FGC | IOCTL_CLK);
    rd(c->wrap + 0x408);
    wr(c->wrap + 0x800, 1);
    for (i = 0; i < 300 && rd(c->wrap + 0x800) != 1; i++) ;
  }
  wr(c->wrap + 0x408, reset | IOCTL_FGC | IOCTL_CLK);
  rd(c->wrap + 0x408);
}

static void core_reset(struct core * c, unsigned int prereset, unsigned int reset,
                       unsigned int postreset)
{
  int i;
  core_disable(c, prereset, reset);
  for (i = 0; i < 50 && (rd(c->wrap + 0x800) & 1); i++) {
    wr(c->wrap + 0x800, 0);
    mynos_sleep(1000);
  }
  wr(c->wrap + 0x408, postreset | IOCTL_CLK);
  rd(c->wrap + 0x408);
}

#define CR4_CPUHALT      0x20
#define D11_PHYCLOCKEN   0x04
#define D11_PHYRESET     0x08

/* the ARM's RAM: its banks' sizes (ARMCR4_CAP 0x04, BANKIDX 0x40,
   BANKINFO 0x44) */
static unsigned int ram_size(struct core * arm)
{
  unsigned int cap = rd(arm->base + 0x04), size = 0, n, i, info;
  n = (cap & 0xF) + ((cap >> 4) & 0xF);
  for (i = 0; i < n; i++) {
    wr(arm->base + 0x40, i);
    info = rd(arm->base + 0x44);
    size += ((info & 0x7F) + 1) * ((info & 0x200) ? 1024 : 8192);
  }
  return size;
}

/* ---- the files ---- */

static unsigned char * load(const char * name, long * len)
{
  char path[96];
  FILE * f;
  unsigned char * b;
  long n;
  int tries;
  snprintf(path, sizeof path, WIFI_DIR "%s", name);
  for (tries = 0; tries < 30 && !(f = fopen(path, "rb")); tries++)
    mynos_sleep(1000000);              /* (/disk comes up after us) */
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  n = ftell(f);
  fseek(f, 0, SEEK_SET);
  b = malloc((size_t)n + 8);
  if (b && fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); b = NULL; }
  fclose(f);
  if (b) memset(b + n, 0, 8);
  *len = n;
  return b;
}

/* the NVRAM's text made into "key=value\0"s, padded, the length token
   last (brcmfmac's brcmf_fw_nvram_strip) */
static unsigned char * nvram(const unsigned char * t, long n, int * out)
{
  unsigned char * b = calloc((size_t)n + 16, 1);
  long i = 0;
  int len = 0, words;
  unsigned int token;
  if (!b) return NULL;
  while (i < n) {
    long s = i, e;
    while (i < n && t[i] != '\n') i++;
    e = i++;
    while (s < e && (t[s] == ' ' || t[s] == '\t')) s++;
    while (e > s && (t[e - 1] == '\r' || t[e - 1] == ' ' || t[e - 1] == '\t')) e--;
    if (s == e || t[s] == '#' || !memchr(t + s, '=', (size_t)(e - s))) continue;
    memcpy(b + len, t + s, (size_t)(e - s));
    len += (int)(e - s);
    b[len++] = 0;
  }
  len = (len + 1 + 3) & ~3;            /* (one 0 at least, then padding) */
  words = len / 4;
  token = (~(unsigned int)words << 16) | ((unsigned int)words & 0xFFFF);
  memcpy(b + len, &token, 4);
  *out = len + 4;
  return b;
}

/* ---- SDPCM and BCDC ---- */

#define SDIO_INTSTATUS     0x20
#define SDIO_HOSTINTMASK   0x24
#define SDIO_TOSBMAILBOX   0x40
#define SDIO_TOSBMBXDATA   0x48
#define SDIO_TOHOSTMBXDATA 0x4C
#define I_HMB_FRAME_IND    (1u << 6)
#define I_HMB_HOST_INT     (1u << 7)
#define HOSTINTMASK        (0xF0u | 1u << 29)

#define F2_ADDR 0x8000
#define FRAME   4096

static struct core * sdc;               /* the chip's SDIO device core */
static unsigned char tx_seq, tx_max = 4;
static unsigned short reqid;
static unsigned char frame[FRAME + 512];
static int events;
/* what came while a command waited (logged when its answer does not) */
static int seen_ctl, seen_ev, seen_data, seen_other, seen_ids[4][3];
static void on_event(const unsigned char * p, int len);
static int handle_frames(int want_id, unsigned char * out, int max, int * status);
static void rx_frame(const unsigned char * eth, int n);

/* EAPOL frames received, handled after the frames' loop (their replies
   and the keys go out through frame[]) */
static unsigned char eapol[4][600];
static int eapol_len[4], neapol;

static void put32(unsigned char * p, unsigned int v)
{
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
static unsigned int get32(const unsigned char * p)
{
  return p[0] | p[1] << 8 | p[2] << 16 | (unsigned int)p[3] << 24;
}

/* the firmware's window: may a frame be sent (SDPCM's credit: the
   sequence number below the last window it gave) */
static int credit(void)
{
  unsigned char d = (unsigned char)(tx_max - tx_seq);
  return d != 0 && !(d & 0x80);
}

/* a frame on channel ch: its payload already at frame + 12 (credit waited
   for: a frame beyond the window is dropped by the firmware) */
static int send_frame(int ch, int len)
{
  int total = len + 12, padded = (total + 3) & ~3, i, st;
  static unsigned char hold[FRAME + 512];
  if (!credit()) {
    memcpy(hold, frame, (size_t)total);   /* (the frames read go through frame[]) */
    for (i = 0; i < 1000 && !credit(); i++) {
      handle_frames(-1, hold + FRAME, 0, &st);
      if (!credit()) mynos_sleep(1000);
    }
    memcpy(frame, hold, (size_t)total);
    if (!credit()) mynos_log("wifid: no credit from the firmware (seq %u, max %u)\n", tx_seq, tx_max);
  }
  if (padded > 512) padded = (padded + 511) & ~511;
  frame[0] = total; frame[1] = total >> 8;
  frame[2] = ~total; frame[3] = ~total >> 8;
  frame[4] = tx_seq;
  frame[5] = ch & 0xF;
  frame[6] = 0;
  frame[7] = 12;                       /* the data's offset */
  memset(frame + 8, 0, 4);
  memset(frame + total, 0, (size_t)(padded - total));
  tx_seq++;
  return sdio_ext(1, 2, F2_ADDR, frame, padded);
}

/* a frame read into buf (FRAME bytes): its length, 0 if none, -1 (the
   first failures logged) */
static int read_errors;
static int read_frame(unsigned char * buf)
{
  int len, chk, got = 64;
  if (sdio_ext(0, 2, F2_ADDR, buf, 64) < 0) {
    if (read_errors++ < 10) mynos_log("wifid: a frame's header not read\n");
    return -1;
  }
  len = buf[0] | buf[1] << 8;
  chk = buf[2] | buf[3] << 8;
  if (len == 0 && chk == 0) return 0;
  if ((len ^ chk) != 0xFFFF || len < 12 || len > FRAME) {
    if (read_errors++ < 10)
      mynos_log("wifid: a bad frame header: %04x %04x %02x %02x %02x %02x\n", len, chk,
                buf[4], buf[5], buf[6], buf[7]);
    sdio_byte(0, 0x06, 2);             /* function 2's read aborted */
    wr(sdc->base + SDIO_TOSBMAILBOX, 1);   /* (a NAK: the firmware sends it again) */
    return -1;
  }
  while (got < len) {
    int n = (len - got + 3) & ~3;
    if (n > 512) n = 512;
    if (sdio_ext(0, 2, F2_ADDR, buf + got, n) < 0) {
      if (read_errors++ < 10) mynos_log("wifid: a frame of %d bytes: read failed at %d\n", len, got);
      return -1;
    }
    got += n;
  }
  tx_max = buf[9];
  return len;
}

/* a BCDC reply's payload, for request id (up to max bytes into out): its
   length, or -1 (an error of the firmware's: its status in *status) */
static int handle_frames(int want_id, unsigned char * out, int max, int * status)
{
  unsigned int st;
  int len, r = -2;
  st = rd(sdc->base + SDIO_INTSTATUS);
  if (st == 0xFFFFFFFF) return -2;
  if (st) wr(sdc->base + SDIO_INTSTATUS, st);
  if (st & I_HMB_HOST_INT) {
    unsigned int m = rd(sdc->base + SDIO_TOHOSTMBXDATA);
    wr(sdc->base + SDIO_TOSBMAILBOX, 2);   /* acknowledged */
    if (m & 0x08) mynos_log("wifid: the firmware says it is ready\n");
  }
  /* every frame waiting: read whether the chip said so or not (a frame
     coming while the indication is acknowledged would wait for the next
     one's otherwise) */
  while ((len = read_frame(frame)) > 0) {
    int ch = frame[5] & 0xF, off = frame[7];
    unsigned char * p = frame + off;
    if (off < 12 || off > len) continue;
    if (ch == 0 && len >= off + 16) {
      unsigned int flags = get32(p + 8);
      int n = (int)get32(p + 4);
      if (want_id < 0 || (int)(flags >> 16) != want_id) {
        if (seen_ctl < 4) {
          seen_ids[seen_ctl][0] = (int)get32(p);
          seen_ids[seen_ctl][1] = (int)(flags >> 16);
          seen_ids[seen_ctl][2] = (int)get32(p + 12);
        }
        seen_ctl++;
        continue;
      }
      *status = (int)get32(p + 12);
      if (flags & 1) { r = -1; continue; }
      if (n > len - off - 16) n = len - off - 16;
      if (n > max) n = max;
      if (n > 0) memcpy(out, p + 16, (size_t)n);
      r = n > 0 ? n : 0;
    } else if (ch == 1) {
      events++;
      seen_ev++;
      on_event(p, len - off);
    } else if (ch == 2 && len - off > 4 + p[3] * 4 + 14) {
      /* data: BDC's header, an Ethernet frame; EAPOL's kept */
      const unsigned char * eth = p + 4 + p[3] * 4;
      int n = len - off - 4 - p[3] * 4;
      seen_data++;
      if (eth[12] == 0x88 && eth[13] == 0x8E) {
        if (neapol < 4 && n <= 600) {
          memcpy(eapol[neapol], eth, (size_t)n);
          eapol_len[neapol++] = n;
        }
      } else
        rx_frame(eth, n);              /* to netd */
    } else {
      if (seen_other++ < 3)
        mynos_log("wifid: a frame on channel %d, %d bytes (flags %02x)\n", ch, len, frame[5]);
    }
  }
  return r;
}

/* a command to the firmware (BCDC), its reply waited for: the reply's
   length, or -1 */
static int dcmd(unsigned int cmd, int set, const void * data, int len, void * reply, int max)
{
  unsigned char * p = frame + 12;
  int i, r, status = 0, attempt;
  if (len > FRAME - 64) return -1;
  for (attempt = 0; attempt < 2; attempt++) {
    unsigned char seq = tx_seq;
    put32(p, cmd);
    put32(p + 4, (unsigned int)len);
    put32(p + 8, (unsigned int)++reqid << 16 | (set ? 2u : 0));
    put32(p + 12, 0);
    memcpy(p + 16, data, (size_t)len);
    seen_ctl = seen_ev = seen_data = seen_other = 0;
    if (send_frame(0, 16 + len) < 0) { mynos_log("wifid: a command not sent\n"); return -1; }
    for (i = 0; i < 2000; i++) {
      r = handle_frames(reqid, reply, max, &status);
      if (r >= 0) return r;
      if (r == -1) { mynos_log("wifid: command %u failed (%d)\n", cmd, status); return -1; }
      mynos_sleep(1000);
    }
    mynos_log("wifid: command %u (id %u, seq %u, window %u): no answer; meanwhile %d control"
              " (%d %d %d, %d %d %d), %d events, %d data\n", cmd, reqid, seq, tx_max, seen_ctl,
              seen_ids[0][0], seen_ids[0][1], seen_ids[0][2],
              seen_ids[1][0], seen_ids[1][1], seen_ids[1][2], seen_ev, seen_data);
  }
  return -1;
}

#define C_UP          2
#define C_SET_INFRA   20
#define C_SET_AUTH    22
#define C_SET_SSID    26
#define C_SET_WSEC    134
#define C_SET_WPA_AUTH 165
#define C_GET_VAR     262
#define C_SET_VAR     263
#define C_SET_WSEC_PMK 268

/* an iovar read: "name\0" sent in a buffer of max bytes, the value back */
static int get_var(const char * name, void * out, int max)
{
  unsigned char b[512];
  int n = (int)strlen(name) + 1, len = n > max ? n : max;
  if (len > (int)sizeof b) return -1;
  memset(b, 0, sizeof b);
  memcpy(b, name, (size_t)n);
  return dcmd(C_GET_VAR, 0, b, len, out, max);
}

/* an iovar set: "name\0" and its value */
static int set_var(const char * name, const void * value, int len)
{
  static unsigned char b[2048];
  unsigned char dummy[4];
  int n = (int)strlen(name) + 1;
  if (n + len > (int)sizeof b) return -1;
  memcpy(b, name, (size_t)n);
  memcpy(b + n, value, (size_t)len);
  return dcmd(C_SET_VAR, 1, b, n + len, dummy, 0) < 0 ? -1 : 0;
}

static int set_int(unsigned int cmd, int v)
{
  unsigned char b[4], dummy[4];
  put32(b, (unsigned int)v);
  return dcmd(cmd, 1, b, 4, dummy, 0) < 0 ? -1 : 0;
}

/* ---- events (on channel 1: BDC's header, an Ethernet frame of type
   0x886C, Broadcom's event message, big-endian) ---- */

#define E_SET_SSID     0
#define E_AUTH         3
#define E_DEAUTH       5
#define E_DEAUTH_IND   6
#define E_ASSOC        7
#define E_DISASSOC     11
#define E_DISASSOC_IND 12
#define E_LINK         16
#define E_PSK_SUP      46
#define E_ESCAN_RESULT 69
#define S_PARTIAL      8

static unsigned int be32(const unsigned char * p)
{
  return (unsigned int)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

struct bss { unsigned char bssid[6], ssid[33]; int channel, rssi, secured, group; };
static struct bss bsses[48];
static int nbss, scan_done, link_up, keyed, joined;

static void scan_result(const unsigned char * d, int n)
{
  const unsigned char * b;
  struct bss * x;
  int i, len;
  if (n < 12 + 82) return;
  b = d + 12;                          /* (buflen, version, sync_id, bss_count) */
  len = b[18] > 32 ? 32 : b[18];
  for (i = 0; i < nbss; i++) if (!memcmp(bsses[i].bssid, b + 8, 6)) break;
  if (i == nbss) {
    if (nbss == 48) return;
    nbss++;
  }
  x = &bsses[i];
  memcpy(x->bssid, b + 8, 6);
  memcpy(x->ssid, b + 19, (size_t)len);
  x->ssid[len] = 0;
  x->channel = (b[72] | b[73] << 8) & 0xFF;
  x->rssi = (short)(b[78] | b[79] << 8);
  x->secured = (b[16] & 0x10) != 0;    /* the capability's privacy bit */
  x->group = 0;
  {                                    /* its RSN element's group cipher */
    int io = b[116] | b[117] << 8, il = (int)get32(b + 120), at = io;
    while (io && at + 2 <= io + il && 12 + at + 2 <= n) {
      int t = b[at], l = b[at + 1];
      if (12 + at + 2 + l > n) break;
      if (t == 0x30 && l >= 8) { x->group = b[at + 7]; x->secured = 2; break; }
      at += 2 + l;
    }
  }
}

static void on_event(const unsigned char * p, int len)
{
  const unsigned char * eth, * ev;
  unsigned int type, status, reason, dlen, flags;
  if (len < 4) return;
  eth = p + 4 + p[3] * 4;
  if (eth + 14 + 10 + 48 > p + len || eth[12] != 0x88 || eth[13] != 0x6C) return;
  ev = eth + 14 + 10;
  flags = (unsigned int)(ev[2] << 8 | ev[3]);
  type = be32(ev + 4);
  status = be32(ev + 8);
  reason = be32(ev + 12);
  dlen = be32(ev + 20);
  if (ev + 48 + dlen > p + len) dlen = (unsigned int)(p + len - (ev + 48));
  switch (type) {
  case E_ESCAN_RESULT:
    if (status == S_PARTIAL) scan_result(ev + 48, (int)dlen);
    else scan_done = 1;
    break;
  case E_SET_SSID:
    joined = status == 0;
    mynos_log("wifid: join %s (status %u)\n", status == 0 ? "done" : "failed", status);
    break;
  case E_LINK:
    link_up = flags & 1;
    mynos_log("wifid: link %s (reason %u)\n", link_up ? "up" : "down", reason);
    if (!link_up) keyed = 0;
    break;
  case E_PSK_SUP:
    mynos_log("wifid: the firmware's supplicant: state %u, reason %u\n", status, reason);
    break;
  case E_DEAUTH: case E_DEAUTH_IND: case E_DISASSOC: case E_DISASSOC_IND:
    mynos_log("wifid: disconnected (event %u, reason %u)\n", type, reason);
    break;
  case E_AUTH: case E_ASSOC:
    if (status) mynos_log("wifid: %s failed (status %u, reason %u)\n",
                          type == E_AUTH ? "authentication" : "association", status, reason);
    break;
  }
}

/* ---- WPA2's keys ---- */

static unsigned char own_mac[6];

/* an Ethernet frame on the data channel (BDC's header: version 2) */
static int send_data(const unsigned char * eth, int n)
{
  unsigned char * p = frame + 12;
  if (n > FRAME - 64) return -1;
  p[0] = 0x20; p[1] = 0; p[2] = 0; p[3] = 0;
  memcpy(p + 4, eth, (size_t)n);
  return send_frame(2, 4 + n);
}

/* a key to the firmware ("wsec_key": brcmfmac's brcmf_wsec_key_le, 164
   bytes): AES-CCM; a pairwise one with the AP's address */
static int set_key(int index, const unsigned char * key, int len, const unsigned char * ea, int primary)
{
  unsigned char k[164];
  memset(k, 0, sizeof k);
  put32(k, (unsigned int)index);
  put32(k + 4, (unsigned int)len);
  memcpy(k + 8, key, (size_t)len);
  put32(k + 112, 4);                   /* CRYPTO_ALGO_AES_CCM */
  put32(k + 116, primary ? 2 : 0);     /* BRCMF_PRIMARY_KEY */
  if (ea) memcpy(k + 156, ea, 6);
  return set_var("wsec_key", k, sizeof k);
}

static void handle_eapol(void)
{
  static unsigned char reply[300], f[600];
  struct wpa_keys k;
  int i, r, n = 0, fl;
  while (neapol > 0) {                 /* (a queue: more may come meanwhile) */
    fl = eapol_len[0];
    memcpy(f, eapol[0], (size_t)fl);
    for (i = 1; i < neapol; i++) {
      memcpy(eapol[i - 1], eapol[i], (size_t)eapol_len[i]);
      eapol_len[i - 1] = eapol_len[i];
    }
    neapol--;
    memset(&k, 0, sizeof k);
    r = wpa_eapol(f, fl, reply, &n, &k);
    if (r & WPA_REPLY) send_data(reply, n);
    {
      int ptk_ok = 1, gtk_ok = 1;
      if ((r & WPA_PTK) && set_key(0, k.tk, 16, k.ap, 0) < 0) {
        ptk_ok = 0;
        mynos_log("wifid: the pairwise key not installed\n");
      }
      if ((r & WPA_GTK) && set_key(k.gtk_idx, k.gtk, k.gtk_len, NULL, 1) < 0) {
        gtk_ok = 0;
        mynos_log("wifid: the group key not installed\n");
      }
      if ((r & WPA_PTK) && ptk_ok && gtk_ok) {
        keyed = 1;
        mynos_log("wifid: WPA2 keys installed (group key %d)\n", k.gtk_idx);
      } else if ((r & WPA_GTK) && !(r & WPA_PTK) && gtk_ok)
        mynos_log("wifid: the new group key installed (%d)\n", k.gtk_idx);
    }
  }
}

/* the events, for ms milliseconds (or until *flag) */
static void poll_events(int ms, int * flag)
{
  unsigned char dummy[4];
  int i, st;
  for (i = 0; i < ms / 10 && !(flag && *flag); i++) {
    handle_frames(-1, dummy, 0, &st);
    if (neapol) handle_eapol();
    mynos_sleep(10000);
  }
}

/* ---- the radio's rules, a scan, a network joined ---- */

/* the CLM blob, in pieces of 1400 bytes ("clmload": a 12-byte header,
   its flags' first and last pieces, its type 2, the CLM) */
static void clm_load(const unsigned char * d, long n)
{
  static unsigned char b[12 + 1400];
  unsigned int flag = 0x1000 | 0x0002, st = 0;
  long off = 0;
  while (off < n) {
    int chunk = n - off > 1400 ? 1400 : (int)(n - off);
    if (off + chunk == n) flag |= 0x0004;
    b[0] = flag; b[1] = flag >> 8;
    b[2] = 2; b[3] = 0;
    put32(b + 4, (unsigned int)chunk);
    put32(b + 8, 0);
    memcpy(b + 12, d + off, (size_t)chunk);
    if (set_var("clmload", b, 12 + chunk) < 0) { mynos_log("wifid: the CLM not loaded\n"); return; }
    flag &= ~0x0002u;
    off += chunk;
  }
  if (get_var("clmload_status", &st, 4) >= 4 && st != 0)
    mynos_log("wifid: the CLM's status %u\n", st);
  else
    mynos_log("wifid: the CLM loaded (%ld bytes)\n", n);
}

static void scan(void)
{
  unsigned char p[76];
  int i, j;
  memset(p, 0, sizeof p);
  put32(p, 1);                         /* version */
  p[4] = 1;                            /* start */
  p[6] = 0x34; p[7] = 0x12;            /* the sync id */
  memset(p + 44, 0xFF, 6);             /* any BSSID */
  p[50] = 2;                           /* any BSS type */
  p[51] = 0;                           /* active */
  for (i = 52; i < 68; i += 4) put32(p + i, 0xFFFFFFFF);   /* the defaults' times */
  nbss = 0;
  scan_done = 0;
  if (set_var("escan", p, sizeof p) < 0) { mynos_log("wifid: no scan\n"); return; }
  poll_events(10000, &scan_done);
  for (i = 1; i < nbss; i++)           /* the strongest first */
    for (j = i; j > 0 && bsses[j].rssi > bsses[j - 1].rssi; j--) {
      struct bss t = bsses[j]; bsses[j] = bsses[j - 1]; bsses[j - 1] = t;
    }
  mynos_log("wifid: %d networks%s\n", nbss, scan_done ? "" : " (the scan did not end)");
  for (i = 0; i < nbss; i++)
    mynos_log("wifid:   %-32s channel %3d, %4d dBm, %s\n",
              bsses[i].ssid[0] ? (char *)bsses[i].ssid : "(hidden)", bsses[i].channel,
              bsses[i].rssi, bsses[i].secured == 2 ? "WPA2" : bsses[i].secured ? "secured" : "open");
}

/* /disk/wifi.env: SSID=, PASSPHRASE=, COUNTRY= (each line's value to its
   end, as written) */
static char env_ssid[33], env_pass[65], env_country[3];

static void read_env(void)
{
  FILE * f = fopen("/disk/wifi.env", "r");
  char line[160];
  if (!f) return;
  while (fgets(line, sizeof line, f)) {
    char * v = strchr(line, '='), * e;
    if (!v || line[0] == '#') continue;
    *v++ = 0;
    for (e = v + strlen(v); e > v && (e[-1] == '\n' || e[-1] == '\r'); ) *--e = 0;
    if (!strcmp(line, "SSID")) snprintf(env_ssid, sizeof env_ssid, "%s", v);
    else if (!strcmp(line, "PASSPHRASE")) snprintf(env_pass, sizeof env_pass, "%s", v);
    else if (!strcmp(line, "COUNTRY")) snprintf(env_country, sizeof env_country, "%s", v);
  }
  fclose(f);
}

static void set_country(const char * cc)
{
  unsigned char b[12];
  memset(b, 0, sizeof b);
  b[0] = cc[0]; b[1] = cc[1];
  put32(b + 4, 0xFFFFFFFF);            /* (its revision: the firmware's) */
  b[8] = cc[0]; b[9] = cc[1];
  if (set_var("country", b, sizeof b) == 0) mynos_log("wifid: country %s\n", cc);
}

/* WPA2-PSK with AES: the handshake on the host (wpa.c: the firmware has
   no supplicant, "sup_wpa" unsupported), our RSN element given to the
   firmware for the association */
static void join(const char * ssid, const char * pass)
{
  unsigned char s[36];
  const unsigned char * rsn;
  int n = (int)strlen(ssid), i, group = 4, rl;
  if (*pass) {
    for (i = 0; i < nbss; i++)
      if (!strcmp((char *)bsses[i].ssid, ssid) && bsses[i].group) { group = bsses[i].group; break; }
    if (group != 4) mynos_log("wifid: the network's group cipher is %d, not CCMP\n", group);
    wpa_start(ssid, pass, own_mac, group);
    set_int(C_SET_WSEC, 4);            /* AES */
    set_int(C_SET_WPA_AUTH, 0x80);     /* WPA2-PSK */
    rsn = wpa_ie(&rl);
    if (set_var("wpaie", rsn, rl) < 0) mynos_log("wifid: the RSN element refused\n");
  } else {
    set_int(C_SET_WSEC, 0);
    set_int(C_SET_WPA_AUTH, 0);
  }
  set_int(C_SET_INFRA, 1);
  set_int(C_SET_AUTH, 0);              /* open system (WPA2 is above it) */
  memset(s, 0, sizeof s);
  put32(s, (unsigned int)n);
  memcpy(s + 4, ssid, (size_t)n);
  mynos_log("wifid: joining \"%s\" (%s)\n", ssid, *pass ? "WPA2" : "open");
  if (dcmd(C_SET_SSID, 1, s, sizeof s, s, 0) < 0) return;
  poll_events(15000, *pass ? &keyed : &link_up);
  if (*pass ? keyed : link_up) mynos_log("wifid: connected to \"%s\"\n", ssid);
  else mynos_log("wifid: not connected to \"%s\" (in 15 s)\n", ssid);
}

/* ---- the service: wifi/1, for netd (doc/decisions/wifi.md) ----

   Two services, each served by a thread of its own, so that a waiting
   receive never holds a send up: "wifi" (0 our MAC address, 1 send an
   Ethernet frame, 2 the status: connected, the network's name) and
   "wifirx" (3 receive: the frames waiting, or those that come within
   max_ms, each as a 16-bit length and its bytes). Only the main thread
   touches the SDIO: frames go through two queues. */

#define QLEN   64
#define QFRAME 1600
struct fq { unsigned char d[QLEN][QFRAME]; int len[QLEN], head, n; };
static struct fq rxq, txq;
static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rx_ready = PTHREAD_COND_INITIALIZER, work = PTHREAD_COND_INITIALIZER;
static int rx_attached;                 /* netd asked: frames are kept */

static int fq_put(struct fq * q, const unsigned char * d, int n)
{
  int i;
  if (q->n == QLEN || n > QFRAME) return -1;
  i = (q->head + q->n) % QLEN;
  memcpy(q->d[i], d, (size_t)n);
  q->len[i] = n;
  q->n++;
  return 0;
}

static int fq_get(struct fq * q, unsigned char * d)
{
  int n;
  if (!q->n) return -1;
  n = q->len[q->head];
  memcpy(d, q->d[q->head], (size_t)n);
  q->head = (q->head + 1) % QLEN;
  q->n--;
  return n;
}

static void rx_frame(const unsigned char * eth, int n)
{
  pthread_mutex_lock(&qlock);
  if (rx_attached && fq_put(&rxq, eth, n) == 0) pthread_cond_signal(&rx_ready);
  pthread_mutex_unlock(&qlock);
}

static void deadline(struct timespec * t, int ms)
{
  clock_gettime(CLOCK_REALTIME, t);
  t->tv_nsec += (long)ms % 1000 * 1000000L;
  t->tv_sec += ms / 1000 + t->tv_nsec / 1000000000L;
  t->tv_nsec %= 1000000000L;
}

static void serve(wire_reader * r, wire_writer * w)
{
  long long k = wire_get_int(r);
  if (r->error) { wire_reply_error(w, "invalid: wifi speaks wifi/1"); return; }
  if (k == 0) {
    wire_reply_ok(w);
    wire_put_string(w, own_mac, 6);
  } else if (k == 1) {
    unsigned int n;
    const char * f = wire_get_string(r, &n);
    int e;
    if (r->error || n < 14 || n > QFRAME) { wire_reply_error(w, "invalid: a frame"); return; }
    pthread_mutex_lock(&qlock);
    e = fq_put(&txq, (const unsigned char *)f, (int)n);
    pthread_cond_signal(&work);
    pthread_mutex_unlock(&qlock);
    if (e) wire_reply_error(w, "busy: the queue is full");
    else wire_reply_ok(w);
  } else if (k == 2) {
    wire_reply_ok(w);
    wire_put_int(w, link_up && keyed);
    wire_put_cstring(w, env_ssid);
  } else if (k == 3) {
    static unsigned char out[16384], f[QFRAME];
    struct timespec t;
    long long ms = wire_get_int(r);
    int used = 0, n;
    if (ms < 0 || ms > 10000) ms = 1000;
    deadline(&t, (int)ms);
    pthread_mutex_lock(&qlock);
    rx_attached = 1;
    while (!rxq.n && pthread_cond_timedwait(&rx_ready, &qlock, &t) == 0) ;
    while (rxq.n && used + 2 + rxq.len[rxq.head] <= (int)sizeof out) {
      n = fq_get(&rxq, f);
      out[used] = (unsigned char)n; out[used + 1] = (unsigned char)(n >> 8);
      memcpy(out + used + 2, f, (size_t)n);
      used += 2 + n;
    }
    pthread_mutex_unlock(&qlock);
    wire_reply_ok(w);
    wire_put_string(w, out, (unsigned int)used);
  } else
    wire_reply_error(w, "invalid: wifi speaks wifi/1");
}

static void * listener(void * arg)
{
  int port = (int)(long)arg;
  for (;;) {
    mynos_msg_t * m;
    wire_reader r;
    wire_writer w;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    if (mynos_recv(ch, &m, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    wire_reader_init(&r, m->start, m->size);
    wire_writer_init(&w);
    if (wire_check_protocol(&r, "wifi/1") != 0) wire_reply_error(&w, "invalid: wifi speaks wifi/1");
    else serve(&r, &w);
    if (!w.error) mynos_send(ch, w.buf, w.len, 0);
    wire_writer_free(&w);
    mynos_freeMsg(&m);
    mynos_freeChannel(ch);
  }
  return NULL;
}

static void start_services(void)
{
  pthread_t t;
  int p1 = mynos_registryRegister("wifi"), p2 = mynos_registryRegister("wifirx");
  if (p1 < 0 || p2 < 0) { mynos_log("wifid: cannot register (%d, %d)\n", p1, p2); return; }
  pthread_create(&t, NULL, listener, (void *)(long)p1);
  pthread_create(&t, NULL, listener, (void *)(long)p2);
}

/* the main thread from now on: the chip's frames, the frames to send */
static void service_loop(void)
{
  static unsigned char f[QFRAME];
  unsigned char dummy[4];
  struct timespec t;
  int n, st;
  for (;;) {
    handle_frames(-1, dummy, 0, &st);
    if (neapol) handle_eapol();
    for (;;) {
      pthread_mutex_lock(&qlock);
      n = fq_get(&txq, f);
      pthread_mutex_unlock(&qlock);
      if (n < 0) break;
      if (keyed) send_data(f, n);
    }
    deadline(&t, 5);
    pthread_mutex_lock(&qlock);
    if (!txq.n) pthread_cond_timedwait(&work, &qlock, &t);
    pthread_mutex_unlock(&qlock);
  }
}

/* ---- the board ---- */

/* the board's revision code's type: 0x11 a Pi 4 B, 0x13 a 400, 0x14 a CM4 */
static int board_type(void)
{
  unsigned int rev;
  if (pi_property(0x00010002, NULL, 0, &rev, 1) < 0) return -1;
  if (!(rev & (1u << 23))) return -1;  /* an old-style code: a Pi 1 */
  return (int)(rev >> 4) & 0xFF;
}

int main(void)
{
  int type = board_type(), nvlen = 0, n;
  unsigned int id, ramsize, rambase = 0x198000, rstvec, i;
  long fwlen, txtlen;
  unsigned char * fw, * txt, * nv, check[64];
  char name[64], ver[256];
  const char * chip;
  struct core * arm, * d11;
  if (type != 0x11 && type != 0x13 && type != 0x14) {
    mynos_log("wifid: not a Raspberry Pi 4, 400 or CM4: no Wi-Fi driven\n");
    return 0;                          /* by choice: init does not start it again */
  }
  /* (the device tree's word: QEMU's raspi4b, whose firmware gives none,
     has the SD card on the Wi-Fi's controller) */
  if (!(mynos_piDevices() & MYNOS_PI_WIFI)) {
    mynos_log("wifid: no Wi-Fi in the device tree\n");
    return 0;
  }
  if (sdio_init() < 0) return 0;
  /* the backplane's clock (ALP), the pull-ups off */
  sdio_byte(1, SB_CHIPCLKCSR, CLK_FORCE_HW_OFF | CLK_ALP_AVAIL_REQ);
  for (i = 0; i < 100; i++) {
    n = sdio_byte(1, SB_CHIPCLKCSR, -1);
    if (n >= 0 && (n & CLK_ALP_AVAIL)) break;
    mynos_sleep(1000);
  }
  if (i == 100) { mynos_log("wifid: no ALP clock (%02x)\n", n); return 0; }
  sdio_byte(1, SB_CHIPCLKCSR, CLK_FORCE_HW_OFF | CLK_FORCE_ALP);
  sdio_byte(1, SB_PULLUP, 0);
  id = rd(CHIPCOMMON);
  chip = (id & 0xFFFF) == 0x4345 && ((id >> 16) & 0xF) == 9 ? "43456" :
         (id & 0xFFFF) == 0x4345 && ((id >> 16) & 0xF) == 6 ? "43455" : NULL;
  mynos_log("wifid: chip %04x revision %u (%s)\n", id & 0xFFFF, (id >> 16) & 0xF,
            chip ? chip : "not known");
  if (!chip) return 0;
  erom_scan();
  arm = core(CORE_CR4);
  d11 = core(CORE_D11);
  sdc = core(CORE_SDIO);
  mynos_log("wifid: %d cores; ARM %08x, 802.11 %08x, SDIO %08x\n", ncores,
            arm ? arm->base : 0, d11 ? d11->base : 0, sdc ? sdc->base : 0);
  if (!arm || !d11 || !sdc) return 0;
  /* the files */
  snprintf(name, sizeof name, "brcmfmac%s-sdio.bin", chip);
  fw = load(name, &fwlen);
  snprintf(name, sizeof name, "brcmfmac%s-sdio.txt", chip);
  txt = load(name, &txtlen);
  if (!fw || !txt) {
    mynos_log("wifid: no firmware in " WIFI_DIR " (make-sd-raspi.sh puts it there)\n");
    return 0;
  }
  nv = nvram(txt, txtlen, &nvlen);
  if (!nv) return 0;
  /* the ARM halted, the 802.11 core reset; the firmware, the NVRAM */
  core_reset(arm, rd(arm->wrap + 0x408) & CR4_CPUHALT, CR4_CPUHALT, CR4_CPUHALT);
  core_reset(d11, D11_PHYRESET | D11_PHYCLOCKEN, D11_PHYCLOCKEN, D11_PHYCLOCKEN);
  ramsize = ram_size(arm);
  mynos_log("wifid: RAM %u KB at %06x; firmware %ld bytes, NVRAM %d\n", ramsize / 1024,
            rambase, fwlen, nvlen);
  if (ramsize < (unsigned int)fwlen + (unsigned int)nvlen) return 0;
  if (bp_write(rambase, fw, (int)((fwlen + 3) & ~3)) < 0 ||
      bp_write(rambase + ramsize - (unsigned int)nvlen, nv, nvlen) < 0) {
    mynos_log("wifid: the firmware not written\n");
    return 0;
  }
  if (bp_read(rambase, check, sizeof check) < 0 || memcmp(check, fw, sizeof check)) {
    mynos_log("wifid: the firmware read back differs\n");
    return 0;
  }
  /* the ARM released at the firmware's reset vector */
  rstvec = get32(fw);
  wr(sdc->base + SDIO_INTSTATUS, 0xFFFFFFFF);
  wr(0, rstvec);
  core_reset(arm, CR4_CPUHALT, 0, 0);
  /* the fast clock, function 2 */
  sdio_byte(1, SB_CHIPCLKCSR, CLK_HT_AVAIL_REQ);
  for (i = 0; i < 2000; i++) {
    n = sdio_byte(1, SB_CHIPCLKCSR, -1);
    if (n >= 0 && (n & CLK_HT_AVAIL)) break;
    mynos_sleep(1000);
  }
  if (i == 2000) { mynos_log("wifid: no HT clock (%02x): the firmware did not start\n", n); return 0; }
  sdio_byte(1, SB_CHIPCLKCSR, n | CLK_FORCE_HT);
  wr(sdc->base + SDIO_TOSBMBXDATA, 4u << 16);    /* SDPCM's version */
  if (sdio_enable(2, 3000) < 0) { mynos_log("wifid: function 2 never ready\n"); return 0; }
  wr(sdc->base + SDIO_HOSTINTMASK, HOSTINTMASK);
  sdio_byte(1, SB_WATERMARK, 8);
  mynos_log("wifid: the firmware runs\n");
  {                                    /* no superframes (glom) to the host */
    unsigned char zero[4] = { 0, 0, 0, 0 };
    if (set_var("bus:txglom", zero, 4) < 0) mynos_log("wifid: superframes not turned off\n");
  }
  /* its version, its MAC address */
  memset(ver, 0, sizeof ver);
  n = get_var("ver", ver, 255);
  if (n > 0) {
    ver[255] = 0;
    for (i = 0; ver[i]; i++) if (ver[i] == '\n' || ver[i] == '\r') ver[i] = ' ';
    mynos_log("wifid: %s\n", ver);
  }
  n = get_var("cur_etheraddr", check, 6);
  if (n >= 6) memcpy(own_mac, check, 6);
  {
    char cap[512];
    memset(cap, 0, sizeof cap);
    if (get_var("cap", cap, 511) > 0) { cap[511] = 0; mynos_log("wifid: capabilities: %s\n", cap); }
  }
  if (n >= 6)
    mynos_log("wifid: MAC address %02x:%02x:%02x:%02x:%02x:%02x (%d events so far)\n",
              check[0], check[1], check[2], check[3], check[4], check[5], events);
  /* the radio's rules, the country, the events wanted, the radio up */
  {
    long clmlen;
    unsigned char * clm;
    unsigned char mask[16];
    static const int wanted[] = { E_SET_SSID, 1, E_AUTH, E_DEAUTH, E_DEAUTH_IND, E_ASSOC,
                                  E_DISASSOC, E_DISASSOC_IND, E_LINK, E_PSK_SUP,
                                  E_ESCAN_RESULT };
    snprintf(name, sizeof name, "brcmfmac%s-sdio.clm_blob", chip);
    clm = load(name, &clmlen);
    if (clm) { clm_load(clm, clmlen); free(clm); }
    else mynos_log("wifid: no CLM in " WIFI_DIR "\n");
    read_env();
    if (env_country[0] && env_country[1]) set_country(env_country);
    memset(mask, 0, sizeof mask);
    if (get_var("event_msgs", mask, sizeof mask) < 0) memset(mask, 0, sizeof mask);
    for (i = 0; i < sizeof wanted / sizeof wanted[0]; i++)
      mask[wanted[i] / 8] |= (unsigned char)(1 << (wanted[i] % 8));
    if (set_var("event_msgs", mask, sizeof mask) < 0) mynos_log("wifid: events not set\n");
    if (set_int(C_UP, 1) < 0) { mynos_log("wifid: the radio not up\n"); return 0; }
  }
  start_services();
  scan();
  if (env_ssid[0]) join(env_ssid, env_pass);
  else mynos_log("wifid: no network to join (/disk/wifi.env: SSID=, PASSPHRASE=, COUNTRY=)\n");
  service_loop();
  return 0;
}

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
#include <mynos.h>
#include "sdio.h"

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

static void put32(unsigned char * p, unsigned int v)
{
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
static unsigned int get32(const unsigned char * p)
{
  return p[0] | p[1] << 8 | p[2] << 16 | (unsigned int)p[3] << 24;
}

/* a frame on channel ch: its payload already at frame + 12 */
static int send_frame(int ch, int len)
{
  int total = len + 12, padded = (total + 3) & ~3;
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

/* a frame read into buf (FRAME bytes): its length, 0 if none, -1 */
static int read_frame(unsigned char * buf)
{
  int len, chk, got = 64;
  if (sdio_ext(0, 2, F2_ADDR, buf, 64) < 0) return -1;
  len = buf[0] | buf[1] << 8;
  chk = buf[2] | buf[3] << 8;
  if (len == 0 && chk == 0) return 0;
  if ((len ^ chk) != 0xFFFF || len < 12 || len > FRAME) {
    sdio_byte(0, 0x06, 2);             /* function 2's read aborted */
    wr(sdc->base + SDIO_TOSBMAILBOX, 1);   /* (a NAK: the firmware sends it again) */
    return -1;
  }
  while (got < len) {
    int n = (len - got + 3) & ~3;
    if (n > 512) n = 512;
    if (sdio_ext(0, 2, F2_ADDR, buf + got, n) < 0) return -1;
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
  if (!(st & I_HMB_FRAME_IND)) return -2;
  while ((len = read_frame(frame)) > 0) {
    int ch = frame[5] & 0xF, off = frame[7];
    unsigned char * p = frame + off;
    if (ch == 0 && len >= off + 16) {
      unsigned int flags = get32(p + 8);
      int n = (int)get32(p + 4);
      if ((int)(flags >> 16) != want_id) continue;
      *status = (int)get32(p + 12);
      if (flags & 1) return -1;
      if (n > len - off - 16) n = len - off - 16;
      if (n > max) n = max;
      memcpy(out, p + 16, (size_t)n);
      r = n;
    } else if (ch == 1)
      events++;
  }
  return r;
}

/* a command to the firmware (BCDC), its reply waited for: the reply's
   length, or -1 */
static int dcmd(unsigned int cmd, int set, const void * data, int len, void * reply, int max)
{
  unsigned char * p = frame + 12;
  int i, r, status = 0;
  if (len > FRAME - 64) return -1;
  put32(p, cmd);
  put32(p + 4, (unsigned int)len);
  put32(p + 8, (unsigned int)++reqid << 16 | (set ? 2u : 0));
  put32(p + 12, 0);
  memcpy(p + 16, data, (size_t)len);
  if (send_frame(0, 16 + len) < 0) { mynos_log("wifid: a command not sent\n"); return -1; }
  for (i = 0; i < 2000; i++) {
    r = handle_frames(reqid, reply, max, &status);
    if (r >= 0) return r;
    if (r == -1) { mynos_log("wifid: command %u failed (%d)\n", cmd, status); return -1; }
    mynos_sleep(1000);
  }
  mynos_log("wifid: command %u: no answer\n", cmd);
  return -1;
}

#define C_GET_VAR 262

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
  /* its version, its MAC address */
  memset(ver, 0, sizeof ver);
  n = get_var("ver", ver, 255);
  if (n > 0) {
    ver[255] = 0;
    for (i = 0; ver[i]; i++) if (ver[i] == '\n' || ver[i] == '\r') ver[i] = ' ';
    mynos_log("wifid: %s\n", ver);
  }
  n = get_var("cur_etheraddr", check, 6);
  if (n >= 6)
    mynos_log("wifid: MAC address %02x:%02x:%02x:%02x:%02x:%02x (%d events so far)\n",
              check[0], check[1], check[2], check[3], check[4], check[5], events);
  return 0;
}

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
 * The SDIO of a Raspberry Pi 4's or 400's Wi-Fi (btq.9, doc/decisions/
 * wifi.md): the BCM2711's first SDHCI, Arasan's ("mmcnr", 0xFE300000;
 * the SD card is on the other, EMMC2: sdhcid), wired to the Wi-Fi chip by
 * GPIO 34-39 (their function ALT3, CMD and DAT0-3 pulled up). The chip's
 * power is the firmware's GPIO expander's line 1, WL_ON (the mailbox).
 *
 * The controller is driven as sdhcid drives the same one on a Pi 3: a
 * 32-bit word at a time, polled, the data through its port (PIO), a write
 * followed by two of the card's clock periods while that clock is slow.
 * The card is an SDIO one: CMD5 for its conditions, CMD3, CMD7, then
 * CMD52 (a byte of a function's space) and CMD53 (bytes or blocks) only;
 * its common registers (function 0's CCCR) set 4 data lines, its
 * functions enabled and their block sizes set (1: 64 bytes, the
 * backplane; 2: 512, the frames).
 *
 * The backplane (the chip's cores' registers and RAM, 32-bit addresses)
 * is reached through function 1: a window of 32 KB whose base is set in
 * three of its registers, its offset in the access's address, with the
 * flag for 4-byte accesses.
 */

#include <string.h>
#include <mynos.h>
#include "sdio.h"

#define GPIO_PHYS 0xFE200000UL
#define MMC_PHYS  0xFE300000UL

/* the controller's registers, as 32-bit words (sdhcid's names) */
#define BLKSIZECNT 0x04
#define ARG1       0x08
#define CMDTM      0x0C
#define RESP0      0x10
#define DATA       0x20
#define STATUS     0x24
#define CONTROL0   0x28
#define CONTROL1   0x2C
#define INTERRUPT  0x30
#define IRPT_MASK  0x34
#define IRPT_EN    0x38
#define CONTROL2   0x3C
#define CAPS0      0x40

#define ST_CMD_INHIBIT  (1u << 0)
#define ST_DAT_INHIBIT  (1u << 1)
#define INT_CMD_DONE    (1u << 0)
#define INT_DATA_DONE   (1u << 1)
#define INT_WRITE_RDY   (1u << 4)
#define INT_READ_RDY    (1u << 5)
#define INT_ERROR       (1u << 15)
#define INT_ERRORS      0xFFFF8000u

#define R_NONE   0
#define R_48     (2u << 16)
#define R_48B    (3u << 16)
#define C_CRC    (1u << 19)
#define C_IDX    (1u << 20)
#define C_DATA   (1u << 21)
#define CMD(N)   ((unsigned int)(N) << 24)
#define T_BLKCNT (1u << 1)
#define T_READ   (1u << 4)
#define T_MULTI  (1u << 5)

static volatile unsigned int * mmc, * gpio;
static unsigned int base_hz, rca;
static int blksz[3] = { 64, 64, 512 };

#define R(OFF) mmc[(OFF) / 4]

/* ---- time ---- */

static unsigned long counter(void)
{
  unsigned long v = 0;
#ifdef __aarch64__
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r"(v));
#endif
  return v;
}

static void udelay(unsigned int us)
{
  unsigned long f = 0, t = counter();
#ifdef __aarch64__
  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r"(f));
#endif
  f = f / 1000000 * us;
  while (counter() - t < f) ;
}

/* ---- the board's firmware ---- */

int pi_property(unsigned int tag, const unsigned int * in, int nin, unsigned int * out, int nout)
{
  unsigned int b[32] __attribute__((aligned(16)));
  int n = nin > nout ? nin : nout, i;
  if (n > 24) return -1;
  memset(b, 0, sizeof b);
  b[0] = (unsigned int)(6 + n) * 4;
  b[2] = tag;
  b[3] = (unsigned int)n * 4;
  b[4] = (unsigned int)nin * 4;
  for (i = 0; i < nin; i++) b[5 + i] = in[i];
  if (mynos_piFirmware(b, (int)b[0]) != 0 || !(b[4] & 0x80000000u)) return -1;
  for (i = 0; i < nout; i++) out[i] = b[5 + i];
  return 0;
}

/* ---- the controller ---- */

static int slow = 1;
static void W(int off, unsigned int v)
{
  R(off) = v;
  if (slow) udelay(10);
}

static int wait_reg(int off, unsigned int mask, unsigned int want, int ms)
{
  int i;
  for (i = 0; i < 1000; i++) if ((R(off) & mask) == want) return 0;
  for (i = 0; i < ms; i++) {
    if ((R(off) & mask) == want) return 0;
    mynos_sleep(1000);
  }
  return (R(off) & mask) == want ? 0 : -1;
}

static unsigned int wait_int(unsigned int mask, int ms)
{
  int i;
  for (i = 0; i < 1000; i++) if (R(INTERRUPT) & mask) return R(INTERRUPT);
  for (i = 0; i < ms; i++) {
    if (R(INTERRUPT) & mask) return R(INTERRUPT);
    mynos_sleep(1000);
  }
  return R(INTERRUPT) & mask ? R(INTERRUPT) : 0;
}

static void recover(void)
{
  W(INTERRUPT, 0xFFFFFFFF);
  W(CONTROL1, R(CONTROL1) | 6u << 24);
  wait_reg(CONTROL1, 6u << 24, 0, 100);
}

static int command(unsigned int cmd, unsigned int arg)
{
  unsigned int v;
  if (wait_reg(STATUS, ST_CMD_INHIBIT, 0, 500) < 0) return -1;
  if ((cmd & R_48B) == R_48B || (cmd & C_DATA))
    if (wait_reg(STATUS, ST_DAT_INHIBIT, 0, 500) < 0) return -1;
  W(INTERRUPT, 0xFFFFFFFF);
  W(ARG1, arg);
  W(CMDTM, cmd);
  v = wait_int(INT_CMD_DONE | INT_ERROR, 500);
  if (!(v & INT_CMD_DONE) || (v & INT_ERRORS)) { recover(); return -1; }
  W(INTERRUPT, INT_CMD_DONE);
  if ((cmd & R_48B) == R_48B) wait_int(INT_DATA_DONE, 500);
  W(INTERRUPT, INT_DATA_DONE);
  return 0;
}

static int set_clock(unsigned int hz)
{
  unsigned int n = 0, c1;
  if (hz < base_hz) {
    n = (base_hz + 2 * hz - 1) / (2 * hz);
    if (n > 1023) n = 1023;
  }
  c1 = R(CONTROL1);
  c1 &= ~0x4u;
  W(CONTROL1, c1);
  c1 &= ~0xFFE0u;
  c1 |= ((n & 0xFF) << 8) | ((n >> 8) << 6) | 1u;
  c1 = (c1 & ~0xF0000u) | (0xEu << 16);
  W(CONTROL1, c1);
  if (wait_reg(CONTROL1, 2u, 2u, 100) < 0) return -1;
  W(CONTROL1, c1 | 4u);
  udelay(100);
  return 0;
}

/* GPIO 34-39 to the SDHCI (ALT3); 35-39 (CMD, DAT0-3) pulled up, 34 (the
   clock) not (the BCM2711's pull registers: two bits a pin, 1 up) */
static void pins(void)
{
  unsigned int f3 = gpio[0x0C / 4], pull = gpio[0xEC / 4];
  int p;
  for (p = 34; p <= 39; p++) f3 = (f3 & ~(7u << ((p - 30) * 3))) | 7u << ((p - 30) * 3);
  gpio[0x0C / 4] = f3;
  for (p = 34; p <= 39; p++) {
    pull &= ~(3u << ((p - 32) * 2));
    if (p != 34) pull |= 1u << ((p - 32) * 2);
  }
  gpio[0xEC / 4] = pull;
}

/* WL_ON: the expander's line 1, the firmware's GPIO 129 */
static int wl_on(int on)
{
  unsigned int in[2] = { 128 + 1, on ? 1u : 0u }, out[2];
  return pi_property(0x00038041, in, 2, out, 2);
}

/* ---- the card's commands ---- */

int sdio_byte(int fn, unsigned int addr, int value)
{
  unsigned int arg = (unsigned int)fn << 28 | (addr & 0x1FFFF) << 9, r;
  if (value >= 0) arg |= 1u << 31 | (unsigned int)(value & 0xFF);
  if (command(CMD(52) | R_48 | C_CRC | C_IDX, arg) < 0) return -1;
  r = R(RESP0);
  if (r & 0xCB00) return -1;          /* CRC, illegal, error, function, range */
  return value >= 0 ? 0 : (int)(r & 0xFF);
}

int sdio_ext(int write, int fn, unsigned int addr, void * buf, int len)
{
  unsigned int * p = buf, cmd, arg, v;
  int block = len > blksz[fn], size = block ? blksz[fn] : len, n = block ? len / size : 1, b, i;
  if (len <= 0 || (len & 3) || (block && len % size) || n > 511) return -1;
  arg = (write ? 1u << 31 : 0) | (unsigned int)fn << 28 | (block ? 1u << 27 : 0) | 1u << 26 |
        (addr & 0x1FFFF) << 9 | (unsigned int)(block ? n : (len == 512 ? 0 : len));
  cmd = CMD(53) | R_48 | C_CRC | C_IDX | C_DATA | T_BLKCNT | (write ? 0 : T_READ) |
        (n > 1 ? T_MULTI : 0);
  if (wait_reg(STATUS, ST_CMD_INHIBIT | ST_DAT_INHIBIT, 0, 1000) < 0) return -1;
  W(BLKSIZECNT, (unsigned int)n << 16 | (unsigned int)size);
  W(INTERRUPT, 0xFFFFFFFF);
  W(ARG1, arg);
  W(CMDTM, cmd);
  v = wait_int(INT_CMD_DONE | INT_ERROR, 1000);
  if (!(v & INT_CMD_DONE) || (v & INT_ERRORS) || (R(RESP0) & 0xCB00)) goto fail;
  W(INTERRUPT, INT_CMD_DONE);
  for (b = 0; b < n; b++) {
    unsigned int ready = write ? INT_WRITE_RDY : INT_READ_RDY;
    v = wait_int(ready | INT_ERROR, 1000);
    if (!(v & ready) || (v & INT_ERRORS)) goto fail;
    W(INTERRUPT, ready);
    if (write) for (i = 0; i < size / 4; i++) R(DATA) = *p++;
    else for (i = 0; i < size / 4; i++) *p++ = R(DATA);
  }
  v = wait_int(INT_DATA_DONE | INT_ERROR, 1000);
  if (!(v & INT_DATA_DONE) || (v & INT_ERRORS)) goto fail;
  W(INTERRUPT, INT_DATA_DONE);
  return 0;
fail:
  recover();
  return -1;
}

int sdio_enable(int fn, int ms)
{
  int e = sdio_byte(0, 0x02, -1), i, r;
  if (e < 0 || sdio_byte(0, 0x02, e | 1 << fn) < 0) return -1;
  for (i = 0; i < ms; i++) {
    r = sdio_byte(0, 0x03, -1);
    if (r >= 0 && (r & 1 << fn)) return 0;
    mynos_sleep(1000);
  }
  return -1;
}

int sdio_init(void)
{
  unsigned int ocr = 0, clk_in[2] = { 1, 0 }, clk[2];
  int i, f, v;
  gpio = mynos_mapPhysical(GPIO_PHYS, 1);
  mmc = mynos_mapPhysical(MMC_PHYS, 1);
  if (!gpio || !mmc) { mynos_log("wifid: cannot map the SDHCI\n"); return -1; }
  /* the chip off, the pins, the chip on (as Linux's mmc-pwrseq-simple) */
  if (wl_on(0) < 0) mynos_log("wifid: the firmware did not set WL_ON\n");
  pins();
  mynos_sleep(20000);
  wl_on(1);
  mynos_sleep(150000);
  /* the controller: reset, powered (3.3 V), the card detected whatever
     its pin says (it is soldered), polled, 400 kHz */
  W(CONTROL1, 1u << 24);
  if (wait_reg(CONTROL1, 7u << 24, 0, 100) < 0) { mynos_log("wifid: SDHCI reset failed\n"); return -1; }
  W(CONTROL0, 0xF00 | 0xC0);
  W(CONTROL2, 0);
  W(IRPT_EN, 0);
  W(IRPT_MASK, 0xFFFFFFFF);
  base_hz = 0;
  if (pi_property(0x00030002, clk_in, 2, clk, 2) == 0 && clk[0] == 1) base_hz = clk[1];
  if (base_hz == 0) base_hz = ((R(CAPS0) >> 8) & 0xFF) * 1000000u;
  if (base_hz == 0) base_hz = 250000000u;
  if (set_clock(400000) < 0) { mynos_log("wifid: SDHCI clock not stable\n"); return -1; }
  mynos_sleep(10000);
  /* the card: CMD0, CMD5 until ready, CMD3, CMD7 */
  command(CMD(0) | R_NONE, 0);
  if (command(CMD(5) | R_48, 0) < 0) {
    mynos_log("wifid: no SDIO card answers CMD5 (base clock %u Hz)\n", base_hz);
    return -1;
  }
  ocr = R(RESP0);
  for (i = 0; i < 100; i++) {
    if (command(CMD(5) | R_48, ocr & 0x00FFFF00u) < 0) return -1;
    if (R(RESP0) & 0x80000000u) break;
    mynos_sleep(10000);
  }
  if (!(R(RESP0) & 0x80000000u)) { mynos_log("wifid: the card never ready (%08x)\n", R(RESP0)); return -1; }
  f = (int)(R(RESP0) >> 28) & 7;
  if (command(CMD(3) | R_48 | C_CRC | C_IDX, 0) < 0) return -1;
  rca = R(RESP0) >> 16;
  if (command(CMD(7) | R_48B | C_CRC | C_IDX, rca << 16) < 0) return -1;
  /* 4 data lines, 25 MHz */
  v = sdio_byte(0, 0x07, -1);
  if (v < 0 || sdio_byte(0, 0x07, (v & ~3) | 2) < 0) return -1;
  W(CONTROL0, R(CONTROL0) | 2u);
  set_clock(25000000);
  slow = 0;
  /* the block sizes: function 1's 64, function 2's 512 (their FBRs) */
  if (sdio_byte(0, 0x110, 64) < 0 || sdio_byte(0, 0x111, 0) < 0 ||
      sdio_byte(0, 0x210, 0) < 0 || sdio_byte(0, 0x211, 2) < 0) {
    mynos_log("wifid: cannot set the block sizes\n");
    return -1;
  }
  if (sdio_enable(1, 1000) < 0) { mynos_log("wifid: function 1 never ready\n"); return -1; }
  mynos_log("wifid: SDIO card, %d functions, RCA %04x, base clock %u Hz\n", f, rca, base_hz);
  return 0;
}

/* ---- the backplane ---- */

static unsigned int window = 0xFFFFFFFF;

static int set_window(unsigned int addr)
{
  unsigned int w = addr & ~0x7FFFu;
  if (w == window) return 0;
  if (sdio_byte(1, SB_ADDRLOW, (int)(w >> 8) & 0x80) < 0 ||
      sdio_byte(1, SB_ADDRMID, (int)(w >> 16) & 0xFF) < 0 ||
      sdio_byte(1, SB_ADDRHIGH, (int)(w >> 24) & 0xFF) < 0) {
    window = 0xFFFFFFFF;
    return -1;
  }
  window = w;
  return 0;
}

int bp_read32(unsigned int addr, unsigned int * v)
{
  if (set_window(addr) < 0) return -1;
  return sdio_ext(0, 1, (addr & 0x7FFF) | 0x8000, v, 4);
}

int bp_write32(unsigned int addr, unsigned int v)
{
  if (set_window(addr) < 0) return -1;
  return sdio_ext(1, 1, (addr & 0x7FFF) | 0x8000, &v, 4);
}

/* bytes to or from the backplane: within a window each piece, in blocks
   of 64 then the rest in one byte-mode access */
static int bp_rw(int write, unsigned int addr, unsigned char * buf, int len)
{
  while (len > 0) {
    int n = 0x8000 - (int)(addr & 0x7FFF);
    if (n > len) n = len;
    if (n > 64 * 32) n = 64 * 32;
    if (n >= 64) n &= ~63;
    if (set_window(addr) < 0 || sdio_ext(write, 1, (addr & 0x7FFF) | 0x8000, buf, n) < 0)
      return -1;
    addr += (unsigned int)n;
    buf += n;
    len -= n;
  }
  return 0;
}

int bp_write(unsigned int addr, const void * buf, int len)
{
  return bp_rw(1, addr, (unsigned char *)buf, len);
}

int bp_read(unsigned int addr, void * buf, int len)
{
  return bp_rw(0, addr, buf, len);
}

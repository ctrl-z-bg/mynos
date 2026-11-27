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
 * sdhcid: the SD card of a Raspberry Pi 3 or Zero 2 W (btq.7.3,
 * doc/decisions/aarch64.md, choice 11), through its SDHCI controller
 * (Arasan's, "EMMC", at 0x3F300000), served as the block service "sd0",
 * protocol block/1, the same as ata's and vblkd's: fatfs uses any.
 *
 * The card's pins (GPIO 48-53) go to this controller (their function
 * ALT3; the firmware leaves them to the Broadcom SDHOST). Then the
 * controller is reset, its clock set to 400 kHz, and the card
 * identified as the SD specification says (CMD0, CMD8, ACMD41, CMD2,
 * CMD3, CMD9 for its size, CMD7), then 4 data lines at 25 MHz at most.
 * Sectors move by the CPU (PIO: the data port, a word at a time), the
 * controller polled: no DMA, no interrupt. The controller is accessed
 * a 32-bit word at a time (the BCM2835's ignores narrower writes).
 *
 * Elsewhere (no such controller: mapPhysical refuses its address, or
 * not AArch64) it ends at once, with code 0, as ata does without a disk.
 */

#include <string.h>
#include <mynos.h>
#include <mynos_wire.h>

#define SERVICE  "sd0"
#define PROTOCOL "block/1"
#define SECTOR   512
#define MAXCOUNT 32

#define GPIO_PHYS 0x3F200000UL
#define EMMC_PHYS 0x3F300000UL

/* the registers, as 32-bit words */
#define ARG2       0x00
#define BLKSIZECNT 0x04
#define ARG1       0x08
#define CMDTM      0x0C
#define RESP0      0x10
#define RESP1      0x14
#define RESP2      0x18
#define RESP3      0x1C
#define DATA       0x20
#define STATUS     0x24
#define CONTROL0   0x28
#define CONTROL1   0x2C
#define INTERRUPT  0x30
#define IRPT_MASK  0x34
#define IRPT_EN    0x38
#define CONTROL2   0x3C
#define CAPS0      0x40
#define SLOTISR_VER 0xFC

#define ST_CMD_INHIBIT  (1u << 0)
#define ST_DAT_INHIBIT  (1u << 1)

#define INT_CMD_DONE    (1u << 0)
#define INT_DATA_DONE   (1u << 1)
#define INT_WRITE_RDY   (1u << 4)
#define INT_READ_RDY    (1u << 5)
#define INT_ERROR       (1u << 15)
#define INT_ERRORS      0xFFFF8000u

/* the command register's upper half: response, checks, data */
#define R_NONE   0
#define R_136    (1u << 16)
#define R_48     (2u << 16)
#define R_48B    (3u << 16)
#define C_CRC    (1u << 19)
#define C_IDX    (1u << 20)
#define C_DATA   (1u << 21)
#define CMD(N)   ((unsigned int)(N) << 24)
/* the lower half: the transfer */
#define T_BLKCNT (1u << 1)
#define T_ACMD12 (1u << 2)
#define T_READ   (1u << 4)
#define T_MULTI  (1u << 5)

static volatile unsigned int * emmc, * gpio;
static unsigned int rca;
static int sdhc;                       /* block addresses (SDHC, SDXC) */
static unsigned long long capacity;    /* sectors */
static unsigned int base_hz;
static unsigned char data[MAXCOUNT * SECTOR];

#define R(OFF) emmc[(OFF) / 4]

/* the generic timer's counter (readable by programs: arch/aarch64/pit.c) */
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

/* a register written; while the card's clock is slow (identification,
   400 kHz), two of its periods after it: the BCM2835's controller loses
   a write that follows another closer than that (Linux's
   sdhci-iproc.c) */
static int slow = 1;
static void W(int off, unsigned int v)
{
  R(off) = v;
  if (slow) udelay(10);
}

static void spin(int n) { while (n-- > 0) __asm__ volatile ("" ::: "memory"); }

/* wait until (R(off) & mask) == want, at most ms milliseconds: 0 if so */
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

/* the interrupt status once one of mask's bits is there (0: none
   within ms milliseconds) */
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

/* after an error: the statuses cleared, the command and data lines reset */
static void recover(void)
{
  W(INTERRUPT, 0xFFFFFFFF);
  W(CONTROL1, R(CONTROL1) | 6u << 24);
  wait_reg(CONTROL1, 6u << 24, 0, 100);
}

/* a command, its response waited for (not its data): 0, or -1 */
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
  if ((cmd & R_48B) == R_48B)        /* busy: the card's data line */
    wait_int(INT_DATA_DONE, 500);
  W(INTERRUPT, INT_DATA_DONE);
  return 0;
}

static int app_command(unsigned int cmd, unsigned int arg)
{
  if (command(CMD(55) | R_48 | C_CRC | C_IDX, rca << 16) < 0) return -1;
  return command(cmd, arg);
}

/* the card's clock: the largest at most hz (the base clock divided by
   2 N, N up to 1023) */
static int set_clock(unsigned int hz)
{
  unsigned int n = 0, c1;
  if (hz < base_hz) {
    n = (base_hz + 2 * hz - 1) / (2 * hz);
    if (n > 1023) n = 1023;
  }
  c1 = R(CONTROL1);
  c1 &= ~0x4u;                       /* the card's clock off */
  W(CONTROL1, c1);
  c1 &= ~0xFFE0u;
  c1 |= ((n & 0xFF) << 8) | ((n >> 8) << 6) | 1u;   /* the divider, the internal clock on */
  c1 = (c1 & ~0xF0000u) | (0xEu << 16);             /* the data timeout: the longest */
  W(CONTROL1, c1);
  if (wait_reg(CONTROL1, 2u, 2u, 100) < 0) return -1;   /* stable */
  W(CONTROL1, c1 | 4u);             /* the card's clock on */
  spin(10000);
  return 0;
}

/* the pins 48-53 to the SDHCI (ALT3), CMD and DAT0-3 pulled up */
static void pins_to_sdhci(void)
{
  unsigned int f4 = gpio[0x10 / 4], f5 = gpio[0x14 / 4];
  f4 = (f4 & ~(0x3Fu << 24)) | (7u << 24) | (7u << 27);
  f5 = (f5 & ~0xFFFu) | 7u | (7u << 3) | (7u << 6) | (7u << 9);
  gpio[0x10 / 4] = f4;
  gpio[0x14 / 4] = f5;
  gpio[0x94 / 4] = 2;                /* pull-up */
  spin(1000);
  gpio[0x9C / 4] = 0x3Eu << 17;      /* GPPUDCLK1: pins 49-53 (CMD, DAT0-3) */
  spin(1000);
  gpio[0x94 / 4] = 0;
  gpio[0x9C / 4] = 0;
}

static int card_init(void)
{
  unsigned int ocr = 0, csd[4], v2;
  int i;
  W(CONTROL1, 1u << 24);            /* the controller reset */
  if (wait_reg(CONTROL1, 7u << 24, 0, 100) < 0) return -1;
  W(CONTROL0, 0xF00);               /* the bus's power: 3.3 V, on */
  W(CONTROL2, 0);
  W(IRPT_EN, 0);                    /* no interrupt signalled: polled */
  W(IRPT_MASK, 0xFFFFFFFF);         /* every status kept */
  base_hz = ((R(CAPS0) >> 8) & 0xFF) * 1000000u;
  if (base_hz == 0) base_hz = 250000000u;   /* (not said: the Pi's most) */
  if (set_clock(400000) < 0) return -1;
  spin(100000);
  command(CMD(0) | R_NONE, 0);
  v2 = command(CMD(8) | R_48 | C_CRC | C_IDX, 0x1AA) == 0 && (R(RESP0) & 0xFFF) == 0x1AA;
  for (i = 0; i < 200; i++) {        /* up to 2 s for the card to be ready */
    if (app_command(CMD(41) | R_48, (v2 ? 0x40000000u : 0) | 0x00FF8000u) < 0) return -1;
    ocr = R(RESP0);
    if (ocr & 0x80000000u) break;
    mynos_sleep(10000);
  }
  if (!(ocr & 0x80000000u)) return -1;
  sdhc = (ocr >> 30) & 1;
  if (command(CMD(2) | R_136 | C_CRC, 0) < 0) return -1;
  if (command(CMD(3) | R_48 | C_CRC | C_IDX, 0) < 0) return -1;
  rca = R(RESP0) >> 16;
  if (command(CMD(9) | R_136 | C_CRC, rca << 16) < 0) return -1;
  csd[0] = R(RESP0); csd[1] = R(RESP1); csd[2] = R(RESP2); csd[3] = R(RESP3);
  /* the CSD without its CRC: its bit n at bit n - 8 of RESP0-3 */
  if (((csd[3] >> 22) & 3) == 1)     /* version 2: C_SIZE (69:48), 512 KB units */
    capacity = (unsigned long long)(((csd[1] >> 8) & 0x3FFFFF) + 1) * 1024;
  else {                             /* version 1 */
    unsigned int c_size = ((csd[2] & 3) << 10) | (csd[1] >> 22);   /* (73:62) */
    unsigned int mult = (csd[1] >> 7) & 7, bl_len = (csd[2] >> 8) & 15;
    capacity = ((unsigned long long)(c_size + 1) << (mult + 2 + bl_len)) / SECTOR;
  }
  if (command(CMD(7) | R_48B | C_CRC | C_IDX, rca << 16) < 0) return -1;
  if (!sdhc && command(CMD(16) | R_48 | C_CRC | C_IDX, SECTOR) < 0) return -1;
  if (app_command(CMD(6) | R_48 | C_CRC | C_IDX, 2) == 0)    /* 4 data lines */
    W(CONTROL0, R(CONTROL0) | 2u);
  set_clock(25000000);
  slow = 0;
  return 0;
}

/* count sectors from lba, read into data[] or written from it: 0, or -1 */
static int transfer(int write, unsigned long long lba, int count)
{
  unsigned int cmd, mode, v, *p = (unsigned int *)data;
  int b, i;
  mode = T_BLKCNT | (write ? 0 : T_READ);
  if (count > 1) mode |= T_MULTI | T_ACMD12;
  cmd = CMD(write ? (count > 1 ? 25 : 24) : (count > 1 ? 18 : 17)) |
        R_48 | C_CRC | C_IDX | C_DATA;
  if (wait_reg(STATUS, ST_CMD_INHIBIT | ST_DAT_INHIBIT, 0, 1000) < 0) return -1;
  W(BLKSIZECNT, ((unsigned int)count << 16) | SECTOR);
  W(INTERRUPT, 0xFFFFFFFF);
  W(ARG1, (unsigned int)(sdhc ? lba : lba * SECTOR));
  W(CMDTM, cmd | mode);
  v = wait_int(INT_CMD_DONE | INT_ERROR, 1000);
  if (!(v & INT_CMD_DONE) || (v & INT_ERRORS)) goto fail;
  W(INTERRUPT, INT_CMD_DONE);
  for (b = 0; b < count; b++) {
    unsigned int ready = write ? INT_WRITE_RDY : INT_READ_RDY;
    v = wait_int(ready | INT_ERROR, 1000);
    if (!(v & ready) || (v & INT_ERRORS)) goto fail;
    W(INTERRUPT, ready);
    if (write) for (i = 0; i < SECTOR / 4; i++) R(DATA) = *p++;
    else for (i = 0; i < SECTOR / 4; i++) *p++ = R(DATA);
  }
  v = wait_int(INT_DATA_DONE | INT_ERROR, 2000);
  if (!(v & INT_DATA_DONE) || (v & INT_ERRORS)) goto fail;
  W(INTERRUPT, INT_DATA_DONE);
  return 0;
fail:
  recover();
  return -1;
}

static const wire_request_doc docs[] = {
  { 1, "info", "U", "I", "The number of sectors of the card." },
  { 1, "read", "(lba:I,count:I)", "S",
    "Read count sectors (1 to 32) from sector lba: their bytes." },
  { 0, "write", "(lba:I,bytes:S)", "U",
    "Write bytes (a whole number of sectors, up to 32) from sector lba." },
  { 0, "flush", "U", "U",
    "Nothing to do: each write is on the card when it is answered." },
};

static void serve(wire_reader * r, wire_writer * w)
{
  long long kind = wire_get_int(r), lba = 0, count = 0;
  const char * bytes = NULL;
  unsigned int blen = 0;
  if (kind == 1) { lba = wire_get_int(r); count = wire_get_int(r); }
  else if (kind == 2) { lba = wire_get_int(r); bytes = wire_get_string(r, &blen); }
  if (r->error || !wire_at_end(r) || kind < 0 || kind > 3) {
    wire_reply_error(w, "invalid: " SERVICE " speaks " PROTOCOL);
    return;
  }
  if (kind == 0) {
    wire_reply_ok(w);
    wire_put_int(w, (long long)capacity);
    return;
  }
  if (kind == 3) { wire_reply_ok(w); return; }
  if (kind == 2) {
    if (blen == 0 || blen % SECTOR) {
      wire_reply_error(w, "invalid: not a whole number of sectors");
      return;
    }
    count = blen / SECTOR;
  }
  if (count < 1 || count > MAXCOUNT || lba < 0 ||
      (unsigned long long)(lba + count) > capacity) {
    wire_reply_error(w, "invalid: sectors out of range");
    return;
  }
  if (kind == 2) memcpy(data, bytes, blen);
  if (transfer(kind == 2, (unsigned long long)lba, (int)count) < 0) {
    wire_reply_error(w, "the card failed");
    return;
  }
  wire_reply_ok(w);
  if (kind == 1) wire_put_string(w, (const char *)data, count * SECTOR);
}

int main(void)
{
  int port;
#ifdef __aarch64__
  emmc = mynos_mapPhysical(EMMC_PHYS, 1);
  gpio = mynos_mapPhysical(GPIO_PHYS, 1);
#endif
  if (!emmc || !gpio) {
    mynos_log("sdhcid: no SD card controller (a Raspberry Pi's)\n");
    return 0;
  }
  pins_to_sdhci();
  if (card_init() < 0) {
    mynos_log("sdhcid: no SD card\n");
    return 0;
  }
  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("sdhcid: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("sdhcid: SD%s card, %u sectors, as " SERVICE "\n",
            sdhc ? "HC" : "SC", (unsigned int)capacity);

  for (;;) {
    int channel = mynos_listenPort(port);
    mynos_msg_t * msg;
    wire_reader r;
    wire_writer w;
    const char * id;
    unsigned int idlen;
    if (channel < 0) continue;
    if (mynos_recv(channel, &msg, 0, 1000) < 0) {
      mynos_freeChannel(channel);
      continue;
    }
    wire_writer_init(&w);
    wire_reader_init(&r, msg->start, msg->size);
    id = wire_get_string(&r, &idlen);
    if (!r.error && idlen == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, idlen)
        && wire_at_end(&r))
      wire_reply_description(&w, PROTOCOL,
                             "A block device (an SD card): sectors of 512 bytes, numbered from 0 (LBA).",
                             docs, sizeof docs / sizeof docs[0]);
    else if (!r.error && idlen == strlen(PROTOCOL) && !memcmp(id, PROTOCOL, idlen))
      serve(&r, &w);
    else
      wire_reply_error(&w, "invalid: " SERVICE " speaks " PROTOCOL);
    if (!w.error) mynos_send(channel, w.buf, w.len, 0);
    wire_writer_free(&w);
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
  }
  return 0;
}

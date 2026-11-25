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
 * The NE2000 network card (a National Semiconductor DP8390 with 16 KB of
 * on-board memory), driven through I/O ports from user space: MyNOS
 * processes have I/O privilege. The card interrupts when a frame arrives
 * (ne2k_init's caller waits for its IRQ); transmission is polled.
 *
 * The on-board memory is addressed in 256-byte pages: one transmit buffer
 * at TX_PAGE, and a receive ring from RX_START to RX_STOP that the card
 * fills. BNRY is the last page we have read, CURR the next page the card
 * will write: the ring is empty when the page after BNRY is CURR. Data
 * moves between the card's memory and ours by "remote DMA": set an
 * address and a count, then read or write the data port, 16 bits at a
 * time.
 */

#include "ne2k.h"

/* registers, page 0 */
#define CR      0x00     /* command */
#define PSTART  0x01
#define PSTOP   0x02
#define BNRY    0x03
#define TPSR    0x04
#define TBCR0   0x05
#define TBCR1   0x06
#define ISR     0x07
#define RSAR0   0x08
#define RSAR1   0x09
#define RBCR0   0x0A
#define RBCR1   0x0B
#define RCR     0x0C
#define TCR     0x0D
#define DCR     0x0E
#define IMR     0x0F
/* page 1 */
#define PAR0    0x01
#define CURR    0x07
#define MAR0    0x08
/* outside the DP8390 */
#define DATA    0x10
#define RESET   0x1F

/* CR bits */
#define CR_STOP   0x01
#define CR_START  0x02
#define CR_TXP    0x04
#define CR_RREAD  0x08
#define CR_RWRITE 0x10
#define CR_NODMA  0x20
#define CR_PAGE1  0x40

/* ISR bits */
#define ISR_PRX   0x01
#define ISR_PTX   0x02
#define ISR_TXE   0x08
#define ISR_OVW   0x10
#define ISR_RDC   0x40
#define ISR_RST   0x80

#define TX_PAGE   0x40
#define RX_START  0x46
#define RX_STOP   0x80

static unsigned short base;

#if defined(__i386__) || defined(__x86_64__)
static inline void outb(unsigned short port, unsigned char v) {
  __asm__ volatile ("outb %0, %1" : : "a"(v), "Nd"(port));
}
static inline unsigned char inb(unsigned short port) {
  unsigned char v;
  __asm__ volatile ("inb %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}
static inline void outw(unsigned short port, unsigned short v) {
  __asm__ volatile ("outw %0, %1" : : "a"(v), "Nd"(port));
}
static inline unsigned short inw(unsigned short port) {
  unsigned short v;
  __asm__ volatile ("inw %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}

#else
/* no I/O ports (AArch64): no NE2000 answers the probe */
static inline void outb(unsigned short port, unsigned char v) { (void)port; (void)v; }
static inline unsigned char inb(unsigned short port) { (void)port; return 0; }
static inline void outw(unsigned short port, unsigned short v) { (void)port; (void)v; }
static inline unsigned short inw(unsigned short port) { (void)port; return 0; }
#endif

#define REG(r) (unsigned short)(base + (r))

/* wait for the end of a remote DMA */
static int dma_done(void) {
  int i;
  for (i = 0; i < 100000; i++)
    if (inb(REG(ISR)) & ISR_RDC) { outb(REG(ISR), ISR_RDC); return 0; }
  return -1;
}

static void dma_setup(unsigned int addr, unsigned int count, unsigned char cmd) {
  outb(REG(RBCR0), count & 0xFF);
  outb(REG(RBCR1), count >> 8);
  outb(REG(RSAR0), addr & 0xFF);
  outb(REG(RSAR1), addr >> 8);
  outb(REG(CR), cmd | CR_START);
}

/* read count bytes of the card's memory (count even) */
static void dma_read(unsigned int addr, unsigned char * buf, unsigned int count) {
  unsigned int i;
  dma_setup(addr, count, CR_RREAD);
  for (i = 0; i < count; i += 2) {
    unsigned short w = inw(REG(DATA));
    buf[i] = w & 0xFF;
    buf[i + 1] = w >> 8;
  }
  dma_done();
}

int ne2k_init(unsigned short iobase, unsigned char mac[6]) {
  unsigned char prom[12];
  int i;

  base = iobase;
  /* reset: reading the reset port and writing it back */
  outb(REG(RESET), inb(REG(RESET)));
  for (i = 0; i < 100000 && !(inb(REG(ISR)) & ISR_RST); i++) ;
  if (!(inb(REG(ISR)) & ISR_RST)) return -1;
  outb(REG(ISR), 0xFF);

  outb(REG(CR), CR_NODMA | CR_STOP);
  if (inb(REG(CR)) != (CR_NODMA | CR_STOP)) return -1;   /* nobody there */
  outb(REG(DCR), 0x49);          /* 16-bit transfers, normal, FIFO 8 bytes */
  outb(REG(RBCR0), 0);
  outb(REG(RBCR1), 0);
  outb(REG(IMR), 0);             /* no interrupts while we set up */
  outb(REG(ISR), 0xFF);
  outb(REG(RCR), 0x20);          /* monitor mode while we set up */
  outb(REG(TCR), 0x02);          /* loopback */

  /* the station address: the PROM's first 12 bytes hold each byte twice */
  dma_read(0, prom, 12);
  for (i = 0; i < 6; i++) mac[i] = prom[2 * i];

  outb(REG(PSTART), RX_START);
  outb(REG(PSTOP), RX_STOP);
  outb(REG(BNRY), RX_START);
  outb(REG(TPSR), TX_PAGE);

  outb(REG(CR), CR_PAGE1 | CR_NODMA | CR_STOP);
  for (i = 0; i < 6; i++) outb(REG(PAR0 + i), mac[i]);
  for (i = 0; i < 8; i++) outb(REG(MAR0 + i), 0xFF);   /* all multicast */
  outb(REG(CURR), RX_START + 1);
  outb(REG(CR), CR_NODMA | CR_STOP);

  outb(REG(ISR), 0xFF);
  outb(REG(RCR), 0x04);          /* our address and broadcasts */
  outb(REG(TCR), 0x00);          /* normal transmission */
  outb(REG(CR), CR_NODMA | CR_START);
  /* interrupts: a frame received, a receive error, the ring full */
  outb(REG(IMR), ISR_PRX | 0x04 | ISR_OVW);
  return 0;
}

int ne2k_send(const void * frame, unsigned int len) {
  const unsigned char * p = frame;
  unsigned int i, n;
  int t;

  if (len > NE2K_MAXFRAME) return -1;
  n = len < 60 ? 60 : len;              /* the minimum Ethernet frame */
  if (n & 1) n++;
  /* wait for the previous transmission */
  for (t = 0; t < 100000 && (inb(REG(CR)) & CR_TXP); t++) ;

  outb(REG(ISR), ISR_RDC);
  dma_setup(TX_PAGE << 8, n, CR_RWRITE);
  for (i = 0; i < n; i += 2) {
    unsigned char lo = i < len ? p[i] : 0;
    unsigned char hi = i + 1 < len ? p[i + 1] : 0;
    outw(REG(DATA), lo | (hi << 8));
  }
  if (dma_done() < 0) return -1;

  outb(REG(TPSR), TX_PAGE);
  outb(REG(TBCR0), n & 0xFF);
  outb(REG(TBCR1), n >> 8);
  outb(REG(CR), CR_NODMA | CR_TXP | CR_START);
  for (t = 0; t < 100000; t++) {
    unsigned char isr = inb(REG(ISR));
    if (isr & (ISR_PTX | ISR_TXE)) {
      outb(REG(ISR), ISR_PTX | ISR_TXE);
      return (isr & ISR_TXE) ? -1 : 0;
    }
  }
  return -1;
}

/* the ring overflowed: the documented recovery is to stop the card, drop
   what is in the ring, and start it again */
static void overflow(void) {
  outb(REG(CR), CR_NODMA | CR_STOP);
  outb(REG(RBCR0), 0);
  outb(REG(RBCR1), 0);
  outb(REG(TCR), 0x02);
  outb(REG(CR), CR_PAGE1 | CR_NODMA | CR_STOP);
  outb(REG(CURR), RX_START + 1);
  outb(REG(CR), CR_NODMA | CR_STOP);
  outb(REG(BNRY), RX_START);
  outb(REG(ISR), 0xFF);
  outb(REG(TCR), 0x00);
  outb(REG(CR), CR_NODMA | CR_START);
}

int ne2k_recv(void * buf) {
  unsigned char hdr[4];
  unsigned char next, curr;
  unsigned int len;

  if (inb(REG(ISR)) & ISR_OVW) { overflow(); return 0; }
  /* acknowledge first, then look: a frame that comes meanwhile raises
     the interrupt again */
  outb(REG(ISR), ISR_PRX | 0x04);

  outb(REG(CR), CR_PAGE1 | CR_NODMA | CR_START);
  curr = inb(REG(CURR));
  outb(REG(CR), CR_NODMA | CR_START);
  next = inb(REG(BNRY)) + 1;
  if (next >= RX_STOP) next = RX_START;
  if (next == curr) return 0;            /* empty */

  /* each frame starts with a header: status, next page, length (with the
     header) */
  dma_read(next << 8, hdr, 4);
  len = hdr[2] | (hdr[3] << 8);
  if (len < 4 || len - 4 > NE2K_MAXFRAME ||
      hdr[1] < RX_START || hdr[1] >= RX_STOP) {
    overflow();                          /* a broken ring: start again */
    return 0;
  }
  len -= 4;
  /* the remote DMA wraps at the end of the ring by itself */
  dma_read((next << 8) + 4, buf, (len + 1) & ~1u);

  /* free the pages: BNRY is the page before the next frame */
  next = hdr[1] - 1;
  if (next < RX_START) next = RX_STOP - 1;
  outb(REG(BNRY), next);
  return (hdr[0] & 0x01) ? (int)len : -1; /* bit 0: received intact */
}

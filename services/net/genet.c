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
 * The Ethernet of a Raspberry Pi 4 and 400 (btq.8.4): the BCM2711's GENET
 * (v5) at 0xFD580000, a UniMAC with its own DMA, and a Broadcom BCM54213PE
 * PHY at MDIO address 1, by RGMII (the PHY's receive clock delayed:
 * "rgmii-rxid" in the device tree). The same calls as the NE2000's
 * (ne2k.h): netd uses whichever card it finds.
 *
 * What is done, as U-Boot's and Linux's drivers do it (their register
 * names kept): the receive buffer and the UniMAC reset, the MAC address
 * (the firmware's, through the mailbox), the PHY reset and its
 * autonegotiation, then one receive ring and one transmit ring, both the
 * default queue (16), of RING descriptors each. The descriptors are the
 * GENET's own memory (three words: length and status, the buffer's
 * address); the buffers are DMA memory, kept out of the processor's
 * caches by hand as usbd does (the GENET is not coherent). A frame
 * received or sent is a producer index the GENET or we move on, and a
 * consumer index the other.
 *
 * The kernel lets a driver map the GENET only if the firmware's device
 * tree has it (QEMU's raspi4b has none: genet_init fails there). The
 * interrupt: the GENET's first line (MyNOS's line 5, SPI 157), level,
 * for a received frame.
 */

#include <string.h>
#include <mynos.h>
#include "genet.h"
#include "ne2k.h"

#ifdef __aarch64__

#define GENET_BASE  0xFD580000UL
#define GENET_PAGES 16

static volatile unsigned char * regs;
#define R(OFF)      (*(volatile unsigned int *)(regs + (OFF)))

/* the system block */
#define SYS_REV_CTRL         0x0000
#define SYS_PORT_CTRL        0x0004
#define  PORT_MODE_EXT_GPHY  3
#define SYS_RBUF_FLUSH_CTRL  0x0008
/* the interrupt controllers (INTRL2_0: the default queue's) */
#define INTRL2_0             0x0200
#define INTRL2_1             0x0240
#define  CPU_STAT            0x00
#define  CPU_CLEAR           0x08
#define  CPU_MASK_STATUS     0x0C
#define  CPU_MASK_SET        0x10
#define  CPU_MASK_CLEAR      0x14
#define  IRQ_RXDMA_MBDONE    (1u << 13)
/* RGMII */
#define EXT_RGMII_OOB_CTRL   0x008C
#define  RGMII_LINK          (1u << 4)
#define  OOB_DISABLE         (1u << 5)
#define  RGMII_MODE_EN       (1u << 6)
#define  ID_MODE_DIS         (1u << 16)
/* the receive buffer */
#define RBUF_CTRL            0x0300
#define  RBUF_ALIGN_2B       (1u << 1)
#define RBUF_TBUF_SIZE_CTRL  0x03B4
/* the UniMAC */
#define UMAC_CMD             0x0808
#define  CMD_TX_EN           (1u << 0)
#define  CMD_RX_EN           (1u << 1)
#define  CMD_SPEED_SHIFT     2
#define  CMD_HD_EN           (1u << 10)
#define  CMD_SW_RESET        (1u << 13)
#define  CMD_LCL_LOOP_EN     (1u << 15)
#define UMAC_MAC0            0x080C
#define UMAC_MAC1            0x0810
#define UMAC_MAX_FRAME_LEN   0x0814
#define UMAC_TX_FLUSH        0x0B34
#define UMAC_MIB_CTRL        0x0D80
#define MDIO_CMD             0x0E14
#define  MDIO_START_BUSY     (1u << 29)
#define  MDIO_READ_FAIL      (1u << 28)
#define  MDIO_RD             (2u << 26)
#define  MDIO_WR             (1u << 26)
/* the DMA: 256 descriptors of 12 bytes, then the 17 rings' registers
   (0x40 each), then the DMA's own */
#define RX_DESC              0x2000
#define TX_DESC              0x4000
#define RDMA_RING            (0x2C00 + 16 * 0x40)      /* the default queue's */
#define TDMA_RING            (0x4C00 + 16 * 0x40)
#define RDMA_REGS            (0x2C00 + 17 * 0x40)
#define TDMA_REGS            (0x4C00 + 17 * 0x40)
#define  DMA_RING_CFG        0x00
#define  DMA_CTRL            0x04
#define  DMA_SCB_BURST_SIZE  0x0C
#define  DMA_EN              (1u << 0)
/* a ring's registers: the receive ring's names, then the transmit's */
#define RDMA_READ_PTR        0x2C
#define RDMA_WRITE_PTR       0x00
#define RDMA_PROD_INDEX      0x08
#define RDMA_CONS_INDEX      0x0C
#define RDMA_XON_XOFF_THRESH 0x28
#define TDMA_READ_PTR        0x00
#define TDMA_CONS_INDEX      0x08
#define TDMA_PROD_INDEX      0x0C
#define TDMA_FLOW_PERIOD     0x28
#define TDMA_WRITE_PTR       0x2C
#define DMA_RING_BUF_SIZE    0x10
#define DMA_START_ADDR       0x14
#define DMA_END_ADDR         0x1C
#define DMA_MBUF_DONE_THRESH 0x24
/* a descriptor */
#define DESC_LEN_STATUS      0
#define DESC_ADDR_LO         4
#define DESC_ADDR_HI         8
#define DMA_OWN              0x8000
#define DMA_EOP              0x4000
#define DMA_SOP              0x2000
#define DMA_TX_APPEND_CRC    0x0040
#define DMA_TX_QTAG          (0x3Fu << 7)
#define DMA_RX_ERRORS        0x001F         /* overrun, CRC, RXER, no, too long */

#define RING   256                          /* descriptors a ring: all of them (a
                                               descriptor is then its index mod 256) */
#define BUF    2048                         /* a buffer */

static unsigned char * rxb, * txb;          /* RING buffers each */
static unsigned long rxb_bus, txb_bus;
static unsigned int rx_cons;                /* the frames taken (16 bits) */
static int rx_i;                            /* the next one's descriptor */
static unsigned int tx_prod;                /* the frames given (16 bits) */
static int tx_i;

static void cache_clean(const void * p, unsigned long len)
{
  unsigned long a = (unsigned long)p & ~63UL, end = (unsigned long)p + len;
  for (; a < end; a += 64) __asm__ volatile ("dc cvac, %0" : : "r"(a) : "memory");
  __asm__ volatile ("dsb sy" : : : "memory");
}

static void cache_drop(const void * p, unsigned long len)
{
  unsigned long a = (unsigned long)p & ~63UL, end = (unsigned long)p + len;
  __asm__ volatile ("dsb sy" : : : "memory");
  for (; a < end; a += 64) __asm__ volatile ("dc civac, %0" : : "r"(a) : "memory");
  __asm__ volatile ("dsb sy" : : : "memory");
}

static void udelay(int us)
{
  mynos_sleep(us < 1000 ? 1000 : us);       /* (a millisecond at least) */
}

/* ---- the PHY, through MDIO ---- */

#define PHY 1

static int mdio_wait(void)
{
  int i;
  for (i = 0; i < 100; i++) {
    if (!(R(MDIO_CMD) & MDIO_START_BUSY)) return 0;
    udelay(1000);
  }
  return -1;
}

static int mdio_read(int reg)
{
  unsigned int v;
  R(MDIO_CMD) = MDIO_RD | PHY << 21 | (unsigned int)reg << 16;
  R(MDIO_CMD) |= MDIO_START_BUSY;
  if (mdio_wait() < 0) return -1;
  v = R(MDIO_CMD);
  return (v & MDIO_READ_FAIL) ? -1 : (int)(v & 0xFFFF);
}

static int mdio_write(int reg, int val)
{
  R(MDIO_CMD) = MDIO_WR | PHY << 21 | (unsigned int)reg << 16 | (val & 0xFFFF);
  R(MDIO_CMD) |= MDIO_START_BUSY;
  return mdio_wait();
}

/* reset, autonegotiation (10 to 1000, both duplexes); the speed (0 10,
   1 100, 2 1000) and duplex agreed, -1 with no link after 5 s */
static int phy_start(int * full)
{
  int i, bmsr = 0, lpa, adv, stat1000;
  if (mdio_write(0, 0x8000) < 0) return -1;              /* BMCR: reset */
  for (i = 0; i < 50 && (mdio_read(0) & 0x8000); i++) udelay(10000);
  mdio_write(4, 0x01E1);                                  /* 10 and 100, both, 802.3 */
  mdio_write(9, 0x0300);                                  /* 1000, both */
  mdio_write(0, 0x1200);                                  /* autonegotiation, restarted */
  for (i = 0; i < 50; i++) {
    udelay(100000);
    mdio_read(1);                                         /* (the link bit latches low) */
    bmsr = mdio_read(1);
    if (bmsr >= 0 && (bmsr & 0x24) == 0x24) break;        /* negotiated, link */
  }
  if (bmsr < 0 || (bmsr & 0x24) != 0x24) return -1;
  stat1000 = mdio_read(10);
  if (stat1000 >= 0 && (stat1000 & 0x0800)) { *full = 1; return 2; }
  if (stat1000 >= 0 && (stat1000 & 0x0400)) { *full = 0; return 2; }
  adv = mdio_read(4);
  lpa = mdio_read(5);
  lpa &= adv;
  if (lpa & 0x0100) { *full = 1; return 1; }
  if (lpa & 0x0080) { *full = 0; return 1; }
  *full = (lpa & 0x0040) != 0;
  return 0;
}

/* ---- the MAC address: the board's, from the firmware ---- */

static int board_mac(unsigned char mac[6])
{
  unsigned int b[8] __attribute__((aligned(16)));
  int i;
  b[0] = sizeof b; b[1] = 0;
  b[2] = 0x00010003;                        /* get board MAC address */
  b[3] = 8; b[4] = 0; b[5] = 0; b[6] = 0;
  b[7] = 0;
  if (mynos_piFirmware(b, sizeof b) != 0 || !(b[4] & 0x80000000u)) return -1;
  for (i = 0; i < 6; i++) mac[i] = ((unsigned char *)&b[5])[i];
  return (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]) ? 0 : -1;
}

/* ---- the rings ---- */

static void rx_ring_init(void)
{
  int i;
  volatile unsigned char * r = regs + RDMA_RING;
  for (i = 0; i < RING; i++) {
    unsigned long a = rxb_bus + (unsigned long)i * BUF;
    R(RX_DESC + 12 * i + DESC_ADDR_LO) = (unsigned int)a;
    R(RX_DESC + 12 * i + DESC_ADDR_HI) = (unsigned int)(a >> 32);
    R(RX_DESC + 12 * i + DESC_LEN_STATUS) = BUF << 16 | DMA_OWN;
  }
  R(RDMA_REGS + DMA_SCB_BURST_SIZE) = 8;
  *(volatile unsigned int *)(r + DMA_START_ADDR) = 0;
  *(volatile unsigned int *)(r + RDMA_READ_PTR) = 0;
  *(volatile unsigned int *)(r + RDMA_WRITE_PTR) = 0;
  *(volatile unsigned int *)(r + DMA_END_ADDR) = RING * 12 / 4 - 1;
  /* (the producer index cannot be written 0: the consumer's follows it) */
  rx_cons = *(volatile unsigned int *)(r + RDMA_PROD_INDEX) & 0xFFFF;
  *(volatile unsigned int *)(r + RDMA_CONS_INDEX) = rx_cons;
  rx_i = (int)(rx_cons % RING);
  *(volatile unsigned int *)(r + DMA_RING_BUF_SIZE) = RING << 16 | BUF;
  *(volatile unsigned int *)(r + RDMA_XON_XOFF_THRESH) = 5u << 16 | (RING >> 4);
  *(volatile unsigned int *)(r + DMA_MBUF_DONE_THRESH) = 1;   /* an interrupt a frame */
  R(RDMA_REGS + DMA_RING_CFG) = 1u << 16;
}

static void tx_ring_init(void)
{
  volatile unsigned char * r = regs + TDMA_RING;
  R(TDMA_REGS + DMA_SCB_BURST_SIZE) = 8;
  *(volatile unsigned int *)(r + DMA_START_ADDR) = 0;
  *(volatile unsigned int *)(r + TDMA_READ_PTR) = 0;
  *(volatile unsigned int *)(r + TDMA_WRITE_PTR) = 0;
  *(volatile unsigned int *)(r + DMA_END_ADDR) = RING * 12 / 4 - 1;
  tx_prod = *(volatile unsigned int *)(r + TDMA_CONS_INDEX) & 0xFFFF;
  *(volatile unsigned int *)(r + TDMA_PROD_INDEX) = tx_prod;
  tx_i = (int)(tx_prod % RING);
  *(volatile unsigned int *)(r + DMA_MBUF_DONE_THRESH) = 1;
  *(volatile unsigned int *)(r + TDMA_FLOW_PERIOD) = 0;
  *(volatile unsigned int *)(r + DMA_RING_BUF_SIZE) = RING << 16 | BUF;
  R(TDMA_REGS + DMA_RING_CFG) = 1u << 16;
}

/* ---- the calls ---- */

int genet_init(unsigned char mac[6], int * irq)
{
  unsigned int rev, cmd;
  int speed, full = 1;
  regs = mynos_mapPhysical(GENET_BASE, GENET_PAGES);
  if (!regs) return -1;                     /* no GENET (not a Pi 4) */
  rev = R(SYS_REV_CTRL);
  if (((rev >> 24) & 0xF) != 6) {           /* (v5 says 6) */
    mynos_log("netd: GENET: revision %08x, not v5\n", rev);
    return -1;
  }
  rxb = mynos_dmaAlloc(RING * BUF / 4096, &rxb_bus);
  txb = mynos_dmaAlloc(RING * BUF / 4096, &txb_bus);
  if (!rxb || !txb) return -1;
  cache_clean(rxb, RING * BUF);
  /* the interrupts, all masked and cleared */
  R(INTRL2_0 + CPU_MASK_SET) = 0xFFFFFFFF;
  R(INTRL2_0 + CPU_CLEAR) = 0xFFFFFFFF;
  R(INTRL2_1 + CPU_MASK_SET) = 0xFFFFFFFF;
  R(INTRL2_1 + CPU_CLEAR) = 0xFFFFFFFF;
  /* the receive buffer flushed, the UniMAC reset, its counters cleared */
  R(SYS_RBUF_FLUSH_CTRL) |= 2;
  udelay(10);
  R(SYS_RBUF_FLUSH_CTRL) &= ~2u;
  udelay(10);
  R(SYS_RBUF_FLUSH_CTRL) = 0;
  udelay(10);
  R(UMAC_CMD) = 0;
  R(UMAC_CMD) = CMD_SW_RESET | CMD_LCL_LOOP_EN;
  udelay(2);
  R(UMAC_CMD) = 0;
  R(UMAC_MIB_CTRL) = 7;
  R(UMAC_MIB_CTRL) = 0;
  R(UMAC_MAX_FRAME_LEN) = 1536;
  R(RBUF_CTRL) |= RBUF_ALIGN_2B;            /* two bytes before each frame */
  R(RBUF_TBUF_SIZE_CTRL) = 1;
  /* RGMII to an external PHY */
  R(SYS_PORT_CTRL) = PORT_MODE_EXT_GPHY;
  /* the MAC address */
  if (board_mac(mac) < 0) {
    unsigned int m0 = R(UMAC_MAC0), m1 = R(UMAC_MAC1);
    mac[0] = m0 >> 24; mac[1] = m0 >> 16; mac[2] = m0 >> 8; mac[3] = m0;
    mac[4] = m1 >> 8; mac[5] = m1;
    if (!(mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5])) {
      static const unsigned char fallback[6] = { 0x02, 0x4D, 0x79, 0x4E, 0x4F, 0x53 };
      memcpy(mac, fallback, 6);
    }
    mynos_log("netd: GENET: no MAC address from the firmware\n");
  }
  R(UMAC_MAC0) = (unsigned int)mac[0] << 24 | mac[1] << 16 | mac[2] << 8 | mac[3];
  R(UMAC_MAC1) = (unsigned int)mac[4] << 8 | mac[5];
  /* the DMA off, the transmit queue flushed; the rings; the DMA on */
  R(TDMA_REGS + DMA_CTRL) &= ~DMA_EN;
  R(RDMA_REGS + DMA_CTRL) &= ~DMA_EN;
  R(UMAC_TX_FLUSH) = 1;
  udelay(10);
  R(UMAC_TX_FLUSH) = 0;
  rx_ring_init();
  tx_ring_init();
  R(TDMA_REGS + DMA_CTRL) = 1u << 17 | DMA_EN;   /* the default queue's ring, the DMA */
  R(RDMA_REGS + DMA_CTRL) = 1u << 17 | DMA_EN;
  /* the PHY: the link, its speed; the UniMAC told, then on */
  speed = phy_start(&full);
  if (speed < 0) {
    mynos_log("netd: GENET: no link (a cable?): 1000 Mb/s assumed\n");
    speed = 2;
  } else
    mynos_log("netd: GENET: link up, %d Mb/s, %s duplex\n",
              speed == 2 ? 1000 : speed == 1 ? 100 : 10, full ? "full" : "half");
  R(EXT_RGMII_OOB_CTRL) = (R(EXT_RGMII_OOB_CTRL) & ~OOB_DISABLE) | RGMII_LINK |
                          RGMII_MODE_EN | ID_MODE_DIS;
  cmd = (unsigned int)speed << CMD_SPEED_SHIFT | (full ? 0 : CMD_HD_EN);
  R(UMAC_CMD) = cmd;
  R(UMAC_CMD) = cmd | CMD_TX_EN | CMD_RX_EN;
  /* a received frame interrupts */
  R(INTRL2_0 + CPU_MASK_CLEAR) = IRQ_RXDMA_MBDONE;
  *irq = 5;                                 /* (raspi.c's lines4[]: SPI 157) */
  return 0;
}

int genet_send(const void * frame, unsigned int len)
{
  volatile unsigned char * r = regs + TDMA_RING;
  unsigned int cons;
  unsigned char * b;
  int tries;
  if (len > NE2K_MAXFRAME) return -1;
  for (tries = 0; ; tries++) {              /* a free descriptor */
    cons = *(volatile unsigned int *)(r + TDMA_CONS_INDEX) & 0xFFFF;
    if (((tx_prod - cons) & 0xFFFF) < RING) break;
    if (tries == 1000) return -1;
    mynos_sleep(1000);
  }
  b = txb + (unsigned long)tx_i * BUF;
  memcpy(b, frame, len);
  if (len < 60) { memset(b + len, 0, 60 - len); len = 60; }
  cache_clean(b, len);
  R(TX_DESC + 12 * tx_i + DESC_ADDR_LO) = (unsigned int)(txb_bus + (unsigned long)tx_i * BUF);
  R(TX_DESC + 12 * tx_i + DESC_ADDR_HI) = (unsigned int)((txb_bus + (unsigned long)tx_i * BUF) >> 32);
  R(TX_DESC + 12 * tx_i + DESC_LEN_STATUS) = len << 16 | DMA_TX_QTAG | DMA_TX_APPEND_CRC |
                                             DMA_SOP | DMA_EOP;
  if (++tx_i == RING) tx_i = 0;
  tx_prod = (tx_prod + 1) & 0xFFFF;
  __asm__ volatile ("dsb sy" : : : "memory");
  *(volatile unsigned int *)(r + TDMA_PROD_INDEX) = tx_prod;
  return 0;
}

int genet_recv(void * buf)
{
  volatile unsigned char * r = regs + RDMA_RING;
  unsigned int prod, ls;
  unsigned char * b;
  int n;
  prod = *(volatile unsigned int *)(r + RDMA_PROD_INDEX) & 0xFFFF;
  if (prod == rx_cons) return 0;
  ls = R(RX_DESC + 12 * rx_i + DESC_LEN_STATUS);
  b = rxb + (unsigned long)rx_i * BUF;
  n = (int)((ls >> 16) & 0xFFF) - 2;        /* (the two bytes of alignment) */
  if (!(ls & DMA_SOP) || !(ls & DMA_EOP) || (ls & DMA_RX_ERRORS) || n <= 0) n = -1;
  else {
    if (n > NE2K_BUFSIZE) n = NE2K_BUFSIZE;
    cache_drop(b, (unsigned long)n + 2);
    memcpy(buf, b + 2, n);
  }
  if (++rx_i == RING) rx_i = 0;
  rx_cons = (rx_cons + 1) & 0xFFFF;
  *(volatile unsigned int *)(r + RDMA_CONS_INDEX) = rx_cons;
  return n;
}

void genet_ack(void)
{
  R(INTRL2_0 + CPU_CLEAR) = R(INTRL2_0 + CPU_STAT) & ~R(INTRL2_0 + CPU_MASK_STATUS);
  mynos_enableIrq(5);
}

#else   /* not a Raspberry Pi */

int genet_init(unsigned char mac[6], int * irq) { (void)mac; (void)irq; return -1; }
int genet_send(const void * frame, unsigned int len) { (void)frame; (void)len; return -1; }
int genet_recv(void * buf) { (void)buf; return 0; }
void genet_ack(void) { }

#endif

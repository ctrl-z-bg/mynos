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
 * A Raspberry Pi 4's or 400's PCIe (MYNOS_RASPI, btq.8.1): the BCM2711's
 * root complex (0xFD500000), whose one device is the VL805, the USB
 * controller (xHCI) of the keyboard, the mouse, the USB sockets. Brought
 * up at boot, as Linux's pcie-brcmstb.c does, when the firmware's device
 * tree has it (QEMU's raspi4b has none: nothing there to touch):
 *
 *   - the bridge out of reset, its SerDes powered, the PCIe's view of
 *     RAM (inbound: PCI 0 is RAM's 0, 4 GB: the device tree's
 *     dma-ranges, 3 GB, rounded up as the bridge wants), the link out of
 *     reset (PERST) and waited for (100 ms);
 *   - the CPU's window into PCI (outbound: CPU 0x6_0000_0000 is PCI
 *     0xC000_0000, 1 GB: the device tree's ranges);
 *   - the root port a bridge to bus 1; the device there (the VL805) its
 *     memory (BAR 0 at the window's start), memory and bus mastering on;
 *   - the firmware told (the mailbox's "xHCI reset" notice), which loads
 *     the VL805's own firmware (the Pi 400's and the later Pi 4s' VL805
 *     has none of its own).
 *
 * Then mapPhysical lets a driver map the bridge's registers (the
 * configuration space: index and data) and the window (raspi.c's
 * raspi_device_ok); the driver is in user space (btq.8.2). The PCIe's
 * DMA is not coherent with the processors' caches: the driver's
 * business.
 */

#ifdef MYNOS_RASPI

#include "global.h"
#include "layout.h"
#include "video.h"
#include "kutils.h"

#define PCIE            0xFD500000UL
#define R(OFF)          (*(volatile uint32_t *)DEVICE(PCIE + (OFF)))

#define RC_VENDOR_REG1          0x0188  /* bits 3:2, BAR2's endianness: 0 little */
#define RC_PRIV1_ID_VAL3        0x043C  /* the root port's class code */
#define MISC_CTRL               0x4008
#define   SCB_ACCESS_EN         (1u << 12)
#define   CFG_READ_UR_MODE      (1u << 13)
#define   MAX_BURST_MASK        (3u << 20)
#define   SCB0_SIZE_SHIFT       27
#define WIN0_LO                 0x400C
#define WIN0_HI                 0x4010
#define RC_BAR1_LO              0x402C
#define RC_BAR2_LO              0x4034
#define RC_BAR2_HI              0x4038
#define RC_BAR3_LO              0x403C
#define PCIE_STATUS             0x4068
#define   DL_ACTIVE             (1u << 5)
#define   PHYLINKUP             (1u << 4)
#define   RC_MODE               (1u << 7)
#define REVISION                0x406C
#define WIN0_BASE_LIMIT         0x4070
#define WIN0_BASE_HI            0x4080
#define WIN0_LIMIT_HI           0x4084
#define HARD_DEBUG              0x4204
#define   SERDES_IDDQ           (1u << 27)
#define INTR2_CPU               0x4300
#define EXT_CFG_DATA            0x8000
#define EXT_CFG_INDEX           0x9000
#define RGR1_SW_INIT_1          0x9210
#define   SW_PERST              (1u << 0)
#define   SW_INIT               (1u << 1)

#define WIN_CPU   0x600000000UL           /* the CPU's window ... */
#define WIN_PCI   0xC0000000UL            /* ... onto PCI's addresses */
#define WIN_SIZE  0x40000000UL

int raspi_pcie_present;                   /* the device tree says so (dtb.c) */
int raspi_pcie_up;                        /* the link is up, the VL805 set up */

int raspi_mbox(volatile uint32_t * buf);

static uint64_t counter(void)
{
  uint64_t v;
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r"(v));
  return v;
}
static void udelay(unsigned int us)
{
  uint64_t f, t = counter();
  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r"(f));
  while (counter() - t < f / 1000000 * us) ;
}

/* a register of a device's configuration space: bus 0 is the root port
   (the bridge's own registers), the others through the index */
static volatile uint32_t * cfg(int bus, int dev, int fn, int reg)
{
  if (bus == 0) return dev == 0 && fn == 0 ? &R(reg & 0xFFC) : NULL;
  R(EXT_CFG_INDEX) = (uint32_t)(bus << 20 | dev << 15 | fn << 12);
  return &R(EXT_CFG_DATA + (reg & 0xFFC));
}

static void put_hex(uint32_t v) { print_ulong_hex(v); }

static volatile uint32_t mb[16] __attribute__((aligned(16)));

void raspi_pcie_init(void)
{
  uint32_t v, id;
  int i;
  volatile uint32_t * c;
  if (!raspi_pcie_present) return;
  printk("PCIe: ");
  /* reset: the bridge and the link (PERST) asserted, then the bridge out */
  R(RGR1_SW_INIT_1) |= SW_INIT | SW_PERST;
  udelay(200);
  R(RGR1_SW_INIT_1) &= ~SW_INIT;
  udelay(200);
  R(HARD_DEBUG) &= ~SERDES_IDDQ;          /* the SerDes on */
  udelay(200);
  printk("revision ");
  put_hex(R(REVISION));
  /* the bus to the memory (SCB): accesses on, unsupported config reads
     answered 0xFFFFFFFF, 128-byte bursts, RAM's 4 GB (log2 - 15 = 17) */
  v = R(MISC_CTRL);
  v |= SCB_ACCESS_EN | CFG_READ_UR_MODE;
  v &= ~MAX_BURST_MASK;
  v = (v & ~(0x1Fu << SCB0_SIZE_SHIFT)) | (17u << SCB0_SIZE_SHIFT);
  R(MISC_CTRL) = v;
  /* inbound: PCI 0 is RAM's 0, 4 GB (the size's code: log2 - 15 = 17) */
  R(RC_BAR2_LO) = 0 | 17;
  R(RC_BAR2_HI) = 0;
  R(RC_BAR1_LO) &= ~0x1Fu;                /* the other two: off */
  R(RC_BAR3_LO) &= ~0x1Fu;
  R(INTR2_CPU + 0x10) = 0xFFFFFFFF;       /* its own interrupts masked */
  R(INTR2_CPU + 0x08) = 0xFFFFFFFF;       /* and cleared */
  /* the link out of reset, waited for */
  R(RGR1_SW_INIT_1) &= ~SW_PERST;
  for (i = 0; i < 20; i++) {
    udelay(5000);
    v = R(PCIE_STATUS);
    if ((v & (DL_ACTIVE | PHYLINKUP)) == (DL_ACTIVE | PHYLINKUP)) break;
  }
  if ((v & (DL_ACTIVE | PHYLINKUP)) != (DL_ACTIVE | PHYLINKUP)) {
    printk(", no link (status ");
    put_hex(v);
    printk(")\n");
    return;
  }
  if (!(v & RC_MODE)) {
    printk(", not a root complex\n");
    return;
  }
  /* outbound: the CPU's 0x6_0000_0000 onto PCI's 0xC000_0000, 1 GB (the
     base and the limit in MB: 12 bits low, the rest high) */
  R(WIN0_LO) = (uint32_t)WIN_PCI;
  R(WIN0_HI) = (uint32_t)(WIN_PCI >> 32);
  {
    uint64_t base_mb = WIN_CPU >> 20, limit_mb = (WIN_CPU + WIN_SIZE - 1) >> 20;
    R(WIN0_BASE_LIMIT) = (uint32_t)((limit_mb & 0xFFF) << 20 | (base_mb & 0xFFF) << 4);
    R(WIN0_BASE_HI) = (uint32_t)(base_mb >> 12);
    R(WIN0_LIMIT_HI) = (uint32_t)(limit_mb >> 12);
  }
  R(RC_PRIV1_ID_VAL3) = (R(RC_PRIV1_ID_VAL3) & ~0xFFFFFFu) | 0x060400;   /* a bridge */
  R(RC_VENDOR_REG1) &= ~0xCu;             /* little endian */
  /* the root port: bus 0 to bus 1, the window's memory forwarded, on */
  c = cfg(0, 0, 0, 0x18); *c = (*c & 0xFF000000u) | 0x00010100u;
  c = cfg(0, 0, 0, 0x20); *c = (uint32_t)((((WIN_PCI + WIN_SIZE - 1) >> 16) & 0xFFF0) << 16 |
                                           ((WIN_PCI >> 16) & 0xFFF0));
  c = cfg(0, 0, 0, 0x04); *c |= 0x6;      /* memory, bus master */
  /* the device on bus 1 */
  id = *cfg(1, 0, 0, 0x00);
  printk(", link up, ");
  put_hex(id);
  if (id == 0xFFFFFFFF || id == 0) {
    printk(": no device\n");
    return;
  }
  c = cfg(1, 0, 0, 0x10); *c = (uint32_t)WIN_PCI;     /* BAR 0 (64 bits) */
  c = cfg(1, 0, 0, 0x14); *c = (uint32_t)(WIN_PCI >> 32);
  c = cfg(1, 0, 0, 0x04); *c |= 0x6;
  /* the firmware loads the VL805's (bus 1, device 0, function 0) */
  i = 0;
  mb[i++] = 0; mb[i++] = 0;
  mb[i++] = 0x00030058; mb[i++] = 4; mb[i++] = 0; mb[i++] = 1u << 20;
  mb[i++] = 0;
  mb[0] = i * 4;
  if (raspi_mbox(mb) != 0) printk(" (the firmware did not answer)");
  raspi_pcie_up = 1;
  printk(" at 0x600000000\n");
}

#endif

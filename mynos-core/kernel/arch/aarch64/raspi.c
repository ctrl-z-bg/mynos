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
 * The Raspberry Pi 3 and Zero 2 W (BCM2837; MYNOS_RASPI, btq.7,
 * doc/decisions/aarch64.md): what QEMU virt's GIC, PSCI and PL031 do
 * there.
 *
 *   - the VideoCore's mailbox (property channel 8): RAM's size, later the
 *     framebuffer. Its buffer is given by its bus address (the
 *     uncached alias, 0xC0000000 | physical), cleaned out of the caches
 *     before and dropped from them after;
 *   - the interrupts: each processor's local controller (0x40000000:
 *     its generic timer, its four mailboxes, the GPU's interrupts routed
 *     to processor 0) and the BCM2835's controller of the GPU's (the
 *     peripherals'). The kernel keeps the GIC's numbers (pic.h): the
 *     timer 27, the IPI 0 (mailbox 0), MyNOS's line n 32 + n, n the
 *     peripheral's place in lines[];
 *   - the other processors: the firmware's spin tables (0xD8 + 8 n: an
 *     address written there, an event, and processor n starts there at
 *     EL2, MMU off);
 *   - the UART: the PL011 (UART0) on GPIO 14 and 15 (a real Pi 3 gives
 *     them to Bluetooth unless config.txt says dtoverlay=disable-bt);
 *   - restart and power off: the power manager's watchdog (power off:
 *     the firmware's "halt" partition, 63, as Linux does; QEMU ends).
 * No real-time clock: the time starts at the build's commit (io.c).
 */

#ifdef MYNOS_RASPI

#include "global.h"
#include "layout.h"
#include "pic.h"
#include "kutils.h"
#include "mem/mem.h"

#define PERI        0x3F000000UL
#define LOCAL       0x40000000UL
#define R(A)        (*(volatile uint32_t *)DEVICE(A))

/* ---- the mailbox ---- */

#define MBOX        (PERI + 0xB880)
#define MBOX_READ   0x00
#define MBOX_STATUS 0x18
#define MBOX_WRITE  0x20
#define MBOX_FULL   0x80000000u
#define MBOX_EMPTY  0x40000000u

static void dcache_clean_inval(void * p, unsigned long len)
{
  unsigned long a = (unsigned long)p & ~63UL, end = (unsigned long)p + len;
  for (; a < end; a += 64) __asm__ volatile ("dc civac, %0" : : "r"(a) : "memory");
  __asm__ volatile ("dsb sy" : : : "memory");
}

/* a property request: buf (16-byte aligned, in the kernel's image: its
   address is its physical one) sent on channel 8, the answer in it.
   0 if the firmware answered */
int raspi_mbox(volatile uint32_t * buf)
{
  uint32_t msg = (uint32_t)(((unsigned long)buf + ARCH_RAM_BASE) | 0xC0000000u) | 8;
  int tries;
  dcache_clean_inval((void *)buf, buf[0]);
  while (R(MBOX + MBOX_STATUS) & MBOX_FULL) ;
  R(MBOX + MBOX_WRITE) = msg;
  for (tries = 0; tries < 10000000; tries++) {
    while (R(MBOX + MBOX_STATUS) & MBOX_EMPTY) ;
    if (R(MBOX + MBOX_READ) == msg) {
      dcache_clean_inval((void *)buf, buf[0]);
      return buf[1] == 0x80000000u ? 0 : -1;
    }
  }
  return -1;
}

static volatile uint32_t mbox_buf[36] __attribute__((aligned(16)));

/* the ARM's RAM, from the firmware: its size (the rest, up to the
   peripherals, is the VideoCore's) */
unsigned long raspi_ram_size(void)
{
  mbox_buf[0] = 8 * 4;
  mbox_buf[1] = 0;
  mbox_buf[2] = 0x00010005;                 /* get ARM memory */
  mbox_buf[3] = 8;
  mbox_buf[4] = 0;
  mbox_buf[5] = 0;
  mbox_buf[6] = 0;
  mbox_buf[7] = 0;                          /* the end tag */
  if (raspi_mbox(mbox_buf) != 0 || mbox_buf[5] != 0) return 0;
  return mbox_buf[6];
}

/* ---- the UART: GPIO 14 and 15 to the PL011, 115200 8N1 ---- */

#define GPIO        (PERI + 0x200000)
#define GPFSEL1     0x04
#define GPPUD       0x94
#define GPPUDCLK0   0x98
#define UART0       (PERI + 0x201000)

static void delay_cycles(int n) { while (n-- > 0) __asm__ volatile ("nop"); }

void raspi_uart_init(void)
{
  uint32_t sel;
  R(UART0 + 0x30) = 0;                      /* CR: off */
  sel = R(GPIO + GPFSEL1);
  sel &= ~((7u << 12) | (7u << 15));
  sel |= (4u << 12) | (4u << 15);           /* ALT0: TXD0, RXD0 */
  R(GPIO + GPFSEL1) = sel;
  R(GPIO + GPPUD) = 0;                      /* no pull-up or down */
  delay_cycles(150);
  R(GPIO + GPPUDCLK0) = (1u << 14) | (1u << 15);
  delay_cycles(150);
  R(GPIO + GPPUDCLK0) = 0;
  R(UART0 + 0x44) = 0x7FF;                  /* ICR: everything cleared */
  R(UART0 + 0x24) = 26;                     /* IBRD, FBRD: 115200 from 48 MHz */
  R(UART0 + 0x28) = 3;
  R(UART0 + 0x2C) = (3u << 5) | (1u << 4);  /* LCRH: 8 bits, FIFOs */
  R(UART0 + 0x38) = 0;                      /* IMSC: no interrupts yet */
  R(UART0 + 0x30) = (1u << 0) | (1u << 8) | (1u << 9);   /* on, TX, RX */
}

/* ---- restart and power off ---- */

#define PM          (PERI + 0x100000)
#define PM_RSTC     0x1C
#define PM_RSTS     0x20
#define PM_WDOG     0x24
#define PM_PASSWORD 0x5A000000u

void raspi_reset(int halt)
{
  uint32_t v;
  if (halt) {                               /* the firmware stops at partition 63 */
    v = R(PM + PM_RSTS);
    v &= ~0xFFFFFAAAu;
    v |= 0x555;
    R(PM + PM_RSTS) = PM_PASSWORD | v;
  }
  R(PM + PM_WDOG) = PM_PASSWORD | 10;
  v = R(PM + PM_RSTC);
  R(PM + PM_RSTC) = PM_PASSWORD | (v & ~0x30u) | 0x20;   /* a full reset */
  for (;;) __asm__ volatile ("wfi");
}

/* ---- the interrupt controllers ---- */

#define LOCAL_GPU_ROUTE   0x0C
#define LOCAL_TIMER_CTL   0x40              /* + 4 n: bit 3, the virtual timer's IRQ */
#define LOCAL_MBOX_CTL    0x50              /* + 4 n: bit 0, mailbox 0's IRQ */
#define LOCAL_IRQ_SOURCE  0x60              /* + 4 n */
#define LOCAL_MBOX_SET    0x80              /* + 16 n: mailbox 0, written to set */
#define LOCAL_MBOX_CLR    0xC0              /* + 16 n: mailbox 0, written to clear */
#define SRC_CNTV          (1u << 3)
#define SRC_MBOX0         (1u << 4)
#define SRC_GPU           (1u << 8)

#define IC                (PERI + 0xB200)
#define IC_PENDING1       0x04
#define IC_PENDING2       0x08
#define IC_ENABLE1        0x10
#define IC_ENABLE2        0x14
#define IC_DISABLE1       0x1C
#define IC_DISABLE2       0x20

/* MyNOS's lines: the GPU's interrupt (0-63) of each, -1 none.
   1 the UART (the PL011, as on virt: consoled), 2 the SD card's SDHCI
   (Arasan), 3 its SDHOST, 4 the USB (DWC2) */
static const signed char lines[16] = { -1, 57, 62, 56, 9, -1, -1, -1,
                                  -1, -1, -1, -1, -1, -1, -1, -1 };
static uint32_t lines_on;

static uint32_t cpu_id(void)
{
  uint64_t m;
  __asm__ volatile ("mrs %0, mpidr_el1" : "=r"(m));
  return m & 3;
}

static void gpu_irq(int g, int on)
{
  if (g < 0) return;
  if (on) R(IC + (g < 32 ? IC_ENABLE1 : IC_ENABLE2)) = 1u << (g & 31);
  else R(IC + (g < 32 ? IC_DISABLE1 : IC_DISABLE2)) = 1u << (g & 31);
}

void init_pics()
{
  R(IC + IC_DISABLE1) = 0xFFFFFFFF;
  R(IC + IC_DISABLE2) = 0xFFFFFFFF;
  R(IC + 0x24) = 0xFF;                      /* the basic ones too */
  R(LOCAL + LOCAL_GPU_ROUTE) = 0;           /* the GPU's: processor 0's IRQ */
  lines_on = 0;
}

/* a processor's own: its timer, its mailbox 0 (the IPIs) */
void gic_cpu_init(void)
{
  uint32_t n = cpu_id();
  R(LOCAL + LOCAL_TIMER_CTL + 4 * n) = SRC_CNTV;
  R(LOCAL + LOCAL_MBOX_CTL + 4 * n) = 1;
}

void gic_enable(uint32_t intid)
{
  if (intid == GIC_TIMER) R(LOCAL + LOCAL_TIMER_CTL + 4 * cpu_id()) = SRC_CNTV;
}

void gic_sgi(uint32_t cpu, uint32_t sgi)
{
  (void)sgi;
  __asm__ volatile ("dsb ishst" : : : "memory");
  R(LOCAL + LOCAL_MBOX_SET + 16 * cpu) = 1;
}

void enable_irq(ushort16_t irq_no)
{
  if (irq_no >= 16) return;
  lines_on |= 1u << irq_no;
  gpu_irq(lines[irq_no], 1);
}

void disable_irq(ushort16_t irq_no)
{
  if (irq_no >= 16) return;
  lines_on &= ~(1u << irq_no);
  gpu_irq(lines[irq_no], 0);
}

void enable_all_irqs()
{
  int i;
  for (i = 0; i < 16; i++) enable_irq(i);
}

void disable_all_irqs()
{
  int i;
  for (i = 0; i < 16; i++) disable_irq(i);
}

/* the interrupt to serve, as the GIC would number it (1023: none) */
uint32_t gic_ack(void)
{
  uint32_t n = cpu_id(), src = R(LOCAL + LOCAL_IRQ_SOURCE + 4 * n);
  if (src & SRC_CNTV) return GIC_TIMER;
  if (src & SRC_MBOX0) {
    R(LOCAL + LOCAL_MBOX_CLR + 16 * n) = 0xFFFFFFFF;
    return 0;
  }
  if (src & SRC_GPU) {
    uint32_t p1 = R(IC + IC_PENDING1), p2 = R(IC + IC_PENDING2), i;
    for (i = 0; i < 16; i++) {
      int g = lines[i];
      if (g < 0 || !(lines_on & (1u << i))) continue;
      if ((g < 32 ? p1 : p2) & (1u << (g & 31))) return GIC_SPI_BASE + i;
    }
  }
  return 1023;
}

void gic_eoi(uint32_t iar) { (void)iar; }

/* no PCI on a Pi 3 (QEMU virt's: pci.c) */
void arch_pci_assign(void) { }

/* processor n started at [entry] (a physical address) by the
   firmware's spin table */
void raspi_start_cpu(uint32_t n, unsigned long entry)
{
  volatile unsigned long * slot = PHYS_TO_VIRT(0xD8 + 8 * n);
  *slot = entry;
  dcache_clean_inval((void *)slot, 8);
  __asm__ volatile ("sev" : : : "memory");
}

#endif

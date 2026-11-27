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
 * The Raspberry Pis (MYNOS_RASPI, doc/decisions/aarch64.md, choice 11):
 * the Pi 3 and Zero 2 W (BCM2837, btq.7) and the Pi 4 and 400 (BCM2711,
 * btq.8), told apart at boot (raspi_detect: the peripherals' address,
 * the interrupt controller); what QEMU virt's GIC, PSCI and PL031 do
 * there.
 *
 *   - the VideoCore's mailbox (property channel 8): RAM's size, later the
 *     framebuffer. Its buffer is given by its bus address (the
 *     uncached alias, 0xC0000000 | physical), cleaned out of the caches
 *     before and dropped from them after;
 *   - the interrupts, a Pi 3's: each processor's local controller (0x40000000:
 *     its generic timer, its four mailboxes, the GPU's interrupts routed
 *     to processor 0) and the BCM2835's controller of the GPU's (the
 *     peripherals'). The kernel keeps the GIC's numbers (pic.h): the
 *     timer 27, the IPI 0 (mailbox 0), MyNOS's line n 32 + n, n the
 *     peripheral's place in lines[]; a Pi 4's: its GIC-400 (pic.c),
 *     the numbers translated the same way (lines4[]);
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
#include "video.h"
#include "process.h"
#include "mynos.h"

#define R(A)        (*(volatile uint32_t *)DEVICE(A))

/* ---- the model ----
   From the processor (MIDR's part number), as early as anything: a
   Cortex-A72 is a Pi 4 or 400 (BCM2711: the peripherals at 0xFE000000,
   in "low peripheral" mode, the firmware's default; a GIC-400), a
   Cortex-A53 a Pi 3 or Zero 2 W (BCM2837: the peripherals at
   0x3F000000; the BCM2836's local controller at 0x40000000) */
int raspi_pi4;
unsigned long raspi_peri = 0x3F000000UL;
#define PERI        raspi_peri
#define LOCAL       0x40000000UL
#define GIC4_DIST   0xFF841000UL
#define GIC4_CPU    0xFF842000UL

void gicv2_bases(unsigned long dist, unsigned long cpuif);
void gicv2_init(void);
void gicv2_cpu_init(void);
void gicv2_enable(uint32_t intid);
void gicv2_disable(uint32_t intid);
void gicv2_sgi(uint32_t cpu, uint32_t sgi);
uint32_t gicv2_ack(void);
void gicv2_eoi(uint32_t iar);

void raspi_detect(void)
{
  uint64_t midr;
  __asm__ volatile ("mrs %0, midr_el1" : "=r"(midr));
  raspi_pi4 = ((midr >> 4) & 0xFFF) == 0xD08;
  if (raspi_pi4) {
    raspi_peri = 0xFE000000UL;
    gicv2_bases(GIC4_DIST, GIC4_CPU);
  }
}

/* mapPhysical's devices (arch.h): the VideoCore's memory past the ARM's
   (its framebuffer), and the peripherals (a Pi 3's local ones too) */
extern int raspi_pcie_up;
int raspi_genet_present;                  /* the device tree says so (dtb.c) */
int raspi_wifi_present;                   /* (dtb.c) */
extern int raspi_pcie_present;

/* piDevices (106): what the firmware's device tree has, for drivers that
   share a controller or must not touch an absent device: 1 the PCIe, 2
   the GENET, 4 the Wi-Fi (on the Arasan SDHCI, which QEMU's raspi4b
   gives the SD card instead) */
long raspi_devices_call(void)
{
  return (raspi_pcie_present ? 1 : 0) | (raspi_genet_present ? 2 : 0) |
         (raspi_wifi_present ? 4 : 0);
}
int raspi_device_ok(unsigned long p, unsigned long n)
{
  unsigned long end = p + (n << 12);
  if (end < p || p < ((unsigned long)__total_phy_pages << 12)) return 0;
  /* a Pi 4's Ethernet, GENET, only if the device tree has it (QEMU's
     raspi4b has none: its driver finds out here) */
  if (p < 0xFD590000UL && end > 0xFD580000UL) return raspi_genet_present && end <= 0xFD590000UL;
  /* a Pi 4's PCIe, only once up (pcie4.c): its bridge's registers (with
     nothing behind them, QEMU's raspi4b, an access never ends), its
     window */
  if (p < 0xFD510000UL && end > 0xFD500000UL) return raspi_pcie_up && end <= 0xFD510000UL;
  if (raspi_pcie_up && p >= 0x600000000UL && end <= 0x640000000UL) return 1;
  if (end <= (raspi_pi4 ? 0x40000000UL : 0x40040000UL)) return 1;
  return raspi_pi4 && p >= 0xFC000000UL && end <= 0x100000000UL;
}

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

/* firmware (105): a property request of a driver (the io privilege), up
   to 64 words, as the mailbox takes it (its size first, then tags and
   the end tag), sent as it is and its answer copied back: the board's
   MAC address for GENET, the GPIO expander's lines for the Wi-Fi.
   0 if the firmware answered */
static volatile uint32_t user_mbox[64] __attribute__((aligned(16)));

long raspi_firmware_call(uint32_t * buf, long len)
{
  long i;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO)) return MYNOS_ERR_DENY;
  if (len < 12 || len > (long)sizeof user_mbox || (len & 3) || !__mem_userArea(buf, len))
    return MYNOS_ERR_INVALID;
  for (i = 0; i < len / 4; i++) user_mbox[i] = buf[i];
  user_mbox[0] = (uint32_t)len;
  user_mbox[1] = 0;
  if (raspi_mbox(user_mbox) != 0) return MYNOS_ERR_INVALID;
  for (i = 0; i < len / 4; i++) buf[i] = user_mbox[i];
  return 0;
}

/* the ARM's clock: the firmware starts it at its lowest (600 MHz on a
   Pi 3 or 4) and raises it only when the system asks, as Linux's cpufreq
   does: asked for its maximum (the firmware lowers it by itself when the
   chip is too hot) */
#define ARM_CLOCK 3

static uint32_t clock_tag(uint32_t tag, uint32_t rate)
{
  mbox_buf[0] = 9 * 4;
  mbox_buf[1] = 0;
  mbox_buf[2] = tag;
  mbox_buf[3] = 12;
  mbox_buf[4] = rate ? 12 : 4;
  mbox_buf[5] = ARM_CLOCK;
  mbox_buf[6] = rate;
  mbox_buf[7] = 0;                          /* (set: the turbo's settings too) */
  mbox_buf[8] = 0;
  if (raspi_mbox(mbox_buf) != 0 || !(mbox_buf[4] & 0x80000000u) || mbox_buf[5] != ARM_CLOCK)
    return 0;
  return mbox_buf[6];
}

/* the firmware's throttling (GET_THROTTLED): bit 0 under-voltage, 1 the
   ARM's clock capped, 2 throttled, 3 the soft temperature limit; bits
   16-19 the same since boot. ~0: no answer */
static uint32_t throttled(void)
{
  mbox_buf[0] = 7 * 4;
  mbox_buf[1] = 0;
  mbox_buf[2] = 0x00030046;
  mbox_buf[3] = 4;
  mbox_buf[4] = 0;
  mbox_buf[5] = 0;
  mbox_buf[6] = 0;
  if (raspi_mbox(mbox_buf) != 0 || !(mbox_buf[4] & 0x80000000u)) return ~0u;
  return mbox_buf[5];
}

static void put_mhz(uint32_t hz)
{
  print_ulong(hz / 1000000);
}

/* the clock as it is: the processor's cycles (PMCCNTR_EL0) in 10 ms of
   the generic timer, in MHz */
static uint32_t measured_mhz(void)
{
  uint64_t f, t0, t1, c0, c1, pmcr;
  __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
  if (!f) return 0;
  __asm__ volatile("mrs %0, pmcr_el0" : "=r"(pmcr));
  __asm__ volatile("msr pmcr_el0, %0" :: "r"((pmcr | 1) & ~8ul));   /* E; no divider */
  __asm__ volatile("msr pmcntenset_el0, %0" :: "r"(1ul << 31));     /* the cycle counter */
  __asm__ volatile("isb; mrs %0, cntpct_el0; mrs %1, pmccntr_el0" : "=r"(t0), "=r"(c0));
  do __asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t1)); while (t1 - t0 < f / 100);
  __asm__ volatile("mrs %0, pmccntr_el0" : "=r"(c1));
  return (uint32_t)((c1 - c0) * f / (t1 - t0) / 1000000);
}

void raspi_cpu_clock(void)
{
  uint32_t was = clock_tag(0x00030002, 0), max = clock_tag(0x00030004, 0),
           min = clock_tag(0x00030007, 0), before = measured_mhz(), set = 0, now, th;
  if (!was || !max) return;                 /* (QEMU: no such clock) */
  if (max > was) set = clock_tag(0x00038002, max);
  now = clock_tag(0x00030002, 0);
  th = throttled();
  printk("ARM clock: ");
  put_mhz(was);
  printk(" MHz (measured ");
  print_ulong(before);
  printk("), asked ");
  put_mhz(max);
  printk(": answered ");
  put_mhz(set);
  printk(", now ");
  put_mhz(now);
  printk(" (measured ");
  print_ulong(measured_mhz());
  printk(", firmware's ");
  put_mhz(clock_tag(0x00030047, 0));
  printk("); min ");
  put_mhz(min);
  if (th != ~0u && th) {
    printk(", throttled ");
    print_ulong_hex(th);
    if (th & 0x10001) printk(": under-voltage (the power supply?)");
  }
  printk("\n");
}

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
  if (!raspi_pi4) {                         /* (the BCM2711's pulls are elsewhere: */
    R(GPIO + GPPUD) = 0;                    /* the firmware's are kept) */
    delay_cycles(150);                      /* no pull-up or down */
    R(GPIO + GPPUDCLK0) = (1u << 14) | (1u << 15);
    delay_cycles(150);
    R(GPIO + GPPUDCLK0) = 0;
  }
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

/* ---- the interrupt controllers ----
   A Pi 3's: each processor's local controller and the BCM2835's for
   the GPU's. A Pi 4's: the GIC-400 (pic.c), its interrupts' numbers
   translated (the peripherals' are the GIC's 96 + the GPU's number:
   lines4[]); the IAR each processor got, kept for its end */

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
/* a Pi 4's lines: the GIC's interrupt of each, -1 none. 1 the UART
   (SPI 121), 2 the SD card's EMMC2 (SPI 126), 4 PCIe's INTA (SPI 147:
   the USB's xHCI), 5 the Ethernet's GENET (SPI 157) */
static const short lines4[16] = { -1, 153, 158, -1, 179, 189, -1, -1,
                                  -1, -1, -1, -1, -1, -1, -1, -1 };
static uint32_t last_iar[4];

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
  lines_on = 0;
  if (raspi_pi4) {
    printk("(GIC-400) ");
    gicv2_init();
    return;
  }
  printk("(BCM2836 and BCM2835) ");
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
  if (raspi_pi4) { gicv2_cpu_init(); return; }
  R(LOCAL + LOCAL_TIMER_CTL + 4 * n) = SRC_CNTV;
  R(LOCAL + LOCAL_MBOX_CTL + 4 * n) = 1;
}

void gic_enable(uint32_t intid)
{
  if (raspi_pi4) { gicv2_enable(intid); return; }
  if (intid == GIC_TIMER) R(LOCAL + LOCAL_TIMER_CTL + 4 * cpu_id()) = SRC_CNTV;
}

void gic_sgi(uint32_t cpu, uint32_t sgi)
{
  if (raspi_pi4) { gicv2_sgi(cpu, sgi); return; }
  (void)sgi;
  __asm__ volatile ("dsb ishst" : : : "memory");
  R(LOCAL + LOCAL_MBOX_SET + 16 * cpu) = 1;
}

void enable_irq(ushort16_t irq_no)
{
  if (irq_no >= 16) return;
  lines_on |= 1u << irq_no;
  if (raspi_pi4) { if (lines4[irq_no] >= 0) gicv2_enable(lines4[irq_no]); return; }
  gpu_irq(lines[irq_no], 1);
}

void disable_irq(ushort16_t irq_no)
{
  if (irq_no >= 16) return;
  lines_on &= ~(1u << irq_no);
  if (raspi_pi4) { if (lines4[irq_no] >= 0) gicv2_disable(lines4[irq_no]); return; }
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
static uint32_t gic4_ack(void)
{
  uint32_t iar = gicv2_ack(), id = iar & 0x3FF, i;
  last_iar[cpu_id()] = iar;
  if (id < 32 || id >= 1020) return id;
  for (i = 0; i < 16; i++)
    if (lines4[i] == (short)id) return GIC_SPI_BASE + i;
  gicv2_disable(id);                        /* not MyNOS's: off, ended */
  gicv2_eoi(iar);
  return 1023;
}

uint32_t gic_ack(void)
{
  uint32_t n, src;
  if (raspi_pi4) return gic4_ack();
  n = cpu_id();
  src = R(LOCAL + LOCAL_IRQ_SOURCE + 4 * n);
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

void gic_eoi(uint32_t iar)
{
  (void)iar;
  if (raspi_pi4 && (iar & 0x3FF) < 1020) gicv2_eoi(last_iar[cpu_id()]);
}

/* no PCI to assign here (QEMU virt's: pci.c); a Pi 4's PCIe, the
   USB's, is its driver's */
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

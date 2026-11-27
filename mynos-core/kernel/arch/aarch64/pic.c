/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A GICv2, in the 8259's place (pic.h): QEMU virt's, and a Raspberry
   Pi 4's (the GIC-400, at its own addresses: gicv2_bases, raspi.c,
   which also translates its interrupts' numbers). The gicv2_ functions
   drive one; on virt the names pic.h gives are theirs, on a Pi raspi.c
   chooses between this and the Pi 3's controllers. */

#include "global.h"
#include "pic.h"

static unsigned long gicd = 0x08000000UL;   /* the distributor (virt's) */
static unsigned long gicc = 0x08010000UL;   /* this processor's interface */

#define D(OFF) (*(volatile uint32_t *)DEVICE(gicd + (OFF)))
#define C(OFF) (*(volatile uint32_t *)DEVICE(gicc + (OFF)))

#define GICD_CTLR       0x000
#define GICD_ISENABLER  0x100
#define GICD_ICENABLER  0x180
#define GICD_IPRIORITYR 0x400
#define GICD_ITARGETSR  0x800
#define GICD_ICFGR      0xC00
#define GICD_SGIR       0xF00
#define GICC_CTLR       0x000
#define GICC_PMR        0x004
#define GICC_IAR        0x00C
#define GICC_EOIR       0x010

void gicv2_bases(unsigned long dist, unsigned long cpuif)
{
  gicd = dist;
  gicc = cpuif;
}

void gicv2_enable(uint32_t intid)
{
  D(GICD_ISENABLER + 4 * (intid / 32)) = 1u << (intid % 32);
}

void gicv2_disable(uint32_t intid)
{
  D(GICD_ICENABLER + 4 * (intid / 32)) = 1u << (intid % 32);
}

/* the distributor and this processor's interface on, every shared
   interrupt off, to processor 0, its priority the same for all */
void gicv2_init(void)
{
  int i;
  D(GICD_CTLR) = 0;
  for (i = 32; i < 1020; i += 32) D(GICD_ICENABLER + i / 8) = 0xFFFFFFFF;
  for (i = 0; i < 1020; i += 4) D(GICD_IPRIORITYR + i) = 0xA0A0A0A0;
  for (i = 32; i < 1020; i += 4) D(GICD_ITARGETSR + i) = 0x01010101;
  D(GICD_CTLR) = 1;
  C(GICC_PMR) = 0xF0;
  C(GICC_CTLR) = 1;
}

/* a processor's own part of the GIC (the distributor's registers of
   interrupts 0-31 are banked: each processor has its own): the software
   interrupts (0-15, the IPIs) and its timer on, their priority, its
   interface on. Processor 0 and the others (smp.c) */
void gicv2_cpu_init(void)
{
  int i;
  for (i = 0; i < 32; i += 4) D(GICD_IPRIORITYR + i) = 0xA0A0A0A0;
  D(GICD_ISENABLER) = 0xFFFFu | (1u << GIC_TIMER);
  C(GICC_PMR) = 0xF0;
  C(GICC_CTLR) = 1;
}

/* a software interrupt to one processor (its GIC interface's number:
   QEMU virt's and a Pi 4's processors are numbered as their interfaces) */
void gicv2_sgi(uint32_t cpu, uint32_t sgi)
{
  __asm__ volatile ("dsb ishst" : : : "memory");
  D(GICD_SGIR) = (1u << (16 + cpu)) | (sgi & 15);
}

uint32_t gicv2_ack(void) { return C(GICC_IAR); }
void gicv2_eoi(uint32_t iar) { C(GICC_EOIR) = iar; }

#ifndef MYNOS_RASPI   /* a Pi's: raspi.c */

void init_pics() { gicv2_init(); }
void gic_cpu_init(void) { gicv2_cpu_init(); }
void gic_enable(uint32_t intid) { gicv2_enable(intid); }
void gic_sgi(uint32_t cpu, uint32_t sgi) { gicv2_sgi(cpu, sgi); }
uint32_t gic_ack(void) { return gicv2_ack(); }
void gic_eoi(uint32_t iar) { gicv2_eoi(iar); }

void enable_irq(ushort16_t irq_no)  { gicv2_enable(GIC_SPI_BASE + irq_no); }
void disable_irq(ushort16_t irq_no) { gicv2_disable(GIC_SPI_BASE + irq_no); }

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

#endif

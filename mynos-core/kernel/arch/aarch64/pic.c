/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A GICv2 (QEMU virt's), in the 8259's place (pic.h). */

#include "global.h"
#include "pic.h"

#define GICD 0x08000000UL               /* the distributor */
#define GICC 0x08010000UL               /* this processor's interface */

#define D(OFF) (*(volatile uint32_t *)DEVICE(GICD + (OFF)))
#define C(OFF) (*(volatile uint32_t *)DEVICE(GICC + (OFF)))

#define GICD_CTLR       0x000
#define GICD_ISENABLER  0x100
#define GICD_ICENABLER  0x180
#define GICD_IPRIORITYR 0x400
#define GICD_ITARGETSR  0x800
#define GICD_ICFGR      0xC00
#define GICC_CTLR       0x000
#define GICC_PMR        0x004
#define GICC_IAR        0x00C
#define GICC_EOIR       0x010

void gic_enable(uint32_t intid)
{
  D(GICD_ISENABLER + 4 * (intid / 32)) = 1u << (intid % 32);
}

static void gic_disable(uint32_t intid)
{
  D(GICD_ICENABLER + 4 * (intid / 32)) = 1u << (intid % 32);
}

/* the distributor and this processor's interface on, every shared
   interrupt off, to processor 0, its priority the same for all */
void init_pics()
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

void enable_irq(ushort16_t irq_no)  { gic_enable(GIC_SPI_BASE + irq_no); }
void disable_irq(ushort16_t irq_no) { gic_disable(GIC_SPI_BASE + irq_no); }

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

uint32_t gic_ack(void) { return C(GICC_IAR); }
void gic_eoi(uint32_t iar) { C(GICC_EOIR) = iar; }

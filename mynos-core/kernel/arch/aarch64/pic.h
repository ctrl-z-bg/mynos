/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The interrupt controller on AArch64: a GICv2 (pic.c). The names are
   the 8259's, which generic code (irq.c) knows: MyNOS's lines 0-15 are
   the GIC's shared interrupts 32-47 (QEMU virt's PCI INTA-D are 35-38,
   lines 3-6). */

#ifndef __PIC_H__
#define __PIC_H__

#include "global.h"

#define M_PIC      0x20             /* (the 8259's: irq.c's EOI, ignored) */
#define S_PIC      0xA0
#define EOI        0x20
#define M_VEC      0x20             /* line n's vector: M_VEC + n, as on the PC */
#define S_VEC      0x28

#define GIC_SPI_BASE 32             /* line n: the GIC's interrupt 32 + n */
#define GIC_TIMER    27             /* the generic timer's virtual timer (a PPI) */

void init_pics();
void enable_irq(ushort16_t irq_num);
void disable_irq(ushort16_t irq_num);
void enable_all_irqs();
void disable_all_irqs();

/* the GIC's interrupt being served (its number), and its end */
uint32_t gic_ack(void);
void gic_eoi(uint32_t iar);
void gic_enable(uint32_t intid);

#endif

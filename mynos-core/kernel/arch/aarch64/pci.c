/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* PCI's devices on QEMU virt get their memory windows here, at boot,
   before any driver (doc/decisions/aarch64.md, choice 8): no firmware
   does it, as the PC's BIOS does. Each device's BARs get addresses of
   their own from its slot (1 MB per slot in the PCI window at
   0x10000000), its interrupt line virt's swizzle (INTA-D of slot s on
   lines 3 + (s + pin) % 4, the GIC's 35-38). Until 2026-11-26 the
   drivers did it, each for every device it looked at: consoled,
   looking for its keyboard among the virtio inputs, turned off and
   moved displayd's mouse while displayd set its queues up, on another
   processor; the mouse then wrote its events where nobody expected
   them (heaps corrupted in displayd and in its clients). */

#ifndef MYNOS_RASPI   /* a Pi 3 has no PCI: raspi.c */

#include "global.h"
#include "layout.h"

#define ECAM 0x4010000000UL                     /* bus 0 */

static volatile uint32_t * reg(int dev, int r)
{
  return (volatile uint32_t *)DEVICE(ECAM + ((paddr_t)dev << 15) + (r & 0xFFC));
}

void arch_pci_assign(void)
{
  int dev;
  for (dev = 0; dev < 32; dev++) {
    unsigned long next = 0x10000000UL + ((unsigned long)dev << 20);
    uint32_t id = *reg(dev, 0), pin;
    int bar;
    if ((id & 0xFFFF) == 0xFFFF) continue;      /* no device */
    *reg(dev, 0x04) &= ~0x7u;                   /* decoding off meanwhile */
    for (bar = 0; bar < 6; bar++) {
      int r = 0x10 + 4 * bar;
      uint32_t old = *reg(dev, r), size;
      int wide = (old & 7) == 4;                /* memory, 64 bits */
      *reg(dev, r) = 0xFFFFFFFF;
      size = *reg(dev, r);
      if ((old & 1) || (size & ~0xFu) == 0) {   /* I/O space, or none */
        *reg(dev, r) = 0;
        continue;
      }
      size = ~(size & ~0xFu) + 1;
      next = (next + size - 1) & ~((unsigned long)size - 1);
      *reg(dev, r) = (uint32_t)next | (old & 0xF);
      if (wide) *reg(dev, r + 4) = 0, bar++;
      next += size;
    }
    pin = (*reg(dev, 0x3C) >> 8) & 0xFF;
    if (pin)
      *reg(dev, 0x3C) = (*reg(dev, 0x3C) & ~0xFFu) | (3 + ((dev + pin - 1) & 3));
    *reg(dev, 0x04) |= 0x2;                     /* memory space on */
  }
}

#endif

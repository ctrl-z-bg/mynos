/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

#include "global.h"
#include "video.h"
#include "main.h"
#include "gdt.h"
#include "io.h"
#include "mem.h"
#include "pic.h"
#include "pit.h"
#include "idt.h"

#include <delay.h>

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

void mynos_main() {
  __asm__("cli");

  clear_screen();

  init_memory();

  printk("Initializing the 8259 Programmable Interrupt Controllers... ");
  init_pics();
  printk("done.\n");

  printk("Loading Interrupt Descriptor Table... ");
  init_idt();
  printk("done.\n");

  printk("Physical Memory : ");
  print_uint(_asm_global_mem_size);
  printk(" MB\n\n");

  print_uint(__memory_bitmap_size);
  printk(" bytes allocated for memory map\n\n");

  cpuSpeed();

  printk("Initializing the Intel 8253 Programmable Interval Timer... ");
  init_pit(18.3, 0);
  set_vector(pit_ISR, M_VEC, (D_INT + D_PRESENT + D_DPL3));
  printk("done\n.");

  enable_irq(1); /* irq1 (keyboard) is interrupt M_VEC+1 (33) */
  enable_irq(0);

  //  init_floppy();

  KPANIC("\nEND OF KERNEL DEMO");
}

void cpuSpeed() {
  uint32_t cpuspeed = 0;
  ulong32_t delaycount = 0;

  printk("Calibrating delay loop... [");
  delaycount = calibrateDelayLoop();
  print_ulong(delaycount);
  printk("]\n");

  cpuspeed = (uint32_t)(((float)delaycount)/500.0);

#if 0
  printk("CPU = ");
  print_ulong(cpuspeed);
  printk("\n");
#endif

}

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

#include "tss.h"
#include "process.h"

#include "kutils.h"

#include "delay.h"
#include "keyboard.h"

#include "multiboot.h"

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

extern tss_t processTable[20];
extern uint32_t numProcess;
ushort16_t * idle_tssd_selector;

void tsksw() {
  ushort16_t gdt_index;

  /* set a tss for the outcoming process */
  processTable[0].pgdir = (uint32_t**)0x100000;
  processTable[0].io_bitmap_offset = 0;
  processTable[0].ldt = 0;

  gdt_index = gdt_get_free_index();
  processTable[0].tssd_gdt_selector = (uint32_t)gdt_index << 3;

  /* set the tssd in the gdt, for the incoming and the outcoming processes */
  gdt_set_entry(gdt_index,
		LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)&(processTable[0])),
		sizeof(tss_t), D_TSS);

  /* load the task register with the relative address in the gdt of the
     current process's tssd */
  idle_tssd_selector = (ushort16_t*)((uint32_t)processTable[0].tssd_gdt_selector);
  __asm__ volatile ("ltrw (idle_tssd_selector)\n");

}

uint32_t test_start;
uint32_t test_len;

void mynos_main(multiboot_info_t *boot_info) {
  module_t * module;

  __asm__("cli");

  clear_screen();

  init_memory();

  printk("Initializing the 8259 Programmable Interrupt Controller... ");
  init_pics();
  printk("done.\n");

  printk("Loading Interrupt Descriptor Table... ");
  init_idt();
  printk("done.\n");
  
  calibratingDelayLoop();

  printk("Physical Memory : ");
  print_uint(_asm_global_mem_size);
  printk(" MB\n");

  print_uint(__memory_bitmap_size);
  printk(" bytes allocated for memory map\n");

  printk("Initializing the Intel 8253 Programmable Interval Timer... ");
  init_pit(PIT_FREQ, 0);
  set_vector(pit_ISR, M_VEC, (D_INT + D_PRESENT));
  printk("done.\n");

  /* prepare the test program information */
  module = boot_info->mods_addr;
  test_start = module->mod_start;
  test_len = module->mod_end - module->mod_start;

  tsksw();

  /* Let's create some task! :) */
  {
    uint32_t i, ntask = 3;
    for (i = 0; i < ntask; i++)
      spawnProcess(&(processTable[numProcess++]));
  }

  InitKeyboard();

  enable_irq(0);

  while(1) {
    asm("int $0x50\n");
  }

  KPANIC("\nEND OF KERNEL DEMO");
}

void calibratingDelayLoop() {
  ulong32_t delaycount = 0;

  printk("Calibrating delay loop... [");
  delaycount = calibrateDelayLoop();
  print_ulong(delaycount);
  printk("]\n");
}

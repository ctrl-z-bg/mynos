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
#include "fdc.h"
#include "keyboard.h"

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

tss_t idle_tss;
tss_t procA_tss;
char * tssd_addr = (char*)(10*8);

void tsksw() {
  /* set a tss for the outcoming process */
  idle_tss.pgdir = (uint32_t**)0x100000;
  idle_tss.io_bitmap_offset = 0;
  idle_tss.ldt = 0;

  /* set the tssd in the gdt, for the incoming and the outcoming processes */
  gdt_set_entry(10, LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)&idle_tss),
		sizeof(tss_t), D_TSS);

  /* load the task register with the relative address in the gdt of the
     current process's tssd */
  __asm__ volatile ("ltrw (tssd_addr)\n");

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

  InitKeyboard();

  init_floppy();

  {
    char * buffer = (char*)50000;
    char asd[10];
    uint32_t sector;

    printk("logical sector for test program [98]: ");
    kreadStr(asd, 10);
    sector = (asd[0]?((ulong32_t)katoi(asd)):98);
    if(read_block(sector, (unsigned char *) buffer, 1)==FALSE)
      {
	printk("Kernel Panic: FDC not responding\n");
	printk("Press any key to try again\n");
      }
  }
  

  tsksw();
  spawnProcess(&procA_tss);
  enable_irq(0);

  while(1) {
    asm("int $0x51\n");
  }

  {
    while (1)
      print_char(getch());
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

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

#include "3parts/delay.h"
#include "3parts/fdc.h"
#include "3parts/keyboard.h"

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

tss_t idle_tss;
tss_t procA_tss;
char * tssd_addr = (char*)(10*8);

void procA() {
  printk("\nSono il primo processo eseguito ufficilamente da MyNOS!!!\n");
  printk("Mi chiamo procA e sono una sorta di kernel thread (la mia page\n");
  printk("directory coincide con quella di mio padre). Il mio codice e'\n");
  printk("interamente in main.c. Dagli un'occhiata (specialmente al mio tss).\n");
  printk("Fra una sega e l'altra questo e' il nostro primo task switch! :-)\n");
 asda: goto asda;
}

void tsksw() {
  /* set a tss for the outcoming process */
  idle_tss.pgdir = (uint32_t**)0x100000;
  idle_tss.io_bitmap_offset = 0;

  /* set a tss for the incoming process! */
  procA_tss.pgdir = (uint32_t**)0x100000;
  procA_tss.io_bitmap_offset = 0;
  procA_tss.eip = (uint32_t)procA;
  procA_tss.cs = 0x8;
  procA_tss.ds = 0x18;
  procA_tss.es = 0x18;
  procA_tss.fs = 0x18;
  procA_tss.gs = 0x18;
  procA_tss.ss = 0x18;
  procA_tss.ldt = 0;
  procA_tss.eflags = 0x200;
  procA_tss.esp = procA_tss.ebp = 
    _asm_last_page_dir_entry_used*0x400000 - 4100;
  procA_tss.esp0 = procA_tss.esp;
  procA_tss.esp1 = procA_tss.esp;
  procA_tss.esp2 = procA_tss.esp;
  procA_tss.ss0 = procA_tss.ss1 = procA_tss.ss2 = 0x18;

  /* set the tssd in the gdt, for the incoming and the outcoming processes */
  gdt_set_entry(10, LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)&idle_tss),
		sizeof(tss_t), D_TSS);
  gdt_set_entry(11, LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)&procA_tss),
		sizeof(tss_t), D_TSS);

  /* load the task register with the relative address in the gdt of the
     incoming process's tssd */
  __asm__ volatile ("ltrw (tssd_addr)\n");

  /* task switching!!! :) */
  __asm__ volatile ("ljmp $88,$0\n");
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

  cpuSpeed();

  printk("Physical Memory : ");
  print_uint(_asm_global_mem_size);
  printk(" MB\n");

  print_uint(__memory_bitmap_size);
  printk(" bytes allocated for memory map\n");

  printk("Initializing the Intel 8253 Programmable Interval Timer... ");
  init_pit(18.3, 0);
  set_vector(pit_ISR, M_VEC, (D_INT + D_PRESENT + D_DPL3));
  printk("done.\n");

  InitKeyboard();
  //  enable_irq(1); /* irq1 (keyboard) is interrupt M_VEC+1 (33) */
  enable_irq(0);

  init_floppy();

  {
    char buffer[512];
	if(read_block(0, (unsigned char *) buffer, 1)==FALSE)
	{
		printk("Kernel Panic: FDC not responding\n");
		printk("Press any key to try again\n");
	} else {
	  printk("\nLetto dal bootsector : ");
	  buffer[11] = '\0';
	  printk(buffer+3);
	  printk("\n");
	}
  }

  tsksw();

  {
    while (1)
      print_char(getch());
  }

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

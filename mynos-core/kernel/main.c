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

#ifdef TRY_VGA
#include "vga.h"
#endif

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
  processTable[0].isAlive = 1;
  processTable[0].isForking = 0;

  // IPC
  processTable[0].isWaitingSender = -1;
  processTable[0].isWaitingReceiver = -1;

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

#ifdef RAMDISK
void * ramdisk;
uint32_t ramdisk_len;
uint32_t ramdisk_present = 0;
#endif

modinfo_t bytecode;

void mynos_main(multiboot_info_t *boot_info) {
  module_t * module;
  modinfo_t modinfo[MAXMODULES];
  int i;

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

  /* prepare the modules informations */
  module = (module_t *)boot_info->mods_addr;
  for (i = 0; i < boot_info->mods_count; i++) {
    //module = (module_t*)((uint32_t*)(boot_info->mods_addr) + i);
    modinfo[i].start = (uint32_t*)module[i].mod_start;
    modinfo[i].len = module[i].mod_end - module[i].mod_start;
#ifdef RAMDISK
    if (!kmemcmp((uint32_t*)modinfo[i].start, ".RAMDISK", 8)) {
      ramdisk = (void *)modinfo[i].start;
      ramdisk_len = modinfo[i].len;
      printk("RAMDISK found (module ");
      print_uint(i);
      printk(")\n");
      ramdisk_present = 1;
    }
#endif
  }

#ifdef RAMDISK
  if (!ramdisk_present)
    printk("No RAMDISK found\n");
#endif

  /* prepare the test program information */
  //test_start = modinfo[0].start;
  //test_len = modinfo[0].len;
  bytecode.start = modinfo[1].start;
  bytecode.len = modinfo[1].len;


#ifdef TRY_VGA
  init_graph_vga(320, 200, 1);
#endif
#if 0
  {
    int y;
    for (y = 0; y < 200; y++)
      vga_draw_line(0, y, 319, y, 0);
  }

  vga_draw_rect(0,0,319,199, 15);
  vga_draw_rect(50, 20, 80, 50, 15);
  vga_draw_rect(100, 20, 130, 50, 15);
  vga_draw_line(90, 50, 90, 150, 15);
  vga_draw_line(60, 170, 120, 170, 15);
  vga_draw_line(50, 160, 60, 170, 15);
  vga_draw_line(120, 170, 130, 160, 15);
#endif

  {
    int i;
    
    for (i = 0; i < MAXPROCESSES; i++)
      processTable[i].isAlive = 0;
  }
  

  /* to try the releasePages */
#if 0
  printk("free pages: ");
  print_uint(__number_of_free_physical_pages);
  print_char('\n');
  {
    uint32_t * pun;
    pun = __OS_askPagesFrom((void*)0x1000000,1,0,0);
    *pun = 5;
    printk("free pages: ");
    print_uint(__number_of_free_physical_pages);
    print_char('\n');
    print_uint_hex(pun);
    print_char('\n');
    print_uint(*pun);
    print_char('\n');
    __OS_releasePages((void*)0x1000000, 1, 1, 0);
    printk("free pages: ");
    print_uint(__number_of_free_physical_pages);
    print_char('\n');
    *pun = 5;
    print_char('\n');
    print_uint_hex(pun);
    print_char('\n');
    print_uint(*pun);
    while(1);
  }
#endif

  tsksw();

  /* start the elf modules */
  {
    uint32_t i;
    for (i = 0; i < boot_info->mods_count; i++) {
      //module = (module_t*)((uint32_t*)(boot_info->mods_addr) + i);
      modinfo[i].start = (uint32_t*)module[i].mod_start;
      modinfo[i].len = module[i].mod_end - module[i].mod_start;
      if ((*((char*)modinfo[i].start) == 0x7F) &&
	  !kmemcmp((char*)modinfo[i].start + 1, "ELF", 3)) {
	if(!spawnProcess(&(processTable[numProcess++]), 
			 modinfo[i].start,
			 modinfo[i].len)) {
	  KPANIC("FULL MEMORY");
	} else {
	  processTable[numProcess - 1].pid = numProcess - 1;
	  processTable[numProcess - 1].ppid = 0;
	}
      }
    }
  }

  InitKeyboard();

  printk("\n-----------------------\n");

  enable_irq(0);

#ifdef RAMDISK
  if (ramdisk_present) {
    uint32_t ramdisk = 0x40400000;
    __OS_ipc_send(1, (char*)&ramdisk, sizeof(uint32_t), 1);
  }
#endif

  // this is the idle process
  while(1) {
    char a = getch();
    print_char(a);
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

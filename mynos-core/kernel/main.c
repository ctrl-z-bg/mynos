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

#include "dynalloc.h"

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

void TryPageAlloc() {
  /* esempio di allocazione: questo funziona... */
  if (__OS_askPagesFrom((void*)(0x200000), 3000) == NULL)
    printk("PROBLEMA DI ALLOCAZIONE!\n\n");
  else {
    printk("Allocate 3000 pagine\n");
    __print_free_phy_pages();
  }

  /* ...questo no perche' non ci sono abbastanza pagine fisiche libere... */
  if (__OS_askPagesFrom((void*)(0x110000), 5000) == NULL)
    printk("PROBLEMA DI ALLOCAZIONE!\n\n");
  else {
    printk("Allocate 5000 pagine\n");
    __print_free_phy_pages();
  }

  /* ...questo funziona... */
  if (__OS_askPagesFrom((void*)(0x110000), 3) == NULL)
    printk("PROBLEMA DI ALLOCAZIONE!\n\n");
  else {
    printk("Allocate 3 pagine\n");
    __print_free_phy_pages();
  }

  /* ...questo non funziona perche' trova pagine gia' allocate! */
  if (__OS_askPagesFrom((void*)(0x10F000), 2) == NULL)
    printk("PROBLEMA DI ALLOCAZIONE!\n\n");
  else {
    printk("Allocate 2 pagine\n");
  __print_free_phy_pages();
  }
}

void mynos_main() {
  int * tmp = (int*)__GET_PAGE_DIR_ENTRY(_asm_last_page_dir_entry_used); 

  __asm__("cli");

  init_memory();

  clear_screen();

  init_pics();
  init_idt();
  init_pit(18.3, 0);
  set_vector(pit_ISR, M_VEC, (D_INT + D_PRESENT + D_DPL3));

  printk("paging enabled!!!\n\n");

  printk("hai ");
  print_uint(_asm_global_mem_size);
  printk(" MB di memoria fisica\n\n");

  printk("quindi hai ");
  print_uint(_asm_global_mem_size*256);
  printk(" pagine di memoria fisica\n\n");

  __print_free_phy_pages();

  printk("la prima non allocata e' la ");
  print_uint_hex(__pg_find_a_free_physical_page());
  printk("\n\n");

  printk("quindi occorrono ");
  print_uint(__memory_bitmap_size);
  printk(" bytes per la memory map\n\n");

  printk("i primi ");
  print_uint((_asm_last_page_dir_entry_used+1)*4);
  printk(" MB di memoria lineare sara' condiviso da tutti i processi\n\n");

  printk("l'ultima page table e' mappata sulla pagina fisica ");
  print_uint(((*tmp)>>12)<<12);
  printk(" (");
  print_uint_hex(((*tmp)>>12)<<12);
  printk(")\n\n\n");

  // TryPageAlloc();

  {
    int * a;
    a = (int*)kmalloc(8192*8);
    a = (int*)kmalloc(8192*8);
    *a = 123;
    printk("--");
    print_ulong((ulong32_t)a);
    printk("--");
    print_ulong((ulong32_t)*a);
    printk("--\n");
  }


  enable_irq(1); /* irq1 (keyboard) is interrupt M_VEC+1 (33) */
  enable_irq(0);

  KPANIC("\nEND OF KERNEL DEMO");
}

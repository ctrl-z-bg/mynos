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
#include "gdt.h"
#include "mem.h"
#include "video.h"
#include "kutils.h"
#include "dynalloc.h"

#define INITIAL_SEGMENTS 4

#define GDT_SIZE 8192*8

union DT_entry * gdt_addr;

desc_table(GDT, INITIAL_SEGMENTS) { //8192) {
  /* dummy descriptor (not used by processor) */
  {dummy:0},
  /* kernel code segment */
    stnd_desc(0, 0xFFFFF, (D_CODE + D_BIG + D_BIG_LIM)),
    /* user code segment */
    stnd_desc(0, 0xFFFFF, (D_CODE + D_READ + D_BIG + D_BIG_LIM)),// + D_DPL3)),
  /* data segment */
    stnd_desc(0, 0xFFFFF, (D_DATA + D_WRITE + D_BIG + D_BIG_LIM)),// + D_DPL3)),
};

struct loadgdt_st
{
	unsigned short limit __attribute__ ((packed));
	union DT_entry *idt __attribute__ ((packed));
} loadgdt = { (INITIAL_SEGMENTS * sizeof(union DT_entry) - 1), GDT };

void _init_gdt() {
  /* alloc a full GDT */
  gdt_addr = (union DT_entry *)__OS_askPages(GDT_SIZE / PAGE_SIZE);
  printk("Alloc ");
  print_ulong(GDT_SIZE);
  printk(" bytes (");
  print_ulong(GDT_SIZE / PAGE_SIZE);
  printk(" pages) for the GDT, starting from linear page ");
  print_ulong_hex((uint32_t)gdt_addr);
  print_char('\n');

  /* let's zero it */
  kbzero((void *)gdt_addr, GDT_SIZE);

  /* copy the temporary GDT to our new one */
  kmemcpy((void*)gdt_addr, (const void*)loadgdt.idt, loadgdt.limit + 1);

  /* set out true gdt */
  loadgdt.idt = gdt_addr;
  loadgdt.limit = (8192 * sizeof(union DT_entry) - 1); /* a full GDT! */
  __asm__ volatile ("lgdtl (loadgdt)\n");
}

void gdt_set_entry(int entry, uint32_t base, uint32_t limit, 
		   ushort16_t control) {
  SEG_createStandardDescriptor((uint32_t *) (gdt_addr+entry),
			       base, limit, control);
}

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

#include "gdt.h"

desc_table(GDT, 5) { //8192) {
  /* dummy descriptor (not used by processor) */
  {dummy:0},
  /* kernel code segment */
  stnd_desc(0, 0xFFFFF, (D_CODE + D_BIG + D_BIG_LIM)),
  /* user code segment */
  stnd_desc(0, 0xFFFFF, (D_CODE + D_READ + D_BIG + D_BIG_LIM + D_DPL3)),
  /* data segment */
  stnd_desc(0, 0xFFFFF, (D_DATA + D_WRITE + D_BIG + D_BIG_LIM + D_DPL3)),
};

struct
{
	unsigned short limit __attribute__ ((packed));
	union DT_entry *idt __attribute__ ((packed));
} loadgdt = { (3 * sizeof(union DT_entry) - 1), GDT };

void _init_gdt() {
  __asm__ volatile ("lgdtl (loadgdt)\n");
}


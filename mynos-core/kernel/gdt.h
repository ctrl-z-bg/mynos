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

#ifndef __GDT_H__
#define __GDT_H__

#include "macro_gdt.h"

#define GDT_OS_CODE_SEL   0x08
#define GDT_USER_CODE_SEL 0x10
#define GDT_DATA_SEL      0x18

void _init_gdt();

void gdt_set_entry(int entry, uint32_t base, uint32_t limit, 
		   ushort16_t control);

#endif

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

#include "mem.h"
#include "dynalloc.h"
#include "kutils.h"
#include "physicalmem.h"

pmemdes_t pmemdes;

void createPhyMemManager() {
  /* allocate space for the new bitmap location */
  pmemdes.bitmap = kmalloc(__memory_bitmap_size);
  pmemdes.page   = kmalloc(__total_phy_pages *
			   sizeof(ppagedes_t));
  kmemcpy(pmemdes.bitmap, __memory_bitmap, __memory_bitmap_size);

  print_ulong(__total_phy_pages *
	      sizeof(ppagedes_t));
  __memory_bitmap = pmemdes.bitmap;
}


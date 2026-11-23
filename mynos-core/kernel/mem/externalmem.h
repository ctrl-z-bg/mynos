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

#ifndef __EXTERNALMEM_H__
#define __EXTERNALMEM_H__

#include "global.h"

/* map npages of the current process to process pid 
   it returns the first linear page allocated for pid
*/
int32_t __OS_mapPagesTo(pid_t pid, uint32_t lpage,
			uint32_t npages, uint32_t mode);

/* map the physical page phyPage at a kernel window and return its address,
   to read structures of another process (its page directory, its page
   tables). *saved receives the window's previous mapping, to give back to
   __mem_unmapFrame. One window: one frame at a time. */
uint32_t * __mem_mapFrame(uint32_t phyPage, uint32_t * saved);
/* another process's page table entry: read (NULL: no page table) or
   written (the page table made if needed); one window, as above */
uint32_t * __mem_externalPTE(pid_t pid, uint32_t laddr);
void __mem_setExternalPTE(pid_t pid, uint32_t laddr, uint32_t entry);
void __mem_unmapFrame(uint32_t saved);

#endif

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

#ifndef __PHYSICALMEM_H__
#define __PHYSICALMEM_H__

#include "global.h"

/* FLAGS for physical pages */
#define PMEM_SWAPABLE    0x1
#define PMEM_COPYONWRITE 0x2

/* Physical Page Descriptor Type */
typedef struct {
  ushort16_t flags;
  ushort16_t countref;
} ppagedes_t;

typedef struct {
  void       * bitmap;
  ppagedes_t * page;
} pmemdes_t;

extern pmemdes_t pmemdes;

/* this function creates a physical memory manager. See .c for commments */
void pmem_createPhyMemManager();

uint32_t pmem_findAFreePhysicalPage();

/* allocates page. if allocated then increments the countref*/
void pmem_set(uint32_t page);

/* it decrements the countref, if zero, deallocates page */
void pmem_unset(uint32_t page);

#endif

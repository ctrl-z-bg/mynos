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

#ifndef __LMEMTRACK_H__
#define __LMEMTRACK_H__

#include "global.h"

typedef struct _pdListEl {
  uint32_t bgn, end; /* boundaries *included* */
  struct _pdListEl *next, *prev;
} pdListEl;

//extern pdListEl *pdListBgn;

uint32_t __lmt_allocArea(pdListEl **pdListBgn, uint32_t nPages);
uint32_t __lmt_freeArea(pdListEl **pdListBgn, uint32_t fromPage, 
			uint32_t nPages);
uint32_t __lmt_forceAllocation(pdListEl **pdListBgn, uint32_t fromPage, 
			       uint32_t npages);
pdListEl *__lmt_copyList(pdListEl *pdListBgn);

#endif

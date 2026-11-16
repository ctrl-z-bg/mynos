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

#ifndef __THREADS_H__
#define __THREADS_H__

#include "global.h"

/* on success it returns the ID of the new thread */
int32_t __OS_threadCreate(uint32_t entry_point, 
			   uint32_t stack,
			   uint32_t flags);

void __OS_threadExit(void * retval);

#include "tss.h"
/* a new thread of the current process, copy of the current one; then
   threadStart makes it run (see threads.c) */
tss_t * threadAlloc(void);
void threadStart(tss_t * tss);
uint32_t __OS_threadSelf();

#endif

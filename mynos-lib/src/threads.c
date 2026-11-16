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

#include "../include/mynos.h"
#include "syscall.h"

int mynos_threadCreate(void * (*start_routine)(void *), 
		       void * arg, void * stack, unsigned int flags) {
  int ret;
  /* set the argument for the thread function */
  stack -= sizeof(void*);
  *(unsigned int *)(stack) = (unsigned int)arg;
  /* set the return address */
  stack -= sizeof(void*);
  *(unsigned int *)(stack) = (unsigned int)mynos_threadExit;
  ret = __mynos_syscall(200, (int)start_routine, (int)stack, (int)flags, 0, 0);
  return ret;
}

void mynos_threadExit(void * retval) {
  __mynos_syscall(201, (int)retval, 0, 0, 0, 0);
}

int mynos_threadSelf() {
  int ret;
  ret = __mynos_syscall(202, 0, 0, 0, 0, 0);
  return ret;
}

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

int mynos_enableIrq(unsigned short n) {
  int ret;
  ret = __mynos_syscall(100, (int)n, 0, 0, 0, 0);
  return ret;    
}

int mynos_disableIrq(unsigned short n){
  int ret;
  ret = __mynos_syscall(101, (int)n, 0, 0, 0, 0);
  return ret;    
}

int mynos_driverRegister(char * name, unsigned int irq, 
			 unsigned int * io, unsigned int * mem) {
  int ret;
  ret = __mynos_syscall(10, (int)name, (int)irq, (int)io, (int)mem, 0);
  return ret;
}


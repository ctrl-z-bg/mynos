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

#include "tss.h"
#include "mem.h"
#include "kutils.h"
#include "process.h"
#include "sem.h"

void sched() {
  struct {long a ,b;} tmp = {0, 0};
  uint32_t oldProcess = currProcess;

  do {
    currProcess = (currProcess + 1) % numProcess;
  }
  while ((!processTable[currProcess].isAlive) ||
	 (processTable[currProcess].isWaitingOnP != -1) );
  tmp.b = (long)processTable[currProcess].tssd_gdt_selector;


  if (currProcess != oldProcess)
    __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
}

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

int __OS_sem_initSemaphores();
int __OS_sem_allocateSemaphore(uint32_t n);
int __OS_sem_freeSemaphore(int semid);
int __OS_sem_P(int semid);
int __OS_sem_tryP(int semid);
int __OS_sem_V(int semid);

#define privP()    __OS_sem_P(processTable[currProcess].privSem)
#define privV(p)   __OS_sem_V(processTable[p].privSem)

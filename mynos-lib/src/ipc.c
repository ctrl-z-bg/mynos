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

int mynos_send(int dest, char * buf, unsigned int size,
	       unsigned int flags) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $3, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(dest));
  __asm__ volatile("movl %0, %%ecx\n"::"m"(buf));
  __asm__ volatile("movl %0, %%edx\n"::"m"(size));
  __asm__ volatile("movl %0, %%esi\n"::"m"(flags));
  __asm__ volatile("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;
}

int mynos_recv(int dest, char * buf, unsigned int maxsize,
	       unsigned int flags) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $4, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(dest));
  __asm__ volatile("movl %0, %%ecx\n"::"m"(buf));
  __asm__ volatile("movl %0, %%edx\n"::"m"(maxsize));
  __asm__ volatile("movl %0, %%esi\n"::"m"(flags));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;
}

int mynos_recvAll(int * dest, char * buf, unsigned int maxsize,
		  unsigned int flags) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $5, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(dest));
  __asm__ volatile("movl %0, %%ecx\n"::"m"(buf));
  __asm__ volatile("movl %0, %%edx\n"::"m"(maxsize));
  __asm__ volatile("movl %0, %%esi\n"::"m"(flags));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;
}

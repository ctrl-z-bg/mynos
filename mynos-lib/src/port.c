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

#include <unistd.h>

int mynos_allocPort() {
  int ret;
  pid_t pid = getpid();
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $20, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(pid));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;    
}

int mynos_allocPortP(int port) {
  int ret;
  pid_t pid = getpid();
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $21, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(port));
  __asm__ volatile("movl %0, %%ecx\n"::"m"(pid));
  __asm__ volatile("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;
}

int mynos_connectToPort(int port) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $22, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(port));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;    
}

int mynos_listenPort(int port) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $23, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(port));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;    
}

int mynos_freePort(int port) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $24, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(port));
  __asm__ volatile ("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;    
}

int mynos_changePortOwner(int port, int newpid) {
  int ret;
  __asm__ volatile("pushal\n");
  __asm__ volatile("movl $25, %eax\n");
  __asm__ volatile("movl %0, %%ebx\n"::"m"(port));
  __asm__ volatile("movl %0, %%ecx\n"::"m"(newpid));
  __asm__ volatile("int $0x90\n");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  __asm__ volatile("popal\n");
  return ret;
}


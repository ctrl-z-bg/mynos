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

#ifdef __aarch64__
#include "syscall.h"
/* no I/O ports on ARM: the kernel answers the few its machine has (102:
   COM2, the UART), the rest read 0xFF (the PC's drivers find nothing) */
void outportb(unsigned short port, unsigned char value)
{
  __mynos_syscall(102, 1, port, value, 0, 0);
}
unsigned char inportb(unsigned short port)
{
  return (unsigned char)__mynos_syscall(102, 0, port, 0, 0, 0);
}
#else
void outportb(unsigned short port,unsigned char value)
{
   __asm__ volatile ("outb %%al,%%dx"::"d" (port), "a" (value));
}

unsigned char inportb(unsigned short port)
{
   unsigned char ret;

   __asm__ volatile ("inb %%dx,%%al":"=a" (ret):"d" (port));
   return ret;
}
#endif


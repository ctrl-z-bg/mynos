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

int mynos_setTimer(unsigned long usec) {
  int ret;
  __asm__ volatile("movl $300, %eax");
  __asm__ volatile("movl %0, %%ebx"::"m"(usec));
  __asm__ volatile("int $0x90");
  __asm__ volatile("movl %%eax, %0":"=m"(ret):);
  return ret;
}

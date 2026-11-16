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

#ifndef __MYNOS_SYSCALL_H__
#define __MYNOS_SYSCALL_H__

/*
 * Native MyNOS system call (int $0x90): number in eax, arguments in
 * ebx, ecx, edx, esi, edi, result in eax.
 *
 * A single asm statement with explicit constraints: the compiler knows
 * which registers are inputs and that the kernel may change them and
 * memory. The original wrappers loaded each register in a separate asm
 * statement between pushal/popal, which only worked by luck and broke
 * with modern gcc (position-independent code keeps the GOT in ebx).
 */
static inline int __mynos_syscall(int n, int b, int c, int d, int S, int D)
{
  int ret = n;
  __asm__ volatile ("int $0x90"
                    : "+a"(ret), "+b"(b), "+c"(c), "+d"(d), "+S"(S), "+D"(D)
                    :
                    : "memory");
  return ret;
}

#endif

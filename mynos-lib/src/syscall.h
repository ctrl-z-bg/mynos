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
#ifdef __x86_64__
/* x86-64 (doc/decisions/x86-64.md): the number in rax, the arguments in
   rdi, rsi, rdx, r10, r8 (Linux's order), the result in rax; the kernel
   may change rcx and r11 */
static inline long __mynos_syscall(long n, long b, long c, long d, long S, long D)
{
  register long r10 __asm__("r10") = S;
  register long r8 __asm__("r8") = D;
  long ret = n;
  __asm__ volatile ("int $0x90"
                    : "+a"(ret), "+D"(b), "+S"(c), "+d"(d), "+r"(r10), "+r"(r8)
                    :
                    : "rcx", "r11", "r9", "memory");
  return ret;
}
#elif defined(__aarch64__)
/* AArch64 (doc/decisions/aarch64.md): svc #0x90, the number in x8, the
   arguments in x0-x4, the result in x0 */
static inline long __mynos_syscall(long n, long b, long c, long d, long S, long D)
{
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = b;
  register long x1 __asm__("x1") = c;
  register long x2 __asm__("x2") = d;
  register long x3 __asm__("x3") = S;
  register long x4 __asm__("x4") = D;
  __asm__ volatile ("svc #0x90"
                    : "+r"(x0)
                    : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
                    : "memory");
  return x0;
}
#else
static inline long __mynos_syscall(long n, long b, long c, long d, long S, long D)
{
  long ret = n;
  __asm__ volatile ("int $0x90"
                    : "+a"(ret), "+b"(b), "+c"(c), "+d"(d), "+S"(S), "+D"(D)
                    :
                    : "memory");
  return ret;
}
#endif

#endif

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

/* set once a native thread exists: malloc takes its lock from then on
   (safe_alloc.c); musl locks by itself only after a pthread_create */
int __mynos_native_threads;

#ifdef __x86_64__
/* x86-64: the thread starts here, with the routine and its argument on
   its stack (the argument goes in rdi), and ends with the routine's
   result */
void __mynos_thread_start(void);
__asm__ (".text\n"
         "__mynos_thread_start:\n"
         "  popq %rax\n"
         "  popq %rdi\n"
         "  andq $-16, %rsp\n"
         "  call *%rax\n"
         "  movq %rax, %rdi\n"
         "  call mynos_threadExit\n"
         "  hlt\n");

int mynos_threadCreate(void * (*start_routine)(void *),
		       void * arg, void * stack, unsigned int flags) {
  void ** sp = (void **)((unsigned long)stack & ~15UL);
  __mynos_native_threads = 1;
  *--sp = arg;
  *--sp = (void *)start_routine;
  return __mynos_syscall(200, (long)__mynos_thread_start, (long)sp, (long)flags, 0, 0);
}
#elif defined(__aarch64__)
/* AArch64: the routine and its argument on the thread's stack, as on
   x86-64 */
void __mynos_thread_start(void);
/* (a global symbol: gcc takes the address of a function through the GOT,
   and a GOT relocation against a local label loses its offset: the
   pointer was the section's start, __mynos_syscall) */
__asm__ (".text\n"
         ".global __mynos_thread_start\n"
         ".type __mynos_thread_start, %function\n"
         "__mynos_thread_start:\n"
         "  ldp x9, x0, [sp], #16\n"
         "  blr x9\n"
         "  bl mynos_threadExit\n"
         "1: b 1b\n");

int mynos_threadCreate(void * (*start_routine)(void *),
		       void * arg, void * stack, unsigned int flags) {
  void ** sp = (void **)((unsigned long)stack & ~15UL);
  __mynos_native_threads = 1;
  *--sp = arg;
  *--sp = (void *)start_routine;
  return __mynos_syscall(200, (long)__mynos_thread_start, (long)sp, (long)flags, 0, 0);
}
#else
int mynos_threadCreate(void * (*start_routine)(void *), 
		       void * arg, void * stack, unsigned int flags) {
  int ret;
  __mynos_native_threads = 1;
  /* set the argument for the thread function */
  stack -= sizeof(void*);
  *(unsigned int *)(stack) = (unsigned int)arg;
  /* set the return address */
  stack -= sizeof(void*);
  *(unsigned int *)(stack) = (unsigned int)mynos_threadExit;
  ret = __mynos_syscall(200, (long)start_routine, (long)stack, (long)flags, 0, 0);
  return ret;
}
#endif

void mynos_threadExit(void * retval) {
  __mynos_syscall(201, (long)retval, 0, 0, 0, 0);
}

int mynos_threadSelf() {
  int ret;
  ret = __mynos_syscall(202, 0, 0, 0, 0, 0);
  return ret;
}

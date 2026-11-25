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

/* malloc, free and realloc under a lock, for processes with native
   threads (mynos_threadCreate). musl's allocator takes its own lock once
   a thread exists, but it learns of threads from pthread_create only.
   Until a native thread is made, the calls go straight to musl: the lock
   is a kernel semaphore, two system calls a call, which made malloc 19
   times slower for every program (mynos-a0w). */

#include <mynos.h>
#include <stdlib.h>

extern void __libc_free(void *ptr);
extern void *__libc_malloc(size_t size);
extern void* __libc_realloc(void* ptr, size_t size);
extern int __mynos_native_threads;

static int __testnset(int *m) {
  int result;
  
  __asm__ volatile ("lock bts $1, %1; sbbl %0, %0"
		    :"=r" (result):"m" (*m):"memory");
  return(result);
}

static inline void __lock(int *m) {
    while (__testnset(m));
}


static inline void __unlock(int *m) {
    __asm__ volatile("lock btr $1, %0\n"::"m" (*m):"memory");
}

static int mutex = 0;

static int sem = -1;

// init the memory semaphre for threadsafe access to memory
static void initMem() {
  __lock(&mutex);
  if (sem < 0)
    sem = mynos_initSem(1);
  __unlock(&mutex);
}

void free(void *ptr) {
  if (!__mynos_native_threads) { __libc_free(ptr); return; }
  initMem();
  mynos_P(sem);
  __libc_free(ptr);
  mynos_V(sem);
}

void *malloc(size_t size) {
  register void *ret;
  if (!__mynos_native_threads) return __libc_malloc(size);
  initMem();
  mynos_P(sem);
  ret=__libc_malloc(size);
  mynos_V(sem);
  return ret;
}

void* realloc(void* ptr, size_t size) {
  register void *ret;
  if (!__mynos_native_threads) return __libc_realloc(ptr, size);
  initMem();
  mynos_P(sem);
  ret=__libc_realloc(ptr, size);
  mynos_V(sem);
  return ret;
}

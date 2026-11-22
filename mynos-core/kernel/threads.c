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

#include "threads.h"
#include "process.h"
#include "mem/dynalloc.h"
#include "kutils.h"
#include "mem/mem.h"
#include "sem.h"
#include "gdt.h"
#include "sched.h"
#include "video.h"
#include "mynos.h"

/* thread ids for threads other than a process's first one (whose tid is
   its pid): above the pids (below 10^9), so that the two never meet, and
   below 2^30: the C library keeps a mutex's owner as tid & 0x3fffffff,
   the bits above being flags (FUTEX_OWNER_DIED...) */
#define FIRST_TID 1000000000
#define LAST_TID  0x3fffffff
static int32_t nextTid = FIRST_TID;

/*
 * A new thread of the current process, as a copy of the current thread:
 * a tss and a kernel stack, those of a thread that exited if any (they are
 * freed with the process). The caller sets the registers and the stack,
 * then calls threadStart.
 */
tss_t * threadAlloc(void) {
  process_descriptor_t * self = processTable[currProcess];
  tss_t ** pt = &(self->deadThreads);
  tss_t * tss;
  uint32_t kstack;

  while (*pt && !(*pt)->kstack)   /* the first thread's stack is elsewhere */
    pt = (tss_t **)&((*pt)->next);
  if (*pt) {
    tss = *pt;
    *pt = tss->next;
    kstack = tss->kstack;
  } else {
    if ((tss = (tss_t*)kmalloc(sizeof(tss_t))) == NULL) return NULL;
    /* a kernel stack in user space but with superuser rights */
    kstack = (uint32_t)__OS_askPages(KERNEL_STACK_NPAGES, 1,
				     PF_SUPERVISOR_IN_USER_SPACE);
    if (!kstack) { kfree(tss); return NULL; }
  }

  kmemcpy(tss, currThread, sizeof(tss_t));
  tss->fpu_valid = 0;            /* a new thread: a clean FPU */
  tss->pid = CURRPID;
  tss->kstack = kstack;
  tss->tid = nextTid++;
  if (nextTid > LAST_TID) nextTid = FIRST_TID;
  tss->clearTid = NULL;
  tss->queue = NULL;
  tss->timeToWake = 0;
  tss->justForked = 0;
  return tss;
}

/* link a thread made by threadAlloc into the process and make it ready */
void threadStart(tss_t * tss) {
  tss_t * next = currThread->next;

  tss->prev = currThread;
  currThread->next = tss;
  tss->next = next;
  if (next) next->prev = tss;

  processTable[currProcess]->numThreads++;
  processTable[currProcess]->lastThread++;
  tss->threadID = processTable[currProcess]->lastThread;
  numThreads++;

  /* the new thread's private semaphore */
  tss->privSem = __OS_sem_allocateSemaphore(0);
  tss->semHeld = 0;

  readyQueueInsert(tss);
}

int32_t __OS_threadCreate(uint32_t entry_point, 
			   uint32_t stack,
			   uint32_t flags) {
  tss_t * tss;

  /* TODO: check the parameters */
  if ((tss = threadAlloc()) == NULL) return MYNOS_ERR_FULL;

  tss->eip = entry_point;
  tss->esp = stack;
  tss->eflags = INITIAL_EFLAGS |
    ((processTable[currProcess]->privileges & MYNOS_PRIV_IO) ? IOPL3 : 0);
  tss->esp0 = tss->kstack + KERNEL_STACK_NPAGES * PAGE_SIZE - 1;

  /* initialize the kernel stack for the new thread */
  initStack(tss->esp0, tss);

  threadStart(tss);
  return tss->threadID;
}

extern void _linux_syscall_exit(int32_t status);
void __OS_threadExit(void * retval) {
  char hasPrev, hasNext;
  tss_t * prev, * next;

  readyQueueExtractThread(currThread);
  timerQueueExtractThread(currThread);

#ifdef DEBUG_THREADS
  printk("Thread ");
  print_ulong(currThread->threadID);
  printk(" (process  ");
  print_ulong(currProcess);
  printk(") exited\n");
#endif

  prev = currThread->prev;
  next = currThread->next;
  hasPrev = (prev != NULL);
  hasNext = (next != NULL);

  if (!hasPrev && !hasNext)           /* the last thread: the process ends */
    _linux_syscall_exit((int)retval);

  processTable[currProcess]->numThreads--;
  numThreads--;

  /* keep the tss and kernel stack for the next thread (it is safe: this
     thread runs no more once sched switches away, and only then can
     another thread of the process create one) */
  __OS_sem_freeSemaphore(currThread->privSem);
  currThread->next = processTable[currProcess]->deadThreads;
  processTable[currProcess]->deadThreads = currThread;

  /* enqueue outgoing thread */
  if (hasNext && hasPrev) {
    prev->next = next;
    next->prev = prev;
    sched();
  } else if (hasPrev && !hasNext) {   /* this is the last thread in queue */
    prev->next = NULL;
    sched();
  } else if (!hasPrev && hasNext) {   /* this is the first thread in queue */
    next->prev = NULL;
    processTable[currProcess]->tss = next;
    sched();
  } else                              /* this is the last thread, we exit! */
    _linux_syscall_exit((int)retval);
}

uint32_t __OS_threadSelf() {
  return currThread->threadID;
}


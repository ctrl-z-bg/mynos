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

int32_t __OS_threadCreate(uint32_t entry_point, 
			   uint32_t stack,
			   uint32_t flags) {
  tss_t * tss;
  tss_t * next = currThread->next;

  /* TODO: check the parameters */

  /* create a new thread descriptor */
  tss = (tss_t*)kmalloc(sizeof(tss_t));

  tss->pid = currProcess;

  /* copy the current thread's descriptor to the new one */
  kmemcpy(tss, currThread, sizeof(tss_t));

  /* fill some entry... */
  tss->eip = entry_point;
  tss->esp = stack;
  tss->eflags = INITIAL_EFLAGS;

  /* create a new kernel stack in user space but with superuser rights */
  tss->esp0 = ((uint32_t)__OS_askPages(KERNEL_STACK_NPAGES, 
				       1, 
				       PF_SUPERVISOR_IN_USER_SPACE)) +
    KERNEL_STACK_NPAGES * PAGE_SIZE - 1;

  /* initialize the kernel stack for the new thread */
  initStack(tss->esp0, tss);

  /* insert the new thread in the current process's threads queue */
  tss->prev = currThread;
  currThread->next = tss;
  tss->next = next;
  if (next) next->prev = tss;

  processTable[currProcess]->numThreads++;
  processTable[currProcess]->lastThread++;
  tss->threadID = processTable[currProcess]->lastThread;

  readyQueueInsert(tss);

  numThreads++;

  /* allocate the new thread's private semaphore */
  tss->privSem = __OS_sem_allocateSemaphore(0);

  return tss->threadID;
}

extern void _linux_syscall_exit(int32_t status);
void __OS_threadExit(void * retval) {
  char hasPrev, hasNext;
  tss_t * prev, * next;

  readyQueueExtractThread(currThread);
  timerQueueExtractThread(currThread);

  printk("Thread ");
  print_ulong(currThread->threadID);
  printk(" (process  ");
  print_ulong(currProcess);
  printk(") exited\n");

  // TODO free this tss
  prev = currThread->prev;
  next = currThread->next;

  processTable[currProcess]->numThreads--;
  numThreads--;

  hasPrev = (prev != NULL);
  hasNext = (next != NULL);

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


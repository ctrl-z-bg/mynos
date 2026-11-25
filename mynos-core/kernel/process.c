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

#include "irq.h"
#include "trace.h"
#include "global.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "sem.h"
#include "kutils.h"
#include "elf.h"
#include "process.h"

#include "video.h"
#include "mem/dynalloc.h"
#include "sched.h"
#include "ipc/port.h"
#include "ipc/channel.h"
#include "mynos.h"
#include "mem/externalmem.h"
#include "linux_syscalls.h"
#include "mem/physicalmem.h"

/* the arguments of a process started without any (GRUB modules) */

process_descriptor_t * processTable[MAXPROCESSES];
uint32_t numProcess = 1;
uint32_t currProcess = 0;  /* the first process is the idle process */

uint32_t numProcesses = 0;
uint32_t numThreads = 0;

tss_t * currThread;

extern modinfo_t bytecode;

void initProcessTable() {
  int i;
  for (i = 0; i < MAXPROCESSES; i++)
    processTable[i] = NULL;
}

/* the generation of each slot: incremented when its process is freed */
static uint32_t generation[MAXPROCESSES];

/* a new pid: a free slot (taken in a cycle), with its generation */
int allocPid(void) {
  static uint32_t last = 0;
  uint32_t i, p;
  for (i = 0; i < MAXPROCESSES - 1; i++) {
    p = (last + i) % (MAXPROCESSES - 1) + 1;          /* 1 .. MAX-1 */
    if (processTable[p] == NULL) {
      last = p;
      if (p >= numProcess) numProcess = p + 1;
      return p + MAXPROCESSES * generation[p];
    }
  }
  {
    static int said = 0;
    ktableFull("process", &said);
  }
  return -1;
}

/*
 * Starts a new process from an ELF image (a GRUB module, or a file a
 * process read: mynos_spawn). Returns its pid, or a MYNOS_ERR_* code.
 */
int createProcess(uint32_t * elf, uint32_t len, char ** argv, char ** envp,
		  pid_t ppid, uint32_t privileges) {
  process_descriptor_t * desc;
  int pid;

  if ((pid = allocPid()) < 0) return MYNOS_ERR_FULL;
  desc = (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));
  if (desc == NULL) return MYNOS_ERR_FULL;
  desc->pid = pid;
  desc->ppid = ppid;
  desc->privileges = privileges;
  trace_setName(desc->name, argv);
  {                                    /* OCaml bytecode, on ocamlrun? */
    const char * a = argv && argv[0] ? argv[0] : "", * base = a;
    for (; *a; a++) if (*a == '/') base = a + 1;
    desc->bytecode = !kmemcmp((char *)base, "ocamlrun", 9);
  }
  if (spawnProcess(desc, elf, len, argv, envp) == NULL) {
    /* a bad image fails before allocating; out of memory, after, and
       leaks the pages it took (only an ended process's are freed) */
    kfree(desc);
    return MYNOS_ERR_INVALID;
  }
  desc->tss->pid = pid;
  desc->tss->tid = pid;
  processTable[PSLOT(pid)] = desc;
  TRACE(TRACE_SPAWN, ppid, pid, -1, 0, 0, desc->name, kstrlen(desc->name));
  return pid;
}


/* processes that ended, whose memory is still to be freed */
static process_descriptor_t * zombies = NULL;

/*
 * Ends a process: the current one (killProcess), or another (kill, native
 * call 34). It releases only what other processes can see (IPC,
 * semaphores), takes its threads out of every queue (ready, timers,
 * semaphores: on one processor, a process that is not the current one has
 * all its threads in some queue, as the other threads of a process that
 * calls exit do) and queues the process: its memory is freed by
 * reapZombies, from another process, after the next switch. The
 * descriptor stays until the parent collects the status (wait4), or goes
 * at once if nobody can.
 */
static void endProcess(process_descriptor_t * self, int status, paddr_t pgdir) {
  uint32_t saved;
  tss_t * tss;
  process_queue_t * q;
  int port, channel;
  int i, n;
  process_descriptor_t * parent;

  TRACE(TRACE_EXIT, self->pid, -1, -1, 0, status, NULL, 0);
  self->isAlive = 0;
  numThreads -= self->numThreads;
  numProcesses--;
  
  tss = self->tss;
  while (tss) {
    timerQueueExtractThread(tss);
    q = tss->queue;
    if (q) pqExtractThread(q, tss);
    __OS_sem_threadEnded(tss);      /* a semaphore's lock a V handed it */
    tss = tss->next;
  }

  /* ports and channels check that the caller owns them: for another
     process (kill), the kernel acts as the one ending while it frees them
     (system calls run with interrupts off: nothing else runs meanwhile).
     Without it, a killed service's port stayed open, and a client that
     connected to it waited for ever. */
  saved = currProcess;
  currProcess = PSLOT(self->pid);

  // free process ports
  n = listNElem(self->portList);
  for (i = 0; i < n; i++) {
    port = (int)(long)listExtract(self->portList);
    __OS_port_freeDead(port);
  }

  // free process channels
  n = listNElem(self->channelList);
  for (i = 0; i < n; i++) {
    channel = (int)(long)listExtract(self->channelList);
    __OS_ipc_freeChannel(channel);
  }


  currProcess = saved;

  /* threads waiting on futexes */
  futexForget(self->pid);

  /* semaphores: the threads' private ones and the children's */
  for (tss = self->tss; tss; tss = tss->next)
    __OS_sem_freeSemaphore(tss->privSem);
  __OS_sem_freeSemaphore(self->childSem);
  __OS_sem_freeProcessSemaphores(self->pid);
  __OS_irq_processEnded(self->pid);
  __pager_processEnded(self->pid);

  /* the children become orphans: nobody will wait for them */
  for (i = 1; i < (int)numProcess; i++) {
    process_descriptor_t * c = processTable[i];
    if (!c || c == self || c->ppid != self->pid) continue;
    c->ppid = 0;
    if (!c->isAlive && c->memFreed)
      freeProcessDescriptor(c->pid);
  }

  /* tell the parent, which may be waiting for it */
  self->exitStatus = status;
  parent = proc(self->ppid);
  if (self->ppid != 0 && parent && parent->isAlive) {
    /* every thread of the parent that waits, not one: woken alone, a
       thread waiting for another child went back to sleep with the
       wakeup, and the one waiting for this child slept on (JOURNAL
       2026-11-23). One V each on its own semaphore: two V on one
       semaphore make the second wait for the first's thread to run, and
       an ending process is not run again. */
    int k;
    for (k = 0; k < CHILD_WAITERS; k++) {
      tss_t * t = parent->childWaiting[k];
      if (t == NULL) continue;
      parent->childWaiting[k] = NULL;
      __OS_sem_V(t->privSem);
    }
    __OS_sem_V(parent->childSem);
  }

  /* the memory: later, from elsewhere */
  self->pgdirPhys = pgdir;
  self->memFreed = 0;
  self->nextZombie = zombies;
  zombies = self;
}

void killProcess(int status) {
  endProcess(processTable[currProcess], status, THREAD_SPACE(currThread));
}

/* kill (34): end another process, as if it had been killed (SIGKILL).
   Not init, not the idle process, and not a process with privileges the
   caller lacks (drivers: only a driver ends a driver). A process may end
   itself. */
int _mynos_syscall_kill(pid_t pid) {
  process_descriptor_t * p = proc(pid);
  process_descriptor_t * self = processTable[currProcess];
  if (p == NULL || !p->isAlive) return MYNOS_ERR_INVALID;
  if (PSLOT(pid) == 0 || pid == 1) return MYNOS_ERR_DENY;
  if (p->privileges & ~self->privileges) return MYNOS_ERR_DENY;
  printk("process ");
  print_int(pid);
  printk(" (");
  printk(p->name);
  printk(") killed by ");
  print_int(self->pid);
  print_char('\n');
  if (p == self) {
    killProcess(SIGNAL_STATUS(SIGKILL));
    sched();                      /* never returns */
  }
  endProcess(p, SIGNAL_STATUS(SIGKILL), THREAD_SPACE(p->tss));
  return 0;
}

void freeProcessDescriptor(pid_t pid) {
  uint32_t slot = PSLOT(pid);
  if (slot == 0 || proc(pid) == NULL) return;
  kfree(processTable[slot]);
  processTable[slot] = NULL;
  generation[slot] = (generation[slot] + 1) % PID_GENERATIONS;
}

/*
 * Frees the memory of the processes that ended, except the current one
 * (it may be the process that is ending, still on its own stack): called
 * by the scheduler, and by wait4 before it frees a child's descriptor.
 */
void reapZombies(void) {
  process_descriptor_t ** pz = &zombies;
  while (*pz) {
    process_descriptor_t * z = *pz;
    tss_t * t, * next;
    if (z == processTable[currProcess]) {
      pz = (process_descriptor_t **)&z->nextZombie;
      continue;
    }
    *pz = z->nextZombie;

    freeAddressSpace(z);
    for (t = z->tss; t; t = next) { next = t->next; kfree(t); }
    for (t = z->deadThreads; t; t = next) { next = t->next; kfree(t); }
    z->tss = z->deadThreads = NULL;
    __lmt_freeList(&(z->lmemmap));
    z->memFreed = 1;

    /* nobody will collect its status */
    if (z->ppid == 0 || z->reaped || !proc(z->ppid) ||
	!proc(z->ppid)->isAlive)
      freeProcessDescriptor(z->pid);
  }
}


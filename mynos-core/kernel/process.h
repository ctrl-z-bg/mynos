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

#ifndef __PROCESS_H__
#define __PROCESS_H__

#include "tss.h"
#include "mem/lmemtrack.h"
#include "global.h"
#include "list.h"

#define MAXPROCESSES (1000)
#define MAXOPENSERVICES (100)
/* user mode, interrupts on; IOPL 3 (port I/O) for privileged processes
   only (doc/decisions/identity-and-permissions.md) */
#define INITIAL_EFLAGS (0x0200)
#define IOPL3          (0x3000)

/* Pids carry a generation (doc/decisions/identity-and-permissions.md):
   pid = slot + MAXPROCESSES * generation, the slot being the index in
   processTable. A pid names one process for its whole life: when its slot
   is reused, the new process has another pid. Generations wrap at
   PID_GENERATIONS, so that pids stay below 10^9 (thread ids are above). */
#define PID_GENERATIONS (1000000)
#define PSLOT(pid) ((uint32_t)(pid) % MAXPROCESSES)

typedef int servicesTable_t;

/* the process data at the end of the process memory space */
typedef struct {
  /* service descriptor table */
  servicesTable_t servicesTable[MAXOPENSERVICES];
} processData_t;

typedef struct {
  tss_t * tss;

  /* selector of the task's tssd */
  uint32_t isAlive;
  pid_t ppid;
  pid_t pid;

  uint32_t numThreads;
  uint32_t lastThread;

  processData_t * processData;

  /* linear space map */
  pdListEl * lmemmap;

  /* these are the lists of ports and channels of this process */
  list_t channelList[1];
  list_t portList[1];

  /* this is the physical address of the page table using to access
     all process' page tables (the last one...) */
  void * ptsMirror;

  /* termination, for the parent's waitpid: the status in the Linux
     encoding (exit code << 8, or the signal number), whether the parent has
     collected it, and a semaphore V'd once for every child that ends */
  int exitStatus;
  uint32_t reaped;
  int childSem;

  /* ending: the threads that exited (their tss and kernel stacks are
     reused by the next threads), the page directory of the process, and
     the list of ended processes whose memory is still to be freed (it can
     be freed only from another process: see reapZombies) */
  tss_t * deadThreads;
  uint32_t pgdirPhys;
  uint32_t memFreed;
  void * nextZombie;

  /* the program's name, for the event recorder (trace.c) */
  char name[16];
  uint32_t privileges;        /* MYNOS_PRIV_* */
  uint32_t bytecode;          /* started as ocamlrun: an OCaml program */
} process_descriptor_t;

extern process_descriptor_t * processTable[];
extern uint32_t numProcess;
extern uint32_t currProcess;      /* the current process's slot */
extern tss_t * currThread;

/* the current process's pid */
#define CURRPID (processTable[currProcess]->pid)

int __OS_touchesRamdisk(uint32_t start, uint32_t len);

/* the process of a pid (alive, or ended and not collected yet), or NULL:
   no such pid, or its slot holds a later process */
static inline process_descriptor_t * proc(pid_t pid) {
  process_descriptor_t * p;
  if (pid < 0) return NULL;
  p = processTable[PSLOT(pid)];
  return (p && p->pid == pid) ? p : NULL;
}

/* the number of running processes */
extern uint32_t numProcesses;

/* the number of running threads */
extern uint32_t numThreads;

void initStack(uint32_t s, tss_t * tss);

void initProcessTable();

process_descriptor_t * spawnProcess(process_descriptor_t * desc, 
				    uint32_t * test_start, uint32_t test_len,
				    char ** argv, char ** envp);
int createProcess(uint32_t * elf, uint32_t len, char ** argv, char ** envp,
		  pid_t ppid, uint32_t privileges);
void killProcess(int status);
int _mynos_syscall_kill(pid_t pid);
int allocPid(void);
void reapZombies(void);
void freeProcessDescriptor(pid_t pid);

/* Linux wait status of a process that called exit(code) / was killed */
#define EXIT_STATUS(code) (((code) & 0xFF) << 8)
#define SIGNAL_STATUS(sig) ((sig) & 0x7F)
#define SIGILL  4
#define SIGFPE  8
#define SIGKILL 9
#define SIGSEGV 11

#endif

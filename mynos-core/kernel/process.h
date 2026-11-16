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
#define INITIAL_EFLAGS (0x3200)

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
} process_descriptor_t;

extern process_descriptor_t * processTable[];
extern uint32_t numProcess;
extern uint32_t currProcess;
extern tss_t * currThread;

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
		  pid_t ppid);
void killProcess(int status);

/* Linux wait status of a process that called exit(code) / was killed */
#define EXIT_STATUS(code) (((code) & 0xFF) << 8)
#define SIGNAL_STATUS(sig) ((sig) & 0x7F)
#define SIGILL  4
#define SIGFPE  8
#define SIGSEGV 11

#endif

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The event recorder: see trace.h. */

#include "trace.h"
#include "process.h"
#include "kutils.h"
#include "pit.h"
#include "mem/mem.h"
#include "mem/dynalloc.h"
#include "mynos.h"

#define TRACE_EVENTS 8192

typedef struct {
  uint32_t seq, tsc_lo, tsc_hi;
  ushort16_t kind, pid;
  uint32_t tid;
  int32_t peer, channel;
  uint32_t size, arg;
  ushort16_t ndata, pad;
  ubyte_t data[TRACE_DATA];
} event_t;

int trace_on = 0;
static event_t * events = NULL;
static uint32_t first = 0, count = 0, seq = 0, dropped = 0;

/* One recording at a time, the process's that started it (mynos-kwe): it
   alone stops, reads and frees it, until it ends; then anyone may. Any
   process may record (doc/decisions/identity-and-permissions.md, 9). */
static pid_t owner = 0;

static int someone_else_owns(void) {
  process_descriptor_t * p;
  if (owner == 0 || owner == CURRPID) return 0;
  p = proc(owner);
  return p != NULL && p->isAlive;
}
static uint32_t start_tsc_lo, start_tsc_hi, start_ticks;

extern uint32_t timerTicks;
extern process_descriptor_t * processTable[];
extern uint32_t numProcess;

static void rdtsc(uint32_t * lo, uint32_t * hi) {
  __asm__ volatile ("rdtsc" : "=a"(*lo), "=d"(*hi));
}

void trace_event(int kind, int pid, int peer, int channel, uint32_t size,
		 uint32_t arg, const void * data, uint32_t n) {
  event_t * e;
  if (events == NULL) return;
  if (count == TRACE_EVENTS) { dropped++; return; }
  e = &events[(first + count) % TRACE_EVENTS];
  count++;
  e->seq = seq++;
  rdtsc(&e->tsc_lo, &e->tsc_hi);
  e->kind = kind;
  e->pid = pid;
  e->tid = currThread ? currThread->tid : 0;
  e->peer = peer;
  e->channel = channel;
  e->size = size;
  e->arg = arg;
  if (n > TRACE_DATA) n = TRACE_DATA;
  if (data == NULL) n = 0;
  e->ndata = n;
  e->pad = 0;
  if (n) kmemcpy(e->data, (void *)data, n);
}

void trace_setName(char * name, char ** argv) {
  const char * a, * base;
  uint32_t n;
  name[0] = 0;
  if (argv == NULL || argv[0] == NULL) return;
  a = argv[0];
  base = a;
  for (; *a; a++) if (*a == '/') base = a + 1;
  /* a bytecode program: its name */
  if (!kmemcmp((char *)base, "ocamlrun", 9) && argv[1] != NULL) {
    for (a = base = argv[1]; *a; a++) if (*a == '/') base = a + 1;
  }
  for (n = 0; base[n] && base[n] != '.' && n < 15; n++) name[n] = base[n];
  name[n] = 0;
}

static uint32_t strlen16(const char * s) {
  uint32_t n = 0;
  while (n < 16 && s[n]) n++;
  return n;
}

int _mynos_syscall_trace(uint32_t op, uint32_t arg1, uint32_t arg2) {
  uint32_t i;
  switch (op) {
  case TRACE_START:
    if (someone_else_owns()) return MYNOS_ERR_BUSY;
    owner = CURRPID;
    if (events == NULL) {
      events = kmalloc(TRACE_EVENTS * sizeof(event_t));
      if (events == NULL) return MYNOS_ERR_FULL;
    }
    first = count = seq = dropped = 0;
    rdtsc(&start_tsc_lo, &start_tsc_hi);
    start_ticks = timerTicks;
    trace_on = 1;
    /* who is there */
    for (i = 0; i < numProcess; i++) {
      process_descriptor_t * p = processTable[i];
      if (p && p->isAlive)
	trace_event(TRACE_PROCESS, p->pid, p->ppid, -1, 0, 0, p->name,
		    strlen16(p->name));
    }
    return 0;
  case TRACE_STOP:
    if (someone_else_owns()) return MYNOS_ERR_DENY;
    trace_on = 0;
    return 0;
  case TRACE_READ: {
    uint32_t n = arg2 < count ? arg2 : count, k;
    if (someone_else_owns()) return MYNOS_ERR_DENY;
    if (n == 0) return 0;
    if (!__mem_userArea((void *)arg1, n * sizeof(event_t)))
      return MYNOS_ERR_INVALID;
    for (k = 0; k < n; k++)
      kmemcpy((event_t *)arg1 + k, &events[(first + k) % TRACE_EVENTS],
	      sizeof(event_t));
    first = (first + n) % TRACE_EVENTS;
    count -= n;
    return n;
  }
  case TRACE_INFO: {
    uint32_t * w = (uint32_t *)arg1;
    if (!__mem_userArea(w, 9 * sizeof(uint32_t))) return MYNOS_ERR_INVALID;
    w[0] = trace_on;
    w[1] = count;
    w[2] = dropped;
    w[3] = start_tsc_lo;
    w[4] = start_tsc_hi;
    w[5] = USER_TICKS(start_ticks);
    rdtsc(&w[6], &w[7]);
    w[8] = USER_TICKS(timerTicks);
    return 0;
  }
  case TRACE_MARK_OP: {
    char label[TRACE_DATA];
    if (!trace_on) return 0;
    if (arg2 > TRACE_DATA) arg2 = TRACE_DATA;
    if (copy_from_user(label, (void *)arg1, arg2)) return MYNOS_ERR_INVALID;
    trace_event(TRACE_MARK, processTable[currProcess]->pid, -1, -1, 0, 0, label, arg2);
    return 0;
  }
  case TRACE_FREE_BUFFER:
    if (someone_else_owns()) return MYNOS_ERR_DENY;
    owner = 0;
    trace_on = 0;
    if (events) kfree(events);
    events = NULL;
    count = 0;
    return 0;
  }
  return MYNOS_ERR_INVALID;
}

/* the page faults resolved (native 36, mynos-0ho): a process's (pid), or
   the system's since boot (pid 0), as two words, allocated on use and
   copy-on-write */
extern uint32_t mem_faultsAlloc, mem_faultsCow;
int _mynos_syscall_faults(int32_t pid, uint32_t buf) {
  uint32_t e[2];
  if (pid == 0) {
    e[0] = mem_faultsAlloc;
    e[1] = mem_faultsCow;
  } else {
    process_descriptor_t * p = pid > 0 ? processTable[PSLOT(pid)] : NULL;
    if (p == NULL || !p->isAlive || p->pid != (pid_t)pid) return MYNOS_ERR_INVALID;
    e[0] = p->faultsAlloc;
    e[1] = p->faultsCow;
  }
  if (copy_to_user((char *)buf, e, sizeof e)) return MYNOS_ERR_INVALID;
  return 0;
}

/* a process's statistics (native 38, sysmonitor): 6 words, its CPU
   ticks, page faults allocated on use and copy-on-write, pages in memory,
   threads, and the clock's ticks since boot. pid 0: the kernel, whose
   ticks are the idle time, and its pages are all those of the RAM. */
extern uint32_t __OS_residentPages(process_descriptor_t * p);
extern uint32_t __total_phy_pages;
int _mynos_syscall_procstat(int32_t pid, uint32_t buf) {
  uint32_t e[6];
  process_descriptor_t * p = pid >= 0 ? processTable[PSLOT(pid)] : NULL;
  if (p == NULL || !p->isAlive || p->pid != (pid_t)pid) return MYNOS_ERR_INVALID;
  e[0] = USER_TICKS(p->cpuTicks);
  e[1] = p->faultsAlloc;
  e[2] = p->faultsCow;
  e[3] = pid == 0 ? __total_phy_pages : __OS_residentPages(p);
  e[4] = p->numThreads;
  e[5] = USER_TICKS(timerTicks);
  if (copy_to_user((char *)buf, e, sizeof e)) return MYNOS_ERR_INVALID;
  return 0;
}

int _mynos_syscall_processes(uint32_t buf, uint32_t max) {
  uint32_t i, n = 0;
  for (i = 0; i < numProcess && n < max; i++) {
    process_descriptor_t * p = processTable[i];
    uint32_t e[PROCESS_ENTRY / 4];
    if (p == NULL || !p->isAlive) continue;
    e[0] = p->pid;
    e[1] = p->ppid;
    e[2] = p->privileges | (p->bytecode ? MYNOS_PROC_BYTECODE : 0);
    e[3] = p->numThreads;
    kmemcpy(&e[4], p->name, 16);
    if (copy_to_user((char *)buf + n * PROCESS_ENTRY, e, PROCESS_ENTRY))
      return MYNOS_ERR_INVALID;
    n++;
  }
  return n;
}


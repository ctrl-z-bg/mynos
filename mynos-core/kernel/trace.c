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
	trace_event(TRACE_PROCESS, i, p->ppid, -1, 0, 0, p->name,
		    strlen16(p->name));
    }
    return 0;
  case TRACE_STOP:
    trace_on = 0;
    return 0;
  case TRACE_READ: {
    uint32_t n = arg2 < count ? arg2 : count, k;
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
    w[5] = start_ticks;
    rdtsc(&w[6], &w[7]);
    w[8] = timerTicks;
    return 0;
  }
  case TRACE_FREE_BUFFER:
    trace_on = 0;
    if (events) kfree(events);
    events = NULL;
    count = 0;
    return 0;
  }
  return MYNOS_ERR_INVALID;
}

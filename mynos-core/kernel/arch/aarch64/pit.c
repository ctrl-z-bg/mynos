/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The clock's tick on AArch64: the generic timer's virtual timer, at
   PIT_FREQ (1000 Hz) as the PIT on the PC; pit_handler as x86-64's. */

#include "pit.h"
#include "pic.h"
#include "random.h"
#include "video.h"
#include "kutils.h"
#include "sched.h"
#include "process.h"

static uint64_t tick_counts;            /* the counter's counts in a tick */

static void timer_arm(void)
{
  __asm__ volatile ("msr cntv_tval_el0, %0; msr cntv_ctl_el0, %1"
                    : : "r"(tick_counts), "r"(1UL));
}

void init_pit(int freq, unsigned char channel)
{
  uint64_t f;
  (void)channel;
  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r"(f));
  tick_counts = f / freq;
  /* programs may read the virtual counter (CNTVCT_EL0, as x86's rdtsc:
     tests/bench), not the timers */
  __asm__ volatile ("msr cntkctl_el1, %0" : : "r"(1UL << 1));
  timer_arm();
  gic_enable(GIC_TIMER);
}

/* main.c sets it as the PIT's vector: the GIC's dispatch (idt.c) calls
   pit_handler itself */
void pit_ISR() { }

uint32_t timerTicks = 0;

/* the other processors' timers (smp.c): a time slice, 10 ms, as
   x86-64's LAPIC timers: the CPU time of the process found running, a
   new round. Processor 0's timer keeps the time (pit_handler) */
static void ap_timer_arm(void)
{
  __asm__ volatile ("msr cntv_tval_el0, %0; msr cntv_ctl_el0, %1"
                    : : "r"(tick_counts * SCHED_TICKS), "r"(1UL));
}

void ap_timer_start(void)
{
  /* programs may read the virtual counter here too (init_pit's) */
  __asm__ volatile ("msr cntkctl_el1, %0" : : "r"(1UL << 1));
  ap_timer_arm();
}

void ap_timer_handler(void)
{
  ap_timer_arm();
  if (processTable[currProcess])
    processTable[currProcess]->cpuTicks += SCHED_TICKS;
  sched();
}

void pit_handler() {
  timer_arm();
  timerTicks++;
  if (processTable[currProcess])
    processTable[currProcess]->cpuTicks++;
  random_event(0);
  if (timerTicks % SCHED_TICKS == 0 || currThread->pid == 0 || timerQueueDue())
    sched();
}

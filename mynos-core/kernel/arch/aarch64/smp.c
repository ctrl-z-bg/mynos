/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The big kernel lock on AArch64 (doc/decisions/smp.md), as x86-64's:
   taken at every way in (entry.S), left at the way out (trap_return),
   unless nested; a depth per processor, kept per thread across a switch.
   Contended since the other processors run (below). */

#include "global.h"
#include "process.h"

static volatile int big_lock;

void kernel_enter(void)
{
  struct cpu * c = arch_cpu();
  if (c->depth++ == 0)
    while (__atomic_exchange_n(&big_lock, 1, __ATOMIC_ACQUIRE))
      while (big_lock) __asm__ volatile ("yield");
}

void kernel_exit(void)
{
  struct cpu * c = arch_cpu();
  if (--c->depth == 0) __atomic_store_n(&big_lock, 0, __ATOMIC_RELEASE);
}

/* ---- the other processors (doc/decisions/smp.md, doc/decisions/aarch64.md) ----

   Started by PSCI's CPU_ON (QEMU virt: a hypervisor call), or a Pi's
   spin tables (raspi.c), before the first process (main.c). Each has its GIC interface (its banked
   registers: the software interrupts, the timer), its generic timer (a
   time slice every 10 ms, as x86-64's LAPIC timer), its idle thread.
   Device interrupts stay on processor 0 (the distributor's targets). A
   page's translation leaves every processor's TLB by itself (TLBI ...IS,
   arch.h): no IPI for that, unlike x86. Software interrupt 0 is the IPI:
   a thread may be ready, or a process ended. */

#include "tss.h"
#include "sched.h"
#include "video.h"
#include "kutils.h"
#include "mem/mem.h"
#include "pic.h"
#include "mem/dynalloc.h"

extern paddr_t kernel_pml4;
extern char exception_vectors[], _start_secondary[];
extern void arch_cpu_set(struct cpu * c);
extern void arch_switch_space(paddr_t top);
extern void gic_cpu_init(void);
extern void gic_sgi(uint32_t cpu, uint32_t sgi);
extern void ap_timer_start(void);

/* the stack of the processor being started, and the kernel's tables'
   real address (start.S reads them) */
uint64_t ap_stack_top, ap_ttbr0;
static volatile int ap_started;

#ifdef MYNOS_RASPI
void raspi_start_cpu(uint32_t n, unsigned long entry);
#else
static long psci(unsigned long fn, unsigned long a1, unsigned long a2, unsigned long a3)
{
  register unsigned long x0 __asm__("x0") = fn;
  register unsigned long x1 __asm__("x1") = a1;
  register unsigned long x2 __asm__("x2") = a2;
  register unsigned long x3 __asm__("x3") = a3;
  __asm__ volatile ("hvc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "memory");
  return (long)x0;
}
#define PSCI_CPU_ON 0xC4000003UL
#endif

static uint64_t counter(void)
{
  uint64_t v;
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r"(v));
  return v;
}

static uint64_t counter_freq(void)
{
  uint64_t f;
  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r"(f));
  return f;
}

void arch_smp_start(void)
{
  uint32_t n;
  uint64_t f = counter_freq();
  gic_cpu_init();                       /* processor 0's software interrupts */
  for (n = 1; n < MAXCPUS; n++) {
    void * stack;
    long r;
    uint64_t t;
    kernel_enter();
    stack = __OS_askPages(KERNEL_STACK_NPAGES, 1, 0);
    kernel_exit();
    if (!stack) break;
    cpus[n].id = n;
    ap_stack_top = (uint64_t)stack + KERNEL_STACK_NPAGES * PAGE_SIZE;
    ap_ttbr0 = kernel_pml4 | ARCH_RAM_BIT;            /* as arch_switch_space */
    __atomic_store_n(&ap_started, 0, __ATOMIC_SEQ_CST);
#ifdef MYNOS_RASPI
    /* a Pi's four, from the firmware's spin tables (raspi.c) */
    if (n >= 4) break;
    raspi_start_cpu(n, (uint64_t)_start_secondary + ARCH_RAM_BASE);
    r = 0;
#else
    /* its MPIDR (QEMU virt: affinity 0 is its number, up to 8), where to
       start (a physical address), its number in x0 */
    r = psci(PSCI_CPU_ON, n, (uint64_t)_start_secondary + ARCH_RAM_BASE, n);
#endif
    if (r != 0) break;                  /* no such processor: the last one (its
                                           stack, 16 KB, left: once, at boot) */
    t = counter();
    while (!__atomic_load_n(&ap_started, __ATOMIC_ACQUIRE) && counter() - t < f)
      __asm__ volatile ("yield");
    if (!ap_started) {
      kernel_enter();
      printk("processor ");
      print_uint(n);
      printk(" did not start\n");
      kernel_exit();
      break;
    }
    ncpus++;
  }
  kernel_enter();
  printk("Processors: ");
  print_uint(ncpus);
  printk("\n");
  kernel_exit();
}

/* another processor's first C: its struct cpu, vectors, tables, GIC
   interface, timer, idle thread */
void ap_main(uint64_t n)
{
  struct cpu * c = &cpus[n];
  arch_cpu_set(c);
  __asm__ volatile ("msr vbar_el1, %0; isb" : : "r"(exception_vectors));
  gic_cpu_init();
  c->depth = 0;
  kernel_enter();
  {
    tss_t * idle = kmalloc(sizeof(tss_t));
    kbzero(idle, sizeof *idle);
    idle->cr3 = kernel_pml4;
    idle->tid = -1 - (int32_t)n;
    c->idle = c->thread = idle;
    c->process = 0;
  }
  printk("Processor ");
  print_uint(n);
  printk(" started\n");
  kernel_exit();
  ap_timer_start();
  __atomic_store_n(&ap_started, 1, __ATOMIC_RELEASE);
  /* the idle loop: interrupts (its timer, an IPI) bring threads */
  for (;;) __asm__ volatile ("msr daifclr, #2; wfi; msr daifset, #2");
}

/* a process ended by another processor while this one ran its thread:
   the thread does not go on (as x86-64's, smp.c there) */
void smp_leave_if_dead(void)
{
  struct cpu * c = arch_cpu();
  process_descriptor_t * p;
  if (ncpus < 2 || c->thread == c->idle || c->thread->pid == 0) return;
  p = proc(c->thread->pid);
  if (p && p->isAlive) return;
  sched();
}

/* a thread became ready: one processor that idles, woken */
void arch_smp_kick(void)
{
  struct cpu * me = arch_cpu();
  uint32_t i;
  if (ncpus < 2) return;
  for (i = 0; i < ncpus; i++)
    if (&cpus[i] != me && cpus[i].thread == cpus[i].idle) {
      gic_sgi(i, 0);
      return;
    }
}

/* a process ended: the processors running its threads leave them */
void arch_smp_kick_process(pid_t pid)
{
  struct cpu * me = arch_cpu();
  uint32_t i;
  if (ncpus < 2) return;
  for (i = 0; i < ncpus; i++)
    if (&cpus[i] != me && cpus[i].thread && cpus[i].thread->pid == pid)
      gic_sgi(i, 0);
}

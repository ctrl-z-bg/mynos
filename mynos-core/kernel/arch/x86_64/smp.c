/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The other processors (doc/decisions/smp.md): found in ACPI's MADT,
 * started with INIT and STARTUP through the local APIC, from the
 * trampoline of ap.asm copied below 1 MB; each prepares itself in
 * ap_main (GS, its TSS, the IDT, syscall, the FPU, its local APIC).
 */

#include "global.h"
#include "paging.h"
#include "process.h"
#include "gdt.h"
#include "video.h"
#include "kutils.h"
#include "mem/mem.h"
#include "delay.h"
#include "arch.h"
#include "layout.h"
#include "idt.h"
#include "mem/dynalloc.h"

extern paddr_t kernel_pml4;
extern void ipi_entry(void), lapic_timer_entry(void);
void set_vector(void * handler, unsigned char n, unsigned short control);
void sched(void);
void idt_load(void);
void arch_init_calls(void);
void fpu_init(void);
void arch_cpu_set(struct cpu * c);

/* ---- the local APIC ---- */

#define LAPIC_ID       0x020
#define LAPIC_TPR      0x080
#define LAPIC_EOI      0x0B0
#define LAPIC_SVR      0x0F0
#define LAPIC_ICR_LO   0x300
#define LAPIC_ICR_HI   0x310
#define LAPIC_TIMER    0x320
#define LAPIC_LINT0    0x350
#define LAPIC_LINT1    0x360
#define LAPIC_TIMER_INIT 0x380
#define LAPIC_TIMER_CUR  0x390
#define LAPIC_TIMER_DIV  0x3E0

#define VEC_IPI   0xF0                  /* a thread to run, a TLB to flush */
#define VEC_TIMER 0xF1                  /* the local APIC's timer */

static volatile uint32_t * lapic;

static uint32_t lapic_read(uint32_t r) { return lapic[r / 4]; }
static void lapic_write(uint32_t r, uint32_t v) { lapic[r / 4] = v; }

static uint64_t rdmsr(uint32_t msr)
{
  uint32_t lo, hi;
  __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
  return ((uint64_t)hi << 32) | lo;
}

/* this processor's local APIC: on (its spurious vector 0xFF), nothing
   masked by priority */
static void lapic_enable(void)
{
  lapic_write(LAPIC_SVR, 0x100 | 0xFF);
  lapic_write(LAPIC_TPR, 0);
}

uint32_t lapic_id(void) { return lapic_read(LAPIC_ID) >> 24; }

/* an inter-processor interrupt: INIT, STARTUP, or a vector */
static void lapic_ipi(uint32_t apic, uint32_t low)
{
  lapic_write(LAPIC_ICR_HI, apic << 24);
  lapic_write(LAPIC_ICR_LO, low);
  while (lapic_read(LAPIC_ICR_LO) & (1 << 12)) ;   /* delivered */
}

static void lapic_eoi(void) { lapic_write(LAPIC_EOI, 0); }

/* ---- the big kernel lock ----
   Taken at every way into the kernel (entry.asm, idt.h, pit.c), left at
   the way out (trap_return), unless nested (a fault inside a call): the
   kernel stays one at a time, as on one processor, and processes run in
   parallel. A processor waiting for it flushes its TLB when asked, so
   that the one holding it can wait for that (smp_tlb_shootdown). */

static volatile int big_lock;

static void flush_tlb(struct cpu * c)
{
  uint64_t cr3;
  __asm__ volatile ("movq %%cr3, %0; movq %0, %%cr3" : "=r"(cr3) : : "memory");
  c->flush = 0;
}

void kernel_enter(void)
{
  struct cpu * c = arch_cpu();
  if (c->depth++ == 0) {
    while (__atomic_exchange_n(&big_lock, 1, __ATOMIC_ACQUIRE))
      while (big_lock) {
        if (c->flush) flush_tlb(c);
        __asm__ volatile ("pause");
      }
    if (c->flush) flush_tlb(c);
  }
}

void kernel_exit(void)
{
  struct cpu * c = arch_cpu();
  if (--c->depth == 0) __atomic_store_n(&big_lock, 0, __ATOMIC_RELEASE);
}

/* A process ended by another processor while this one ran its thread
   (or waited for the big lock to enter the kernel for it): the thread
   does not go on, neither into a call nor back to the process. sched
   never comes back to it: it is not ready any more. Interrupts' handlers
   run first (their EOI), this is checked at a call's start and at the
   way back to a process (entry.asm). */
void smp_leave_if_dead(void)
{
  struct cpu * c = arch_cpu();
  process_descriptor_t * p;
  if (ncpus < 2 || c->thread == c->idle || c->thread->pid == 0) return;
  p = proc(c->thread->pid);
  if (p && p->isAlive) return;
  sched();
}

/* ---- the other processors told ---- */

/* a page's translation changed: the processors that may hold it in their
   TLB (any, for the kernel's half; those running this address space, for
   a process's) flush theirs; the caller holds the big lock, and waits */
void smp_tlb_shootdown(unsigned long laddr)
{
  struct cpu * me = arch_cpu();
  uint64_t cr3;
  uint32_t i, asked = 0;
  if (!lapic) return;
  __asm__ volatile ("movq %%cr3, %0" : "=r"(cr3));
  for (i = 0; i < ncpus; i++) {
    struct cpu * c = &cpus[i];
    if (c == me) continue;
    /* the kernel's half (below the processes', and the direct map) is in
       every address space */
    if (laddr < USER_AREA_START || laddr >= USER_SPACE_TOP ||
        (c->thread && c->thread->cr3 == cr3)) {
      c->flush = 1;
      asked |= 1 << i;
      lapic_ipi(c->apic_id, VEC_IPI);
    }
  }
  for (i = 0; i < ncpus; i++)
    if (asked & (1 << i))
      while (cpus[i].flush) __asm__ volatile ("pause");
}

/* a thread became ready: one processor that idles, woken */
void arch_smp_kick(void)
{
  struct cpu * me = arch_cpu();
  uint32_t i;
  if (ncpus < 2 || !lapic) return;
  for (i = 0; i < ncpus; i++)
    if (&cpus[i] != me && cpus[i].thread == cpus[i].idle) {
      lapic_ipi(cpus[i].apic_id, VEC_IPI);
      return;
    }
}

/* a process ended: the processors running its threads leave them */
void arch_smp_kick_process(pid_t pid)
{
  struct cpu * me = arch_cpu();
  uint32_t i;
  if (ncpus < 2 || !lapic) return;
  for (i = 0; i < ncpus; i++)
    if (&cpus[i] != me && cpus[i].thread && cpus[i].thread->pid == pid)
      lapic_ipi(cpus[i].apic_id, VEC_IPI);
}

/* the local APIC's counts in 10 ms (a time slice, as the PIT's
   SCHED_TICKS), measured by processor 0 before starting the others */
static uint32_t lapic_10ms;

/* another processor's interrupts: an IPI (the TLB was flushed by
   kernel_enter; a thread may be ready) or its timer: a new round */
void smp_interrupt(uint64_t vector)
{
  struct cpu * c = arch_cpu();
  lapic_eoi();
  if (vector == VEC_TIMER && processTable[c->process])
    processTable[c->process]->cpuTicks += 10;     /* PIT ticks: 1 ms */
  sched();
}

/* ---- ACPI: the processors, from the MADT ---- */

static int checksum(const uint8_t * p, uint32_t n)
{
  uint8_t s = 0;
  while (n--) s += *p++;
  return s == 0;
}

static const uint8_t * rsdp_in(paddr_t from, paddr_t to)
{
  paddr_t a;
  for (a = from; a + 20 <= to; a += 16) {
    const uint8_t * p = PHYS_TO_VIRT(a);
    if (!kmemcmp((char *)p, "RSD PTR ", 8) && checksum(p, 20)) return p;
  }
  return NULL;
}

/* the enabled processors' local APIC ids, in ids; their number */
static int madt_cpus(uint32_t * ids, int max)
{
  const uint8_t * rsdp, * sdt;
  paddr_t ebda = (paddr_t)*(uint16_t *)PHYS_TO_VIRT(0x40E) << 4;
  uint32_t n, i, entry_size;
  int found = 0;

  rsdp = ebda ? rsdp_in(ebda, ebda + 1024) : NULL;
  if (!rsdp) rsdp = rsdp_in(0xE0000, 0x100000);
  if (!rsdp) return 0;
  /* ACPI 2: the XSDT (64-bit entries); else the RSDT */
  if (rsdp[15] >= 2 && *(uint64_t *)(rsdp + 24)) {
    sdt = PHYS_TO_VIRT(*(uint64_t *)(rsdp + 24));
    entry_size = 8;
  } else {
    sdt = PHYS_TO_VIRT((paddr_t)*(uint32_t *)(rsdp + 16));
    entry_size = 4;
  }
  n = (*(uint32_t *)(sdt + 4) - 36) / entry_size;
  for (i = 0; i < n; i++) {
    paddr_t t = entry_size == 8 ? *(uint64_t *)(sdt + 36 + 8 * i)
                                : *(uint32_t *)(sdt + 36 + 4 * i);
    const uint8_t * madt = PHYS_TO_VIRT(t), * e, * end;
    if (kmemcmp((char *)madt, "APIC", 4)) continue;
    end = madt + *(uint32_t *)(madt + 4);
    for (e = madt + 44; e + 2 <= end && e[1] >= 2; e += e[1])
      /* a processor's local APIC, enabled (flags bit 0) */
      if (e[0] == 0 && (*(uint32_t *)(e + 4) & 1) && found < max)
        ids[found++] = e[3];
    break;
  }
  return found;
}

/* ---- starting them ---- */

#define TRAMP 0x7000
extern char ap_trampoline[], ap_trampoline_end[];
extern uint64_t ap_cr3, ap_efer, ap_stack, ap_entry, ap_arg;
static volatile int ap_started;

/* the address of one of the trampoline's data, in its copy */
#define AP_DATA(x) ((uint64_t *)PHYS_TO_VIRT(TRAMP + ((char *)&(x) - ap_trampoline)))

void ap_main(uint64_t n);

void arch_smp_start(void)
{
  uint32_t ids[MAXCPUS], me;
  int count, i, k, t;

  lapic = PHYS_TO_VIRT(rdmsr(0x1B) & 0xFFFFF000);
  lapic_enable();
  me = lapic_id();
  cpus[0].apic_id = me;
  count = madt_cpus(ids, MAXCPUS);
  if (count <= 1) { lapic = NULL; return; }

  /* the local APIC timer's speed: counts in 10 ms, divided by 16 */
  lapic_write(LAPIC_TIMER_DIV, 0x3);
  lapic_write(LAPIC_TIMER, 1 << 16);              /* masked, one shot */
  lapic_write(LAPIC_TIMER_INIT, 0xFFFFFFFF);
  delay(10);
  lapic_10ms = 0xFFFFFFFF - lapic_read(LAPIC_TIMER_CUR);
  lapic_write(LAPIC_TIMER_INIT, 0);
  set_vector(ipi_entry, VEC_IPI, D_INT + D_PRESENT);
  set_vector(lapic_timer_entry, VEC_TIMER, D_INT + D_PRESENT);

  kmemcpy(PHYS_TO_VIRT(TRAMP), ap_trampoline, ap_trampoline_end - ap_trampoline);
  for (k = 0; k < count; k++) {
    void * stack;
    if (ids[k] == me) continue;
    i = ncpus;
    if (i >= MAXCPUS) break;
    /* the processors already started run threads: the kernel's data
       under the big lock */
    kernel_enter();
    stack = __OS_askPages(KERNEL_STACK_NPAGES, 1, 0);
    kernel_exit();
    if (!stack) break;
    cpus[i].id = i;
    cpus[i].apic_id = ids[k];
    *AP_DATA(ap_cr3) = kernel_pml4;
    *AP_DATA(ap_efer) = rdmsr(0xC0000080) & 0xFFFFFFFF;
    *AP_DATA(ap_stack) = (uint64_t)stack + KERNEL_STACK_NPAGES * PAGE_SIZE;
    *AP_DATA(ap_entry) = (uint64_t)ap_main;
    *AP_DATA(ap_arg) = i;
    ap_started = 0;
    lapic_ipi(ids[k], 0x00004500);                     /* INIT */
    delay(10);
    lapic_ipi(ids[k], 0x00004600 | (TRAMP >> 12));     /* STARTUP */
    delay(1);
    if (!ap_started) lapic_ipi(ids[k], 0x00004600 | (TRAMP >> 12));
    for (t = 0; t < 1000 && !ap_started; t++) delay(1);
    if (ap_started) ncpus++;
    else {
      kernel_enter();
      printk("processor (APIC ");
      print_uint(ids[k]);
      printk(") did not start\n");
      kernel_exit();
    }
  }
  kernel_enter();
  printk("Processors: ");
  print_uint(ncpus);
  printk("\n");
  kernel_exit();
}

/* another processor's first C: its struct cpu, tables and devices */
void ap_main(uint64_t n)
{
  struct cpu * c = &cpus[n];
  arch_cpu_set(c);
  gdt_load_ap(n);
  idt_load();
  arch_init_calls();
  fpu_init();
  arch_write_protect_kernel();
  lapic_enable();
  lapic_write(LAPIC_LINT0, 1 << 16);         /* the 8259's interrupts: processor 0's */
  lapic_write(LAPIC_LINT1, 1 << 16);

  /* its idle thread: process 0's, the kernel's tables; never in the ready
     queue (sched takes it when nothing else is ready) */
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
  printk(" started (APIC ");
  print_uint(c->apic_id);
  printk(")\n");
  kernel_exit();

  /* its time slices: the timer, periodic, every 10 ms */
  lapic_write(LAPIC_TIMER_DIV, 0x3);
  lapic_write(LAPIC_TIMER, VEC_TIMER | (1 << 17));
  lapic_write(LAPIC_TIMER_INIT, lapic_10ms ? lapic_10ms : 100000);
  ap_started = 1;

  /* the idle loop: interrupts (its timer, an IPI) bring threads */
  for (;;) __asm__ volatile ("sti; hlt; cli");
}

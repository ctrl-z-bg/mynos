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

extern paddr_t kernel_pml4;
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
#define LAPIC_LINT0    0x350
#define LAPIC_LINT1    0x360

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
  if (count <= 1) return;

  kmemcpy(PHYS_TO_VIRT(TRAMP), ap_trampoline, ap_trampoline_end - ap_trampoline);
  for (k = 0; k < count; k++) {
    void * stack;
    if (ids[k] == me) continue;
    i = ncpus;
    if (i >= MAXCPUS) break;
    stack = __OS_askPages(KERNEL_STACK_NPAGES, 1, 0);
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
      printk("processor (APIC ");
      print_uint(ids[k]);
      printk(") did not start\n");
    }
  }
  printk("Processors: ");
  print_uint(ncpus);
  printk("\n");
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
  printk("Processor ");
  print_uint(n);
  printk(" started (APIC ");
  print_uint(c->apic_id);
  printk(")\n");
  ap_started = 1;
  for (;;) __asm__ volatile ("cli; hlt");
}

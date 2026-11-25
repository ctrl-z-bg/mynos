/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's GDT and TSS (doc/decisions/x86-64.md). */

#include "global.h"
#include "gdt.h"
#include "video.h"
#include "process.h"

struct tss64 {
  uint32_t reserved0;
  uint64_t rsp0, rsp1, rsp2;
  uint64_t reserved1;
  uint64_t ist[7];
  uint64_t reserved2;
  uint16_t reserved3;
  uint16_t iomap;                 /* past the limit: no I/O bitmap */
} __attribute__((packed));

/* one per processor (doc/decisions/smp.md) */
static struct tss64 tss[MAXCPUS] __attribute__((aligned(16)));

static uint64_t gdt[5 + 2 * MAXCPUS] __attribute__((aligned(16))) = {
  0,
  0x00AF9A000000FFFFULL,          /* kernel code, 64 bits */
  0x00CF92000000FFFFULL,          /* kernel data */
  0x00AFFA000000FFFFULL,          /* user code, 64 bits, DPL 3 */
  0x00CFF2000000FFFFULL,          /* user data, DPL 3 */
  /* then each processor's TSS: 16 bytes, filled in */
};

static struct { uint16_t limit; uint64_t base; } __attribute__((packed)) gdtr;

/* the kernel stack's top for the current kernel entries; also read by the
   syscall entry (entry.asm), which the processor does not switch: the
   processor's struct cpu holds it */
void gdt_set_rsp0(uint64_t rsp0)
{
  struct cpu * c = arch_cpu();
  tss[c->id].rsp0 = rsp0;
  c->rsp0 = rsp0;
}

#define MSR_GS_BASE        0xC0000101
#define MSR_KERNEL_GS_BASE 0xC0000102
static void wrmsr(uint32_t msr, uint64_t v)
{
  __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}

/* this processor's struct cpu in GS's base; the processes' GS (0) in the
   one swapgs exchanges it with */
void arch_cpu_set(struct cpu * c)
{
  c->self = c;
  wrmsr(MSR_GS_BASE, (uint64_t)c);
  wrmsr(MSR_KERNEL_GS_BASE, 0);
}

void arch_cpu_boot(void)
{
  arch_cpu_set(&cpus[0]);
}

/* the GDT loaded, the code and data segments reloaded */
static void load_gdt(void)
{
  gdtr.limit = sizeof gdt - 1;
  gdtr.base = (uint64_t)gdt;
  __asm__ volatile ("lgdt %0\n\t"
                    "pushq $0x08\n\t"
                    "leaq 1f(%%rip), %%rax\n\t"
                    "pushq %%rax\n\t"
                    "lretq\n"
                    "1:\n\t"
                    "movw $0x10, %%ax\n\t"
                    "movw %%ax, %%ds\n\t"
                    "movw %%ax, %%es\n\t"
                    "movw %%ax, %%ss\n\t"
                    "xorw %%ax, %%ax\n\t"
                    "movw %%ax, %%fs\n\t"
                    : : "m"(gdtr) : "rax", "memory");
}

void _init_gdt(void)
{
  int i;
  for (i = 0; i < MAXCPUS; i++) {
    uint64_t base = (uint64_t)&tss[i], limit = sizeof tss[i] - 1;
    tss[i].iomap = sizeof tss[i];
    gdt[5 + 2 * i] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) | (0x89ULL << 40) |
                     (((limit >> 16) & 0xF) << 48) | (((base >> 24) & 0xFF) << 56);
    gdt[6 + 2 * i] = base >> 32;
  }
  load_gdt();
  __asm__ volatile ("ltr %w0" : : "r"(GDT_TSS_SEL));
  printk("GDT and TSS (64 bits) loaded\n");
}

/* another processor's: the same GDT, its own TSS */
void gdt_load_ap(uint32_t id)
{
  load_gdt();
  __asm__ volatile ("ltr %w0" : : "r"(GDT_TSS_SEL + 16 * id));
}

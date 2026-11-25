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

struct tss64 {
  uint32_t reserved0;
  uint64_t rsp0, rsp1, rsp2;
  uint64_t reserved1;
  uint64_t ist[7];
  uint64_t reserved2;
  uint16_t reserved3;
  uint16_t iomap;                 /* past the limit: no I/O bitmap */
} __attribute__((packed));

static struct tss64 tss __attribute__((aligned(16)));

static uint64_t gdt[7] __attribute__((aligned(16))) = {
  0,
  0x00AF9A000000FFFFULL,          /* kernel code, 64 bits */
  0x00CF92000000FFFFULL,          /* kernel data */
  0x00AFFA000000FFFFULL,          /* user code, 64 bits, DPL 3 */
  0x00CFF2000000FFFFULL,          /* user data, DPL 3 */
  0, 0                            /* the TSS: 16 bytes, filled in */
};

static struct { uint16_t limit; uint64_t base; } __attribute__((packed)) gdtr;

/* the kernel stack's top for the current kernel entries; also read by the
   syscall entry (entry.asm), which the processor does not switch */
uint64_t kernel_rsp0;

void gdt_set_rsp0(uint64_t rsp0)
{
  tss.rsp0 = rsp0;
  kernel_rsp0 = rsp0;
}

void _init_gdt(void)
{
  uint64_t base = (uint64_t)&tss, limit = sizeof tss - 1;
  tss.iomap = sizeof tss;
  gdt[5] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) | (0x89ULL << 40) |
           (((limit >> 16) & 0xF) << 48) | (((base >> 24) & 0xFF) << 56);
  gdt[6] = base >> 32;
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
                    "movw %%ax, %%gs\n\t"
                    : : "m"(gdtr) : "rax", "memory");
  __asm__ volatile ("ltr %w0" : : "r"(GDT_TSS_SEL));
  printk("GDT and TSS (64 bits) loaded\n");
}

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The processor's struct cpu in TPIDR_EL1 (percpu.h); no GDT, no TSS. */

#include "global.h"
#include "gdt.h"
#include "process.h"

void _init_gdt(void) { }

void gdt_set_rsp0(uint64_t rsp0)
{
  arch_cpu()->rsp0 = rsp0;
}

void arch_cpu_set(struct cpu * c)
{
  c->self = c;
  __asm__ volatile ("msr tpidr_el1, %0" : : "r"(c));
}

void arch_cpu_boot(void)
{
  cpus[0].id = 0;
  arch_cpu_set(&cpus[0]);
}

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The processor running this code (process.h's struct cpu): the i386
   runs on one, cpus[0] (doc/decisions/smp.md). */

#ifndef __PERCPU_H__
#define __PERCPU_H__

#define arch_cpu() (&cpus[0])
static inline void arch_cpu_boot(void) { }
static inline void arch_smp_start(void) { }

#endif

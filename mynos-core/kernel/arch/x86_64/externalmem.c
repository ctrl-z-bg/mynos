/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Another process's memory on x86-64: its tables through the direct map.
   Not written yet (mynos-btq.3). */

#include "global.h"
#include "mem/mem.h"
#include "mem/externalmem.h"
#include "process.h"

int32_t __OS_mapPagesTo(pid_t pid, uint32_t lpage,
			uint32_t npages, uint32_t mode) { return -1; }
uint32_t * __mem_mapFrame(uint32_t phyPage, uint32_t * saved) { return PHYS_TO_VIRT((paddr_t)phyPage << 12); }
void __mem_unmapFrame(uint32_t saved) { }
pte_t * __mem_externalPTE(pid_t pid, uint32_t laddr) { return NULL; }
void __mem_setExternalPTE(pid_t pid, uint32_t laddr, pte_t entry) { }

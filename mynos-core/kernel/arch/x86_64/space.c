/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A process's address space on x86-64: not written yet (the next step of
   mynos-btq.3). The kernel boots without processes. */

#include "global.h"
#include "mem/mem.h"
#include "process.h"
#include "video.h"

process_descriptor_t * spawnProcess(process_descriptor_t * desc,
				    uint32_t * test_start, uint32_t test_len,
				    char ** argv, char ** envp)
{
  printk("x86-64: processes are not there yet\n");
  return NULL;
}

int arch_space_fork(paddr_t * pd, paddr_t * mirror) { return -12; }
void freeAddressSpace(process_descriptor_t * d) { }
void __OS_freeSpaceFrames(uint32_t pdFrame, uint32_t mirrorFrame) { }
uint32_t __OS_residentPages(process_descriptor_t * p) { return 0; }
int __OS_touchesRamdisk(vaddr_t start, uint32_t len) { return 0; }
void initStack(uint32_t s, tss_t * tss) { }
void arch_fork_child(void * t) { }

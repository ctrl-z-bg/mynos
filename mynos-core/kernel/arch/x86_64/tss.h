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
 * A thread on x86-64 (doc/decisions/x86-64.md, choice 5). The name stays
 * tss_t, which generic code knows; unlike the i386's it is not the
 * processor's task state segment (there is one of those, gdt.c): the
 * registers live on the thread's kernel stack, and the context switch
 * (switch.c) keeps only its stack pointer here.
 */

#ifndef __TSS_H__
#define __TSS_H__

#include "global.h"

typedef struct {
  /* the architecture's: offsets known by entry.asm */
  uint64_t rsp;          /* 0: the kernel stack pointer when switched out */
  uint64_t rsp0;         /* 8: the top of its kernel stack */
  uint64_t cr3;          /* 16: its address space (the top table) */
  uint64_t fs_base;      /* 24: its TLS (arch_prctl) */

  pid_t pid;
  uint32_t justForked;
  int privSem;
  void * next, * prev;
  int32_t lastChannel;
  uint32_t timeToWake;
  void * queue;

  /* kernel stack of a thread made by __OS_threadCreate (0: the first
     thread's, in the process's top area), kept for reuse */
  vaddr_t kstack;

  int32_t tid;
  int32_t * clearTid;

  uint32_t fpu_valid;
  ubyte_t fpu_area[512 + 16];

  int semHeld;

  /* its ways into the kernel when switched out (smp.c's big lock): a
     new thread's first is 1, which trap_return ends */
  uint32_t kdepth;
} tss_t;

#define THREAD_SPACE(T)        ((paddr_t)(T)->cr3)
#define THREAD_SET_SPACE(T, P) ((T)->cr3 = (P))

#endif

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The context switch on AArch64, as x86-64's: the outgoing thread's FP
   and SIMD registers saved, the incoming one's restored, its TLS
   (TPIDR_EL0) and address space (TTBR0) set, then the kernel stacks
   swapped (entry.S's switch_stacks). */

#include "global.h"
#include "tss.h"
#include "process.h"
#include "softtaskswitch.h"
#include "paging.h"
#include "kutils.h"
#include "gdt.h"

static ubyte_t fpu_clean[512 + 16];

#define FPU_AREA(A) ((void *)(((vaddr_t)(A) + 15) & ~15UL))

/* the 32 Q registers, then FPCR and FPSR (528 bytes with the alignment:
   fpu_area's size) */
static void fpu_store(void * a)
{
  __asm__ volatile (
    "stp q0, q1, [%0, #0];    stp q2, q3, [%0, #32]\n"
    "stp q4, q5, [%0, #64];   stp q6, q7, [%0, #96]\n"
    "stp q8, q9, [%0, #128];  stp q10, q11, [%0, #160]\n"
    "stp q12, q13, [%0, #192]; stp q14, q15, [%0, #224]\n"
    "stp q16, q17, [%0, #256]; stp q18, q19, [%0, #288]\n"
    "stp q20, q21, [%0, #320]; stp q22, q23, [%0, #352]\n"
    "stp q24, q25, [%0, #384]; stp q26, q27, [%0, #416]\n"
    "stp q28, q29, [%0, #448]; stp q30, q31, [%0, #480]\n"
    "mrs x9, fpcr; mrs x10, fpsr; str x9, [%0, #512]; str x10, [%0, #520]\n"
    : : "r"(a) : "x9", "x10", "memory");
}

static void fpu_load(void * a)
{
  __asm__ volatile (
    "ldp q0, q1, [%0, #0];    ldp q2, q3, [%0, #32]\n"
    "ldp q4, q5, [%0, #64];   ldp q6, q7, [%0, #96]\n"
    "ldp q8, q9, [%0, #128];  ldp q10, q11, [%0, #160]\n"
    "ldp q12, q13, [%0, #192]; ldp q14, q15, [%0, #224]\n"
    "ldp q16, q17, [%0, #256]; ldp q18, q19, [%0, #288]\n"
    "ldp q20, q21, [%0, #320]; ldp q22, q23, [%0, #352]\n"
    "ldp q24, q25, [%0, #384]; ldp q26, q27, [%0, #416]\n"
    "ldp q28, q29, [%0, #448]; ldp q30, q31, [%0, #480]\n"
    "ldr x9, [%0, #512]; ldr x10, [%0, #520]; msr fpcr, x9; msr fpsr, x10\n"
    : : "r"(a) : "x9", "x10", "memory");
}

void fpu_init(void)
{
  kbzero(fpu_clean, sizeof fpu_clean);      /* zeros, FPCR 0: round to nearest */
}

void fpu_save(tss_t * t)
{
  fpu_store(FPU_AREA(t->fpu_area));
  t->fpu_valid = 1;
}

extern void switch_stacks(uint64_t * old_rsp, uint64_t new_rsp);

void switchTo(tss_t * old, tss_t * new)
{
  struct cpu * c = arch_cpu();
  if (old == new) return;
  old->kdepth = c->depth;
  c->depth = new->kdepth;
  fpu_save(old);
  fpu_load(new->fpu_valid ? FPU_AREA(new->fpu_area) : FPU_AREA(fpu_clean));
  gdt_set_rsp0(new->rsp0);
  /* the TLS: EL0 sets TPIDR_EL0 itself (musl), so it is read back here */
  __asm__ volatile ("mrs %0, tpidr_el0" : "=r"(old->fs_base));
  __asm__ volatile ("msr tpidr_el0, %0" : : "r"(new->fs_base));
  if (old->cr3 != new->cr3) arch_switch_space(new->cr3);
  switch_stacks(&old->rsp, new->rsp);
}

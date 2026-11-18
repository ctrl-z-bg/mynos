/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

#include "global.h"
#include "process.h"
#include "tss.h"
#include "softtaskswitch.h"
#include "linux_syscalls.h"

#include "mem/mem.h"

static tss_t * prev, * next;

/* ---- the floating-point unit (mynos-t6p) ----
   Every thread has its own x87/MMX/SSE state: saved at each context
   switch, eagerly (FXSAVE/FXRSTOR, or FNSAVE/FRSTOR on a processor without
   them). A thread that has never been switched out starts from the state
   of a freshly initialized FPU, recorded at boot. The kernel itself never
   touches the FPU (it is compiled with -mgeneral-regs-only), so the state
   in the registers is always the running thread's. */

#define FPU_AREA(a) ((void *)(((uint32_t)(a) + 15) & ~15u))

static int fpu_fxsr;                           /* FXSAVE available */
static ubyte_t fpu_clean[512 + 16];            /* a freshly initialized FPU */

static void fpu_store(void * area)
{
  if (fpu_fxsr) asm volatile("fxsave (%0)" :: "r"(area) : "memory");
  else asm volatile("fnsave (%0)\n\tfrstor (%0)" :: "r"(area) : "memory");
}

static void fpu_load(const void * area)
{
  if (fpu_fxsr) asm volatile("fxrstor (%0)" :: "r"(area) : "memory");
  else asm volatile("frstor (%0)" :: "r"(area) : "memory");
}

/* at boot: turn on FXSAVE and SSE if the processor has them (CR4.OSFXSR,
   OSXMMEXCPT), and record the clean state */
void fpu_init(void)
{
  uint32_t a = 1, b, c, d, cr4;
  asm volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
  fpu_fxsr = (d >> 24) & 1;
  if (fpu_fxsr) {
    asm volatile("movl %%cr4, %0" : "=r"(cr4));
    cr4 |= 1 << 9;                             /* OSFXSR */
    if ((d >> 25) & 1) cr4 |= 1 << 10;         /* SSE: OSXMMEXCPT */
    asm volatile("movl %0, %%cr4" :: "r"(cr4));
  }
  asm volatile("fninit");
  if (fpu_fxsr) {
    uint32_t mxcsr = 0x1F80;                   /* all SSE exceptions masked */
    if ((d >> 25) & 1) asm volatile("ldmxcsr %0" :: "m"(mxcsr));
  }
  fpu_store(FPU_AREA(fpu_clean));
}

/* the running thread's state into its tss (fork copies it) */
void fpu_save(tss_t * t)
{
  fpu_store(FPU_AREA(t->fpu_area));
  t->fpu_valid = 1;
}
static tss_t * tss;

/* from main.c */
extern tss_t THEtss;

/* a task created with taskSpawn needs to be 'adjusted' */
void startThread();

__asm__ (".pushsection .text\n" ".globl startThread \n" \
	 "startThread: \n"\
	 "  popw %gs\n"\
	 "  popw %fs\n"\
	 "  popw %es\n"\
	 "  popw %ds\n"\
	 "  iret\n" ".popsection\n");



void switchTo(tss_t * old, tss_t * new) {
  tss = &THEtss;
  
  if (old == new) return;

  /* the floating-point state: the outgoing thread's saved, the incoming
     one's (or a clean one) loaded */
  fpu_save(old);
  fpu_load(new->fpu_valid ? FPU_AREA(new->fpu_area) : FPU_AREA(fpu_clean));
  
  prev = old;
  next = new;

  tss->esp0 = next->esp0;

  /* the incoming thread's TLS segment, reloaded when %gs is popped below */
  tls_load(next);

  /* save some register */
  asm volatile(\
	       "pushl %esi\n\t"			\
	       "pushl %edi\n\t"			\
	       "pushl %ebx\n\t"			\
	       "pushl %ebp\n\t"			\
	       "pushw %ds\n"\
	       "pushw %es\n"\
	       "pushw %fs\n"\
	       "pushw %gs\n");

  /* change page directories only if they are different */
  if (prev->pgdir != next->pgdir)
    asm volatile("movl %0,%%cr3\n\t" :: "r"(next->pgdir) : "memory");

  /* save esp and eip (a fixed label) of the outcoming process, 
     restore esp of the incoming process */
  asm volatile(\
	       "movl %%esp,%0\n\t"	/* save old process ESP */	\
	       "movl %2,%%esp\n\t"	/* restore new process ESP */	\
	       "movl $1f,%1\n\t"	/* save old process EIP */\
	       :"=m" (prev->esp),"=m" (prev->eip)	\
	       :"m" (next->esp), "m"(next->eip));

  /* restore the incoming process's eip and jump to it */
  asm volatile(\
	       "pushl %3\n"\
	       "ret\n"				\
	       "1:\t"						\
	       :"=m" (prev->esp),"=m" (prev->eip)	\
	       :"m" (next->esp), "m"(next->eip));

  /* restore some register */
  asm volatile(\
	       "popw %gs\n"\
	       "popw %fs\n"\
	       "popw %es\n"\
	       "popw %ds\n"\
	       "popl %ebp\n\t"					\
	       "popl %ebx\n\t"					\
	       "popl %edi\n\t"					\
	       "popl %esi\n\t");
  
}

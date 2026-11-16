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

#include "mem/mem.h"

static tss_t * prev, * next;
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
  
  prev = old;
  next = new;

  tss->esp0 = next->esp0;

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
    asm volatile(\
		 "movl %0,%%eax\n\t"\
		 "movl %%eax,%%cr3\n\t"\
		 ::"m"(next->pgdir));

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

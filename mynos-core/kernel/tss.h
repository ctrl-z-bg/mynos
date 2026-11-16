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

#ifndef __TSS_H__
#define __TSS_H__

#include "global.h"

typedef struct {
  /* i80386 TSS */
  
  uint32_t backlink;
  uint32_t esp0;
  uint32_t ss0;
  uint32_t esp1;
  uint32_t ss1;
  uint32_t esp2;
  uint32_t ss2;
  uint32_t **pgdir;
  uint32_t eip;
  uint32_t eflags;
  uint32_t eax;
  uint32_t ecx;
  uint32_t edx;
  uint32_t ebx;
  uint32_t esp;
  uint32_t ebp;
  uint32_t esi;
  uint32_t edi;
  uint32_t es;
  uint32_t cs;
  uint32_t ss;
  uint32_t ds;
  uint32_t fs;
  uint32_t gs;
  uint32_t ldt;
  uint32_t io_bitmap_offset;
  
  /* End of i386 TSS.  */

  pid_t pid;
  uint32_t threadID;

  uint32_t justForked;

  // SEM
  int privSem;
  // end SEM

  void * next, * prev;

  int32_t lastChannel;  // last channel assigned by connectToPort

  uint32_t timeToWake;

  // in which queue I am
  void * queue;

  // thread-local storage segment, set by set_thread_area (Linux syscall 243)
  // and loaded into the GDT_TLS_INDEX descriptor on every context switch
  uint32_t tls_base;
  uint32_t tls_limit;
  uint32_t tls_pages;   // limit in 4K units

  // kernel stack of a thread made by __OS_threadCreate (0 for the first
  // thread, whose stack is in the process's top area), kept for reuse
  uint32_t kstack;

} tss_t;

#endif

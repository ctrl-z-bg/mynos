/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's GDT: flat 64-bit segments and the one task state segment, which
   holds the kernel stack used when a process enters the kernel (rsp0) */

#ifndef __GDT_H__
#define __GDT_H__

#include "macro_gdt.h"

#define GDT_OS_CODE_SEL     0x08
#define GDT_OS_DATA_SEL     0x10
#define GDT_USER_CODE_SEL   0x18
#define GDT_USER_DATA_SEL   0x20
#define GDT_TSS_SEL         0x28

void _init_gdt(void);
/* the kernel stack's top for the next entry into the kernel */
void gdt_set_rsp0(uint64_t rsp0);
void gdt_load_ap(uint32_t id);       /* another processor's (smp.c) */

#endif

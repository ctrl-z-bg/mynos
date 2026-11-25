/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* No segments on AArch64: the names generic code calls. The kernel stack
   used when a process enters the kernel is SP_EL1, which a return to the
   process leaves at the thread's stack top (entry.S). */

#ifndef __GDT_H__
#define __GDT_H__

#include "macro_gdt.h"

void _init_gdt(void);
void gdt_set_rsp0(uint64_t rsp0);

#endif

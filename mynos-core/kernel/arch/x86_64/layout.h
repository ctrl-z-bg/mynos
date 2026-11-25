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
 * x86-64's address space (doc/decisions/x86-64.md, choice 3):
 *
 *   0xFFFF800000000000  physical memory, all of it (the direct map)
 *   0x0000008000000000  the end of the process's space (512 GB: one entry
 *                       of the top table, PML4[0], per process)
 *   ...                 process information, the first thread's kernel
 *                       stack (the kernel's only), the user stack
 *   0x0000000040000000  the program
 *   0x0000000000000000  the kernel's gigabyte, shared: PDPT[0] of every
 *                       process points at the same page directory
 */

#ifndef __LAYOUT_H__
#define __LAYOUT_H__

#define PDPT_ENTRIES     512
#define LAST_PDPT_INDEX  511

#define USERMINPAGE      0x40000UL              /* 1 GB */
#define USERMAXPAGE      0x7FFFFFFUL            /* 512 GB - 4 KB */
#define __LAST_LINEAR_PAGE USERMAXPAGE
#define USER_SPACE_TOP   0x8000000000UL

#define USER_AREA_START  (USERMINPAGE << 12)
#define USER_AREA_END    (USER_SPACE_TOP - \
                          0x1000UL * (PROCESS_INFO_NPAGES + KERNEL_STACK_NPAGES))

#define DIRECT_MAP       0xFFFF800000000000UL

/* where threads' kernel stacks are made (threads.c): the kernel's
   gigabyte, which every space shares (a context switch changes the space
   while on the outgoing thread's stack: it must be mapped in both) */
#define ARCH_KSTACK_FLAGS 0

#endif

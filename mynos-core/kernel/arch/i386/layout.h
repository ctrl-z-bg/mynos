/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The i386's address space (appendix B.2): the kernel's gigabyte, then
   the process's pages, numbered from USERMINPAGE to USERMAXPAGE. Moved
   from global.h and mem/mem.h. */

#ifndef __LAYOUT_H__
#define __LAYOUT_H__

#define PDPT_ENTRIES (1024)
#define LAST_PDPT_INDEX (1023)

#define USERMINPAGE (0x40000)
#define USERMAXPAGE (0xFFFFF)
#define __LAST_LINEAR_PAGE 0xFFFFF

/* the process's own memory: from USERMINPAGE to the bottom of its kernel
   stack (the process info pages and the kernel stack sit above the user
   stack, under the page table mirrors) */
#define USER_AREA_START ((uint32_t)USERMINPAGE << 12)
#define USER_AREA_END   ((uint32_t)(0 - (0x400000 + 0x1000)) - \
                         0x1000 * (PROCESS_INFO_NPAGES + KERNEL_STACK_NPAGES))

/* where threads' kernel stacks are made (threads.c): the process's own
   space, with superuser rights */
#define ARCH_KSTACK_FLAGS PF_SUPERVISOR_IN_USER_SPACE

#endif

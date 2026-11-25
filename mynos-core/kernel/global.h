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

#ifndef __GLOBAL_H__
#define __GLOBAL_H__

#include "arch.h"

#define NULL (0x0)

//#define ARCH386
//#define TRY_VGA
//#define DEBUG
#define RAMDISK

#define __MEMORY_BITMAP_PHY_ADDRESS (0x32000)    /* 200KB */

#define PDPT_ENTRIES (1024)
#define LAST_PDPT_INDEX (1023)

#define USERMINPAGE (0x40000)
#define USERMAXPAGE (0xFFFFF)

/* kernel messages go to the screen too (see video.c); a panic always does */
extern int kernel_on_screen;
/* a kernel error it cannot go on from: print it and stop the machine
   (with interrupts off: other processes must not run on a broken kernel) */
#define KPANIC(MSG) { arch_irq_disable(); kernel_on_screen = 1; \
                      printk("\nKERNEL PANIC: "); printk(MSG); \
                      arch_halt_forever(); }

typedef char           byte_t;
typedef unsigned char  ubyte_t;
typedef unsigned int   uint32_t;
typedef int            int32_t;
typedef unsigned long  ulong32_t;
typedef long           long32_t;
typedef unsigned short ushort16_t;
typedef short          short16_t;

/* addresses (doc/decisions/x86-64.md): as wide as a pointer, 32 bits on
   the i386, 64 on x86-64 */
typedef unsigned long vaddr_t;         /* linear (virtual) */
typedef unsigned long paddr_t;         /* physical */

typedef int pid_t;
typedef unsigned int   __kernel_size_t;
typedef __kernel_size_t size_t;
typedef size_t ssize_t;
typedef long int off_t;               /* Type of file sizes and offsets.  */

// ticks of timer elapsed from the beginning...
extern uint32_t timerTicks;

extern int _asm_global_mem_size;
extern int _asm_last_kernel_page_dir_entry_used;
extern int _asm_first_free_physical_page_address;

/* PROCESS INFORMATION AND STACKs MEMORY SIZE */
#define PROCESS_INFO_NPAGES  2
#define KERNEL_STACK_NPAGES  4
#define USER_STACK_NPAGES  256

#define MAXMODULES 10
typedef struct {
  uint32_t * start;
  uint32_t len;
} modinfo_t;

#endif

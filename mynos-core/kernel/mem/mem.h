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

#ifndef __MEM_H__
#define __MEM_H__

#include "global.h"
#include "physicalmem.h"

#define PAGE_SIZE          0x1000
#define FOURMB             0x400000

#define PF_USER            (1<<2)
#define PF_SUPERVISOR      0x0
#define PF_READWRITE       (1<<1)
#define PF_LOGICAL_PRESENT 0x800    /* one of the available bits */
#define PF_COW             0x400    /* one of the available bits */
#define PF_SHARED          0x200    /* one of the available bits */
/* the same bit in an entry that is not present (the processor ignores
   every other bit of those): a page of a region given to the external
   pager (pager.c, mynos-vzp), its token in bits 12-31; PF_READWRITE says
   whether the region may be written */
#define PF_PAGER           PF_SHARED
#define IS_PAGER_ENTRY(E) \
  (((E) & (PF_PRESENT | PF_PAGER | PF_LOGICAL_PRESENT | PF_COW)) == PF_PAGER)
#define PF_PRESENT         0x1
#define PF_ACCESSED        0x20     /* set by the processor at a use */
#define PF_DIRTY           0x40     /* set by the processor at a write */
#define PF_NOTPRESENT      0x0

/* this is used to allocate kernel pages in user space */
#define PF_SUPERVISOR_IN_USER_SPACE 0x1000

/* the page tables' shape: the architecture's (arch/ARCH/paging.h) */
#include "paging.h"

/* a page's translation forgotten, after its entry changed */
#define INVALIDATE_THE_CACHE(LADDR) arch_flush_page((vaddr_t)(LADDR))



extern byte_t * __memory_bitmap;
extern uint32_t __memory_bitmap_size;
extern uint32_t __number_of_free_physical_pages;
extern uint32_t __total_phy_pages;

/* to call in mynos_main() */
void init_memory();
void mem_reserveAtBoot(paddr_t start, uint32_t len);

/* return value:
   'pageaddr' on success
   'NULL'     if some problem occours
*/
void * __OS_mapPhysical(paddr_t phys, uint32_t npages);
#define DMA_AREA_SIZE 0x10000
extern uint32_t __dma_area;
void * __OS_mapDmaArea(void);
void * __OS_allocDma(uint32_t npages, paddr_t * phys);
void * __OS_askPagesFrom(void * pageaddr, unsigned int npages,
			 int alloc_now, uint32_t flags);

void * __OS_askPages(unsigned int npages, int alloc_now, uint32_t flags);
/* if free is false the physical page is left allocated 
   if check is false no check is made on the page permissions */
void * __OS_releasePages(void *pageaddr, unsigned int npages, 
			 int free, int check);

/* return the id of a free physical page */
uint32_t __pg_find_a_free_physical_page();

/* - if 'npages' is 0 then the number of free linear pages, starting, 
     from 'first_page', is returned.
   - if 'npages' is not 0 then the search is stopped after 'npages'.
   'new_pt_required' is filled with the number of new page tables required.
*/
uint32_t __pg_free_pages_from_page(uint32_t first_page, uint32_t npages,
	 			   uint32_t * new_pts_required);

/* segments stuff */
/******************/
void SEG_createStandardDescriptor(uint32_t * address,
				  uint32_t base, uint32_t limit, 
				  ushort16_t control);

/* PAGE FAULT STUFF!!! */
void _page_fault_handler_TRAP();  /* the wrapper... */
void _page_fault_handler(vaddr_t addr, uint32_t errcode, unsigned long * frame); /* ... and the 
							      real handler */
/* special cases */
// it returns the new copy physical address
paddr_t __mem_copyPageToCOWSpace(vaddr_t addr);
void __mem_cowManager(vaddr_t addr);
void __mem_allocateOnUse(vaddr_t addr);

/* Pointers from processes. The user part of a process's linear space runs
   from USERMINPAGE to the bottom of its kernel stack (process.c: the
   process info pages and the kernel stack sit above the user stack, under
   the page table mirrors). */
/* USER_AREA_START, USER_AREA_END: arch/ARCH/layout.h */

/* is [start, start + size) memory of the current process the kernel may
   read or write for it? user pages, allocated or to be allocated on use;
   no wrap around; never the kernel's */
int __mem_userArea(const void * start, uint32_t size);
/* end the current process for an invalid access at addr */
void __mem_userSegfault(vaddr_t addr);
/* pager.c: a user thread's fault on a page given to the external pager
   (entry: its page table entry); returns once the page is there */
void __pager_fault(pte_t entry, vaddr_t addr, uint32_t errcode);
/* pager.c: a process has ended (the pager itself, or one that waited) */
void __pager_processEnded(pid_t pid);

/* copies to and from a process's memory: 0, or -1 if the address is not
   the process's or faults (the process goes on) */
int copy_to_user(void * user, const void * kernel, uint32_t n);
int copy_from_user(void * kernel, const void * user, uint32_t n);
/* the length of the string at s if all of it (and its final 0) is user
   memory and it is shorter than max, else -1 */
int __mem_userString(const char * s, uint32_t max);
/* a NULL-terminated vector of strings (argv): 0 if all of it is user
   memory, else -1 */
int __mem_userVector(char ** v, uint32_t max_entries, uint32_t max_len);

#endif

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

#define __LAST_LINEAR_PAGE 0xFFFFF
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
#define PF_NOTPRESENT      0x0

/* this is used to allocate kernel pages in user space */
#define PF_SUPERVISOR_IN_USER_SPACE 0x1000

/************************************************************************
*                   PAGE DIRECTORY AND PAGE TABLES STUFF                *
************************************************************************/

/* this macro takes the page dir index (DIR), the page table index (TAB), 
   the offset between the page frame (OFFSET) and calculate the linear 
   address */
#define __MEM_LINEAR_ADDRESS(DIR,TAB,OFFSET) \
                     (((DIR)<<22) | ((TAB)<<12) | (OFFSET))

/* given a linear address, these macros return the corresponding
   index in the page dir, in the page table and the offset */
#define __ADDRESS_PD_INDEX(ADDRESS)    (((ADDRESS)>>22) & 0x3FF)
#define __ADDRESS_PT_INDEX(ADDRESS)    (((ADDRESS)>>12) & 0x3FF)
#define __ADDRESS_OFFSET(ADDRESS)      ((ADDRESS)       & 0xFFF)

/* given a absolute page frame index, these macros return the corresponding
   index in the page dir and in the page table
   e.g. the page frame index of address 0x402000 is 0x402, then:
        __PAGE_PD_INDEX(0x402) -> 1   // it's pointed by the pd entry '1'...
        __PAGE_PT_INDEX(0x402) -> 2   // ...and by the pt entry '2'
 */
#define __PAGE_PD_INDEX(PAGE)          (((PAGE)>>10)    & 0x3FF)
#define __PAGE_PT_INDEX(PAGE)          ((PAGE)          & 0x3FF)

/* return a linear address to access the entry ENTRY in the 
   current page directory */
#define __GET_PAGE_DIR_ENTRY(ENTRY) \
                     __MEM_LINEAR_ADDRESS(LAST_PDPT_INDEX - 1,\
                                           LAST_PDPT_INDEX, (ENTRY)*4)

/* return a linear address to access the entry ENTRY in the 
   page table TABLE */
#define __GET_PAGE_TABLE_ENTRY(TABLE, ENTRY) \
                     __MEM_LINEAR_ADDRESS(LAST_PDPT_INDEX,\
                                          (TABLE), (ENTRY)*4)

/* true if the entry ENTRY, in the page directory, points to a present
   page table */
#define __IS_PAGE_TABLE_PRESENT(ENTRY) \
                     ((*(uint32_t*)(__GET_PAGE_DIR_ENTRY(ENTRY))) & 0x1)
#define __IS_PAGE_TABLE_FREE(ENTRY) (!__IS_PAGE_TABLE_PRESENT(ENTRY))

/* as above but from the address */
#define __IS_PAGE_TABLE_PRESENT_GIVEN_LINEAR_ADDRESS(ADDRESS)\
                     __IS_PAGE_TABLE_PRESENT(__ADDRESS_PD_INDEX(ADDRESS))
#define __IS_PAGE_TABLE_FREE_GIVEN_LINEAR_ADDRESS(ADDRESS)\
                     (!__IS_PAGE_TABLE_PRESENT_GIVEN_LINEAR_ADDRESS(ADDRESS))

/* set a linear page as allocated */
#define __SET_PAGE_TABLE_ENTRY(TABLE, ENTRY, FLAGS)\
                     {\
                      uint32_t * pun = (uint32_t*)__GET_PAGE_TABLE_ENTRY(TABLE, ENTRY);\
                      *pun = FLAGS | PF_LOGICAL_PRESENT;\
                     }

/* map a linear page to a physical one */
#define __SET_PAGE_TABLE_ENTRY_AND_ALLOC(TABLE, ENTRY, PAGE_PHY_ADDRESS, \
					 FLAGS) \
                     {\
                      uint32_t * pun = (uint32_t*)__GET_PAGE_TABLE_ENTRY(TABLE, ENTRY);\
                      *pun = (PAGE_PHY_ADDRESS) | FLAGS | PF_PRESENT; \
                      pmem_set((PAGE_PHY_ADDRESS)>>12);\
                     }


/* define a new page table: it adjusts the corresponding page dir entry and
   the page tables mapping on the last page table */
#define __SET_PAGE_DIR_ENTRY(ENTRY, PAGE_TAB_PHY_ADDRESS) \
                     {\
                      uint32_t * pun  = (uint32_t*)__GET_PAGE_DIR_ENTRY(ENTRY);\
                      uint32_t * pun2 = (uint32_t*)__GET_PAGE_TABLE_ENTRY(\
                                                LAST_PDPT_INDEX,\
                                                ENTRY);\
                      *pun = (PAGE_TAB_PHY_ADDRESS) | \
                             PF_USER | PF_READWRITE |PF_PRESENT;\
                      *pun2 = *pun;\
                      pmem_set((PAGE_TAB_PHY_ADDRESS)>>12);\
                     }

/* true if the linear page frame ENTRY is present. Use it ONLY if you
 are SURE that the page table for this page it exists */
#define __IS_PAGE_PRESENT(ENTRY) \
		     ((*((uint32_t*)__GET_PAGE_TABLE_ENTRY( \
                                      __PAGE_PD_INDEX(ENTRY), \
				      __PAGE_PT_INDEX(ENTRY)))) & \
                                         (PF_LOGICAL_PRESENT | PF_PRESENT | PF_PAGER))

#define __IS_PAGE_FREE(ENTRY) (!__IS_PAGE_PRESENT(ENTRY))


/* shortcut to change the external process VM mapping */
#define __EXTERNAL_VMSPACE_TABLE (_asm_last_kernel_page_dir_entry_used - 1)
#define __EXTERNAL_VMSPACE_ENTRY (LAST_PDPT_INDEX)
#define __EXTERNAL_VMSPACE_PAGE_ENTRY ((uint32_t*)(__GET_PAGE_TABLE_ENTRY(__EXTERNAL_VMSPACE_TABLE, __EXTERNAL_VMSPACE_ENTRY)))
#define __EXTERNAL_VMSPACE_PAGE ((uint32_t*)(__MEM_LINEAR_ADDRESS(__EXTERNAL_VMSPACE_TABLE, __EXTERNAL_VMSPACE_ENTRY, 0)))

/* shortcut to change the cow page */
#define __COW_TABLE (_asm_last_kernel_page_dir_entry_used - 1)
#define __COW_ENTRY (LAST_PDPT_INDEX - 1)
#define __COW_PAGE_ENTRY ((uint32_t*)(__GET_PAGE_TABLE_ENTRY(__COW_TABLE, __COW_ENTRY)))
#define __COW_PAGE ((uint32_t*)(__MEM_LINEAR_ADDRESS(__COW_TABLE, __COW_ENTRY, 0)))

/* reset the entries in a new page directory */
#define INIT_PAGE_DIR(ADDRESS) \
                     {\
                      uint32_t * pun = (uint32_t *)(ADDRESS);\
                      uint32_t i;\
                      for(i = 0; i <= LAST_PDPT_INDEX; i++) {\
                        *pun = 0;\
                        pun++;\
                      }\
                     }
                        
/* reset the entries in a new page table */
#define INIT_PAGE_TABLE(ADDRESS) \
                     {\
                      uint32_t * pun = (uint32_t *)(ADDRESS);\
                      uint32_t i;\
                      for(i = 0; i <= LAST_PDPT_INDEX; i++) {\
                        *pun = 0;\
                        pun++;\
                      }\
                     }
                        
/* given a linear address, it returns the physical one. Be sure the address
   is really a valid one */
#define LINEAR_TO_PHYSICAL_ADDRESS(LADDRESS) \
        (((*((uint32_t*)__GET_PAGE_TABLE_ENTRY( \
                             __ADDRESS_PD_INDEX((uint32_t) (LADDRESS)), \
		             __ADDRESS_PT_INDEX((uint32_t) (LADDRESS))))) & 0xFFFFF000) | \
         __ADDRESS_OFFSET((uint32_t) (LADDRESS)))


/* invalidate the cache: for 386 the cr3 must be reload */
#ifdef ARCH386
#define INVALIDATE_THE_CACHE(LADDR) \
  __asm__ volatile ("pushl %eax\n"\
		    "movl  %cr3, %eax\n"\
		    "movl  %eax, %cr3\n"\
		    "popl  %eax\n")
#else
#define INVALIDATE_THE_CACHE(LADDR) \
  __asm__ volatile ("invlpg %0\n"::"m"(*((uint32_t*)(LADDR))))
#endif



extern byte_t * __memory_bitmap;
extern uint32_t __memory_bitmap_size;
extern uint32_t __number_of_free_physical_pages;
extern uint32_t __total_phy_pages;

/* to call in mynos_main() */
void init_memory();
void mem_reserveAtBoot(uint32_t start, uint32_t len);

/* return value:
   'pageaddr' on success
   'NULL'     if some problem occours
*/
void * __OS_mapPhysical(uint32_t phys, uint32_t npages);
#define DMA_AREA_SIZE 0x10000
extern uint32_t __dma_area;
void * __OS_mapDmaArea(void);
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
void _page_fault_handler(uint32_t addr, uint32_t errcode, uint32_t * frame); /* ... and the 
							      real handler */
/* special cases */
// it returns the new copy physical address
uint32_t __mem_copyPageToCOWSpace(uint32_t addr);
void __mem_cowManager(uint32_t addr);
void __mem_allocateOnUse(uint32_t addr);

/* Pointers from processes. The user part of a process's linear space runs
   from USERMINPAGE to the bottom of its kernel stack (process.c: the
   process info pages and the kernel stack sit above the user stack, under
   the page table mirrors). */
#define USER_AREA_START ((uint32_t)USERMINPAGE << 12)
#define USER_AREA_END   ((uint32_t)(0 - (0x400000 + 0x1000)) - \
                         PAGE_SIZE * (PROCESS_INFO_NPAGES + KERNEL_STACK_NPAGES))

/* is [start, start + size) memory of the current process the kernel may
   read or write for it? user pages, allocated or to be allocated on use;
   no wrap around; never the kernel's */
int __mem_userArea(const void * start, uint32_t size);
/* end the current process for an invalid access at addr */
void __mem_userSegfault(uint32_t addr);
/* pager.c: a user thread's fault on a page given to the external pager
   (entry: its page table entry); returns once the page is there */
void __pager_fault(uint32_t entry, uint32_t addr, uint32_t errcode);
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

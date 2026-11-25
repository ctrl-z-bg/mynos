/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The i386's page tables (doc/decisions/x86-64.md, choice 4): two levels,
 * a page directory of 1024 entries and page tables of 1024, 4 KB pages.
 * The current address space's tables are reached through the directory's
 * last entry, which points at the directory itself ("recursive"): table
 * i at 0xFFC00000 + 4 KB x i, the directory at 0xFFBFF000.
 *
 * Generic code uses pte_t, PTE_FRAME and the functions at the end; the
 * macros above them are the i386's own, used by the code that is still
 * the i386's (process creation, fork, another process's memory).
 */

#ifndef __PAGING_H__
#define __PAGING_H__

typedef uint32_t pte_t;
#define PTE_FRAME(E)     ((paddr_t)((E) & 0xFFFFF000))
#define PTE_FLAGS(E)     ((E) & 0xFFF)
#define PAGES_PER_TABLE  1024           /* the pages one leaf table maps */

/* the kernel's pages: below its last page directory entry, which stays
   empty (arch_init_kernel_space); the processes' from the next one */
#define ARCH_KERNEL_LAST_PAGE \
  ((_asm_last_kernel_page_dir_entry_used * FOURMB - PAGE_SIZE) >> 12)
#define ARCH_USER_FIRST_PAGE \
  (((_asm_last_kernel_page_dir_entry_used + 1) * FOURMB) >> 12)

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



/* the entry of [va] in the current address space; NULL if the table that
   would hold it does not exist */
static inline pte_t * arch_pte(vaddr_t va)
{
  if (!__IS_PAGE_TABLE_PRESENT(__ADDRESS_PD_INDEX(va))) return NULL;
  return (pte_t *)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(va), __ADDRESS_PT_INDEX(va));
}

/* the physical address of [va], mapped in the current address space */
static inline paddr_t arch_virt_to_phys(vaddr_t va)
{
  return LINEAR_TO_PHYSICAL_ADDRESS(va);
}

/* arch/i386/mm.c */
pte_t * arch_pte_make(vaddr_t va);
void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n);
void * arch_cow_window(paddr_t * phys);

#endif

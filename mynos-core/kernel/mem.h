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

#define __LAST_LINEAR_PAGE 0xFFFFF

/*************************************************************************
*                        MEMORY BITMAP STUFF                             *
*************************************************************************/

/* set a bit in the physical memory bitmap */
#define __SET_MEMORY_BITMAP_PAGE_BIT(PHY_PAGE) \
                     {\
                      __memory_bitmap[(PHY_PAGE) / 8] |= (1<<((PHY_PAGE)%8));\
                      __number_of_free_physical_pages--;\
                     }

/* reset a bit in the physical memory bitmap */
#define __RESET_MEMORY_BITMAP_PAGE_BIT(PHY_PAGE) \
                     {\
                      __memory_bitmap[(PHY_PAGE) / 8] &= ~(1<<((PHY_PAGE)%8));\
                      __number_of_free_physical_pages++;\
                     }

/* true if the page is not allocated */
#define __IS_PHYSICAL_PAGE_FREE(PHY_PAGE) \
                     (!(__memory_bitmap[(PHY_PAGE) / 8] & (1<<((PHY_PAGE)%8))))

/* it returns a byte from the memory bitmap */
#define __GET_MEMORY_BITMAP_BYTE(B) (__memory_bitmap[B])

/* given a byte and a bit in the memory bitmap, it returns the corresponding
   page number */
#define __MEMORY_BITMAP_BIT_TO_PAGE(BYTE, BIT) (8*(BYTE) + (BIT))

/************************************************************************
*                        END OF MEMORY BITMAP STUFF                     *
************************************************************************/



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
                     __MEM_LINEAR_ADDRESS(_asm_last_page_dir_entry_used - 1,\
                                           1023, (ENTRY)*4)

/* return a linear address to access the entry ENTRY in the 
   page table TABLE */
#define __GET_PAGE_TABLE_ENTRY(TABLE, ENTRY) \
                     __MEM_LINEAR_ADDRESS(_asm_last_page_dir_entry_used,\
                                          (TABLE), (ENTRY)*4)

/* true if the entry ENTRY, in the page directory, points to a present
   page table */
#define __IS_PAGE_TABLE_PRESENT(ENTRY) \
                     ((*(uint32_t*)(__GET_PAGE_DIR_ENTRY(ENTRY))) & 0x1)
#define __IS_PAGE_TABLE_FREE(ENTRY) __IS_PAGE_TABLE_PRESENT(ENTRY)

/* as above but from the address */
#define __IS_PAGE_TABLE_PRESENT_GIVEN_LINEAR_ADDRESS(ADDRESS)\
                     __IS_PAGE_TABLE_PRESENT(__ADDRESS_PD_INDEX(ADDRESS))
#define __IS_PAGE_TABLE_FREE_GIVEN_LINEAR_ADDRESS(ADDRESS)\
                     __IS_PAGE_TABLE_PRESENT_GIVEN_LINEAR_ADDRESS(ADDRESS)

/* map a linear page to a physical one */
#define __SET_PAGE_TABLE_ENTRY(TABLE, ENTRY, PAGE_PHY_ADDRESS) \
                     {\
                      int * pun = (int*)__GET_PAGE_TABLE_ENTRY(TABLE, ENTRY);\
                      *pun = (PAGE_PHY_ADDRESS) | 0x1; /* present bit */\
                      __SET_MEMORY_BITMAP_PAGE_BIT((PAGE_PHY_ADDRESS)>>12);\
                     }

/* define a new page table: it adjusts the corresponding page dir entry and
   the page tables mapping on the last page table */
#define __SET_PAGE_DIR_ENTRY(ENTRY, PAGE_TAB_PHY_ADDRESS) \
                     {\
                      int * pun  = (int*)__GET_PAGE_DIR_ENTRY(ENTRY);\
                      int * pun2 = (int*)__GET_PAGE_TABLE_ENTRY(\
                                                _asm_last_page_dir_entry_used,\
                                                ENTRY);\
                      *pun = (PAGE_TAB_PHY_ADDRESS) | 0x1;\
                      *pun2 = *pun;\
                      __SET_MEMORY_BITMAP_PAGE_BIT((PAGE_TAB_PHY_ADDRESS)>>12);\
                     }

/* true if the linear page frame ENTRY is present. Use it ONLY if you
 are SURE that the page table for this page it exists */
#define __IS_PAGE_PRESENT(ENTRY) \
		     ((*((uint32_t*)__GET_PAGE_TABLE_ENTRY( \
                                             __PAGE_PD_INDEX(ENTRY), \
				             __PAGE_PT_INDEX(ENTRY)))) & 0x1)
#define __IS_PAGE_FREE(ENTRY) __IS_PAGE_PRESENT(ENTRY)

/* reset the entries in a new page directory */
#define INIT_PAGE_DIR(ADDRESS) \
                     {\
                      uint32_t * pun = (uint32_t *)(ADDRESS);\
                      uint32_t i;\
                      for(i = 0; i < 1024; i++) {\
                        *pun = 0;\
                        pun++;\
                      }\
                     }
                        
/* reset the entries in a new page table */
#define INIT_PAGE_TABLE(ADDRESS) \
                     {\
                      uint32_t * pun = (uint32_t *)(ADDRESS);\
                      uint32_t i;\
                      for(i = 0; i < 1024; i++) {\
                        *pun = 0;\
                        pun++;\
                      }\
                     }
                        

extern byte_t * __memory_bitmap;
extern uint32_t __memory_bitmap_size;
extern uint32_t __number_of_free_physical_pages;

/* to call in mynos_main() */
void init_memory();

/* return value:
   'pageaddr' on success
   'NULL'     if some problem occours
*/
void * __OS_askPagesFrom(void * pageaddr, unsigned int npages);

void * __OS_askPages(unsigned int npages);
void * __OS_releasePages(void *pageaddr, unsigned int npages);

/* return the id of a free physical page */
uint32_t __pg_find_a_free_physical_page();

/* - if 'npages' is 0 then the number of free linear pages, starting, 
     from 'first_page', is returned.
   - if 'npages' is not 0 then the search is stopped after 'npages'.
   'new_pt_required' is filled with the number of new page tables required.
*/
uint32_t __pg_free_pages_from_page(uint32_t first_page, uint32_t npages,
	 			   uint32_t * new_pts_required);


#endif

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

#include "mem.h"
#include "video.h"

byte_t * __memory_bitmap;
uint32_t __memory_bitmap_size;
uint32_t __number_of_free_physical_pages;

void init_memory() {
  uint32_t i;
  uint32_t first_free_phy_page = (_asm_first_free_physical_page_address>>12);
  uint32_t total_phy_pages = (_asm_global_mem_size*256);

  __memory_bitmap = (byte_t*)__MEMORY_BITMAP_PHY_ADDRESS;
  __memory_bitmap_size = total_phy_pages / 8;

  __number_of_free_physical_pages = total_phy_pages;

  /* let the memory bitmap be coerent with the actual physical memory
     allocation (from 0 to _asm_first_free_physical_page_address - 1) */
  for (i = 0; i < __memory_bitmap_size; i++)  // reset the bitmap
    __memory_bitmap[i] = 0x0;
  for (i = 0; i < first_free_phy_page; i++)   // set bitmap for paged already
    __SET_MEMORY_BITMAP_PAGE_BIT(i);          // allcoated
}

void * __OS_askPages(unsigned int npages) {return (void*)0;}
void * __OS_releasePages(void *pageaddr, unsigned int npages) {return (void*)0;}


uint32_t __pg_find_a_free_physical_page() {
  static uint32_t current_page = 0;
  uint32_t current_byte        = current_page / 8;
  uint32_t old_current_byte    = current_byte;
  uint32_t memory_full         = 0;
  uint32_t i;

  if (__IS_PHYSICAL_PAGE_FREE(current_page))
    return current_page;

  /* find the first 8 page group where I can find a free page */
  while (!memory_full && !(~(__GET_MEMORY_BITMAP_BYTE(current_byte)))) {
    current_byte = (current_byte+1) % __memory_bitmap_size;
    if (current_byte == old_current_byte)
      memory_full = 1;
  }

  /* memory full */
  if (memory_full)
    return 0;          // page 0 is always reserved and so it cannot be free

  /* search for the first bit unused in the new current_byte */
  current_page = __MEMORY_BITMAP_BIT_TO_PAGE(current_byte, 0);
  for (i = 0; i < 8; i++) {
    if (__IS_PHYSICAL_PAGE_FREE(current_page))
      return current_page;
    else
      current_page++;
  }

  KPANIC("KERNEL ERROR IN __find_first_free_physical_page");
}



void * __OS_askPagesFrom(void * pageaddr, unsigned int npages) {
  uint32_t page;
  uint32_t first_page = (((uint32_t)pageaddr)>>12);
  uint32_t last_page  = (first_page + npages -1);
  uint32_t new_pts_required = 0;     // how many new page tables are required
  uint32_t free_pages;

  if (npages < 1)
    return NULL;

  /* I don't check the last_page because the last linear page is already
     allocated */

  free_pages = __pg_free_pages_from_page(first_page, npages, 
					 &new_pts_required);

  /* are there npages free pages? */
  if (free_pages != npages)
    return NULL;

  /* TO BE CHANGED WHEN SWAPPING WILL BE ADDED!!! */
  if ((npages+new_pts_required) > __number_of_free_physical_pages)
    return NULL;

  /* ok, now we're going to serve the request */
  for (page = first_page; page <= last_page; page++) {
    /* if the page table for 'page' doesn't exist, we create it */
    if (!__IS_PAGE_TABLE_PRESENT(__PAGE_PD_INDEX(page))) {
      uint32_t newptaddr = (__pg_find_a_free_physical_page() << 12);
      INIT_PAGE_TABLE((uint32_t*)newptaddr);
      __SET_PAGE_DIR_ENTRY(__PAGE_PD_INDEX(page), newptaddr);
    }

    __SET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page),
			   __PAGE_PT_INDEX(page),
			   (__pg_find_a_free_physical_page() << 12));
  }
	
  return pageaddr;
}


uint32_t __pg_free_pages_from_page(uint32_t first_page, uint32_t npages,
				   uint32_t * new_pts_required) {
  uint32_t page;
  uint32_t last_page;
  uint32_t last_pt_required = 12345; // an invalid value :)
  uint32_t new_pts = 0;     // how many new page tables are required

  if (npages != 0)
    last_page = (first_page + npages -1);
  else
    last_page = __LAST_LINEAR_PAGE;

  for (page = first_page; page <= last_page; page++) {
    if (!__IS_PAGE_TABLE_PRESENT(__PAGE_PD_INDEX(page))) {
      if (last_pt_required != __PAGE_PD_INDEX(page)) {  /* did I have already
							   added this pt? */
	last_pt_required = __PAGE_PD_INDEX(page);
	new_pts++;
      }
    } else
      if (__IS_PAGE_PRESENT(page)) { // page is not free
	*new_pts_required = new_pts;
	return (page - first_page);
      }
  }

  *new_pts_required = new_pts;
  return (page - first_page);
}

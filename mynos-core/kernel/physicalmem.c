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
#include "dynalloc.h"
#include "kutils.h"
#include "video.h"
#include "physicalmem.h"

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


static pmemdes_t pmemdes;
/* initialised == 1 if the physical memory manager has been created */
static uint32_t  initialized = 0;

void pmem_createPhyMemManager() {
  uint32_t i;

  /* ok, I'm creating the manager */
  initialized = 1;

  /* allocate space for the new bitmap location */
  pmemdes.bitmap = kmalloc(__memory_bitmap_size);
  pmemdes.page   = kmalloc(__total_phy_pages *
			   sizeof(ppagedes_t));

  /* copy here the temporary staticaly allocated physical memory bitmap */
  kmemcpy(pmemdes.bitmap, __memory_bitmap, __memory_bitmap_size);
  __memory_bitmap = pmemdes.bitmap;

  /* initialize the physical memory pages descriptors */
  for (i = 0; i < __total_phy_pages; i++) {
    if (!__IS_PHYSICAL_PAGE_FREE(i)) {
      pmemdes.page[i].countref = 1;
      // TODO FLAGS!!!
    } else {
      pmemdes.page[i].countref = 0;
      // TODO FLAGS!!!
    }
  }
}

void pmem_set(uint32_t page) {
  /* if the manager is not yet created I do the basic stuff */
  if (!initialized) {
    __SET_MEMORY_BITMAP_PAGE_BIT(page);
    return;
  }

  if (pmemdes.page[page].countref == 0) {
    __SET_MEMORY_BITMAP_PAGE_BIT(page);
    pmemdes.page[page].countref = 1;
    pmemdes.page[page].flags = 0;
  } else
    pmemdes.page[page].countref++;
}

void pmem_unset(uint32_t page) {
  /* if the manager is not yet created I do the basic stuff */
  if (!initialized) {
    __RESET_MEMORY_BITMAP_PAGE_BIT(page);
    return;
  }

  if (pmemdes.page[page].countref == 0)
    KPANIC("pmem_unset: PHYSICAL MEMORY INCONSISTENT!!!");

  pmemdes.page[page].countref--;
  if (pmemdes.page[page].countref == 0)
    __RESET_MEMORY_BITMAP_PAGE_BIT(page);
}

ushort16_t pmem_countref(uint32_t page) {
  return pmemdes.page[page].countref;
}

uint32_t pmem_findAFreePhysicalPage() {
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
    return 0;          /* page 0 is always reserved and so it cannot be free */

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


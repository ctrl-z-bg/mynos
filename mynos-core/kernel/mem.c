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

#define NEWMEM

#include "mem.h"
#include "gdt.h"
#include "video.h"
#include "kutils.h"
#include "process.h"
#include "physicalmem.h"

byte_t * __memory_bitmap;
uint32_t __memory_bitmap_size;
uint32_t __number_of_free_physical_pages;
uint32_t __total_phy_pages;

static void __cowManager(uint32_t * pte, uint32_t addr);
static void __allocateOnUse(uint32_t * pte, uint32_t addr);

void init_memory() {
  uint32_t i;
  uint32_t * tmp;
  uint32_t first_free_phy_page = (_asm_first_free_physical_page_address>>12);

  __total_phy_pages = (_asm_global_mem_size*256);

  __memory_bitmap = (byte_t*)__MEMORY_BITMAP_PHY_ADDRESS;
  __memory_bitmap_size = __total_phy_pages / 8;

  __number_of_free_physical_pages = __total_phy_pages;

  /* let the memory bitmap be coerent with the actual physical memory
     allocation (from 0 to _asm_first_free_physical_page_address - 1) */
  for (i = 0; i < __memory_bitmap_size; i++)  /* reset the bitmap */
    __memory_bitmap[i] = 0x0;
  for (i = 0; i < first_free_phy_page; i++)   /* set bitmap for pages already 
						 allocated */
    pmem_set(i);
  //__SET_MEMORY_BITMAP_PAGE_BIT(i);

  _init_gdt();

  /* let the first (_asm_last_kernel_page_dir_entry_used + 1) PTs 
     be allocated (to be share by all processes).
     we'll use the kernel space's last PT to map the page tables of
     another process, so, for the moment, we tag it as allocated.
  */
  printk("Allocating the first ");
  print_ulong(_asm_last_kernel_page_dir_entry_used + 1);
  printk(" PTs...");
  for (i = 0; i < _asm_last_kernel_page_dir_entry_used; i++)
    if (__IS_PAGE_TABLE_FREE(i)) {
      uint32_t newptaddr = (pmem_findAFreePhysicalPage() << 12);
      __SET_PAGE_DIR_ENTRY(i, newptaddr);
      INIT_PAGE_TABLE(__GET_PAGE_TABLE_ENTRY(i, 0));
    }
  __SET_PAGE_DIR_ENTRY(_asm_last_kernel_page_dir_entry_used, 0);
  printk(" done\n");

  /*
    we'll use the kernel space's last but one PT to temporary
    management tasks:
      - last entry: to map the page directory of another process
      - last but one entry: to map the new page for a copy-on-write
                          option
  */
  tmp = __EXTERNAL_VMSPACE_PAGE_ENTRY;
  *tmp = 0x1; // tagged as allocated
  tmp = __COW_PAGE_ENTRY;
  *tmp = 0x1; // tagged as allocated

  /* create the real physical memory manager*/
  pmem_createPhyMemManager();
}

void * __OS_askPages(unsigned int npages, int alloc_now, uint32_t flags) {
  uint32_t page_addr;
  uint32_t last_page;
  uint32_t not_used;

  if ((flags & PF_USER) || (flags & PF_SUPERVISOR_IN_USER_SPACE)) {
    page_addr = ((_asm_last_kernel_page_dir_entry_used+1) * FOURMB)>>12;
    last_page = __LAST_LINEAR_PAGE;
    flags &= (~PF_SUPERVISOR_IN_USER_SPACE); // remove, if present
  } else {
    page_addr = 0;
    last_page = ((_asm_last_kernel_page_dir_entry_used+1) * FOURMB - 
		 PAGE_SIZE) >> 12;
  }

  // TO TEST THE LINEAR SPACE MAP!!!
#ifdef NEWMEM
  if ((flags & PF_USER) || (flags & PF_SUPERVISOR_IN_USER_SPACE)) {
    uint32_t start = __lmt_allocArea(&(processTable[currProcess].lmemmap), 
				     npages);
    //printk("====   "); print_uint_hex(start);
    return __OS_askPagesFrom((void *)(start<<12), npages, alloc_now,
			     flags);
  }
#endif

  for (; page_addr <= last_page; page_addr++) {
    if (__pg_free_pages_from_page(page_addr, npages, &not_used) == npages)
      return __OS_askPagesFrom((void *)(page_addr<<12), npages, alloc_now,
			       flags);
  }

  page_addr = 0x0;

  return (void*)0;
}

void * __OS_askPagesFrom(void * pageaddr, unsigned int npages,
			 int alloc_now, uint32_t flags) {
  uint32_t page;
  uint32_t first_page = (((uint32_t)pageaddr)>>12);
  uint32_t last_page  = (first_page + npages -1);
  uint32_t new_pts_required = 0;     /* how many new page tables are 
					required */
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
  if (alloc_now &&
      ((npages+new_pts_required) > __number_of_free_physical_pages))
  return NULL;

  /* ok, now we're going to serve the request */
  for (page = first_page; page <= last_page; page++) {
    /* if the page table for 'page' doesn't exist, we create it */
    if (!__IS_PAGE_TABLE_PRESENT(__PAGE_PD_INDEX(page))) {
      uint32_t newptaddr = (pmem_findAFreePhysicalPage() << 12);

      __SET_PAGE_DIR_ENTRY(__PAGE_PD_INDEX(page), newptaddr);
      INIT_PAGE_TABLE(__GET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page), 0));
    }

    if (alloc_now)
      __SET_PAGE_TABLE_ENTRY_AND_ALLOC(__PAGE_PD_INDEX(page),
				       __PAGE_PT_INDEX(page),
				       (pmem_findAFreePhysicalPage() << 12),
				       flags)
    else
      __SET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page),
			     __PAGE_PT_INDEX(page),
			     flags);
  }
	
  return pageaddr;
}

void * __OS_releasePages(void *pageaddr, unsigned int npages, 
			 int free, int check) {
  uint32_t addr = (uint32_t)pageaddr;
  uint32_t * pte;
  uint32_t phyaddr;
  uint32_t i;

#ifdef NEWMEM
  if ((addr >> 12) >= USERMINPAGE) // if it's user space
    if (__lmt_freeArea(&(processTable[currProcess].lmemmap),
		       (addr >> 12),
		       npages) != 0)
      printk("Problems releasing pages\n");
#endif

  for (i = 0; i < npages; i++) {
    /* check if the page dir entry is valid */
    if (check &&
	((*(uint32_t*)__GET_PAGE_DIR_ENTRY(__ADDRESS_PD_INDEX(addr)) &
	  PF_PRESENT) == 0))
      return NULL;
    
    /* get the page table entry */
    pte = (int*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
				       __ADDRESS_PT_INDEX(addr));
    
    /* check if the page is an allocated user page */
    if (check &&
	(!(*pte & (PF_PRESENT | PF_LOGICAL_PRESENT)) ||
	 !(*pte & PF_USER)))
      return NULL;
    
#ifdef DEBUG
    printk(__FUNCTION__": releasing page ");
    print_uint_hex(addr);
#endif    
    /* free the physical page only if the page is really allocated */
    if (free && (*pte & PF_PRESENT)) {
      phyaddr = (*pte) & 0xFFFFF000;
      pmem_unset(phyaddr>>12);
      //__RESET_MEMORY_BITMAP_PAGE_BIT(phyaddr>>12);
#ifdef DEBUG
      printk(" (phy: ");
      print_uint_hex(phyaddr);
      print_char(')');
#endif    
    }
#ifdef DEBUG
    print_char('\n');
#endif    
    
    /* let's zero the page table entry */
    *pte = 0;
    
    /* invalidate the cache */
    INVALIDATE_THE_CACHE(addr);
    addr += PAGE_SIZE;
  }

  return pageaddr;
}
  




uint32_t __pg_free_pages_from_page(uint32_t first_page, uint32_t npages,
				   uint32_t * new_pts_required) {
  uint32_t page;
  uint32_t last_page;
  uint32_t last_pt_required = 12345; /* an invalid value :) */
  uint32_t new_pts = 0;     /* how many new page tables are required */

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
      if (__IS_PAGE_PRESENT(page)) { /* page is not free */
	*new_pts_required = new_pts;
	return (page - first_page);
      }
  }

  *new_pts_required = new_pts;
  return (page - first_page);
}

void SEG_createStandardDescriptor(uint32_t * address,
				  uint32_t base, uint32_t limit, 
				  ushort16_t control) {
  union DT_entry newdesc = stnd_desc(base, limit, control);

  kmemcpy((void *)address, (const void *)&newdesc, sizeof(union DT_entry));
}


extern void _page_fault_handler_TRAP();
__asm__ (\
	 ".globl _page_fault_handler_TRAP \n"\
	 "_page_fault_handler_TRAP:       \n"\
	 "   movl %eax, (0)               \n"\
	 "   popl %eax                    \n"  /* retrieve error code */\
         "   pushal                       \n"  /* save all registers */\
	 "   pushl %eax                   \n"  /* push error code */\
	 "   movl %cr2, %eax              \n"\
	 "   pushl %eax                   \n"  /* push faulting address */\
	 "   call _page_fault_handler     \n"  /* call the ISR handler */\
	 "   popl %eax                    \n"  /* pop the address */\
	 "   popl %eax                    \n"  /* pop the error code */\
	 "   popal                        \n"\
	 "   movl (0), %eax               \n"\
	 "   iret                         \n"\
	 );

/* exported functions for special cases (cow, alloc-on-write) */

void __mem_cowManager(uint32_t addr) {
  uint32_t * pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
						     __ADDRESS_PT_INDEX(addr));
  __cowManager(pte, addr);
}

void __mem_allocateOnUse(uint32_t addr) {
  uint32_t * pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
						     __ADDRESS_PT_INDEX(addr));
  __allocateOnUse(pte, addr);
}


uint32_t __mem_copyPageToCOWSpace(uint32_t addr) {
    void * dest;
    void * orig;
    
#ifdef DEBUG
    printk("So let's copy it!\n");
#endif

    /* alloc a new physical page to the COW tmp linear address */
    __SET_PAGE_TABLE_ENTRY_AND_ALLOC(__COW_TABLE,
				     __COW_ENTRY,
				     (pmem_findAFreePhysicalPage() << 12),
				     0);
    
    /* reload the cache corresponding to the current cow page */
    INVALIDATE_THE_CACHE((void*)__COW_PAGE);
    
    /* copy the faulting page to the new one */
    dest = (void*)__COW_PAGE;
    orig = (void*)(addr & 0xFFFFF000);
    kmemcpy(dest, orig, PAGE_SIZE);
    
    return LINEAR_TO_PHYSICAL_ADDRESS(dest);
}


/* the copy-on-write code */
static void __cowManager(uint32_t * pte, uint32_t addr) {
#ifdef DEBUG
  printk("There are ");
  print_ulong(pmem_countref((*pte)>>12));
  printk(" references\n");
#endif
  
  /* if I'm the last referencing process then the page is mine! */
  if (pmem_countref((*pte)>>12) == 1) {
#ifdef DEBUG
    printk("So now it's mine!\n");
#endif
    *pte = *pte & ~PF_COW;
    *pte |= PF_READWRITE;
    INVALIDATE_THE_CACHE(addr);
  } else { // else...
    uint32_t paddr = __mem_copyPageToCOWSpace(addr);

    /* unset the faulting page, the new page was already set by
       __SET_PAGE_TABLE_ENTRY_AND_ALLOC */
    pmem_unset((*pte)>>12);

    /* bind the linear page to the new physical one */
    *pte = paddr | (*pte & 0xFFF);
    *pte = *pte & ~PF_COW;
    *pte |= PF_READWRITE;
    INVALIDATE_THE_CACHE(addr);
  }
}

static void __allocateOnUse(uint32_t * pte, uint32_t addr) {
  uint32_t new_phy_page;
  uint32_t flags;
  
  flags = *pte & 0x7FF; /* save the page flags, but not the 
			   PF_LOGICAL_PRESENT */
  new_phy_page = (pmem_findAFreePhysicalPage()<<12);
  *pte = new_phy_page | flags | PF_PRESENT;
  pmem_set((new_phy_page)>>12);
  //__SET_MEMORY_BITMAP_PAGE_BIT((new_phy_page)>>12);
  
  // QUESTION: should be invalidated now? To be sure...
  INVALIDATE_THE_CACHE(addr);
#ifdef DEBUG
  printk("new allocated page: ");
  print_ulong_hex(new_phy_page);
  print_char('\n');
  print_char('\n');
#endif
}

extern uint32_t currProcess;
void _page_fault_handler(uint32_t addr, uint32_t errcode) {
  uint32_t * pte;

#ifdef DEBUG
  print_char('\n');
  print_char('\n');
  printk("Process ");
  print_uint(currProcess);
  printk(" thread ");
  print_uint(currThread->threadID);
  printk(" tried to access the linear address ");
  print_uint_hex(addr);
  print_char('\n');
  printk("and you got the errorcode ");
  print_uint_hex(errcode & 7);
  print_char('\n');
  printk("It means ");
  if (errcode & 1)
    printk("page present ");
  else
    printk("not present ");

  if (errcode & 2)
    printk("on a write ");
  else
    printk("on a read ");

  if (errcode & 4)
    printk("in user mode\n");
  else
    printk("in superuser mode\n");
#endif

  /* check if the page table is allocated */
  if ((*(uint32_t*)__GET_PAGE_DIR_ENTRY(__ADDRESS_PD_INDEX(addr)) &
       PF_PRESENT) == 0)
    KPANIC("page fault (?)");

  pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
					  __ADDRESS_PT_INDEX(addr));
#ifdef DEBUG
  if ((*pte) & PF_LOGICAL_PRESENT)
    printk("but the page is tagged as allocated\n");
  if ((*pte) & PF_COW)
    printk("but the page is tagged as COPY-ON_WRITE\n");
#endif

  if (!((*pte) & PF_LOGICAL_PRESENT) &&
      !((*pte) & PF_COW)) // not allocated & not cow
    KPANIC("page fault");
  if (__number_of_free_physical_pages == 0)
    KPANIC("full memory!");

  if ((*pte) & PF_LOGICAL_PRESENT) { /* ALLOCATE ON USE */
    __allocateOnUse(pte, addr);
  } else if ((*pte) & PF_COW) {      /* COPY ON WRITE */
    __cowManager(pte, addr);
  } else KPANIC("MEMORY ERROR: NOT COW OR LOGICAL");
}


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
#include "sched.h"
#include "physicalmem.h"

byte_t * __memory_bitmap;
uint32_t __memory_bitmap_size;
uint32_t __number_of_free_physical_pages;
uint32_t __total_phy_pages;

static void __cowManager(uint32_t * pte, uint32_t addr);
static void __allocateOnUse(uint32_t * pte, uint32_t addr);

extern uint32_t currProcess;

/* Physical ranges already in use at boot outside the first 4MB (the
   multiboot modules), registered by mynos_main before init_memory so that
   no allocation can reuse them. */
#define MAX_BOOT_RESERVED 32
static uint32_t boot_reserved_start[MAX_BOOT_RESERVED];
static uint32_t boot_reserved_len[MAX_BOOT_RESERVED];
static uint32_t n_boot_reserved = 0;

void mem_reserveAtBoot(uint32_t start, uint32_t len) {
  if (n_boot_reserved < MAX_BOOT_RESERVED && len > 0) {
    boot_reserved_start[n_boot_reserved] = start;
    boot_reserved_len[n_boot_reserved] = len;
    n_boot_reserved++;
  }
}

/* The DMA area (mynos-7jn): 64 KB of RAM below 16 MB on a 64 KB
   boundary, as ISA DMA needs (a sound card's: the 8237 reaches 16 MB, and
   a transfer does not cross 64 KB), chosen at boot where nothing was
   loaded, kept for ever, mapped for drivers by mapDmaArea. 0: none. */
uint32_t __dma_area = 0;

static int overlaps_boot_reserved(uint32_t start, uint32_t len) {
  uint32_t i;
  for (i = 0; i < n_boot_reserved; i++)
    if (start < boot_reserved_start[i] + boot_reserved_len[i] &&
	boot_reserved_start[i] < start + len)
      return 1;
  return 0;
}

/* Where: first between the kernel's page directory (1 MB to 0x105000)
   and its image (2 MB), a part of the first 4 MB that the kernel keeps
   but does not use (a bootloader may have put a small module there:
   GRUB does); else above 4 MB, below 16 MB, in pages still free (the
   modules are marked by then). */
static void reserve_dma_area(void) {
  uint32_t a, k, page;
  for (a = 0x110000; a + DMA_AREA_SIZE <= 0x1000000; a += DMA_AREA_SIZE) {
    if (a >= 0x200000 && a < 0x400000) continue;   /* the kernel, its stack */
    if (overlaps_boot_reserved(a, DMA_AREA_SIZE)) continue;
    if (a >= 0x400000) {
      for (k = 0; k < DMA_AREA_SIZE / PAGE_SIZE; k++) {
	page = (a >> 12) + k;
	if (__memory_bitmap[page / 8] & (1 << (page % 8))) break;
      }
      if (k < DMA_AREA_SIZE / PAGE_SIZE) continue;
      for (k = 0; k < DMA_AREA_SIZE / PAGE_SIZE; k++) pmem_set((a >> 12) + k);
    }
    __dma_area = a;
    return;
  }
}

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
  /* and for the multiboot modules (they may extend past the first 4MB) */
  for (i = 0; i < n_boot_reserved; i++) {
    uint32_t page = boot_reserved_start[i] >> 12;
    uint32_t last = (boot_reserved_start[i] + boot_reserved_len[i] - 1) >> 12;
    for (; page <= last && page < __total_phy_pages; page++)
      if (!(__memory_bitmap[page / 8] & (1 << (page % 8))))
	pmem_set(page);
  }
  //__SET_MEMORY_BITMAP_PAGE_BIT(i);
  reserve_dma_area();
  printk("DMA area (64 KB, ISA): ");
  if (__dma_area) print_uint_hex(__dma_area); else printk("none");
  printk("\n");

  /* start.asm identity-maps only the first 4MB: map the module pages above
     it at linear == physical too, so that modinfo addresses stay valid.
     This must happen before any allocation (the GDT is next): present
     entries keep __OS_askPages from handing out those linear addresses. */
  for (i = 0; i < n_boot_reserved; i++) {
    uint32_t page = boot_reserved_start[i] >> 12;
    uint32_t last = (boot_reserved_start[i] + boot_reserved_len[i] - 1) >> 12;
    for (; page <= last; page++) {
      if (page < first_free_phy_page) continue;
      if (__IS_PAGE_TABLE_FREE(__PAGE_PD_INDEX(page))) {
	uint32_t newptaddr = (pmem_findAFreePhysicalPage() << 12);
	__SET_PAGE_DIR_ENTRY(__PAGE_PD_INDEX(page), newptaddr);
	INIT_PAGE_TABLE(__GET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page), 0));
      }
      __SET_PAGE_TABLE_ENTRY_AND_ALLOC(__PAGE_PD_INDEX(page),
				       __PAGE_PT_INDEX(page),
				       page << 12, PF_READWRITE);
    }
  }

  _init_gdt();

  /* allocate the kernel's page tables now, so that every process shares
     them (a process copies the kernel's directory entries when it is
     made). The last entry of the kernel's gigabyte stays empty, and
     __OS_askPages never reaches it. (Until 2026 it pointed at physical
     page 0 "to tag it as allocated", with the user bit: low memory, where
     the page fault handler saves EAX, was read as a page table, and a
     program could choose what that table mapped: mynos-vm8.) */
  printk("Allocating the first ");
  print_ulong(_asm_last_kernel_page_dir_entry_used);
  printk(" PTs...");
  for (i = 0; i < _asm_last_kernel_page_dir_entry_used; i++)
    if (__IS_PAGE_TABLE_FREE(i)) {
      uint32_t newptaddr = (pmem_findAFreePhysicalPage() << 12);
      __SET_PAGE_DIR_ENTRY(i, newptaddr);
      INIT_PAGE_TABLE(__GET_PAGE_TABLE_ENTRY(i, 0));
    }
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

#ifndef NEWMEM
  if ((flags & PF_USER) || (flags & PF_SUPERVISOR_IN_USER_SPACE)) {
    page_addr = ((_asm_last_kernel_page_dir_entry_used+1) * FOURMB)>>12;
    last_page = __LAST_LINEAR_PAGE;
    flags &= (~PF_SUPERVISOR_IN_USER_SPACE); // remove, if present
  } else {
    page_addr = 0;
    last_page = ((_asm_last_kernel_page_dir_entry_used+1) * FOURMB - 
		 PAGE_SIZE) >> 12;
  }
#else
  // TO TEST THE LINEAR SPACE MAP!!!
  if ((flags & PF_USER) || (flags & PF_SUPERVISOR_IN_USER_SPACE)) {
    uint32_t start = __lmt_allocArea(&(processTable[currProcess]->lmemmap), 
				     npages);
    void * ret;
    if (start < USERMINPAGE) return NULL;   /* no room */
    flags &= (~PF_SUPERVISOR_IN_USER_SPACE); // remove, if present
    //printk("====   "); print_uint_hex(start);
    ret = __OS_askPagesFrom((void *)(start<<12), npages, alloc_now, flags);
    if (ret == NULL)   /* give the linear area back */
      __lmt_freeArea(&(processTable[currProcess]->lmemmap), start, npages);
    return ret;
  }
#endif

  /* the kernel's pages: below its last page directory entry, which stays
     empty (init_memory) */
  page_addr = 0;
  last_page = (_asm_last_kernel_page_dir_entry_used * FOURMB -
	       PAGE_SIZE) >> 12;
  for (; page_addr + npages - 1 <= last_page; page_addr++) {
    if (__pg_free_pages_from_page(page_addr, npages, &not_used) == npages)
      return __OS_askPagesFrom((void *)(page_addr<<12), npages, alloc_now,
			       flags);
  }

  page_addr = 0x0;

  return (void*)0;
}

/* physical memory that is not RAM (a device's: a frame buffer), mapped
   into the current process: its address, or NULL. The pages are shared
   (PF_SHARED: a fork keeps them as they are) and never counted as RAM. */
void * __OS_mapPhysical(uint32_t phys, uint32_t npages) {
  uint32_t start, i;
  if (npages == 0 || (phys & 0xFFF) || (phys >> 12) < __total_phy_pages ||
      (phys >> 12) + npages > 0x100000)
    return NULL;
  start = __lmt_allocArea(&(processTable[currProcess]->lmemmap), npages);
  if (start < USERMINPAGE) return NULL;
  if (__OS_askPagesFrom((void *)(start << 12), npages, 0, PF_USER | PF_READWRITE) == NULL) {
    __lmt_freeArea(&(processTable[currProcess]->lmemmap), start, npages);
    return NULL;
  }
  for (i = 0; i < npages; i++) {
    uint32_t page = start + i;
    uint32_t * pte = (uint32_t *)__GET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page),
							 __PAGE_PT_INDEX(page));
    *pte = (phys + (i << 12)) | PF_USER | PF_READWRITE | PF_PRESENT | PF_SHARED;
    INVALIDATE_THE_CACHE(page << 12);
  }
  return (void *)(start << 12);
}

/* the DMA area, mapped into the current process (one reference to each
   of its pages, dropped when the process ends: the area itself keeps
   the first): its address, or NULL */
void * __OS_mapDmaArea(void) {
  uint32_t start, i, npages = DMA_AREA_SIZE / PAGE_SIZE;
  if (__dma_area == 0) return NULL;
  start = __lmt_allocArea(&(processTable[currProcess]->lmemmap), npages);
  if (start < USERMINPAGE) return NULL;
  if (__OS_askPagesFrom((void *)(start << 12), npages, 0, PF_USER | PF_READWRITE) == NULL) {
    __lmt_freeArea(&(processTable[currProcess]->lmemmap), start, npages);
    return NULL;
  }
  for (i = 0; i < npages; i++) {
    uint32_t page = start + i;
    uint32_t * pte = (uint32_t *)__GET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(page),
							 __PAGE_PT_INDEX(page));
    pmem_set((__dma_area >> 12) + i);
    *pte = (__dma_area + (i << 12)) | PF_USER | PF_READWRITE | PF_PRESENT | PF_SHARED;
    INVALIDATE_THE_CACHE(page << 12);
  }
  return (void *)(start << 12);
}

/* npages of RAM in one physical piece, above 16 MB (ISA DMA keeps the
   memory below), mapped into the current process and zeroed: their
   address, the physical one in *phys; NULL if no piece is free. The
   mapping holds the pages' only reference (pmem_set once each): the
   process's end frees them. */
void * __OS_allocDma(uint32_t npages, uint32_t * phys) {
  uint32_t first, run = 0, page, start, i;
  for (page = 0x1000; page < __total_phy_pages; page++) {
    if (__memory_bitmap[page / 8] & (1 << (page % 8))) { run = 0; continue; }
    if (++run == npages) break;
  }
  if (run < npages) return NULL;
  first = page + 1 - npages;
  start = __lmt_allocArea(&(processTable[currProcess]->lmemmap), npages);
  if (start < USERMINPAGE) return NULL;
  if (__OS_askPagesFrom((void *)(start << 12), npages, 0, PF_USER | PF_READWRITE) == NULL) {
    __lmt_freeArea(&(processTable[currProcess]->lmemmap), start, npages);
    return NULL;
  }
  for (i = 0; i < npages; i++) {
    uint32_t * pte = (uint32_t *)__GET_PAGE_TABLE_ENTRY(__PAGE_PD_INDEX(start + i),
							 __PAGE_PT_INDEX(start + i));
    pmem_set(first + i);
    *pte = ((first + i) << 12) | PF_USER | PF_READWRITE | PF_PRESENT | PF_SHARED;
    INVALIDATE_THE_CACHE((start + i) << 12);
  }
  kbzero((void *)(start << 12), npages * PAGE_SIZE);
  *phys = first << 12;
  return (void *)(start << 12);
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

  /* the kernel's own pages are writable (with CR0.WP its writes respect
     the R/W bit too) */
  if (!(flags & PF_USER)) flags |= PF_READWRITE;

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

    if (alloc_now) {
      __SET_PAGE_TABLE_ENTRY_AND_ALLOC(__PAGE_PD_INDEX(page),
				       __PAGE_PT_INDEX(page),
				       (pmem_findAFreePhysicalPage() << 12),
				       flags)
      /* a fresh frame reads as zeros: after a reset (shutdown -r) memory
	 holds the previous run's data, and it must not leak between
	 processes either */
      INVALIDATE_THE_CACHE(page << 12);
      kbzero((void *)(page << 12), PAGE_SIZE);
    } else
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
    if (__lmt_freeArea(&(processTable[currProcess]->lmemmap),
		       (addr >> 12),
		       npages) != 0)
    {
      /* part of the area is free already */
      printk("Problems releasing pages at ");
      print_uint_hex(addr);
      printk(", ");
      print_uint(npages);
      printk(" pages\n");
    }
#endif

  for (i = 0; i < npages; i++) {
    /* check if the page dir entry is valid */
    if (check &&
	((*(uint32_t*)__GET_PAGE_DIR_ENTRY(__ADDRESS_PD_INDEX(addr)) &
	  PF_PRESENT) == 0))
      return NULL;
    
    /* get the page table entry */
    pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
				       __ADDRESS_PT_INDEX(addr));
    
    /* check if the page is an allocated user page */
    if (check &&
	(!((*pte & (PF_PRESENT | PF_LOGICAL_PRESENT)) || IS_PAGER_ENTRY(*pte)) ||
	 !(*pte & PF_USER)))
      return NULL;
    
#ifdef DEBUG
    printk(__FUNCTION__);
    printk("(process ");
    print_uint(CURRPID);
    printk("): releasing page ");
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
/* the entry: arch/i386/entry.c */


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
				     PF_READWRITE);
    
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

  /* fresh memory must read as zeros (as on Linux: libcs rely on it), and
     must not leak what the frame held for its previous owner */
  kbzero((void *)(addr & ~(PAGE_SIZE - 1)), PAGE_SIZE);
#ifdef DEBUG
  printk("new allocated page: ");
  print_ulong_hex(new_phy_page);
  print_char('\n');
  print_char('\n');
#endif
}

//#define DEBUG
/* an invalid access from user mode terminates the process (SIGSEGV) */
int __mem_userArea(const void * start, uint32_t size) {
  uint32_t a = (uint32_t)start, end, page;
  if (size == 0) return 1;
  end = a + size;
  if (end < a || a < USER_AREA_START || end > USER_AREA_END) return 0;
  for (page = a >> 12; page <= (end - 1) >> 12; page++) {
    uint32_t pte;
    if (!(*(uint32_t*)__GET_PAGE_DIR_ENTRY(page >> 10) & PF_PRESENT))
      return 0;
    pte = *(uint32_t*)__GET_PAGE_TABLE_ENTRY(page >> 10, page & 1023);
    if (!(pte & PF_USER)) return 0;      /* a kernel stack of a thread */
    if (!(pte & (PF_PRESENT | PF_LOGICAL_PRESENT | PF_COW))) return 0;
  }
  return 1;
}

int __mem_userString(const char * s, uint32_t max) {
  uint32_t i;
  for (i = 0; i < max; i++) {
    /* a page at a time */
    if ((i == 0 || (((uint32_t)(s + i)) & 0xFFF) == 0) &&
	!__mem_userArea(s + i, 1))
      return -1;
    if (s[i] == 0) return i;
  }
  return -1;
}

int __mem_userVector(char ** v, uint32_t max_entries, uint32_t max_len) {
  uint32_t i;
  if (v == NULL) return 0;
  for (i = 0; i < max_entries; i++) {
    if (!__mem_userArea(&v[i], sizeof(char *))) return -1;
    if (v[i] == NULL) return 0;
    if (__mem_userString(v[i], max_len) < 0) return -1;
  }
  return -1;
}

/*
 * Copies between the kernel and a process's memory that may fault
 * (doc/decisions/identity-and-permissions.md): a page fault in the kernel
 * at copy_user_insn resumes at copy_user_fault, and copy_user returns -1,
 * instead of ending the process halfway through a system call. Needed
 * where a call writes into the process after blocking (recv, wait4):
 * meanwhile another thread may have unmapped that memory.
 */
int copy_user(void * to, const void * from, uint32_t n);
extern char copy_user_insn[], copy_user_fault[];
/* copy_user itself: arch/i386/entry.c */


int copy_to_user(void * user, const void * kernel, uint32_t n) {
  if (!__mem_userArea(user, n)) return -1;
  return copy_user(user, kernel, n);
}

int copy_from_user(void * kernel, const void * user, uint32_t n) {
  if (!__mem_userArea(user, n)) return -1;
  return copy_user(kernel, user, n);
}

/* a fault in copy_user: resume at its fix-up (frame: pushal's registers,
   the error code, then eip) */
static int copy_user_fixup(uint32_t * frame) {
  if (frame[9] != (uint32_t)copy_user_insn) return 0;
  frame[9] = (uint32_t)copy_user_fault;
  return 1;
}

void __mem_userSegfault(uint32_t addr) {
  printk("process ");
  print_ulong(CURRPID);
  printk(" killed: invalid memory access at ");
  print_ulong_hex(addr);
  print_char('\n');
  killProcess(SIGNAL_STATUS(SIGSEGV));
  sched();         /* switches to another process, never returns */
}

/* the faults resolved since boot, by kind (mynos-0ho) */
uint32_t mem_faultsAlloc, mem_faultsCow;

void _page_fault_handler(uint32_t addr, uint32_t errcode, uint32_t * frame) {
  uint32_t * pte;

#ifdef DEBUG
  print_char('\n');
  print_char('\n');
  printk("Process ");
  print_uint(CURRPID);
  printk(" thread ");
  print_uint(currThread->tid);
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
       PF_PRESENT) == 0) {
    if (errcode & 4) __mem_userSegfault(addr);
    if (copy_user_fixup(frame)) return;
    /* the kernel, in a system call, on a bad pointer of the process: end
       the process, not the system */
    if (addr >= USER_AREA_START && addr < USER_AREA_END) __mem_userSegfault(addr);
    kernel_on_screen = 1;
    printk("kernel page fault at ");
    print_ulong_hex(addr);
    printk(", process ");
    print_ulong(CURRPID);
    print_char('\n');
    KPANIC("page fault (?)");
  }

  pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(addr), 
					  __ADDRESS_PT_INDEX(addr));
#ifdef DEBUG
  if ((*pte) & PF_LOGICAL_PRESENT)
    printk("but the page is tagged as allocated\n");
  if ((*pte) & PF_COW)
    printk("but the page is tagged as COPY-ON_WRITE\n");
#endif

  /* a page of a region given to the external pager: the thread waits
     for it (pager.c). A system call's access to one ends below, as an
     invalid one (copy_user fails): the kernel does not wait in a call. */
  if (IS_PAGER_ENTRY(*pte) && (errcode & 4)) {
    __pager_fault(*pte, addr, errcode);
    return;
  }

  if (!((*pte) & PF_LOGICAL_PRESENT) &&
      !((*pte) & PF_COW)) { // not allocated & not cow
    if (errcode & 4) __mem_userSegfault(addr);
    if ((errcode & 3) == 3) {   /* the kernel wrote on a read-only page */
      printk("kernel write to a read-only page at ");
      print_ulong_hex(addr);
      printk(", pte ");
      print_ulong_hex(*pte);
      printk(", eip ");
      print_ulong_hex(frame[9]);
      print_char('\n');
    }
    if (copy_user_fixup(frame)) return;
    if (addr >= USER_AREA_START && addr < USER_AREA_END) __mem_userSegfault(addr);
    kernel_on_screen = 1;
    printk("kernel page fault at ");
    print_ulong_hex(addr);
    printk(", process ");
    print_ulong(CURRPID);
    print_char('\n');
    KPANIC("page fault");
  }
  if (__number_of_free_physical_pages == 0)
    KPANIC("full memory!");

  if ((*pte) & PF_LOGICAL_PRESENT) { /* ALLOCATE ON USE */
    __allocateOnUse(pte, addr);
    mem_faultsAlloc++;
    processTable[currProcess]->faultsAlloc++;
  } else if ((*pte) & PF_COW) {      /* COPY ON WRITE */
    __cowManager(pte, addr);
    mem_faultsCow++;
    processTable[currProcess]->faultsCow++;
  } else KPANIC("MEMORY ERROR: NOT COW OR LOGICAL");
}


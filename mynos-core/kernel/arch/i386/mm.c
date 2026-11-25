/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The i386's page tables, as generic memory code asks for them
   (paging.h; doc/decisions/x86-64.md, choice 4). Moved from mem/mem.c,
   unchanged. */

#include "mem/mem.h"
#include "gdt.h"
#include "video.h"
#include "kutils.h"

/* the entry of [va] in the current space, its page table made (zeroed)
   if there was none */
pte_t * arch_pte_make(vaddr_t va)
{
  if (!__IS_PAGE_TABLE_PRESENT(__ADDRESS_PD_INDEX(va))) {
    uint32_t newptaddr = (pmem_findAFreePhysicalPage() << 12);
    __SET_PAGE_DIR_ENTRY(__ADDRESS_PD_INDEX(va), newptaddr);
    INIT_PAGE_TABLE(__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(va), 0));
  }
  return (pte_t *)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(va), __ADDRESS_PT_INDEX(va));
}

/* the kernel's space at boot: the modules above the first 4 MB mapped at
   linear == physical, the GDT, the kernel's page tables (shared by every
   process), the two windows */
void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n)
{
  uint32_t i;
  uint32_t * tmp;

  /* start.asm identity-maps only the first 4MB: map the module pages above
     it at linear == physical too, so that modinfo addresses stay valid.
     This must happen before any allocation (the GDT is next): present
     entries keep __OS_askPages from handing out those linear addresses. */
  for (i = 0; i < (uint32_t)n; i++) {
    uint32_t page = start[i] >> 12;
    uint32_t last = (start[i] + len[i] - 1) >> 12;
    for (; page <= last; page++) {
      if (page < first_free_phy_page) continue;
      arch_pte_make(page << 12);
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
  for (i = 0; i < (uint32_t)_asm_last_kernel_page_dir_entry_used; i++)
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
}

/* a fresh frame, mapped in the copy-on-write window (the kernel's, one
   page): its address there; *phys, the frame */
void * arch_cow_window(paddr_t * phys)
{
  __SET_PAGE_TABLE_ENTRY_AND_ALLOC(__COW_TABLE,
				   __COW_ENTRY,
				   (pmem_findAFreePhysicalPage() << 12),
				   PF_READWRITE);
  INVALIDATE_THE_CACHE((void*)__COW_PAGE);
  *phys = LINEAR_TO_PHYSICAL_ADDRESS(__COW_PAGE);
  return (void *)__COW_PAGE;
}

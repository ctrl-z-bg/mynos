/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * x86-64's page tables, as generic memory code asks for them (paging.h;
 * doc/decisions/x86-64.md, choice 4). Every table is reached through the
 * direct map. The kernel's gigabyte has one page directory, whose 511
 * page tables are made at boot: every address space points at it
 * (PDPT[0]), so the kernel's mappings are the same in all of them.
 */

#include "mem/mem.h"
#include "gdt.h"
#include "video.h"
#include "kutils.h"

paddr_t kernel_pml4, kernel_pd;

static paddr_t new_table(void)
{
  paddr_t p = (paddr_t)pmem_findAFreePhysicalPage() << 12;
  pmem_set(p >> 12);
  kbzero(PHYS_TO_VIRT(p), PAGE_SIZE);
  return p;
}

/* the entry of [va] in the space [top], the tables on the way made */
pte_t * arch_pte_make_in(paddr_t top, vaddr_t va)
{
  pte_t * t = PHYS_TO_VIRT(top & ~0xFFFUL);
  int shift;
  for (shift = 39; shift > 12; shift -= 9) {
    pte_t * e = &t[(va >> shift) & 511];
    if (!(*e & PF_PRESENT))
      *e = new_table() | PF_PRESENT | PF_READWRITE | PF_USER;
    t = PHYS_TO_VIRT(PTE_FRAME(*e));
  }
  return &t[(va >> 12) & 511];
}

pte_t * arch_pte_make(vaddr_t va)
{
  return arch_pte_make_in(arch_cr3(), va);
}

/* the kernel's space at boot: its page directory and all its page
   tables, the boot's pages and the modules mapped at linear == physical,
   the direct map kept (start.asm's), and the switch to these tables */
void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n)
{
  paddr_t pdpt, page;
  pte_t * pd, * pml4, * boot = PHYS_TO_VIRT(0x100000);
  int i;

  kernel_pml4 = new_table();
  pdpt = new_table();
  kernel_pd = new_table();
  pml4 = PHYS_TO_VIRT(kernel_pml4);
  pml4[0] = pdpt | PF_PRESENT | PF_READWRITE | PF_USER;
  pml4[256] = boot[256];                         /* the direct map */
  ((pte_t *)PHYS_TO_VIRT(pdpt))[0] = kernel_pd | PF_PRESENT | PF_READWRITE | PF_USER;
  pd = PHYS_TO_VIRT(kernel_pd);
  printk("Allocating the kernel's 511 page tables...");
  for (i = 0; i < 511; i++)                      /* the last: unused */
    pd[i] = new_table() | PF_PRESENT | PF_READWRITE;
  printk(" done\n");

  /* the boot's pages, identity-mapped */
  for (page = 0; page < first_free_phy_page; page++)
    *arch_pte_make_in(kernel_pml4, page << 12) = (page << 12) | PF_PRESENT | PF_READWRITE;
  for (i = 0; i < n; i++)
    for (page = start[i] >> 12; page <= (start[i] + len[i] - 1) >> 12; page++)
      *arch_pte_make_in(kernel_pml4, page << 12) = (page << 12) | PF_PRESENT | PF_READWRITE;

  __asm__ volatile ("movq %0, %%cr3" : : "r"(kernel_pml4) : "memory");
  _init_gdt();
}

/* a fresh frame, reached through the direct map: no window needed */
void * arch_cow_window(paddr_t * phys)
{
  *phys = (paddr_t)pmem_findAFreePhysicalPage() << 12;
  pmem_set(*phys >> 12);
  return PHYS_TO_VIRT(*phys);
}

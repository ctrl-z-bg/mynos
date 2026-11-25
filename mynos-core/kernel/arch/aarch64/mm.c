/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The kernel's space on AArch64 (doc/decisions/aarch64.md, choice 4), as
   x86-64's mm.c: its top table, the gigabyte's level-1 and level-2
   tables shared by every process, the boot's pages and the modules at
   linear == MyNOS's physical. TTBR1 (the direct map, the devices) stays
   start.S's. */

#include "global.h"
#include "mem/mem.h"
#include "video.h"
#include "kutils.h"

paddr_t kernel_pml4, kernel_pd;

/* a table entry: the next table's real address, valid, a table */
pte_t arch_table_entry(paddr_t table)
{
  return table | ARCH_RAM_BIT | PTE_VALID | PTE_PAGE;
}

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
    if (!(*e & PTE_VALID)) *e = arch_table_entry(new_table());
    t = PHYS_TO_VIRT(PTE_FRAME(*e));
  }
  return &t[(va >> 12) & 511];
}

pte_t * arch_pte_make(vaddr_t va)
{
  return arch_pte_make_in(arch_cr3(), va);
}

void arch_switch_space(paddr_t top)
{
  __asm__ volatile ("dsb ish; msr ttbr0_el1, %0; isb; tlbi vmalle1; dsb nsh; isb"
                    : : "r"(top | ARCH_RAM_BIT) : "memory");
}

void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n)
{
  paddr_t pdpt, page;
  pte_t * pd, * pml4;
  int i;

  kernel_pml4 = new_table();
  pdpt = new_table();
  kernel_pd = new_table();
  pml4 = PHYS_TO_VIRT(kernel_pml4);
  pml4[0] = arch_table_entry(pdpt);
  ((pte_t *)PHYS_TO_VIRT(pdpt))[0] = arch_table_entry(kernel_pd);
  pd = PHYS_TO_VIRT(kernel_pd);
  printk("Allocating the kernel's 511 page tables...");
  for (i = 0; i < 511; i++)                      /* the last: unused */
    pd[i] = arch_table_entry(new_table());
  printk(" done\n");

  for (page = 0; page < first_free_phy_page; page++)
    pte_set(arch_pte_make_in(kernel_pml4, page << 12),
	    (page << 12) | PF_PRESENT | PF_READWRITE);
  for (i = 0; i < n; i++)
    for (page = start[i] >> 12; page <= (start[i] + len[i] - 1) >> 12; page++)
      pte_set(arch_pte_make_in(kernel_pml4, page << 12),
	      (page << 12) | PF_PRESENT | PF_READWRITE);

  arch_switch_space(kernel_pml4);
}

/* a fresh frame, reached through the direct map */
void * arch_cow_window(paddr_t * phys)
{
  *phys = (paddr_t)pmem_findAFreePhysicalPage() << 12;
  pmem_set(*phys >> 12);
  return PHYS_TO_VIRT(*phys);
}

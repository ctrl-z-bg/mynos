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
 * x86-64's page tables (doc/decisions/x86-64.md, choice 4): four levels
 * (PML4, PDPT, PD, PT) of 512 entries, 4 KB pages; the kernel reaches any
 * of them through the direct map, never through a recursive entry.
 */

#ifndef __PAGING_H__
#define __PAGING_H__

typedef uint64_t pte_t;
#define PTE_FRAME(E)     ((paddr_t)((E) & 0x000FFFFFFFFFF000ULL))
#define PTE_FLAGS(E)     ((E) & 0xFFF)
#define PAGES_PER_TABLE  512

#define PHYS_TO_VIRT(P)  ((void *)((paddr_t)(P) + DIRECT_MAP))

/* the kernel's pages: its gigabyte but the last 2 MB (the windows'); the
   processes' from 1 GB */
#define ARCH_KERNEL_LAST_PAGE  ((0x40000000UL - 0x200000UL - 0x1000UL) >> 12)
#define ARCH_USER_FIRST_PAGE   USERMINPAGE

static inline paddr_t arch_cr3(void)
{
  paddr_t v;
  __asm__ volatile ("movq %%cr3, %0" : "=r"(v));
  return v;
}

/* the entry of [va] in the address space whose top table is [top]; NULL
   if a table on the way does not exist */
static inline pte_t * arch_pte_in(paddr_t top, vaddr_t va)
{
  pte_t * t = PHYS_TO_VIRT(top & ~0xFFFUL);
  int shift;
  for (shift = 39; shift > 12; shift -= 9) {
    pte_t e = t[(va >> shift) & 511];
    if (!(e & 1)) return NULL;
    t = PHYS_TO_VIRT(PTE_FRAME(e));
  }
  return &t[(va >> 12) & 511];
}

static inline pte_t * arch_pte(vaddr_t va)
{
  return arch_pte_in(arch_cr3(), va);
}

static inline paddr_t arch_virt_to_phys(vaddr_t va)
{
  pte_t * e = arch_pte(va);
  return e ? PTE_FRAME(*e) | (va & 0xFFF) : 0;
}

/* arch/x86_64/mm.c */
pte_t * arch_pte_make(vaddr_t va);
pte_t * arch_pte_make_in(paddr_t top, vaddr_t va);
void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n);
void * arch_cow_window(paddr_t * phys);


/* an entry written (mem/, the pager): on x86 a store; an architecture
   whose entries carry more than MyNOS's bits sets them here (aarch64) */
static inline void pte_set(pte_t * p, pte_t v) { *p = v; }
/* the pager's clock: the page's use, its writes, forgotten */
static inline void pte_mark_old(pte_t * p) { *p &= ~(pte_t)0x20; }      /* accessed */
static inline void pte_mark_clean(pte_t * p) { *p &= ~(pte_t)0x40; }    /* dirty */

#endif

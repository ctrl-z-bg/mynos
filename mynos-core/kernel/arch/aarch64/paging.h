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
 * AArch64's page tables (doc/decisions/aarch64.md, choices 3-5): four
 * levels of 512 entries, 4 KB pages, 48-bit addresses, the same shape as
 * x86-64's. The kernel's physical addresses start at RAM's base: a valid
 * entry of RAM carries the base in bit 30 (ARCH_RAM_BIT), which
 * PTE_FRAME takes away. The kernel reaches any table through the direct
 * map (TTBR1).
 */

#ifndef __PAGING_H__
#define __PAGING_H__

typedef uint64_t pte_t;

/* RAM's real physical base: QEMU virt's 1 GB (bit 30, at most 1 GB of
   RAM: an OR is exact); a Raspberry Pi's 0 (btq.7) */
#ifdef MYNOS_RASPI
#define ARCH_RAM_BASE    0x0UL
#else
#define ARCH_RAM_BASE    0x40000000UL
#endif
#define ARCH_RAM_BIT     ARCH_RAM_BASE

/* a device's page: device memory; on a Pi, the VideoCore's memory (the
   framebuffer, below the peripherals) normal non-cacheable memory
   (MAIR's 2: start.S), where programs' copies may be unaligned (device
   memory faults them) */
#ifdef MYNOS_RASPI
#define ARCH_DEVICE_ATTR(E) (((E) & PTE_ADDR) < 0x3F000000UL ? PTE_ATTR_NC : PTE_ATTR_DEVICE)
#else
#define ARCH_DEVICE_ATTR(E) PTE_ATTR_DEVICE
#endif

/* the hardware's bits (ptebits.h has MyNOS's) */
#define PTE_VALID        0x1UL
#define PTE_PAGE         0x2UL          /* level 3: a page; levels 0-2: a table */
#define PTE_ATTR_NORMAL  (0UL << 2)     /* MAIR index 0: write-back */
#define PTE_ATTR_DEVICE  (1UL << 2)     /* MAIR index 1: device nGnRE */
#define PTE_ATTR_NC      (2UL << 2)     /* MAIR index 2: normal non-cacheable */
#define PTE_AP_RO        (1UL << 7)
#define PTE_SH_INNER     (3UL << 8)
#define PTE_AF           (1UL << 10)
#define PTE_NG           (1UL << 11)
#define PTE_PXN          (1UL << 53)
#define PTE_UXN          (1UL << 54)
#define PTE_ADDR         0x0000FFFFFFFFF000UL

/* a valid entry's frame, without RAM's base; a non-valid one's bits
   12-47 (the pager's token) as they are */
#define PTE_FRAME(E)     ((paddr_t)((E) & PTE_ADDR & (((E) & 1) ? ~ARCH_RAM_BIT : ~0UL)))
#define PTE_FLAGS(E)     ((E) & ~(pte_t)PTE_FRAME(E))
#define PAGES_PER_TABLE  512

#define PHYS_TO_VIRT(P)  ((void *)((paddr_t)(P) + DIRECT_MAP))

/* the kernel's pages: its gigabyte but the last 2 MB (the windows', as
   on x86-64); the processes' from 1 GB */
#define ARCH_KERNEL_LAST_PAGE  ((0x40000000UL - 0x200000UL - 0x1000UL) >> 12)
#define ARCH_USER_FIRST_PAGE   USERMINPAGE

/* the current address space's top table (TTBR0), MyNOS's physical
   address */
static inline paddr_t arch_cr3(void)
{
  paddr_t v;
  __asm__ volatile ("mrs %0, ttbr0_el1" : "=r"(v));
  return v & PTE_ADDR & ~ARCH_RAM_BIT;
}

/* an entry written: the hardware's bits from MyNOS's. A valid entry is a
   page (level 3), accessed; RAM is normal memory, inner shareable, its
   real address; a device's, device memory, never executed; read-only
   unless MyNOS's writable bit; the kernel's pages global and never run
   by EL0, the processes' non-global and never run by EL1. Doing it twice
   changes nothing. */
static inline pte_t pte_hw(pte_t v)
{
  if (!(v & PTE_VALID)) return v;
  v |= PTE_PAGE | PTE_AF;
  if (v & (1UL << 59))                              /* PF_DEVICE */
    v = (v & ~(7UL << 2)) | ARCH_DEVICE_ATTR(v) | PTE_PXN | PTE_UXN;
  else
    v |= PTE_SH_INNER | ARCH_RAM_BIT;
  if (v & (1UL << 55)) v &= ~PTE_AP_RO;             /* PF_READWRITE */
  else v |= PTE_AP_RO;
  if (v & (1UL << 6)) v |= PTE_NG | PTE_PXN;        /* PF_USER */
  else v |= PTE_UXN;
  if (v & (1UL << 55)) v |= 1UL << 61;              /* writable: dirty, for the pager */
  v |= 1UL << 60;                                   /* accessed */
  return v;
}
static inline void pte_set(pte_t * p, pte_t v) { *p = pte_hw(v); }
/* ARMv8.0 keeps no accessed and dirty bits for MyNOS: they are kept by
   software, with faults (the pager's clock and write-back, pager.c).
   Use forgotten: the access flag off too, the next access faults;
   written back: a writable page read-only for the hardware (MyNOS's own
   writable bit kept), the next write faults. pte_fault_fixup, from the
   page fault handler, gives the access flag (and the accessed bit), and
   on a write the hardware's writable bit (and the dirty one) back. */
/* (ptebits.h's bits: 55 PF_READWRITE, 60 PF_ACCESSED, 61 PF_DIRTY) */
static inline void pte_mark_old(pte_t * p) { *p &= ~((1UL << 60) | PTE_AF); }
static inline void pte_mark_clean(pte_t * p)
{
  *p &= ~(1UL << 61);
  if (*p & (1UL << 55)) *p |= PTE_AP_RO;
}
static inline void pte_fault_fixup(pte_t * p, int write)
{
  *p |= PTE_AF | (1UL << 60);
  if (write && (*p & (1UL << 55))) *p = (*p & ~PTE_AP_RO) | (1UL << 61);
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
  pte_t * e;
  if (va >= DIRECT_MAP && va < DEVICE_MAP) return va - DIRECT_MAP;
  e = arch_pte(va);
  return e && (*e & 1) ? PTE_FRAME(*e) | (va & 0xFFF) : 0;
}

/* arch/aarch64/mm.c */
pte_t * arch_pte_make(vaddr_t va);
pte_t * arch_pte_make_in(paddr_t top, vaddr_t va);
void arch_init_kernel_space(uint32_t first_free_phy_page, const paddr_t * start,
			    const uint32_t * len, int n);
void * arch_cow_window(paddr_t * phys);
/* a top table into TTBR0, the TLB's non-global entries forgotten */
void arch_switch_space(paddr_t top);

#endif

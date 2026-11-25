/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * Another process's memory on AArch64, as on x86-64 (doc/decisions/
 * x86-64.md): its page tables through the direct map, no window. __OS_mapPagesTo is the
 * i386's logic (arch/i386/externalmem.c): pages of the caller given to
 * another process, copy-on-write or shared (IPC's long messages).
 */

#include "global.h"
#include "mem/mem.h"
#include "mem/externalmem.h"
#include "mem/lmemtrack.h"
#include "process.h"
#include "tss.h"
#include "mynos.h"

static paddr_t space_of(pid_t pid)
{
  return THREAD_SPACE(proc(pid)->tss);
}

static void setExternal(pid_t pid, vaddr_t va, paddr_t frame, pte_t flags)
{
  pte_set(arch_pte_make_in(space_of(pid), va), frame | flags);
}

static int32_t mapPageTo(pid_t pid, vaddr_t sender, vaddr_t receiver, uint32_t mode)
{
  pte_t * pte = arch_pte(sender);
  paddr_t frame;
  if (!(mode & MYNOS_IPC_SHARED)) {
    if (*pte & PF_SHARED) {
      setExternal(pid, receiver, __mem_copyPageToCOWSpace(sender),
		  PF_USER | PF_PRESENT | PF_READWRITE);
      return 0;
    }
    if (*pte & PF_LOGICAL_PRESENT) {
      setExternal(pid, receiver, 0, PF_USER | PF_READWRITE | PF_LOGICAL_PRESENT);
      return 0;
    }
    if (*pte & PF_READWRITE) {
      pte_set(pte, (*pte | PF_COW) & ~(pte_t)PF_READWRITE);
      INVALIDATE_THE_CACHE(sender);
    }
    frame = PTE_FRAME(*pte);
    pmem_set(frame >> 12);
    setExternal(pid, receiver, frame, PTE_FLAGS(*pte));
  } else {
    if (*pte & PF_LOGICAL_PRESENT) __mem_allocateOnUse(sender);
    if (*pte & PF_COW) __mem_cowManager(sender);
    pte = arch_pte(sender);
    if (!(*pte & PF_SHARED) && (*pte & PF_READWRITE)) {
      pte_set(pte, *pte | PF_SHARED);
      INVALIDATE_THE_CACHE(sender);
    }
    frame = PTE_FRAME(*pte);
    pmem_set(frame >> 12);
    setExternal(pid, receiver, frame, PTE_FLAGS(*pte));
  }
  return 0;
}

int32_t __OS_mapPagesTo(pid_t pid, uint32_t lpage, uint32_t npages, uint32_t mode)
{
  uint32_t newLPage, i;
  for (i = 0; i < npages; i++) {
    pte_t * e = arch_pte((vaddr_t)(lpage + i) << 12);
    if (e == NULL || IS_PAGER_ENTRY(*e)) return MYNOS_ERR_INVALID;
  }
  newLPage = __lmt_allocArea(&(proc(pid)->lmemmap), npages);
  if (newLPage < USERMINPAGE) return MYNOS_ERR_FULL;
  for (i = 0; i < npages; i++)
    mapPageTo(pid, (vaddr_t)(lpage + i) << 12, (vaddr_t)(newLPage + i) << 12, mode);
  return newLPage;
}

uint32_t * __mem_mapFrame(uint32_t phyPage, uint32_t * saved)
{
  return PHYS_TO_VIRT((paddr_t)phyPage << 12);
}

void __mem_unmapFrame(uint32_t saved) { }

pte_t * __mem_externalPTE(pid_t pid, uint32_t laddr)
{
  return arch_pte_in(space_of(pid), laddr);
}

void __mem_setExternalPTE(pid_t pid, uint32_t laddr, pte_t entry)
{
  pte_set(arch_pte_make_in(space_of(pid), laddr), entry);
}

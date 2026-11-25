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

#include "mem/externalmem.h"
#include "process.h"
#include "mem/mem.h"
#include "video.h"
#include "mynos.h"

// set a new PT for another process given the physical address for new PT
static int32_t __setExternalPT(pid_t pid, uint32_t table, 
			       uint32_t phyPage);

// map a new physical page to another process linear space
static int32_t __setExternalProcessPage(pid_t pid, uint32_t table, 
					uint32_t entry, uint32_t phyPage,
					uint32_t flags);

// map a linear page of mine to a linear page of pid
static int32_t __mapPageTo(pid_t pid,
			   uint32_t lpagesender,
			   uint32_t lpagereceiver,
			   uint32_t mode);

/* map a physical page to the externalVMPage (see mem.h) */
static void __mapPageToAppPage(uint32_t phyPage) {
  *(__EXTERNAL_VMSPACE_PAGE_ENTRY) = (phyPage<<12) | PF_READWRITE | PF_PRESENT;
  INVALIDATE_THE_CACHE((void*)__EXTERNAL_VMSPACE_PAGE);
}

uint32_t * __mem_mapFrame(uint32_t phyPage, uint32_t * saved) {
  *saved = *(__EXTERNAL_VMSPACE_PAGE_ENTRY);
  __mapPageToAppPage(phyPage);
  return __EXTERNAL_VMSPACE_PAGE;
}

void __mem_unmapFrame(uint32_t saved) {
  *(__EXTERNAL_VMSPACE_PAGE_ENTRY) = saved;
  INVALIDATE_THE_CACHE((void*)__EXTERNAL_VMSPACE_PAGE);
}

static void __mapProcessPD(pid_t pid) {
  uint32_t phyPageAddress;

  if (!proc(pid) || !proc(pid)->isAlive)
    KPANIC("Try to alloc a inexistent process PD!!!");

  phyPageAddress = (uint32_t)((proc(pid)->tss)->pgdir);
  __mapPageToAppPage(phyPageAddress >> 12);
}

/* return != 0 if the PT is not present */
static int32_t __mapProcessPT(pid_t pid, uint32_t table) {
  uint32_t phyPageAddress;
  uint32_t * pd;

  if (!proc(pid) || !proc(pid)->isAlive)
    KPANIC("Try to alloc a inexistent process PT!!!");

  /* map the process PD */
  __mapProcessPD(pid);

  pd = __EXTERNAL_VMSPACE_PAGE;

  // check if the PT is present
  if (!(pd[table] & PF_PRESENT)) return -1;

  phyPageAddress = pd[table] & 0xFFFFF000;
  __mapPageToAppPage(phyPageAddress >> 12);
  return 0;
}


/* check if the PT exists, otherwise allocate a fresh one */
static int32_t __setExternalProcessPage(pid_t pid, uint32_t table, 
					uint32_t entry, uint32_t phyPage,
					uint32_t flags) {
  uint32_t * pt;

  // if PT does not exist than allocate a fresh one!
  if (__mapProcessPT(pid, table) != 0) {
    uint32_t * newPT = (uint32_t*)__OS_askPages(1, 1, 0);
    INIT_PAGE_TABLE(newPT);
    __setExternalPT(pid, table, 
		       (LINEAR_TO_PHYSICAL_ADDRESS(newPT)>>12));
    __OS_releasePages(newPT, 1, 0, 0);
    if (__mapProcessPT(pid, table) != 0)
      KPANIC("problem in __OS_setExternalProcessPage");
  }

  pt = __EXTERNAL_VMSPACE_PAGE;
  pt[entry] = (phyPage<<12) | flags;

  return 0;
}

static int32_t __setExternalPT(pid_t pid, uint32_t table, 
			       uint32_t phyPage) {
  uint32_t * pd;

  // set the PD entry
  __mapProcessPD(pid);

  pd = __EXTERNAL_VMSPACE_PAGE;
  pd[table] = (phyPage<<12) | PF_READWRITE | PF_USER | PF_PRESENT;

  // set the PD mirror entry
  __setExternalProcessPage(pid, LAST_PDPT_INDEX, table, phyPage,
			      PF_READWRITE | PF_USER | PF_PRESENT);

  return 0;
}

static int32_t __mapPageTo(pid_t pid,
			   uint32_t lpagesender,
			   uint32_t lpagereceiver,
			   uint32_t mode) {
  uint32_t * pte;
  uint32_t laddrsender;
  uint32_t laddrreceiver;
  uint32_t ppage;
  uint32_t flags;

  // my page data
  laddrsender = lpagesender << 12;
  laddrreceiver = lpagereceiver << 12;

  pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(laddrsender), 
					  __ADDRESS_PT_INDEX(laddrsender));
  
  if (!(mode & MYNOS_IPC_SHARED)) { // the page should not be shared
    if (*pte & PF_SHARED) {
      ppage = (__mem_copyPageToCOWSpace(laddrsender) >> 12);

      flags = PF_USER | PF_PRESENT | PF_READWRITE;

      __setExternalProcessPage(pid,
			       __ADDRESS_PD_INDEX(laddrreceiver),
			       __ADDRESS_PT_INDEX(laddrreceiver),
			       ppage,
			       flags);
    } else {
      // not really allocated: copy as is
      if (*pte & PF_LOGICAL_PRESENT) {
	__setExternalProcessPage(pid,
				 __ADDRESS_PD_INDEX(laddrreceiver),
				 __ADDRESS_PT_INDEX(laddrreceiver),
				 0, /* no frame yet: allocated on first access */
				 PF_USER | PF_READWRITE | PF_LOGICAL_PRESENT);
	return 0;
      }

      // set this page as cow if...
      if (*pte & PF_READWRITE) {
	*pte |= PF_COW;
	*pte = *pte & ~PF_READWRITE;  // to have the fault on write!
	INVALIDATE_THE_CACHE(laddrsender);
      }
      ppage = (*pte)>>12;
      pmem_set(ppage);
      
      // I could just copy the flags between descriptors, but
      // I would copy processor flags too
      flags = *pte & 0xFFF;
      
      __setExternalProcessPage(pid,
			       __ADDRESS_PD_INDEX(laddrreceiver),
			       __ADDRESS_PT_INDEX(laddrreceiver),
			       ppage,
			       flags);
    
    }
  } else { // shared
    if (*pte & PF_LOGICAL_PRESENT) // not really allocated
      __mem_allocateOnUse(laddrsender); // allocate it
    
    // a page cannot be cow and shared at the same time
    if (*pte & PF_COW)
      __mem_cowManager(laddrsender);
    
    // reload the page data after the changes
    pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(laddrsender), 
					    __ADDRESS_PT_INDEX(laddrsender));

    // set my page as shared if it's not already and it's not read-only
    if (!(*pte & PF_SHARED) && (*pte & PF_READWRITE)) {
      *pte |= PF_SHARED;
      INVALIDATE_THE_CACHE(laddrsender);
    }
      
    ppage = (*pte)>>12;
    pmem_set(ppage);

    // set the flags
    flags = *pte & 0xFFF;
    
    __setExternalProcessPage(pid,
			     __ADDRESS_PD_INDEX(laddrreceiver),
			     __ADDRESS_PT_INDEX(laddrreceiver),
			     ppage,
			     flags);
  }

  return 0;
}

int32_t __OS_mapPagesTo(pid_t pid, uint32_t lpage,
			uint32_t npages, uint32_t mode) {
  uint32_t newLPage;
  uint32_t i;
  // the area should be checked before this function

  /* a page the external pager has not given yet cannot be sent: the
     kernel does not wait for the pager in a system call */
  for (i = 0; i < npages; i++) {
    uint32_t a = (lpage + i) << 12;
    if (IS_PAGER_ENTRY(*(uint32_t*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(a),
                                                          __ADDRESS_PT_INDEX(a))))
      return MYNOS_ERR_INVALID;
  }

  // alloc a new area in the receiver linear space
  newLPage = __lmt_allocArea(&(proc(pid)->lmemmap),
			     npages);
  /* no room in the receiver's linear space: __lmt_allocArea's failure
     values are small page numbers, below the user area (mynos-py9: page 1
     is inside the kernel's page table, shared by every process) */
  if (newLPage < USERMINPAGE) return MYNOS_ERR_FULL;

  for (i = 0; i < npages; i++)
    __mapPageTo(pid, lpage + i, newLPage + i, mode);

  return newLPage;
}

/* another process's page table entries, for the external pager (pager.c,
   mynos-vzp): read one, or write one (making its page table if needed).
   Through the kernel's one window: the pointer is good until the window
   is used again. */
pte_t * __mem_externalPTE(pid_t pid, uint32_t laddr) {
  if (__mapProcessPT(pid, __ADDRESS_PD_INDEX(laddr)) != 0) return NULL;
  return (uint32_t *)__EXTERNAL_VMSPACE_PAGE + __ADDRESS_PT_INDEX(laddr);
}

void __mem_setExternalPTE(pid_t pid, uint32_t laddr, pte_t entry) {
  __setExternalProcessPage(pid, __ADDRESS_PD_INDEX(laddr),
                           __ADDRESS_PT_INDEX(laddr), entry >> 12, entry & 0xFFF);
}


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

#include "externalmem.h"
#include "process.h"
#include "mem.h"
#include "video.h"

/* map a physical page to the externalVMPage (see mem.h) */
static void __mapPageToAppPage(uint32_t phyPage) {
  *(__EXTERNAL_VMSPACE_PAGE_ENTRY) = (phyPage<<12) | 0x1;
  INVALIDATE_THE_CACHE((void*)__EXTERNAL_VMSPACE_PAGE);
}

static void __mapProcessPD(pid_t pid) {
  uint32_t phyPageAddress;

  if (!processTable[pid].isAlive)
    KPANIC("Try to alloc a inexistent process PD!!!");

  phyPageAddress = (uint32_t)(processTable[pid].tss->pgdir);
  __mapPageToAppPage(phyPageAddress >> 12);
}

/* return != 0 if the PT is not present */
static int __mapProcessPT(pid_t pid, uint32_t table) {
  uint32_t phyPageAddress;
  uint32_t * pd;

  if (!processTable[pid].isAlive)
    KPANIC("Try to alloc a inexistent process PT!!!");

  /* map the process PD */
  __mapProcessPD(pid);

  pd = __EXTERNAL_VMSPACE_PAGE;

  phyPageAddress = pd[table] & 0xFFFFF000;
  if (!phyPageAddress) return -1;
  __mapPageToAppPage(phyPageAddress >> 12);
  return 0;
}

int __OS_setExternalProcessPage(pid_t pid, uint32_t table, 
				uint32_t entry, uint32_t phyPage,
				uint32_t flags) {
  uint32_t * pt;

  __mapProcessPT(pid, table);

  pt = __EXTERNAL_VMSPACE_PAGE;
  pt[entry] = (phyPage<<12) | flags;

  return 0;
}

int __OS_setExternalPT(pid_t pid, uint32_t table, 
		       uint32_t phyPage) {
  uint32_t * pd;

  // set the PD entry
  __mapProcessPD(pid);

  pd = __EXTERNAL_VMSPACE_PAGE;
  pd[table] = (phyPage<<12) | PF_READWRITE | PF_USER | PF_PRESENT;

  // set the PD mirror entry
  __OS_setExternalProcessPage(pid, LAST_PDPT_INDEX, table, phyPage,
			      PF_READWRITE | PF_USER | PF_PRESENT);

  return 0;
}



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
 * MyNOS's names for an entry's bits, on AArch64 (doc/decisions/aarch64.md,
 * choice 5), included by mem/mem.h. ARM's level-3 entry has the valid bit
 * (0), AP[1] (6: EL0 may use it), AP[2] (7: read-only), the access flag
 * (10), the memory type (2-4), shareability (8-9); bits 55-61 are the
 * software's. "Writable" is MyNOS's bit 55: paging.h's pte_set sets
 * AP[2] from it, and the other bits a valid entry needs.
 */

#ifndef __PTEBITS_H__
#define __PTEBITS_H__

#define PF_PRESENT         0x1UL
#define PF_USER            (1UL << 6)
#define PF_SUPERVISOR      0x0
#define PF_READWRITE       (1UL << 55)
#define PF_LOGICAL_PRESENT (1UL << 56)
#define PF_COW             (1UL << 57)
#define PF_SHARED          (1UL << 58)
/* registers of a device, not RAM (mapPhysical): device memory, its real
   address */
#define PF_DEVICE          (1UL << 59)
/* no hardware access and dirty bits on ARMv8.0: kept by software (the
   pager's clock; a page that may be written counts as written) */
#define PF_ACCESSED        (1UL << 60)
#define PF_DIRTY           (1UL << 61)
/* a page of a region given to the external pager (pager.c): not valid,
   its token in bits 12-31 */
#define PF_PAGER           PF_SHARED
#define IS_PAGER_ENTRY(E) \
  (((E) & (PF_PRESENT | PF_PAGER | PF_LOGICAL_PRESENT | PF_COW)) == PF_PAGER)
#define PF_NOTPRESENT      0x0

/* a flag of the allocation functions only, never in an entry */
#define PF_SUPERVISOR_IN_USER_SPACE 0x1000

#endif

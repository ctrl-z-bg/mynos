/*
  MyNOS
  Copyright (C) 2002, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The kernel heap: kmalloc and kfree (dynalloc.c).
 *
 * Small blocks (up to 2 KB with their header) come from size classes: each
 * class keeps a list of free blocks, and takes a whole page when it runs
 * out. Larger blocks are whole pages, given back by kfree. Every block has
 * a header with a magic number: freeing a block twice, or something that
 * is not a block, is reported (with the caller) and ignored.
 *
 * The 2003 allocator (one address-ordered list of blocks that gave pages
 * back as soon as they emptied) had four bugs about which page belonged to
 * which block; see doc/JOURNAL.md.
 */

#ifndef __DYNALLOC_H__
#define __DYNALLOC_H__

#include "global.h"

void * kmalloc(unsigned int sz);
void kfree(void * ptr);

/* bytes in use and pages held by the heap (statistics) */
uint32_t kheap_used(void);
uint32_t kheap_pages(void);

#ifndef NULL
#define NULL ((void*) 0x0)
#endif

#endif

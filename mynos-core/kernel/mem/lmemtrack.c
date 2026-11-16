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

#include"lmemtrack.h"

#include "dynalloc.h"
#include "video.h"

#define myalloc(sz) kmalloc(sz)
#define myfree(ptr) kfree(ptr)

/* The list holds the FREE areas of a process's linear space, in address
   order; bgn and end are page numbers, both included. */
#define PAGESPAN(p) ((p).end - (p).bgn + 1)

/* page numbers start at USERMINPAGE: 1 cannot be one */
#define BLOCKNOTFOUND 1
#define AREATOOLARGE 1

#define NOTALLOCATED 1

//pdListEl *pdListBgn = NULL;

pdListEl *__lmt_newPdListEl(uint32_t bgn, uint32_t end, pdListEl* next, pdListEl* prev)
{
  pdListEl *toret = (pdListEl*) myalloc(sizeof(pdListEl));
  toret->bgn = bgn;
  toret->end = end;
  toret->next = next;
  toret->prev = prev;
  return toret;
}

pdListEl *__lmt_findArea(pdListEl **pdListBgn, uint32_t npages)
{
  pdListEl *runner;

  if (!(*pdListBgn)) { /* allocate and return */
    (*pdListBgn) = __lmt_newPdListEl(USERMINPAGE, USERMAXPAGE, NULL, NULL);
    return *pdListBgn;
  }

  /* otherwise, first fit */
  runner = *pdListBgn;
  while ( runner && (PAGESPAN(*runner) < npages) ) {    
    runner = runner->next;
  }
  return runner;
}

/* returns the page number at which the area begins (BLOCKNOTFOUND if there
   is no room). Adjusts the free space list */
uint32_t __lmt_allocArea(pdListEl **pdListBgn, uint32_t npages)
{
  pdListEl *tomod;
  uint32_t toret;

  if (npages == 0 || npages > (USERMAXPAGE-USERMINPAGE)) return AREATOOLARGE;
  
  /* first fit */
  tomod = __lmt_findArea(pdListBgn, npages);
  if ( tomod ) {
    toret = tomod->bgn;
    if ( PAGESPAN(*tomod) == npages ) { /* the element must be removed */
      if ( tomod->prev )
	tomod->prev->next = tomod->next;
      else
	*pdListBgn = tomod->next;
      if ( tomod->next )
	tomod->next->prev = tomod->prev;
      myfree(tomod);
    } else /* adjust this block's data */
      tomod->bgn += npages;
    return(toret);
  } else /* block not found! */
    return BLOCKNOTFOUND;
}

/* frees a block of pages, adjusting the list. Fails (NOTALLOCATED) if part
   of it is free already. (The 2003 version unlinked a merged element
   without fixing its successor's back pointer, and could not free an area
   above the last free one.) */
uint32_t __lmt_freeArea(pdListEl **pdListBgn, uint32_t fromPage, uint32_t npages)
{
  uint32_t last = fromPage + npages - 1;
  pdListEl *prev = NULL, *next = *pdListBgn;

  if (npages == 0) return 0;
  /* prev: the last free area before ours; next: the first one after it */
  while ( next && next->bgn <= last ) {
    if ( next->end >= fromPage ) /* overlaps a free area */
      return NOTALLOCATED;
    prev = next;
    next = next->next;
  }

  if ( prev && prev->end + 1 == fromPage ) {        /* sticks to prev */
    prev->end = last;
    if ( next && last + 1 == next->bgn ) {          /* and to next: join */
      prev->end = next->end;
      prev->next = next->next;
      if ( next->next )
	next->next->prev = prev;
      myfree(next);
    }
  } else if ( next && last + 1 == next->bgn ) {     /* sticks to next */
    next->bgn = fromPage;
  } else {                                          /* a new free area */
    pdListEl *el = __lmt_newPdListEl(fromPage, last, next, prev);
    if ( prev )
      prev->next = el;
    else
      *pdListBgn = el;
    if ( next )
      next->prev = el;
  }
  return 0;
}

pdListEl *__lmt_copyList(pdListEl *pdListBgn)
{
  pdListEl *ret = NULL;
  pdListEl *run = NULL;
  pdListEl *prev = NULL;

  while ( pdListBgn ) {
    run = __lmt_newPdListEl(pdListBgn->bgn, pdListBgn->end, NULL, prev);
    if ( prev )
      prev->next = run;
    else
      ret = run;
    prev = run;
    pdListBgn = pdListBgn->next;
  }

  return ret;
}

uint32_t __lmt_forceAllocation(pdListEl **pdListBgn, uint32_t fromPage, uint32_t npages)
{
  /* we must find the first block whose 'bgn' is after fromPage+npages */
  pdListEl *runner = *pdListBgn;

  if ( fromPage < USERMINPAGE )
    KPANIC("lmemtrack.c: cannot allocate under 1GB (LA)");

  if ( !(*pdListBgn) ) {
    if ( fromPage == USERMINPAGE ) {
      *pdListBgn = __lmt_newPdListEl(fromPage+npages, USERMAXPAGE, NULL, NULL);
    } else {
      pdListEl *newEl;
      *pdListBgn = __lmt_newPdListEl(USERMINPAGE, fromPage-1, NULL, NULL);
      newEl = __lmt_newPdListEl(fromPage+npages, USERMAXPAGE, NULL, *pdListBgn);
      (*pdListBgn)->next = newEl;
    }
    return 0;
  }
  
  while ( runner && (runner->end < fromPage) )
    runner = runner->next;

  if ( !runner || runner->bgn > fromPage ||
       !(runner->end >= (fromPage+npages-1)) )
    KPANIC("lmemtrack.c: Block not found");
  
  if ( (runner->bgn == fromPage) && runner->end == (fromPage+npages-1) ) {
    /* the block must be removed!! */
    if ( runner == *pdListBgn )
      *pdListBgn = runner->next;
    else /* assert(runner->prev); */
      runner->prev->next = runner->next;
    if ( runner->next )
      runner->next->prev = runner->prev;
    myfree(runner);
  } else if ( runner->bgn == fromPage ) { /* the block must be left trimmed */
    runner->bgn = fromPage+npages;
  } else if ( runner->end == (fromPage+npages-1) ) { /* right trimmed */
    runner->end = fromPage - 1;
  } else { /* the block must be splitted */
    pdListEl *newEl = __lmt_newPdListEl(runner->bgn, fromPage-1,
					runner, runner->prev);
    if ( runner->prev )
      runner->prev->next = newEl;
    runner->bgn = fromPage+npages;
    runner->prev = newEl;
  }
  
  return 0;
}

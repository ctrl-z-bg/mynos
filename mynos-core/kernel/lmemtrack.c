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

#include "global.h"
#include "dynalloc.h"
#include "video.h"

#define myalloc(sz) kmalloc(sz)
#define myfree(ptr) kfree(ptr)

#define MINPAGES (0x40001)
#define MAXPAGES (0x100000)
#define PAGESPAN(p) ((p).end - (p).bgn)

#define BLOCKNOTFOUND -1
#define AREATOOLARGE -2

#define NOTALLOCATED -1

//pdListEl *pdListBgn = NULL;

pdListEl *__lmt_newPdListEl(int bgn, int end, pdListEl* next, pdListEl* prev)
{
  pdListEl *toret = (pdListEl*) myalloc(sizeof(pdListEl));
  toret->bgn = bgn;
  toret->end = end;
  toret->next = next;
  toret->prev = prev;
  return toret;
}

pdListEl *__lmt_findArea(pdListEl **pdListBgn, int npages)
{
  pdListEl *runner;

  if (!(*pdListBgn)) { /* allocate and return */
    (*pdListBgn) = __lmt_newPdListEl(MINPAGES, MAXPAGES, NULL, NULL);
    return *pdListBgn;
  }

  /* otherwise, first fit */
  runner = *pdListBgn;
  while ( runner && (PAGESPAN(*runner) < npages) ) {    
    runner = runner->next;
  }
  return runner;
}

/* returns the page number at which the area begins.
   Adjusts the free space list */
int __lmt_allocArea(pdListEl **pdListBgn, int npages)
{
  pdListEl *tomod;
  int toret;

  if (npages > (MAXPAGES-MINPAGES)) return AREATOOLARGE;
  
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

/* frees a block of pages, adjusting the list */
int __lmt_freeArea(pdListEl **pdListBgn, int fromPage, int npages)
{
  /* we must find the first block whose 'bgn' is after fromPage+npages */
  pdListEl *runner = *pdListBgn;
  pdListEl *prev;

  while ( runner && (runner->bgn < (fromPage + npages)) )
    runner = runner->next;
  
  if ( !runner ) /* the area was not found! */
    return NOTALLOCATED;

  prev = runner->prev;
  /* runner == *pdListBgn */
  if ( !prev ) {
    if ( (fromPage + npages) == runner->bgn ) { /* extend runner */
      runner->bgn = fromPage;
    } else { /* must create a new previous... */
      *pdListBgn = __lmt_newPdListEl(fromPage, fromPage+npages-1, runner, NULL);
      runner->prev = *pdListBgn;
    }
    return 0;
  }

  if ( (runner->bgn - prev->end) == npages+1 ) {
    /* the freed area joins prev and runner */
    /* must join the two blocks */
    prev->end = runner->end;
    prev->next = runner->next;
    myfree(runner);
  } else if ( prev->end == (fromPage - 1) ) { /* sticks to prev */
    prev->end = fromPage+npages - 1;
  } else if ( (fromPage + npages) == runner->bgn ) { /* sticks to runner */
    runner->bgn = fromPage;
  } else if ( prev->end < (fromPage - 1) ) {
    /* must create another block */
    pdListEl *newBlock =
      __lmt_newPdListEl(fromPage, fromPage+npages-1, runner, prev);
    prev->next = runner->prev  = newBlock;
  } else /* error!! */
    return NOTALLOCATED;
  
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

int __lmt_forceAllocation(pdListEl **pdListBgn, int fromPage, int npages)
{
  /* we must find the first block whose 'bgn' is after fromPage+npages */
  pdListEl *runner = *pdListBgn;

  if ( fromPage < MINPAGES )
    KPANIC("lmemtrack.c: cannot allocate under 1GB (LA)");

  if ( !pdListBgn ) {
    if ( fromPage == MINPAGES ) {
      *pdListBgn = __lmt_newPdListEl(fromPage+npages, MAXPAGES, NULL, NULL);
    } else {
      pdListEl *newEl;
      *pdListBgn = __lmt_newPdListEl(MINPAGES, fromPage-1, NULL, NULL);
      newEl = __lmt_newPdListEl(fromPage+npages, MAXPAGES, NULL, *pdListBgn);
      (*pdListBgn)->next = newEl;
    }
    return 0;
  }
  
  while ( runner && (runner->bgn <= fromPage) )
    runner = runner->next;

  if ( !runner || !(runner->end >= (fromPage+npages-1)) )
    KPANIC("lmemtrack.c: Block not found");
  
  if ( runner->bgn == fromPage ) {
    runner->bgn = fromPage+npages;
  } else { /* create a new block */
    pdListEl *newEl = __lmt_newPdListEl(runner->bgn, fromPage-1,
					runner, runner->prev);
    runner->bgn = fromPage+npages;
    runner->prev = newEl;
  }
  
  return 0;
}

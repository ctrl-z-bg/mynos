#include "dynalloc.h"

extern void * __OS_askPages(unsigned int npages);
extern void * __OS_askPagesFrom(void * pageaddr, unsigned int npages);
extern void * __OS_releasePages(void *pageaddr, unsigned int npages);


/* 1st allocated block (beginning of heap), NULL initialized */
void *_heap = 0;

inline void
_insertBlock(void * current, unsigned int sz, void *previous, void *next)
{
  _BLOCK_SZ(current) = sz;
  _PREV_BLOCK_PTR(current) = previous;
  _NEXT_BLOCK_PTR(current) = next;

  if ( previous )
    _NEXT_BLOCK_PTR(previous) = current;

  if ( next )
    _PREV_BLOCK_PTR(next) = current;
}

int
_allPagesAllocatedBetween(void *begin, void *end)
{
  /* check if there's a whole free page in between, which would be
     UNALLOCATED (and therefore unusable, by our current assumptions */
  /* NOTE: if, from begin to end, there are 3 pages, then there's a
     middle, unallocated one (which explains the '3') */
  return(_PAGE_SPAN(begin, end) < 3 );
}

/* looks for a free block in the allocated heap */
void *
_findFreeBlock(unsigned int sz)
{
  unsigned int osz = sz + _OVERHEAD_SZ; 
  void *old, *runner;
 
  /* first of all, we look for space in the first page of the heap */
  void *page = _GET_PAGE_BLOCK(_heap);
  void *block_bgn = _BLOCK_BGN(_heap);
  if ( block_bgn - page >= osz ) { /* Alright! Found! */
    _insertBlock(page + _SIZE_SZ, sz, 0, _heap);
    _heap = page + _SIZE_SZ;
    return(_heap);
  }
  
  old = 0;
  runner = _NEXT_BLOCK_PTR(_heap);

  while ( runner ) {
    void *ret = _BLOCK_END(old);
    if ( (_BLOCK_BGN(runner) - ret) >= osz ) { /* found! */
      /* check for unallocated pages in between, which make the space
	 unusable */
      if ( _allPagesAllocatedBetween(ret - 1, _BLOCK_BGN(runner)) ) {
	_insertBlock(ret + _SIZE_SZ, sz, old, runner);
	return(ret);
      } else { /* ask for those pages! */
	void * paddr = ret;
	unsigned int npages;
	if ( ret != _GET_PAGE_ADDRESS(ret) ) { /* not at the beginn. of page */
	  paddr = _GET_NPAGE_ADDRESS(ret);
	  /* number of bytes taken from the first page */
	  if ( paddr - ret >= osz ) { /* OK, the sp. in the page was enough */
	    _insertBlock(ret + _SIZE_SZ, sz, old, runner);
	    return(ret);
	  }
	}
	/* otherwise, must allocate */
	npages = _PAGE_SPAN(paddr, ret + osz - 1);
	if ( _GET_PAGE_ADDRESS(ret + osz - 1) == _GET_PAGE_BLOCK(runner) )
	  /* end within an allocated page */
	  npages--;
	__OS_askPagesFrom(paddr, npages);
	_insertBlock(ret + _SIZE_SZ, sz, old, runner);
	return(ret);
      }
    }
    
    old = runner;
    runner = _NEXT_BLOCK_PTR(runner);
  }

  /* if runner is null, check for space at the end of the page */
  if ( !runner ) {
    void *bend = _BLOCK_END(old);
    /* address os the successive (unallocated) page */
    void *npage = _GET_NPAGE_ADDRESS(bend);
    if ( (npage - bend) >= osz ) { /* space at the end! */
      void *ret = bend + _SIZE_SZ;
      _insertBlock(ret, sz, old, 0);
      return(ret);
    }
  }
  
  /* no free space found */
  return(0);
}

/* asks the OS for npages, and allocates a block of size sz */
void *
_createNewBlock(unsigned int npages, unsigned int sz)
{
  void *addr = __OS_askPages(npages);
  if ( !addr ) /* storage exhausted */
    return(0);

  /* now, find the first block successive to address */
  if ( _heap ) {
    void *old = 0;
    void *runner = _heap;
    
    while ( runner && (addr > runner) ) {
      old = runner;
      runner = _NEXT_BLOCK_PTR(runner);
    }
    /* now we know that old and runner are previous and next to addr, or
       NULL */
    addr += _SIZE_SZ;
    _insertBlock(addr, sz, old, runner);
  } else { /* first allocation */
    addr += _SIZE_SZ;
    _insertBlock(addr, sz, 0, 0);
    _heap = addr;
  }

  return(addr);
}


void *
malloc(unsigned int sz)
{
  void *ret = 0;

  /* first of all, figures out how many pages are needed */
  unsigned int npages = _N_PAGES(sz);
  /* We now assume we KNOW what page to request. Therefore, we don't care
     for how many pages were requested unless no space was found, or if
     nothing was ever allocated */
  if ( _heap ) /* was: ( _heap && !npages ) */
    ret = _findFreeBlock(sz);
  /* If a hole couldn't be found, or nothing was ever allocated,
     ask OS for some page (at least 1) */
  if ( !ret )
    ret = _createNewBlock(((npages < 1)?1:npages), sz);
  /* done (whatever ret is) */
  return(ret);
}

/* removes a block from the allocated list, and returns eventually freed
   pages to the OS */
void
_removeBlock(void *ptr, void *prev)
{
  void *next = _NEXT_BLOCK_PTR(ptr);
  /* void *bgn = _BLOCK_BGN(ptr); */
  void *end = _BLOCK_END(ptr);
  void *firstPage;
  void *lastPage;
  
  if ( prev )
    _NEXT_BLOCK_PTR(prev) = next;
  if ( next )
    _PREV_BLOCK_PTR(next) = prev;

  /* now, frees all pages between bgn and end */
  firstPage =
    (_GET_PAGE_BLOCK(ptr) == ptr)?_GET_PAGE_BLOCK(ptr):_GET_NPAGE_ADDRESS(ptr);
  lastPage = _GET_PAGE_ADDRESS(end);
  if ( end < lastPage + (1 << 12) - 1)  /* it wasn't at the end of the p. */
    lastPage -= ( 1 << 12); /* up one page */
}

void
free(void *ptr)
{
  void *runner;

  /* first, checks if we're deallocating at the beginning of the heap */
  if ( ptr == _heap ) {
    _heap = _NEXT_BLOCK_PTR(ptr);
    _removeBlock(ptr, 0);
    return;
  }

  runner = _heap;

  /* assertion, ptr *IS* a pointer allocated by malloc, therefore
   *MUST* be found in the list */
  while ( ptr != _NEXT_BLOCK_PTR(runner) )
    runner = _NEXT_BLOCK_PTR(runner);
  
  _removeBlock(ptr, runner);

  return;
}
















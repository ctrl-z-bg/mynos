#include "global.h"
#include "dynalloc.h"

extern void * __OS_askPages(unsigned int npages, int alloc_now, 
			    uint32_t flags);
extern void * __OS_askPagesFrom(void * pageaddr, unsigned int npages,
				int alloc_now, uint32_t flags);
extern void * __OS_releasePages(void *pageaddr, unsigned int npages);


/* 1st allocated block (beginning of heap), NULL initialized */
void *_heap = NULL;

inline void
_insertBlock(void * current, unsigned int sz, void *previous, void *next)
{
  /* first of all, see if the new block is above the current heap,
     in which case the block address is the new address of the heap */
  /* CHECK!!! */
  if ( (_heap == NULL) || (current < _heap) )
    _heap = current;
  /* /CHECK!!! */

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
     UNALLOCATED (and therefore unusable, by our current assumptions) */
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
 
/*   /\* first of all, we look for space in the first page of the heap *\/ */
/*   void *page = _GET_PAGE_BLOCK(_heap); */
/*   void *block_bgn = _BLOCK_BGN(_heap); */
/*   if ( block_bgn - page >= osz ) { /\* Alright! Found! *\/ */
/*     _insertBlock(page + _SIZE_SZ, sz, 0, _heap); */
/*     _heap = page + _SIZE_SZ; */
/*     return(_heap); */
/*   } */
/* It's not clear why I would treat the first heap page differently */
/* from the rest. Now it's all nice and clean. */
  
  old = _heap;
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
	__OS_askPagesFrom(paddr, npages, 0, 0);
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
    /* address of the successive (unallocated) page */
    void *npage = _GET_NPAGE_ADDRESS(bend);
    if ( (npage - bend) >= osz ) { /* space at the end! */
      void *ret = bend + _SIZE_SZ;
      _insertBlock(ret, sz, old, 0);
      return(ret);
    }
  }
  
  /* no free space found */
  return(NULL);
}

/* asks the OS for npages, and allocates a block of size sz */
void *
_createNewBlock(unsigned int npages, unsigned int sz)
{
  void *addr = __OS_askPages(npages, NULL, NULL);
  /* now, find the first block successive to address */
  void *old = NULL;
  void *runner = _heap;
  

  if ( !addr ) /* storage exhausted */
    return(NULL);

  /* The actual address is 4 bytes more, since we must leave room
     to hold the size */
  addr += _SIZE_SZ;

  /* In case addr is less than _heap, we simply insert the block
     on top (_insertBlock will also modify the value of _heap).
     NOTE: if _heap is NULL, this while is skipped, and old and runner
     will both be NULL.
  */
  while ( runner && (addr > runner) ) {
    old = runner;
    runner = _NEXT_BLOCK_PTR(runner);
  }
  /* now we know that old and runner are previous and next to addr, or
     NULL */
  _insertBlock(addr, sz, old, runner);
  
  return(addr);
}

void *
kmalloc(unsigned int sz)
{
  void *ret = NULL;

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
  int nPagesToRelease;

  if ( prev )
    _NEXT_BLOCK_PTR(prev) = next;
  if ( next )
    _PREV_BLOCK_PTR(next) = prev;

  /* find the first page whose first byte was withing the current block */
  firstPage =
    (_GET_PAGE_BLOCK(ptr) == ptr)?_GET_PAGE_BLOCK(ptr):_GET_NPAGE_ADDRESS(ptr);
  /* same thing, find the last page whose LAST byte was within the block */
  lastPage = _GET_PAGE_ADDRESS(end);
  if ( end < lastPage + (1 << 12) - 1)  /* it wasn't at the end of the p. */
    lastPage -= ( 1 << 12); /* up one page */
  
  nPagesToRelease = ((int) (((unsigned int) lastPage) >> 12)) -
    ((int) (((unsigned int) firstPage) >> 12 ));
  
  /* now, ask the OS to release these pages */
  if ( nPagesToRelease > 0 )
    __OS_releasePages(firstPage, (unsigned int) nPagesToRelease);
    
}

void
kfree(void *ptr)
{
  void *runner;

  /* first, check if we're deallocating at the beginning of the heap */
  if ( ptr == _heap ) {
    /* WARNING: THIS MOVES THE HEAP FORWARD!!! */
    /* (however, if there's not enough space at the end of the heap, the
       OS might return a page above the current heap, which, if everything
       is correct, should move the value of _heap back again) */
    _heap = _NEXT_BLOCK_PTR(ptr);
    _removeBlock(ptr, NULL);
    return;
    /* Returning after having modified the _heap, might have set it to
       NULL, in case there is nothing more allocated. This is OK. */
  }

  /* Otherwise, look for the block we are deallocating */
  runner = _heap;

  /* assertion, ptr *IS* a pointer allocated by kmalloc, therefore
   *MUST* be found in the list */
  while ( ptr != _NEXT_BLOCK_PTR(runner) )
    runner = _NEXT_BLOCK_PTR(runner);
  
  _removeBlock(ptr, runner);

  /* NOTE: a robustness check: we might want to check for ptr being
     different from NULL. If ptr is NULL, it means the block was not found,
     and an error could be issued (not really returned, since the function
     returns void) */

  return;
}


#include "global.h"
#include "dynalloc.h"

extern void * __OS_askPages(unsigned int npages, int alloc_now, 
			    uint32_t flags);
extern void * __OS_askPagesFrom(void * pageaddr, unsigned int npages,
				int alloc_now, uint32_t flags);
extern void * __OS_releasePages(void *pageaddr, unsigned int npages, 
				int free, int check);


/* 1st allocated block (beginning of heap), NULL initialized */
void *_heap = NULL;

static inline void
_insertBlock(void * current, unsigned int sz, void *previous, void *next)
{
  /* first of all, see if the new block is above the current heap,
     in which case the block address is the new address of the heap */
  if ( (_heap == NULL) || (current < _heap) )
    _heap = current;

  _BLOCK_SZ(current) = sz;
  _PREV_BLOCK_PTR(current) = previous;
  _NEXT_BLOCK_PTR(current) = next;

  if ( previous )
    _NEXT_BLOCK_PTR(previous) = current;

  if ( next )
    _PREV_BLOCK_PTR(next) = current;
}

/* Can a new block occupy [begin, end] (end included) between two heap
   blocks without asking for pages? Only if it stays in pages the heap
   already holds: the page where the previous block ends (begin's page) and
   the page where the next block starts. Any other page may belong to
   someone else: __OS_askPages hands out kernel pages for other uses too
   (page directories...), interleaved with heap pages. The old test (fewer
   than 3 pages spanned) let a block run into such a page and overwrite it. */
static int
_heapOwnsSpan(void *begin, void *end, void *next)
{
  void *first = _GET_PAGE_ADDRESS(begin);
  void *last = _GET_PAGE_ADDRESS(end);
  if (last == first) return 1;
  return (last == _GET_PAGE_BLOCK(next)) && (last - first == _PAGE_SZ);
}

/* looks for a free block in the allocated heap */
void *
_findFreeBlock(unsigned int sz)
{
  unsigned int osz = sz + _OVERHEAD_SZ; 
  void *old, *runner;
 
  /* first of all, we look for space in the first page of the heap,
     but ABOVE the address of _heap */
  void *page = _GET_PAGE_BLOCK(_heap);
  void *block_bgn = _BLOCK_BGN(_heap);
  if ( block_bgn - page >= osz ) { /* Alright! Found! */
    _insertBlock(page + _SIZE_SZ, sz, NULL, _heap);
    return(_heap); /* returning the new, modified _heap (page + _SIZE_SZ) */
  }
  
  /* Otherwise, scans through the list of busy blocks to find sufficient
     space */
  old = _heap;
  runner = _NEXT_BLOCK_PTR(_heap);

  while ( runner ) {
    void *ret = _BLOCK_END(old);
    if ( (_BLOCK_BGN(runner) - ret) >= osz ) { /* found! */
      /* If all the pages this block spans are allocated, the space
	 is immediately usable */
      if ( _heapOwnsSpan(ret, ret + osz - 1, runner) ) {
	_insertBlock(ret + _SIZE_SZ, sz, old, runner);
	return(ret + _SIZE_SZ);
      } else { /* ask for those pages! */
	void * paddr = ret; /* address of the 1st page to request */
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
	if ( __OS_askPagesFrom(paddr, npages, 1, 0) != NULL ) {
	  /* ok, insert the block and return the address */
	  _insertBlock(ret + _SIZE_SZ, sz, old, runner);
	  return(ret + _SIZE_SZ);
	} /* otherwise, keep scanning */
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
      _insertBlock(ret, sz, old, NULL);
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
  void *addr = __OS_askPages(npages, 1, 0);
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
     are both NULL.
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
  void *bgn = _BLOCK_BGN(ptr);
  void *end = _BLOCK_END(ptr);
  void *firstPage = _GET_PAGE_BLOCK(ptr);
  void *firstPageToRelease;
  void *lastPageToRelease;
  int nPagesToRelease;

  if ( prev )
    _NEXT_BLOCK_PTR(prev) = next;
  if ( next )
    _PREV_BLOCK_PTR(next) = prev;

  /* find the first page whose first byte was within the current block */
  /* ...however, perhaps the previous block does not use the page, in which
     case we can release it */
  if ( (firstPage == bgn) ||
       !prev || (firstPage > _GET_PAGE_BLOCK(_BLOCK_END(prev)-1)) )
    firstPageToRelease = firstPage;
  else
    /* skip this busy page: free the successive one */
    firstPageToRelease = firstPage + ( 1 << 12 );


  /* same thing, find the last page whose LAST byte was within the block */
  /* unless the following block begins on the same page, we can release
     the page, otherwise, the last page is one page up */
  lastPageToRelease = _GET_PAGE_ADDRESS(end-1);
  if ( next && (_GET_PAGE_BLOCK(next) == lastPageToRelease) )
    lastPageToRelease -= ( 1 << 12); /* up one page */
  
  nPagesToRelease = _PAGE_SPAN(firstPageToRelease, lastPageToRelease);
  
  /* now, ask the OS to release these pages */
  /* (it used to release from firstPage, even when that page still held
     the previous block) */
  if ( nPagesToRelease > 0 )
    __OS_releasePages(firstPageToRelease, (unsigned int) nPagesToRelease, 1, 0);
    
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


/*
  dynalloc.h -- dynamic allocation functions and structures

  (c) MyNOS team etc. etc.

  So far:
  for each allocation request of n bytes, malloc looks for a space sufficient
  for a block of the form:

  +---------+
  | 4 bytes |  holds the value n (BLOCK_SZ) 
  +---------+
  |         |<- BLOCK_PTR
  : n bytes :  data block, the pointer to this area is returned (BLOCK_PTR)
  |         |
  +---------+
  | 4 bytes |  the pointer to the previous allocated block (PBLOCK_PTR)
  +---------+
  | 4 bytes |  the pointer to the next allocated block (NBLOCK_PTR)
  +---------+

  pointers always refer to BLOCK_PTR, so that the following holds:
  *(BLOCK_PTR - 4) = n (4 is to be replaced by a define)
  *(BLOCK_PTR + *(BLOCK_PTR - 4)) = PBLOCK_PTR
  *(BLOCK_PTR + *(BLOCK_PTR - 4) + 4) = NBLOCK_PTR

  The pointer to the first allocated block is held in a global variable.

  For this version, we assume whenever a page is free, it is returned
  to the OS. Therefore, whenever more than 8kb are requested, pages
  must be asked to the OS. In theory, it is possible that a free space
  of strictly less than 8kb exists, spanning across two pages. In practice,
  it's probably a good idea, under these assumption, to ask for a new
  page whenever the allocation of more than 4kb is requested.

*/

/* Some defines */

#define _SIZE_SZ (4)  /* number of bytes for size */
#define _ADDR_SZ  (4) /* number of bytes for address */
/* # of overhead bytes for allocation */
#define _OVERHEAD_SZ ((2 * _ADDR_SZ) + _SIZE_SZ)

/* Macros of various sort */

 /* size of a block */
#define _BLOCK_SZ(ptr) (*(unsigned int *)(ptr - _SIZE_SZ))
/* total size of block + overhead */
#define _BLOCK_OSZ(ptr) (_BLOCK_SZ(ptr) + _OVERHEAD_SZ)

/* actual beginning of a block */
#define _BLOCK_BGN(ptr) (ptr - _SIZE_SZ)
/* pointer to right after the end of the block */
#define _BLOCK_END(ptr) (_BLOCK_BGN(ptr) + _BLOCK_OSZ(ptr))

/* Given a block, returns the beginning of the page holding that block */
/* We are assuming 12-bit page addresses, here */
#define _GET_PAGE_BLOCK(ptr) \
    ((void *) (((unsigned int) (_BLOCK_BGN(ptr)) >> 12) << 12))

/* same thing, beginning of the next page */
#define _GET_NPAGE_BLOCK(ptr) \
    ((void *) (((unsigned int) (_BLOCK_END(ptr)) >> 12) + 1) << 12))

/* same thing as the previous two, but for addresses in general */
/* page holding an address */
#define _GET_PAGE_ADDRESS(ptr) \
    ((void *) ((((unsigned int) (ptr)) >> 12 ) << 12))
/* next page */
#define _GET_NPAGE_ADDRESS(ptr) \
    ((void *) (((((unsigned int) (ptr)) >> 12 ) + 1) << 12))

/* number of pages to request for a block of size sz */
#define _N_PAGES(sz) (((sz) + _OVERHEAD_SZ) >> 12)

/* pointer to the previous and next block */
#define _PREV_BLOCK_PTR(ptr) (*(void **)((ptr) + _BLOCK_SZ(ptr)))
#define _NEXT_BLOCK_PTR(ptr) (*(void **)((ptr) + _BLOCK_SZ(ptr) + _ADDR_SZ))

/* number of pages from bgn to end */
#define _PAGE_SPAN(bgn, end) ((((unsigned int) (end)) >> 12) - \
                              (((unsigned int) (bgn)) >> 12) + 1)

/* No explanation needed */
void *
malloc(unsigned int sz);

/* No explanation needed */
void
free(void *ptr);

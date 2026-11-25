/*
  MyNOS
  Copyright (C) 2002, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The kernel heap: size classes and whole pages (see dynalloc.h). */

#include "global.h"
#include "dynalloc.h"
#include "kutils.h"
#include "video.h"

extern void * __OS_askPages(unsigned int npages, int alloc_now,
			    uint32_t flags);
extern void * __OS_releasePages(void *pageaddr, unsigned int npages,
				int free, int check);

/* define HEAP_CHECK to fill freed blocks with a pattern and check it when
   they are given again: a write after kfree is then reported, and a read
   after kfree sees the pattern, not plausible data. Every block also
   records its caller, and kheap_owners counts the blocks in use by caller
   (a leak is a count that grows: print it from gdb). */
/* #define HEAP_CHECK */

#define PAGE 4096

/* every block starts with this header; the caller gets the bytes after */
typedef struct {
  uint32_t magic;
  uint32_t size;       /* small: the class's block size; large: pages */
#ifdef HEAP_CHECK
  void * caller;       /* who allocated it */
  uint32_t pad;
#endif
} header_t;

#ifdef HEAP_CHECK
/* blocks in use by caller of kmalloc: a leak shows as a count that grows
   (print it from gdb: kheap_owners) */
#define NOWNERS 128
struct { void * caller; int blocks; } kheap_owners[NOWNERS];
static void owner_count(void * caller, int d) {
  int i, free_slot = -1;
  for (i = 0; i < NOWNERS; i++) {
    if (kheap_owners[i].caller == caller) { kheap_owners[i].blocks += d; return; }
    if (free_slot < 0 && kheap_owners[i].caller == NULL) free_slot = i;
  }
  if (free_slot >= 0 && d > 0) {
    kheap_owners[free_slot].caller = caller;
    kheap_owners[free_slot].blocks = d;
  }
}
#endif

#define HDR sizeof(header_t)

#define MAGIC_SMALL 0x4B4D5331   /* in use */
#define MAGIC_LARGE 0x4B4D4C31   /* in use, whole pages */
#define MAGIC_FREE  0x4B4D4630   /* in a free list */

#define POISON 0xDB

/* block sizes, header included */
static const uint32_t class_size[] = { 32, 64, 128, 256, 512, 1024, 2048 };
#define NCLASSES (sizeof(class_size) / sizeof(class_size[0]))

/* the free blocks of each class, linked through their first word after
   the header */
static header_t * free_list[NCLASSES];

static uint32_t used_bytes = 0, held_pages = 0;

uint32_t kheap_used(void) { return used_bytes; }
uint32_t kheap_pages(void) { return held_pages; }

static void report(const char * what, void * ptr, void * caller)
{
  int on_screen = kernel_on_screen;
  kernel_on_screen = 1;
  printk("kernel heap: ");
  printk((char *)what);
  printk(" ");
  print_ulong_hex((unsigned long)ptr);
  printk(" (caller ");
  print_ulong_hex((unsigned long)caller);
  printk(")\n");
  kernel_on_screen = on_screen;
}

/* a page more for class c, cut into blocks */
static int refill(int c)
{
  char * page = __OS_askPages(1, 1, 0);
  uint32_t off;
  if (page == NULL) return -1;
  held_pages++;
  for (off = 0; off + class_size[c] <= PAGE; off += class_size[c]) {
    header_t * h = (header_t *)(page + off);
    h->magic = MAGIC_FREE;
    h->size = class_size[c];
#ifdef HEAP_CHECK
    kmemset((char *)h + HDR, POISON, class_size[c] - HDR);
#endif
    *(header_t **)((char *)h + HDR) = free_list[c];
    free_list[c] = h;
  }
  return 0;
}

static void * alloc(unsigned int sz, void * caller)
{
  uint32_t c;
  header_t * h;

  if (sz == 0) sz = 1;
  for (c = 0; c < NCLASSES && class_size[c] - HDR < sz; c++) ;
  if (c == NCLASSES) {                     /* whole pages */
    uint32_t npages = (sz + HDR + PAGE - 1) / PAGE;
    h = __OS_askPages(npages, 1, 0);
    if (h == NULL) return NULL;
    h->magic = MAGIC_LARGE;
    h->size = npages;
    held_pages += npages;
    used_bytes += npages * PAGE;
    return (char *)h + HDR;
  }
  if (free_list[c] == NULL && refill(c) < 0) return NULL;
  h = free_list[c];
  if (h->magic != MAGIC_FREE) {
    report("free list corrupted at", h, caller);
    free_list[c] = NULL;                   /* drop the list, start again */
    if (refill(c) < 0) return NULL;
    h = free_list[c];
  }
#ifdef HEAP_CHECK
  {
    unsigned char * p = (unsigned char *)h + HDR + sizeof(header_t *);
    unsigned char * end = (unsigned char *)h + class_size[c];
    for (; p < end; p++)
      if (*p != POISON) {
	report("block written after kfree", (char *)h + HDR, caller);
	break;
      }
  }
#endif
  free_list[c] = *(header_t **)((char *)h + HDR);
  h->magic = MAGIC_SMALL;
  used_bytes += class_size[c];
#ifdef HEAP_CHECK
  h->caller = caller;
  owner_count(caller, 1);
#endif
  /* blocks are given zeroed: a field left unset is 0, not whatever the
     block held before (a page fresh from the OS is zeroed, a reused block
     is not: the difference hid a bug for twenty years) */
  kbzero((char *)h + HDR, class_size[c] - HDR);
  return (char *)h + HDR;
}

static void release(void * ptr, void * caller)
{
  header_t * h;
  uint32_t c;

  if (ptr == NULL) return;
  h = (header_t *)((char *)ptr - HDR);
  if (h->magic == MAGIC_LARGE) {
    h->magic = MAGIC_FREE;
    held_pages -= h->size;
    used_bytes -= h->size * PAGE;
    __OS_releasePages(h, h->size, 1, 0);
    return;
  }
  if (h->magic != MAGIC_SMALL) {
    report(h->magic == MAGIC_FREE ? "block freed twice:" : "not a block:",
	   ptr, caller);
    return;
  }
  for (c = 0; c < NCLASSES && class_size[c] != h->size; c++) ;
  if (c == NCLASSES) {
    report("bad block size:", ptr, caller);
    return;
  }
  h->magic = MAGIC_FREE;
  used_bytes -= class_size[c];
#ifdef HEAP_CHECK
  owner_count(h->caller, -1);
#endif
#ifdef HEAP_CHECK
  kmemset((char *)h + HDR, POISON, class_size[c] - HDR);
#endif
  *(header_t **)((char *)h + HDR) = free_list[c];
  free_list[c] = h;
}

void * kmalloc(unsigned int sz)
{
  return alloc(sz, __builtin_return_address(0));
}

void kfree(void * ptr)
{
  release(ptr, __builtin_return_address(0));
}

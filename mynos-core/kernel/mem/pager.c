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
 * The external pager (mynos-vzp; doc/manual/appendix-b-memory.md, B.14).
 *
 * A process with the io privilege may become the pager. It gives regions
 * of other processes' memory pages that are not there yet: entries not
 * present, marked PF_PAGER, with a token (bits 12-31) that names the page
 * for the pager. A thread that touches one waits; the pager is told (its
 * semaphore, as a driver is told of its IRQ), asks which page with
 * pager_next, and answers with pager_supply: one of its own pages,
 * moved (not copied) to the waiting process, or none (the thread's
 * process ends, as for an invalid access). The kernel decides nothing
 * about the pages: what they hold, and when, is the pager's.
 *
 * Every page the kernel manages today stays as it is: only the regions
 * given to the pager wait for it, and the pager's own memory, the file
 * system's and the disk driver's are never among them.
 */

#include "mem.h"
#include "externalmem.h"
#include "physicalmem.h"
#include "lmemtrack.h"
#include "../process.h"
#include "../sem.h"
#include "../trace.h"
#include "../video.h"
#include "mynos.h"

#define PAGER_WAITS 64             /* pages waited for at once */
#define PAGER_TOKENS (1 << 20)     /* bits 12-31 of an entry */

typedef struct {
  int used;
  pid_t pid;                       /* the process that waits */
  uint32_t page;                   /* the linear page */
  uint32_t token;
  int write;                       /* the first fault was a write */
  int delivered;                   /* the pager has read it (pager_next) */
  int done;                        /* answered: the waiters are woken */
  int failed;                      /* answered with no page */
  int waiters;                     /* threads waiting on sem */
  int sem;
} pager_wait_t;

static pager_wait_t waits[PAGER_WAITS];
static pid_t pagerPid = 0;         /* 0: no pager */
static int pagerSem = -1;          /* V once for each page waited for */
static int slotsSem = -1;          /* the free entries of waits */

static int pagerAlive(void) {
  process_descriptor_t * p = pagerPid ? proc(pagerPid) : NULL;
  return p && p->isAlive && p->pid == pagerPid;
}

static pager_wait_t * findWait(pid_t pid, uint32_t page) {
  int i;
  for (i = 0; i < PAGER_WAITS; i++)
    if (waits[i].used && !waits[i].done && waits[i].pid == pid && waits[i].page == page)
      return &waits[i];
  return NULL;
}

static void release(pager_wait_t * w) {
  __OS_sem_freeSemaphore(w->sem);
  w->used = 0;
  __OS_sem_V(slotsSem);
}

/* answered: wake whoever waits; the last of them frees the entry */
static void wake(pager_wait_t * w, int failed) {
  int i, n = w->waiters;
  w->failed = failed;
  w->done = 1;
  if (n == 0) { release(w); return; }
  for (i = 0; i < n; i++) __OS_sem_V(w->sem);
}

void __pager_fault(uint32_t entry, uint32_t addr, uint32_t errcode) {
  pid_t pid = CURRPID;
  uint32_t page = addr >> 12;
  pager_wait_t * w;
  int failed, i;

  /* a write to a region the pager gave read-only, or nobody to ask */
  if (((errcode & 2) && !(entry & PF_READWRITE)) || !pagerAlive())
    __mem_userSegfault(addr);

  w = findWait(pid, page);
  if (w == NULL) {
    __OS_sem_P(slotsSem);              /* a free entry (may wait) */
    w = findWait(pid, page);           /* another thread asked meanwhile */
    if (w != NULL) __OS_sem_V(slotsSem);
    else {
      for (i = 0; i < PAGER_WAITS && waits[i].used; i++) ;
      w = &waits[i];
      w->used = 1;
      w->pid = pid;
      w->page = page;
      w->token = entry >> 12;
      w->write = (errcode & 2) != 0;
      w->delivered = w->done = w->failed = 0;
      w->waiters = 0;
      w->sem = __OS_sem_allocateSemaphore(0);
      TRACE(TRACE_FAULT, pid, pagerPid, -1, 0, page, NULL, 0);
      if (!pagerAlive()) { wake(w, 1); __mem_userSegfault(addr); }
      __OS_sem_V(pagerSem);
    }
  }
  w->waiters++;
  __OS_sem_P(w->sem);
  failed = w->failed;
  if (--w->waiters == 0 && w->done) release(w);
  if (failed) __mem_userSegfault(addr);
  /* the page is there: the instruction runs again */
}

/* the pager, or a process that waited, has ended */
void __pager_processEnded(pid_t pid) {
  int i;
  if (pid == pagerPid) {
    /* nobody will answer: every waiting thread's process ends */
    pagerPid = 0;
    pagerSem = -1;                     /* freed with the pager's semaphores */
    for (i = 0; i < PAGER_WAITS; i++)
      if (waits[i].used && !waits[i].done) wake(&waits[i], 1);
  }
  /* its own waits: its threads are gone, nobody will decrement them */
  for (i = 0; i < PAGER_WAITS; i++)
    if (waits[i].used && waits[i].pid == pid) release(&waits[i]);
}

/* ---- the pager's system call (native 37) ---- */

static int pagerRegister(void) {
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (pagerAlive() && pagerPid != CURRPID) return MYNOS_ERR_BUSY;
  if (slotsSem < 0) slotsSem = __OS_sem_allocateSemaphore(PAGER_WAITS);
  if (pagerSem < 0 || pagerPid != CURRPID) {
    pagerSem = __OS_sem_allocateSemaphore(0);
    __OS_sem_setOwner(pagerSem, CURRPID);   /* the pager waits on it */
  }
  pagerPid = CURRPID;
  return pagerSem;
}

/* npages of pid's linear space, from token on: the first page's number */
static int pagerRegion(pid_t pid, uint32_t npages, uint32_t token, uint32_t writable) {
  process_descriptor_t * p = proc(pid);
  uint32_t first, i;
  if (pagerPid != CURRPID) return MYNOS_ERR_DENY;
  if (!p || !p->isAlive || p->pid != pid || npages == 0 ||
      token >= PAGER_TOKENS || npages > PAGER_TOKENS - token)
    return MYNOS_ERR_INVALID;
  first = __lmt_allocArea(&p->lmemmap, npages);
  if (first < USERMINPAGE) return MYNOS_ERR_FULL;
  for (i = 0; i < npages; i++)
    __mem_setExternalPTE(pid, (first + i) << 12,
                         ((token + i) << 12) | PF_PAGER | PF_USER |
                         (writable ? PF_READWRITE : 0));
  return (int)first;
}

/* the next page waited for, not told yet: 1, or 0 for none */
static int pagerNext(uint32_t buf) {
  uint32_t e[4];
  int i;
  if (pagerPid != CURRPID) return MYNOS_ERR_DENY;
  for (i = 0; i < PAGER_WAITS; i++) {
    pager_wait_t * w = &waits[i];
    if (!w->used || w->delivered || w->done) continue;
    e[0] = w->pid;
    e[1] = w->page << 12;
    e[2] = w->token;
    e[3] = w->write;
    if (copy_to_user((void *)buf, e, sizeof e)) return MYNOS_ERR_INVALID;
    w->delivered = 1;
    return 1;
  }
  return 0;
}

/* the answer: the pager's page at src moves to pid at addr (src 0: no
   page, the waiting process ends) */
static int pagerSupply(pid_t pid, uint32_t addr, uint32_t src) {
  pager_wait_t * w;
  process_descriptor_t * p = proc(pid);
  uint32_t * pte, * target, frame;

  if (pagerPid != CURRPID) return MYNOS_ERR_DENY;
  w = findWait(pid, addr >> 12);
  if (w == NULL) return MYNOS_ERR_INVALID;
  if (!p || !p->isAlive || p->pid != pid) { release(w); return MYNOS_ERR_INVALID; }
  if (src == 0) { wake(w, 1); return 0; }

  /* the pager's page: its own, present, not shared with anyone */
  if ((src & 0xFFF) || !__mem_userArea((void *)src, PAGE_SIZE)) return MYNOS_ERR_INVALID;
  pte = (uint32_t *)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(src), __ADDRESS_PT_INDEX(src));
  if (*pte & PF_LOGICAL_PRESENT) __mem_allocateOnUse(src);
  else if (*pte & PF_COW) __mem_cowManager(src);
  if (!(*pte & PF_PRESENT) || (*pte & PF_SHARED) || pmem_countref(*pte >> 12) != 1)
    return MYNOS_ERR_INVALID;
  frame = *pte >> 12;

  target = __mem_externalPTE(pid, addr);
  if (target == NULL || !IS_PAGER_ENTRY(*target)) {
    /* not a page of the pager's any more (unmapped meanwhile): the thread
       tries again, and finds what is there now */
    wake(w, 0);
    return MYNOS_ERR_INVALID;
  }
  *target = (frame << 12) | PF_PRESENT | PF_USER | (*target & PF_READWRITE);

  /* the pager's address gets a fresh page at its next use */
  *pte = PF_USER | PF_READWRITE | PF_LOGICAL_PRESENT;
  INVALIDATE_THE_CACHE(src);

  TRACE(TRACE_PAGE, CURRPID, pid, -1, PAGE_SIZE, addr >> 12, NULL, 0);
  wake(w, 0);
  return 0;
}

int _mynos_syscall_pager(uint32_t op, uint32_t a, uint32_t b, uint32_t c, uint32_t d) {
  switch (op) {
  case MYNOS_PAGER_REGISTER: return pagerRegister();
  case MYNOS_PAGER_REGION:   return pagerRegion((pid_t)a, b, c, d);
  case MYNOS_PAGER_NEXT:     return pagerNext(a);
  case MYNOS_PAGER_SUPPLY:   return pagerSupply((pid_t)a, b, c);
  }
  return MYNOS_ERR_INVALID;
}

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
 * A process's address space on x86-64 (doc/decisions/x86-64.md, choices
 * 3 and 4): built from an ELF64 image, copied for fork, freed. Every
 * table and frame is reached through the direct map, whatever space is
 * current.
 *
 *   PML4[256..511]  the kernel's (the direct map), shared
 *   PML4[0]         the process's PDPT: entry 0, the kernel's gigabyte
 *                   (one page directory, shared); entries 1..511, the
 *                   process's own, from 1 GB to 512 GB
 *
 * The program at 1 GB (at most 4 MB, as on the i386), the RAM disk right
 * after it, read-only, its frames shared and never counted; the user
 * stack under USER_AREA_END. Unlike the i386's, the first thread's kernel
 * stack and the process information are in the kernel's gigabyte (kept
 * in ptsMirror and processData, freed with the space).
 */

#include "global.h"
#include "mem/mem.h"
#include "mem/dynalloc.h"
#include "mem/lmemtrack.h"
#include "tss.h"
#include "idt.h"
#include "process.h"
#include "threads.h"
#include "kutils.h"
#include "sem.h"
#include "random.h"
#include "sched.h"
#include "video.h"
#include "ipc/port.h"
#include "ipc/channel.h"
#include "mynos.h"

extern process_descriptor_t * processTable[];
extern uint32_t numProcesses, numThreads;
extern paddr_t kernel_pml4, kernel_pd;
extern struct frame * current_frame;
extern void trap_return(void);
#ifdef RAMDISK
extern void * ramdisk;
extern uint32_t ramdisk_len;
extern uint32_t ramdisk_present;
#endif

#define PROGRAM_BASE 0x40000000UL
#define PROGRAM_MAX  0x400000UL
#define RAMDISK_BASE (PROGRAM_BASE + PROGRAM_MAX)

static char * default_argv[] = { "mynos", NULL };

/* ---- ELF64 ---- */

typedef struct {
  unsigned char ident[16];
  uint16_t type, machine;
  uint32_t version;
  uint64_t entry, phoff, shoff;
  uint32_t flags;
  uint16_t ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
} Elf64_Ehdr;

typedef struct {
  uint32_t type, flags;
  uint64_t offset, vaddr, paddr, filesz, memsz, align;
} Elf64_Phdr;

#define PT_LOAD 1
#define ELF_MAXSEG 16

/* ---- frames and tables ---- */

static paddr_t new_frame(void)
{
  paddr_t p = (paddr_t)pmem_findAFreePhysicalPage() << 12;
  if (p == 0) return 0;
  pmem_set(p >> 12);
  kbzero(PHYS_TO_VIRT(p), PAGE_SIZE);
  return p;
}

static int isRamdiskFrame(paddr_t f)
{
#ifdef RAMDISK
  return ramdisk_present && f >= (paddr_t)ramdisk &&
         f < (paddr_t)ramdisk + ramdisk_len;
#else
  return 0;
#endif
}

/* a new space: the kernel's halves shared, the process's PDPT empty */
static paddr_t new_space(void)
{
  paddr_t top = new_frame(), pdpt = new_frame();
  pte_t * t = PHYS_TO_VIRT(top), * k = PHYS_TO_VIRT(kernel_pml4);
  int i;
  for (i = 256; i < 512; i++) t[i] = k[i];
  t[0] = pdpt | PF_PRESENT | PF_READWRITE | PF_USER;
  ((pte_t *)PHYS_TO_VIRT(pdpt))[0] = kernel_pd | PF_PRESENT | PF_READWRITE | PF_USER;
  return top;
}

/* ---- the initial stack: argc, argv, envp, the auxiliary vector ---- */

/* what the auxiliary vector tells the C library: where the program's
   headers are (musl finds PT_TLS there: without it a thread's TLS block
   was taken as empty, and new threads' TLS lay on their stacks' tops),
   the entry, 16 random bytes (the stack protector's canary) */
struct auxinfo { vaddr_t phdr; uint64_t phnum, entry; };
#define AUX_WORDS (2 * 6)               /* PHDR PHENT PHNUM PAGESZ ENTRY RANDOM */

static uint32_t initialStackSize(char ** argv, char ** envp)
{
  uint32_t words = 1 + 1 + 1 + 2 + AUX_WORDS, bytes = 16, i;
  for (i = 0; argv && argv[i]; i++, words++) bytes += kstrlen(argv[i]) + 1;
  for (i = 0; envp && envp[i]; i++, words++) bytes += kstrlen(envp[i]) + 1;
  bytes = (bytes + words * 8 + 15) & ~15;
  return bytes <= PAGE_SIZE ? bytes : 0;
}

static void buildInitialStack(char * page, vaddr_t topUser, uint32_t size,
			      char ** argv, char ** envp, struct auxinfo * aux)
{
  uint64_t * vec = (uint64_t *)(page + PAGE_SIZE - size);
  char * str = page + PAGE_SIZE;
  uint32_t i, n = 0;
  vaddr_t random;
  str -= 16;                                        /* AT_RANDOM's bytes */
  random_get((ubyte_t *)str, 16);
  random = topUser - (page + PAGE_SIZE - str);
  for (i = 0; argv && argv[i]; i++) ;
  vec[n++] = i;
  for (i = 0; argv && argv[i]; i++) {
    uint32_t len = kstrlen(argv[i]) + 1;
    str -= len;
    kmemcpy(str, argv[i], len);
    vec[n++] = topUser - (page + PAGE_SIZE - str);
  }
  vec[n++] = 0;
  for (i = 0; envp && envp[i]; i++) {
    uint32_t len = kstrlen(envp[i]) + 1;
    str -= len;
    kmemcpy(str, envp[i], len);
    vec[n++] = topUser - (page + PAGE_SIZE - str);
  }
  vec[n++] = 0;
  if (aux->phdr) {
    vec[n++] = 3;  vec[n++] = aux->phdr;            /* AT_PHDR */
    vec[n++] = 4;  vec[n++] = sizeof(Elf64_Phdr);   /* AT_PHENT */
    vec[n++] = 5;  vec[n++] = aux->phnum;           /* AT_PHNUM */
  }
  vec[n++] = 6;  vec[n++] = PAGE_SIZE;              /* AT_PAGESZ */
  vec[n++] = 9;  vec[n++] = aux->entry;             /* AT_ENTRY */
  vec[n++] = 25; vec[n++] = random;                 /* AT_RANDOM */
  vec[n++] = 0;                                     /* AT_NULL */
  vec[n++] = 0;
}

/* a thread's first kernel stack (thread.c) */
void arch_thread_frame(tss_t * t, uint64_t entry, uint64_t stack, uint64_t rax,
		       int privileged);

/* ---- a process from an ELF64 image ---- */

process_descriptor_t * spawnProcess(process_descriptor_t * desc,
				    uint32_t * image, uint32_t len,
				    char ** argv, char ** envp)
{
  Elf64_Ehdr eh;
  Elf64_Phdr ph[ELF_MAXSEG];
  uint64_t base = 0, last = 0;
  uint32_t initialStack, i;
  paddr_t top;
  vaddr_t va, ustackTop = USER_AREA_END, ustackBottom;
  tss_t * tss;
  void * kstack;

  desc->lmemmap = NULL;
  listInit(desc->channelList);
  listInit(desc->portList);

  if (!argv) argv = default_argv;
  if ((initialStack = initialStackSize(argv, envp)) == 0) return NULL;
  if (len < sizeof eh) return NULL;
  kmemcpy(&eh, image, sizeof eh);
  if (kmemcmp((char *)eh.ident, "\177ELF", 4) || eh.ident[4] != 2 ||
      eh.machine != 62 || eh.type != 2 || eh.phentsize != sizeof(Elf64_Phdr) ||
      eh.phnum > ELF_MAXSEG || eh.phoff > len ||
      eh.phnum * sizeof(Elf64_Phdr) > len - eh.phoff)
    return NULL;
  kmemcpy(ph, (char *)image + eh.phoff, eh.phnum * sizeof(Elf64_Phdr));
  for (i = 0; i < eh.phnum; i++) {
    if (ph[i].type != PT_LOAD) continue;
    if (ph[i].offset > len || ph[i].filesz > len - ph[i].offset ||
	ph[i].filesz > ph[i].memsz || ph[i].vaddr < base)
      return NULL;
    if (base == 0) base = ph[i].vaddr;
    last = ph[i].vaddr + ph[i].memsz;
  }
  if (base != PROGRAM_BASE || last <= base || last - base > PROGRAM_MAX) return NULL;

  numProcesses++;
  numThreads++;
  top = new_space();

  /* the linear space map: the program, the RAM disk, the stack's top */
  ustackBottom = ustackTop - PAGE_SIZE * USER_STACK_NPAGES;
  __lmt_forceAllocation(&(desc->lmemmap), USERMINPAGE, ((last - base) >> 12) + 1);
  __lmt_forceAllocation(&(desc->lmemmap), ustackBottom >> 12,
			USERMAXPAGE - (ustackBottom >> 12) + 1);

  /* the program: every page of its segments, the file's bytes copied */
  for (va = base & ~0xFFFUL; va < last; va += PAGE_SIZE)
    *arch_pte_make_in(top, va) = new_frame() | PF_PRESENT | PF_READWRITE | PF_USER;
  for (i = 0; i < eh.phnum; i++) {
    uint64_t off;
    if (ph[i].type != PT_LOAD) continue;
    for (off = 0; off < ph[i].filesz; ) {
      vaddr_t a = ph[i].vaddr + off;
      uint64_t n = PAGE_SIZE - (a & 0xFFF);
      if (n > ph[i].filesz - off) n = ph[i].filesz - off;
      kmemcpy((char *)PHYS_TO_VIRT(PTE_FRAME(*arch_pte_in(top, a))) + (a & 0xFFF),
	      (char *)image + ph[i].offset + off, n);
      off += n;
    }
  }

#ifdef RAMDISK
  /* the RAM disk, read-only, its frames the module's */
  if (ramdisk_present) {
    uint32_t npages = (ramdisk_len + PAGE_SIZE - 1) / PAGE_SIZE;
    __lmt_forceAllocation(&(desc->lmemmap), RAMDISK_BASE >> 12, npages);
    for (i = 0; i < npages; i++)
      *arch_pte_make_in(top, RAMDISK_BASE + (vaddr_t)i * PAGE_SIZE) =
	((paddr_t)ramdisk + (paddr_t)i * PAGE_SIZE) | PF_PRESENT | PF_USER | PF_SHARED;
  }
#endif

  /* the user stack: allocated on use, but its top page, which holds the
     initial stack */
  for (va = ustackBottom; va < ustackTop - PAGE_SIZE; va += PAGE_SIZE)
    *arch_pte_make_in(top, va) = PF_USER | PF_READWRITE | PF_LOGICAL_PRESENT;
  {
    paddr_t f = new_frame();
    *arch_pte_make_in(top, ustackTop - PAGE_SIZE) = f | PF_PRESENT | PF_READWRITE | PF_USER;
    struct auxinfo aux = { 0, eh.phnum, eh.entry };
    /* the headers in memory: inside the loaded segment that holds them */
    for (i = 0; i < eh.phnum; i++)
      if (ph[i].type == PT_LOAD && ph[i].offset <= eh.phoff &&
	  eh.phoff + eh.phnum * sizeof(Elf64_Phdr) <= ph[i].offset + ph[i].filesz)
	aux.phdr = ph[i].vaddr + (eh.phoff - ph[i].offset);
    buildInitialStack(PHYS_TO_VIRT(f), ustackTop, initialStack, argv, envp, &aux);
  }

  /* the process information and the first thread's kernel stack: the
     kernel's gigabyte */
  desc->processData = __OS_askPages(PROCESS_INFO_NPAGES, 1, 0);
  kbzero(desc->processData, PROCESS_INFO_NPAGES * PAGE_SIZE);
  kstack = __OS_askPages(KERNEL_STACK_NPAGES, 1, 0);
  desc->ptsMirror = kstack;

  tss = desc->tss = kmalloc(sizeof(tss_t));
  kbzero(tss, sizeof(tss_t));
  tss->cr3 = top;
  tss->rsp0 = (vaddr_t)kstack + KERNEL_STACK_NPAGES * PAGE_SIZE;
  arch_thread_frame(tss, eh.entry, ustackTop - initialStack, 0,
		    (desc->privileges & MYNOS_PRIV_IO) != 0);
  desc->isAlive = 1;
  desc->numThreads = 1;
  tss->privSem = __OS_sem_allocateSemaphore(0);

  desc->exitStatus = 0;
  desc->cpuTicks = 0;
  desc->faultsAlloc = desc->faultsCow = 0;
  kbzero(desc->childWaiting, sizeof desc->childWaiting);
  desc->reaped = 0;
  desc->childSem = __OS_sem_allocateSemaphore(0);
  desc->deadThreads = NULL;
  desc->memFreed = 0;
  desc->nextZombie = NULL;

  readyQueueInsert(tss);
  return desc;
}

/* ---- freeing ---- */

static void unsetFrame(paddr_t f)
{
  if (isRamdiskFrame(f)) return;
  if (pmem_countref(f >> 12) > 0) pmem_unset(f >> 12);
}

/* the process's tables and frames, from its PML4 [top] */
static void freeSpace(paddr_t top)
{
  pte_t * pml4 = PHYS_TO_VIRT(top);
  pte_t * pdpt = PHYS_TO_VIRT(PTE_FRAME(pml4[0]));
  int i, j, k;
  for (i = 1; i < 512; i++) {
    pte_t * pd;
    if (!(pdpt[i] & PF_PRESENT)) continue;
    pd = PHYS_TO_VIRT(PTE_FRAME(pdpt[i]));
    for (j = 0; j < 512; j++) {
      pte_t * pt;
      if (!(pd[j] & PF_PRESENT)) continue;
      pt = PHYS_TO_VIRT(PTE_FRAME(pd[j]));
      for (k = 0; k < 512; k++)
	if (pt[k] & PF_PRESENT) unsetFrame(PTE_FRAME(pt[k]));
      unsetFrame(PTE_FRAME(pd[j]));
    }
    unsetFrame(PTE_FRAME(pdpt[i]));
  }
  unsetFrame(PTE_FRAME(pml4[0]));
  unsetFrame(top);
}

void __OS_freeSpaceFrames(uint32_t pdFrame, uint32_t mirrorFrame)
{
  freeSpace((paddr_t)pdFrame << 12);
}

void freeAddressSpace(process_descriptor_t * d)
{
  tss_t * t;
  freeSpace(d->pgdirPhys);
  /* the threads' kernel stacks, in the kernel's gigabyte */
  for (t = d->tss; t; t = t->next)
    if (t->kstack) __OS_releasePages((void *)t->kstack, KERNEL_STACK_NPAGES, 1, 0);
  for (t = d->deadThreads; t; t = t->next)
    if (t->kstack) __OS_releasePages((void *)t->kstack, KERNEL_STACK_NPAGES, 1, 0);
  if (d->ptsMirror) __OS_releasePages(d->ptsMirror, KERNEL_STACK_NPAGES, 1, 0);
  if (d->processData) __OS_releasePages(d->processData, PROCESS_INFO_NPAGES, 1, 0);
  d->ptsMirror = NULL;
  d->processData = NULL;
}

uint32_t __OS_residentPages(process_descriptor_t * p)
{
  pte_t * pml4, * pdpt;
  uint32_t n = 0;
  int i, j, k;
  if (p == NULL || !p->isAlive || p->tss == NULL) return 0;
  pml4 = PHYS_TO_VIRT(THREAD_SPACE(p->tss));
  pdpt = PHYS_TO_VIRT(PTE_FRAME(pml4[0]));
  for (i = 1; i < 512; i++) {
    pte_t * pd;
    if (!(pdpt[i] & PF_PRESENT)) continue;
    pd = PHYS_TO_VIRT(PTE_FRAME(pdpt[i]));
    for (j = 0; j < 512; j++) {
      pte_t * pt;
      if (!(pd[j] & PF_PRESENT)) continue;
      pt = PHYS_TO_VIRT(PTE_FRAME(pd[j]));
      for (k = 0; k < 512; k++)
	if ((pt[k] & (PF_PRESENT | PF_USER)) == (PF_PRESENT | PF_USER) &&
	    !isRamdiskFrame(PTE_FRAME(pt[k])))
	  n++;
    }
  }
  return n;
}

/* munmap must leave the RAM disk alone */
int __OS_touchesRamdisk(vaddr_t start, uint32_t len)
{
#ifdef RAMDISK
  vaddr_t end = RAMDISK_BASE + ((ramdisk_len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1));
  if (!ramdisk_present || len == 0) return 0;
  return start < end && start + len > RAMDISK_BASE;
#else
  return 0;
#endif
}

void initStack(uint32_t s, tss_t * tss) { }

/* ---- fork ---- */

/* the current space copied: the user pages copy-on-write (both sides
   read-only, one more reference), the kernel's pages in the process's
   range (other threads' kernel stacks) copied, the rest as it is */
int arch_space_fork(paddr_t * pd, paddr_t * mirror)
{
  paddr_t top = new_space();
  pte_t * src = PHYS_TO_VIRT(PTE_FRAME(((pte_t *)PHYS_TO_VIRT(arch_cr3()))[0]));
  pte_t * dst = PHYS_TO_VIRT(PTE_FRAME(((pte_t *)PHYS_TO_VIRT(top))[0]));
  int i, j, k;
  for (i = 1; i < 512; i++) {
    pte_t * spd, * dpd;
    if (!(src[i] & PF_PRESENT)) continue;
    dst[i] = new_frame() | PTE_FLAGS(src[i]);
    spd = PHYS_TO_VIRT(PTE_FRAME(src[i]));
    dpd = PHYS_TO_VIRT(PTE_FRAME(dst[i]));
    for (j = 0; j < 512; j++) {
      pte_t * spt, * dpt;
      if (!(spd[j] & PF_PRESENT)) continue;
      dpd[j] = new_frame() | PTE_FLAGS(spd[j]);
      spt = PHYS_TO_VIRT(PTE_FRAME(spd[j]));
      dpt = PHYS_TO_VIRT(PTE_FRAME(dpd[j]));
      for (k = 0; k < 512; k++) {
	pte_t e = spt[k];
	if (!(e & PF_PRESENT)) { dpt[k] = e; continue; }
	if (!(e & PF_USER)) {                 /* the kernel's: a copy */
	  paddr_t f = new_frame();
	  kmemcpy(PHYS_TO_VIRT(f), PHYS_TO_VIRT(PTE_FRAME(e)), PAGE_SIZE);
	  dpt[k] = f | PTE_FLAGS(e);
	  continue;
	}
	if (!(e & PF_SHARED) && (e & PF_READWRITE) && !(e & PF_COW)) {
	  e = (e | PF_COW) & ~(pte_t)PF_READWRITE;
	  spt[k] = e;
	}
	dpt[k] = e;
	if (!isRamdiskFrame(PTE_FRAME(e))) pmem_set(PTE_FRAME(e) >> 12);
      }
    }
  }
  /* the parent's entries changed: its TLB forgets them */
  __asm__ volatile ("movq %%cr3, %%rax; movq %%rax, %%cr3" : : : "rax", "memory");
  /* and so do the other processors running its threads (smp.c) */
  if (ncpus > 1) smp_tlb_shootdown(USER_AREA_START);
  *pd = top;
  *mirror = 0;
  return 0;
}

/* the child's first thread (a copy of the caller's tss, fork's): its own
   kernel stack and process information, and a frame that returns from
   fork with 0 */
void arch_fork_child(void * v)
{
  tss_t * t = v;
  process_descriptor_t * d = processTable[PSLOT(t->pid)];
  void * kstack = __OS_askPages(KERNEL_STACK_NPAGES, 1, 0);
  uint64_t * sp;
  void * info = __OS_askPages(PROCESS_INFO_NPAGES, 1, 0);
  kmemcpy(info, d->processData, PROCESS_INFO_NPAGES * PAGE_SIZE);
  d->processData = info;
  d->ptsMirror = kstack;
  t->kstack = 0;
  t->rsp0 = (vaddr_t)kstack + KERNEL_STACK_NPAGES * PAGE_SIZE;
  sp = (uint64_t *)t->rsp0;
  sp -= sizeof(struct frame) / 8;
  kmemcpy(sp, current_frame, sizeof(struct frame));
  ((struct frame *)sp)->rax = 0;
  t->kdepth = 1;
  *--sp = (uint64_t)trap_return;
  sp -= 6;
  kbzero(sp, 6 * 8);
  t->rsp = (uint64_t)sp;
}

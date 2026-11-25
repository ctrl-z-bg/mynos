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


/*
 * A process's address space on the i386 (doc/decisions/x86-64.md, choice
 * 4): building it from an ELF32 image (spawnProcess), freeing it, and
 * what reads it (resident pages, the RAM disk's shared page tables), the
 * first stack of a thread. Moved from process.c, unchanged: x86-64 has
 * its own.
 */

#include "irq.h"
#include "trace.h"
#include "global.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "sem.h"
#include "kutils.h"
#include "elf.h"
#include "process.h"
#include "video.h"
#include "mem/dynalloc.h"
#include "sched.h"
#include "ipc/port.h"
#include "ipc/channel.h"
#include "mynos.h"
#include "mem/externalmem.h"
#include "linux_syscalls.h"
#include "mem/physicalmem.h"

static char * default_argv[] = { "mynos", NULL };
extern process_descriptor_t * processTable[];
extern uint32_t currProcess, numProcesses, numThreads;
extern modinfo_t bytecode;

extern void startThread();
typedef struct {
  /* segment registers (except cs and ss) */
  ushort16_t gs;
  ushort16_t fs;
  ushort16_t es;
  ushort16_t ds;

  /* information for the taskswitch iret */
  uint32_t eip;
  uint32_t cs;
  uint32_t eflags;
  uint32_t esp;
  uint32_t ss;
} init_stack_t;


#ifdef RAMDISK
extern void * ramdisk;
extern uint32_t ramdisk_len;
extern uint32_t ramdisk_present;

/* The RAM disk is mapped read-only in every process, right after the
   program (0x40400000 up, read by memrofs), by page tables built once and
   shared: read-only pages are left alone by fork's copy-on-write. */
#define RAMDISK_MAXPTS 16   /* 64 MB */
static uint32_t * ramdiskPTs[RAMDISK_MAXPTS];
static uint32_t ramdiskPTframes[RAMDISK_MAXPTS];   /* physical page numbers */
static uint32_t ramdiskNPTs = 0;

static int buildRamdiskPTs(void) {
  uint32_t npages = (ramdisk_len - 1) / PAGE_SIZE + 1;
  uint32_t n = (npages - 1) / PDPT_ENTRIES + 1, k, i;
  if (n > RAMDISK_MAXPTS) {
    printk("RAM disk too large, not mapped\n");
    return -1;
  }
  for (k = 0; k < n; k++) {
    if ((ramdiskPTs[k] = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL)
      return -1;
    kbzero(ramdiskPTs[k], PAGE_SIZE);
    ramdiskPTframes[k] = LINEAR_TO_PHYSICAL_ADDRESS(ramdiskPTs[k]) >> 12;
  }
  for (i = 0; i < npages; i++)
    ramdiskPTs[i / PDPT_ENTRIES][i % PDPT_ENTRIES] =
      LINEAR_TO_PHYSICAL_ADDRESS(ramdisk + (PAGE_SIZE * i))
      | PF_USER | PF_PRESENT;
  ramdiskNPTs = n;
  return 0;
}
#endif

/*
 * The initial stack the Linux ABI expects, which modern libcs read at
 * startup: argc, argv[], NULL, envp[], NULL, auxv (AT_NULL), with the
 * strings above them. It must fit in the top page of the user stack.
 * Returns the bytes it takes (16-byte aligned), or 0 if it does not fit.
 */
static uint32_t initialStackSize(char ** argv, char ** envp) {
  uint32_t words = 1 + 1 + 1 + 2, bytes = 0, i;
  for (i = 0; argv && argv[i]; i++, words++)
    bytes += kstrlen(argv[i]) + 1;
  for (i = 0; envp && envp[i]; i++, words++)
    bytes += kstrlen(envp[i]) + 1;
  bytes = (bytes + words * 4 + 15) & ~15;
  return bytes <= PAGE_SIZE ? bytes : 0;
}

/* writes it at the end of page, whose user address ends at topUser */
static void buildInitialStack(uint32_t * page, uint32_t topUser,
			      uint32_t size, char ** argv, char ** envp) {
  uint32_t * vec = page + (PAGE_SIZE - size) / sizeof(uint32_t);
  char * str = (char *)page + PAGE_SIZE;
  uint32_t i, n = 0;

  for (i = 0; argv && argv[i]; i++) ;
  vec[n++] = i;                                     /* argc */
  for (i = 0; argv && argv[i]; i++) {
    uint32_t len = kstrlen(argv[i]) + 1;
    str -= len;
    kmemcpy(str, argv[i], len);
    vec[n++] = topUser - ((char *)page + PAGE_SIZE - str);
  }
  vec[n++] = 0;
  for (i = 0; envp && envp[i]; i++) {
    uint32_t len = kstrlen(envp[i]) + 1;
    str -= len;
    kmemcpy(str, envp[i], len);
    vec[n++] = topUser - ((char *)page + PAGE_SIZE - str);
  }
  vec[n++] = 0;
  vec[n++] = 0;                                     /* auxv: AT_NULL */
  vec[n++] = 0;
}

/*
 * Starting from the top of the linear address space, after the PD and
 * the PTs mapping, we should have a fixed-size space for process
 * informations (PROCESS_INFO_NPAGES), fixed-space kernel stack
 * (KERNEL_STACK_NPAGES), and than the user-space stack
 * (USER_STACK_NPAGES).
 */


process_descriptor_t * spawnProcess(process_descriptor_t * desc, 
				    uint32_t * test_start, uint32_t test_len,
				    char ** argv, char ** envp) {
  uint32_t * newPD;
  uint32_t * lastPT;
  uint32_t * lastButOnePT;
  uint32_t * infoAndStacksPTs;
  uint32_t nInfoAndStacksPTs;
  uint32_t * currPT;
  uint32_t * currPF;        /* current page frame */
  uint32_t * stackFrame; 
  uint32_t * pun;
  uint32_t i;
  tss_t * tss;
  uint32_t npages_for_process;
  uint32_t initialStack;

  Elf32_Phdr elf_phdata[ELF_MAXSEG];
  Elf32_Ehdr elf_ex;
  uint32_t entryaddr, curraddr, size;
  uint32_t baseaddr = 0, lastaddr = 0;

  /* new process linear addresses for info and stacks */
  uint32_t pinfoAddr;
  uint32_t kstackBottomAddr, ustackBottomAddr;

  /* last linear address usable (top - PTs and PD mapping) */
  uint32_t upperLimit = 0 - (0x400000 + 0x1000);

  /* initial kernel stack data of the new process */
  void * stackData;

  /* The pages built here are allocated in the kernel's linear space, then
     mapped into the new process. Once it is built, those kernel mappings
     ("aliases") are dropped: each frame then belongs to the process alone,
     and is freed with it (reapZombies). */
  void * alias[8 + KERNEL_STACK_NPAGES + PROCESS_INFO_NPAGES];
  uint32_t aliasPages[8 + KERNEL_STACK_NPAGES + PROCESS_INFO_NPAGES];
  uint32_t nAliases = 0;
#define ALIAS(ADDR, N) { alias[nAliases] = (ADDR); aliasPages[nAliases++] = (N); }

  // the linear space process map
  desc->lmemmap = NULL;

  // channel and port lists
  listInit(desc->channelList);
  listInit(desc->portList);

  pinfoAddr  = upperLimit - PAGE_SIZE * PROCESS_INFO_NPAGES;
  kstackBottomAddr = pinfoAddr  - PAGE_SIZE * KERNEL_STACK_NPAGES;
  ustackBottomAddr = kstackBottomAddr - PAGE_SIZE * USER_STACK_NPAGES;

  nInfoAndStacksPTs = (LAST_PDPT_INDEX - 1) - __ADDRESS_PD_INDEX(ustackBottomAddr) + 1;

  /* check everything before allocating anything: the image may come from a
     process (mynos_spawn) */
  if (!argv) argv = default_argv;
  if ((initialStack = initialStackSize(argv, envp)) == 0)
    return NULL;
  if (test_len < sizeof(Elf32_Ehdr))
    return NULL;

  elf_ex=*(Elf32_Ehdr *)test_start;

  /* Used GRUB as inspiration */
  /* Check if is a good ELF for us */
  if (!BOOTABLE_I386_ELF(elf_ex))
      return(NULL);

  entryaddr = (uint32_t) elf_ex.e_entry;
  /* End check */
  
  /* Now read in all of the header information, after some consistency tests */
  if (elf_ex.e_phentsize != sizeof(Elf32_Phdr))
      return(NULL);
  if ( (elf_ex.e_phnum > ELF_MAXSEG) ||
       (elf_ex.e_phnum > (65536U / elf_ex.e_phentsize) ) )
      return(NULL);
  size = elf_ex.e_phnum * elf_ex.e_phentsize;
  if (elf_ex.e_phoff > test_len || size > test_len - elf_ex.e_phoff)
      return(NULL);
  kmemcpy(elf_phdata, (char *)test_start + elf_ex.e_phoff, size);
   
  for (i = 0; i < elf_ex.e_phnum; i++) {
      Elf32_Phdr *phdr = &elf_phdata[i];
      /* we consider only the segments to be loaded*/
      if (phdr->p_type != PT_LOAD) continue; 
      if (phdr->p_offset > test_len ||
	  phdr->p_filesz > test_len - phdr->p_offset ||
	  phdr->p_vaddr < baseaddr || phdr->p_memsz > 0x400000)
	return(NULL);
      if (baseaddr == 0) baseaddr=phdr->p_vaddr;
      lastaddr = phdr->p_vaddr+phdr->p_memsz;
  }

  /* the program lives in one page table, right after the kernel space */
  if (baseaddr != (uint32_t)USERMINPAGE << 12 || lastaddr <= baseaddr ||
      lastaddr - baseaddr > 0x400000)
    return(NULL);

  npages_for_process = ((lastaddr - baseaddr)>>12)+1;
  numProcesses++;
  numThreads++;

  /* initialize the linear space map */
  // set the beginning of the space (process code, etc.)
  __lmt_forceAllocation(&(desc->lmemmap), USERMINPAGE, npages_for_process);
  // set the end of linear space as allocated: the stacks, the process
  // info and the page tables mapping (it reserved the right number of
  // pages, but at the very top, above where the stacks are)
  __lmt_forceAllocation(&(desc->lmemmap), ustackBottomAddr >> 12,
			USERMAXPAGE - (ustackBottomAddr >> 12) + 1);

  if ((newPD = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  ALIAS(newPD, 1);
  kbzero(newPD, PAGE_SIZE);

  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    newPD[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  // HORRIBLE HACK!!! Open VGA memory to all processes!
#ifdef TRY_VGA
  {
    uint32_t * pte;
    uint32_t i;

    newPD[0] = newPD[0] | PF_USER | PF_READWRITE;
    for (i = 0xA0000; i<0xB0000; i+=0x1000) {
      pte = (int*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(i), 
					 __ADDRESS_PT_INDEX(i));
      *pte = *pte | PF_USER | PF_READWRITE;
    }
  }
#endif

  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  ALIAS(lastPT, 1);
  desc->ptsMirror = (void*)LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  kbzero(lastPT, PAGE_SIZE);

  /* allocate the page tables needed for info and stacks */
  if ((infoAndStacksPTs = 
       (uint32_t*)__OS_askPages(nInfoAndStacksPTs, 1, 0)) == NULL) return NULL;
  ALIAS(infoAndStacksPTs, nInfoAndStacksPTs);
  kbzero(infoAndStacksPTs, PAGE_SIZE * nInfoAndStacksPTs);

  lastButOnePT = infoAndStacksPTs + (PAGE_SIZE / sizeof(uint32_t)) * (nInfoAndStacksPTs - 1);

  if ((currPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  ALIAS(currPT, 1);
  kbzero(currPT, PAGE_SIZE);
  newPD[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_USER | PF_READWRITE | PF_PRESENT;

  if ((currPF = (uint32_t*)__OS_askPages(npages_for_process, 1, 0)) == NULL) return NULL;
  ALIAS(currPF, npages_for_process);

  kbzero(currPF, npages_for_process * PAGE_SIZE);

  /* From here instead ELF code is Grub "inspired" */
  curraddr = (uint32_t) currPF;
  baseaddr = 0;


  for (i = 0; i < elf_ex.e_phnum; i++) {
      Elf32_Phdr *phdr = &elf_phdata[i];
      uint32_t memsz, filesz;

      /* we consider only the segments to be loaded*/
      if (phdr->p_type != PT_LOAD) continue; 
      if (baseaddr == 0) baseaddr=phdr->p_vaddr;
      memsz = phdr->p_memsz;
      filesz = phdr->p_filesz;
      curraddr = (uint32_t)currPF + ( phdr->p_vaddr - baseaddr );
      if (filesz > memsz) filesz = memsz; /* It should not occur (I think) */
      kmemcpy((void*)curraddr, (void*)((uint32_t)test_start + (uint32_t)(phdr->p_offset)), 
	      filesz);
      if (memsz > filesz) { /*We do not need that if we already zero'ed all the pages */
	  kbzero((void *)(curraddr + filesz), memsz-filesz);
      }
  }
  /* Here the segments are loaded, we have not symbol loading at the moment,
     neither relocatable segments. */
  
  for (i = 0; i < npages_for_process; i++)
  currPT[i] = LINEAR_TO_PHYSICAL_ADDRESS(currPF +(PDPT_ENTRIES*i)) 
    | PF_USER | PF_PRESENT | PF_READWRITE;

  newPD[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_READWRITE | PF_PRESENT;
  lastPT[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_READWRITE | PF_PRESENT;

  pun = infoAndStacksPTs;

  /* register the last PTs */
  for (i = (LAST_PDPT_INDEX - 1) - nInfoAndStacksPTs + 1; i < LAST_PDPT_INDEX; i++) {
    newPD[i] = LINEAR_TO_PHYSICAL_ADDRESS(pun) | PF_USER | PF_READWRITE | PF_PRESENT;
    lastPT[i] = LINEAR_TO_PHYSICAL_ADDRESS(pun) | PF_READWRITE | PF_PRESENT;
    pun += PDPT_ENTRIES;
  }

  pun = infoAndStacksPTs + (nInfoAndStacksPTs*PDPT_ENTRIES - 1 -
			    (PROCESS_INFO_NPAGES +
			     KERNEL_STACK_NPAGES +
			     USER_STACK_NPAGES));// + nInfoAndStacksPTs*1024 - 1;

  /* allocate-on-demand the user stack, except its top page: it holds the
     initial process stack (argc, argv, envp, auxv) */
  for (i = 0; i < USER_STACK_NPAGES - 1; i++)
    *(pun++) = PF_USER | PF_LOGICAL_PRESENT | PF_READWRITE;
  {
    uint32_t * top;
    uint32_t topUser = ustackBottomAddr + PAGE_SIZE * USER_STACK_NPAGES;

    if ((top = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    ALIAS(top, 1);
    kbzero(top, PAGE_SIZE);
    buildInitialStack(top, topUser, initialStack, argv, envp);
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(top)
      | PF_USER | PF_PRESENT | PF_READWRITE;
  }

  /* allocate the kernel stack */
  for (i = 0; i < KERNEL_STACK_NPAGES; i++) {
    if ((stackFrame = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    ALIAS(stackFrame, 1);
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_READWRITE | PF_PRESENT;
    /* at the end of this cycle stackData points to the last kernel
       stack page of the new process, mapped in the current process page */
    stackData = stackFrame;
  }

  /* allocate the process info space */
  for (i = 0; i < PROCESS_INFO_NPAGES; i++) {
    if ((currPF = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    ALIAS(currPF, 1);
    kbzero(currPF, PAGE_SIZE);
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(currPF) | PF_READWRITE | PF_PRESENT;
  }
  
  /* copy the first shared entries in the PTs images */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    lastPT[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  lastPT[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_READWRITE | PF_PRESENT;
  
  /* map the page directory in the process linear space */
  lastButOnePT[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(newPD) | PF_READWRITE | PF_PRESENT;

  /* allocate a new tss */
  desc->tss = (tss_t*)kmalloc(sizeof(tss_t));

  tss = desc->tss;
  /* every field not set below is 0: justForked, queue, kstack, clearTid,
     the general registers (with garbage in justForked the scheduler took
     the new process for a forked one) */
  kbzero(tss, sizeof(tss_t));

  /* set the new process tss */
  tss->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(newPD);
  tss->io_bitmap_offset = sizeof(tss_t)<<16;
  tss->eip = entryaddr;  /* ELF entry point (was hardcoded 0x40000000) */

  desc->isAlive = 1;

  desc->processData = (processData_t*)pinfoAddr;

  tss->cs = GDT_USER_CODE_SEL + 3;
  tss->ds = GDT_USER_DATA_SEL + 3;
  tss->es = GDT_USER_DATA_SEL + 3;
  tss->fs = GDT_USER_DATA_SEL + 3;
  tss->gs = GDT_USER_DATA_SEL + 3;
  tss->ss = GDT_USER_DATA_SEL + 3;

  tss->ldt = 0;

  tss->eflags = INITIAL_EFLAGS |
    ((desc->privileges & MYNOS_PRIV_IO) ? IOPL3 : 0);
  tss->esp = tss->ebp = ustackBottomAddr + PAGE_SIZE * USER_STACK_NPAGES -
    initialStack;
  tss->esp0 = tss->esp1 = tss->esp2 = kstackBottomAddr + PAGE_SIZE * KERNEL_STACK_NPAGES;
  tss->ss0 = tss->ss1 = tss->ss2 = GDT_OS_DATA_SEL;

  /* prepare the initial stack for the new process */
  initStack(((uint32_t)stackData) + PAGE_SIZE, tss);

  // THREADS
  desc->numThreads = 1;
  desc->tss->next = desc->tss->prev = NULL;
  // end THREADS
  desc->tss->timeToWake = 0;

  /* Private Semaphore initialized to 0, as soon as P is made it yields */
  desc->tss->privSem = __OS_sem_allocateSemaphore(0);
  desc->tss->semHeld = 0;

#ifdef RAMDISK
  if (ramdisk_present && (ramdiskNPTs || buildRamdiskPTs() == 0)) {
    uint32_t first = _asm_last_kernel_page_dir_entry_used + 2;
    /* record it in the linear space map, or mmap could hand out addresses
       overlapping it */
    __lmt_forceAllocation(&(desc->lmemmap), first * PDPT_ENTRIES,
			  ramdiskNPTs * PDPT_ENTRIES);
    for (i = 0; i < ramdiskNPTs; i++) {
      newPD[first + i] = LINEAR_TO_PHYSICAL_ADDRESS(ramdiskPTs[i])
	| PF_USER | PF_READWRITE | PF_PRESENT;
      lastPT[first + i] = LINEAR_TO_PHYSICAL_ADDRESS(ramdiskPTs[i])
	| PF_PRESENT;
    }
  }
#endif

  desc->exitStatus = 0;
  desc->cpuTicks = 0;
  desc->faultsAlloc = desc->faultsCow = 0;
  kbzero(desc->childWaiting, sizeof desc->childWaiting);
  desc->reaped = 0;
  desc->childSem = __OS_sem_allocateSemaphore(0);
  desc->deadThreads = NULL;
  desc->memFreed = 0;
  desc->nextZombie = NULL;
  tss->kstack = 0;
  tss->tid = 0;            /* the pid, set by createProcess */
  tss->clearTid = NULL;

  /* drop the kernel aliases (the frames stay, mapped in the process) */
  for (i = 0; i < nAliases; i++)
    __OS_releasePages(alias[i], aliasPages[i], 0, 0);
#undef ALIAS

  /* ready to run: only now can the scheduler pick it */
  readyQueueInsert(tss);
  return desc;
}

/* drop one reference to a physical page (it is free at the last one) */
static void unsetFrame(uint32_t frame) {
  static int warned = 0;
  if (pmem_countref(frame) > 0)
    pmem_unset(frame);
  else if (!warned) {
    warned = 1;
    printk("freeing a process: frame ");
    print_uint_hex(frame);
    printk(" already free\n");
  }
}

#ifdef RAMDISK
static int isRamdiskPT(uint32_t frame) {
  uint32_t k;
  for (k = 0; k < ramdiskNPTs; k++)
    if (ramdiskPTframes[k] == frame) return 1;
  return 0;
}
#else
#define isRamdiskPT(frame) 0
#endif

/* a live process's pages in memory: present user pages of its own
   page tables (the RAM disk's, shared by all, apart), for sysmonitor
   (native 38) */
uint32_t __OS_residentPages(process_descriptor_t * p) {
  uint32_t * w, saved, unused, i, j, n = 0;
  uint32_t pdFrame;
  if (p == NULL || !p->isAlive || p->tss == NULL) return 0;
  pdFrame = ((uint32_t)p->tss->pgdir) >> 12;
  w = __mem_mapFrame(pdFrame, &saved);
  for (i = _asm_last_kernel_page_dir_entry_used + 1; i < LAST_PDPT_INDEX; i++) {
    uint32_t pde;
    w = __mem_mapFrame(pdFrame, &unused);
    pde = w[i];
    if (!(pde & PF_PRESENT) || isRamdiskPT(pde >> 12)) continue;
    w = __mem_mapFrame(pde >> 12, &unused);
    for (j = 0; j < PDPT_ENTRIES; j++)
      if ((w[j] & (PF_PRESENT | PF_USER)) == (PF_PRESENT | PF_USER)) n++;
  }
  __mem_unmapFrame(saved);
  return n;
}

/* whether [start, start + len) in the current process touches the RAM
   disk's page tables, shared by every process (munmap must leave them
   alone: mynos-q5b) */
int __OS_touchesRamdisk(vaddr_t start, uint32_t len) {
  uint32_t pd;
  if (len == 0) return 0;
  for (pd = start >> 22; pd <= (start + len - 1) >> 22; pd++) {
    uint32_t pde = *(uint32_t *)__GET_PAGE_DIR_ENTRY(pd);
    if ((pde & PF_PRESENT) && isRamdiskPT(pde >> 12)) return 1;
  }
  return 0;
}

/*
 * Frees every frame of an ended process's address space, from another
 * process: its pages (program, heap, stacks, kernel stacks, process info;
 * shared or copy-on-write pages just lose a reference), its page tables,
 * its page directory and the page table that mirrors it. The kernel's
 * page tables and the shared RAM disk ones are not the process's.
 */
void __OS_freeSpaceFrames(uint32_t pdFrame, uint32_t mirrorFrame) {
  uint32_t * w, saved, unused, i, j;
  int pdSeen = 0;

  /* one window: map the directory to read an entry, then its table */
  w = __mem_mapFrame(pdFrame, &saved);
  for (i = _asm_last_kernel_page_dir_entry_used + 1; i < LAST_PDPT_INDEX;
       i++) {
    uint32_t pde, ptFrame;
    w = __mem_mapFrame(pdFrame, &unused);
    pde = w[i];
    ptFrame = pde >> 12;
    if (!(pde & PF_PRESENT) || isRamdiskPT(ptFrame)) continue;
    w = __mem_mapFrame(ptFrame, &unused);
    for (j = 0; j < PDPT_ENTRIES; j++)
      if (w[j] & PF_PRESENT) {
	/* the page directory is mapped as a page too (top area) */
	if ((w[j] >> 12) == pdFrame) pdSeen = 1;
	unsetFrame(w[j] >> 12);
      }
    unsetFrame(ptFrame);
  }
  __mem_unmapFrame(saved);

  if (!pdSeen) unsetFrame(pdFrame);
  unsetFrame(mirrorFrame);
}

void freeAddressSpace(process_descriptor_t * d) {
  __OS_freeSpaceFrames(d->pgdirPhys >> 12, ((uint32_t)d->ptsMirror) >> 12);
}

void initStack(uint32_t s, tss_t * tss) {
  init_stack_t * stack = (init_stack_t*)(s - sizeof(init_stack_t));

  tss->esp0 -= sizeof(init_stack_t);  

  stack->ss = GDT_USER_DATA_SEL + 3;
  stack->esp = tss->esp;
  stack->eflags = tss->eflags;
  stack->cs = GDT_USER_CODE_SEL + 3;
  stack->eip = tss->eip;

  stack->ds = GDT_USER_DATA_SEL + 3;
  stack->es = GDT_USER_DATA_SEL + 3;
  stack->fs = GDT_USER_DATA_SEL + 3;
  /* a thread created by a thread that has a TLS segment (set_thread_area)
     starts with that segment too: the creator's TLS block is shared until
     threads get their own (mynos-51c, mynos-l9h) */
  if (tss->tls_base || tss->tls_limit)
    stack->gs = (GDT_TLS_INDEX << 3) | 3;
  else
    stack->gs = GDT_USER_DATA_SEL + 3;
  
  tss->esp = tss->esp0;
  tss->eip = (uint32_t)startThread;
}

/* it returns:
   1: on success
   0: error
   something else: address for the PD image
*/
static uint32_t copy_page_table(uint32_t ptp, uint32_t * ptc) {
  uint32_t i;
  uint32_t * pte, flags;
  uint32_t * pf;

  /* copy the page table entries */
  for (i = 0; i <= LAST_PDPT_INDEX; i++) {
    if ((ptp == (LAST_PDPT_INDEX - 1)) && (i == LAST_PDPT_INDEX)) return 1; // this is the pd image
    pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(ptp, i);
    if (*pte & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PF is allocated
      flags = *pte & 0xFFF;
      if (*pte & PF_PRESENT) {  // the page is really allocated

	/* if the page is a superuser page then copy it (in 386 arch
	   ro check is not done in superuser mode, so cow cannot work) */
	if (!(*pte & PF_USER)) {
	  if ((pf = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
	  ptc[i] = LINEAR_TO_PHYSICAL_ADDRESS(pf) | flags;
	  
	  /* copy the page frame */
	  kmemcpy((void*)pf, (void*)__MEM_LINEAR_ADDRESS(ptp, i, 0), 
		  PAGE_SIZE);
	  /* drop the kernel alias: the frame is the child's alone */
	  __OS_releasePages(pf, 1, 0, 0);
	} else {   // ok, it's a user page
	  /* the page is set as cow only if: it's not shared, it's not RO,
	     it's not already cow */
	  if (!(*pte & PF_SHARED) && (*pte & PF_READWRITE) && !(*pte & PF_COW)) {
	    *pte |= PF_COW;
	    *pte = *pte & ~PF_READWRITE;  // to have the fault on write!
	    INVALIDATE_THE_CACHE(__MEM_LINEAR_ADDRESS(ptp, i, 0));
	  }
	  /* anyway copy the pte...*/
	  ptc[i] = *pte;
	  /* ... and increment the page references counter */
	  pmem_set((*pte)>>12);
	}
      } else  // logical allocated
	ptc[i] = flags;
    } else if (IS_PAGER_ENTRY(*pte))
      ptc[i] = *pte;   /* the external pager's: the child asks it too */
    else
      ptc[i] = 0;
  }
  return 1;
}

/* a fork that ran out of memory: the child's address space built so far
   is freed (its page tables, the pages they took or referenced, the
   directory and its mirror); the parent's pages left copy-on-write become
   writable again at their next write, as their only user's */
static int forkFailed(uint32_t * pdc, uint32_t * lastPT, uint32_t * ptc) {
  uint32_t pdFrame = LINEAR_TO_PHYSICAL_ADDRESS(pdc) >> 12;
  uint32_t mirrorFrame = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) >> 12;
  if (ptc) __OS_releasePages(ptc, 1, 0, 0);
  __OS_releasePages(lastPT, 1, 0, 0);
  __OS_releasePages(pdc, 1, 0, 0);
  __OS_freeSpaceFrames(pdFrame, mirrorFrame);
  return -12;                                   /* -ENOMEM */
}


/* fork's half that is the architecture's: the current process's address
   space copied for a child (its pages copy-on-write, its page tables
   new), the child's directory and mirror in *pd, *mirror (physical);
   0, or -ENOMEM, with nothing left allocated. Moved from linux_syscalls.c */
int arch_space_fork(paddr_t * pd, paddr_t * mirror) {
  uint32_t i;
  uint32_t * pde, flags;
  uint32_t * pdc, *ptc = NULL, *prevPtc = NULL;
  uint32_t *lastPT;

  if ((pdc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -12;
  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) {
    __OS_releasePages(pdc, 1, 1, 0);
    return -12;                                 /* -ENOMEM */
  }
  kbzero(pdc, PAGE_SIZE);   /* a failure frees what the entries name */

  pdc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | 
    PF_USER | PF_READWRITE | PF_PRESENT;

  /* copy the shared kernel space */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    pdc[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  /* copy the page dir entries, but not the last one (image for PTs...) */
  for (i = _asm_last_kernel_page_dir_entry_used + 1; i < LAST_PDPT_INDEX; i++) {
    pde = (uint32_t*)__GET_PAGE_DIR_ENTRY(i);
    /* this if should never be PF_LOGICAL_PRESENT because we don't allocate
       a page table logically */
    if (*pde & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PT is allocated
      flags = *pde & 0xFFF;
      if (*pde & PF_PRESENT) {
	if ((ptc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) {
	  if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	  return forkFailed(pdc, lastPT, NULL);
	}
	kbzero(ptc, PAGE_SIZE);
	pdc[i] = LINEAR_TO_PHYSICAL_ADDRESS(ptc) | flags;
	
	/* copy the page table */
	if (copy_page_table(i, ptc) == -1) {
	  if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	  return forkFailed(pdc, lastPT, ptc);
	}

	/* the kernel aliases of the child's structures are dropped once
	   they are built: the last page table still has to be written */
	if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	prevPtc = ptc;
      } else
	pdc[i] = flags;
    } else
      pdc[i] = 0;
  }

  /* set the PD pointer: now ptc is the last but one PT */
  ptc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(pdc) | PF_READWRITE | PF_PRESENT;
  kmemcpy((void*)lastPT, (void*)pdc, PAGE_SIZE);
  __OS_releasePages(ptc, 1, 0, 0);

  *pd = LINEAR_TO_PHYSICAL_ADDRESS(pdc);
  *mirror = LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  __OS_releasePages(lastPT, 1, 0, 0);
  __OS_releasePages(pdc, 1, 0, 0);
  return 0;
}

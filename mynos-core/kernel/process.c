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

/* the arguments of a process started without any (GRUB modules) */
static char * default_argv[] = { "mynos", NULL };

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

process_descriptor_t * processTable[MAXPROCESSES];
uint32_t numProcess = 1;
uint32_t currProcess = 0;  /* the first process is the idle process */

uint32_t numProcesses = 0;
uint32_t numThreads = 0;

tss_t * currThread;

extern modinfo_t bytecode;

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

void initProcessTable() {
  int i;
  for (i = 0; i < MAXPROCESSES; i++)
    processTable[i] = NULL;
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

  newPD[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;
  lastPT[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;

  pun = infoAndStacksPTs;

  /* register the last PTs */
  for (i = (LAST_PDPT_INDEX - 1) - nInfoAndStacksPTs + 1; i < LAST_PDPT_INDEX; i++) {
    newPD[i] = LINEAR_TO_PHYSICAL_ADDRESS(pun) | PF_USER | PF_READWRITE | PF_PRESENT;
    lastPT[i] = LINEAR_TO_PHYSICAL_ADDRESS(pun) | PF_PRESENT;
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
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_PRESENT;
    /* at the end of this cycle stackData points to the last kernel
       stack page of the new process, mapped in the current process page */
    stackData = stackFrame;
  }

  /* allocate the process info space */
  for (i = 0; i < PROCESS_INFO_NPAGES; i++) {
    if ((currPF = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    ALIAS(currPF, 1);
    kbzero(currPF, PAGE_SIZE);
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(currPF) | PF_PRESENT;
  }
  
  /* copy the first shared entries in the PTs images */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    lastPT[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  lastPT[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_PRESENT;
  
  /* map the page directory in the process linear space */
  lastButOnePT[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(newPD) | PF_PRESENT;

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
  desc->lastThread = 0;
  desc->tss->next = desc->tss->prev = NULL;
  desc->tss->threadID = 0;
  // end THREADS
  desc->tss->timeToWake = 0;

  /* Private Semaphore initialized to 0, as soon as P is made it yields */
  desc->tss->privSem = __OS_sem_allocateSemaphore(0);

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

/* the generation of each slot: incremented when its process is freed */
static uint32_t generation[MAXPROCESSES];

/* a new pid: a free slot (taken in a cycle), with its generation */
int allocPid(void) {
  static uint32_t last = 0;
  uint32_t i, p;
  for (i = 0; i < MAXPROCESSES - 1; i++) {
    p = (last + i) % (MAXPROCESSES - 1) + 1;          /* 1 .. MAX-1 */
    if (processTable[p] == NULL) {
      last = p;
      if (p >= numProcess) numProcess = p + 1;
      return p + MAXPROCESSES * generation[p];
    }
  }
  {
    static int said = 0;
    ktableFull("process", &said);
  }
  return -1;
}

/*
 * Starts a new process from an ELF image (a GRUB module, or a file a
 * process read: mynos_spawn). Returns its pid, or a MYNOS_ERR_* code.
 */
int createProcess(uint32_t * elf, uint32_t len, char ** argv, char ** envp,
		  pid_t ppid, uint32_t privileges) {
  process_descriptor_t * desc;
  int pid;

  if ((pid = allocPid()) < 0) return MYNOS_ERR_FULL;
  desc = (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));
  if (desc == NULL) return MYNOS_ERR_FULL;
  desc->pid = pid;
  desc->ppid = ppid;
  desc->privileges = privileges;
  trace_setName(desc->name, argv);
  if (spawnProcess(desc, elf, len, argv, envp) == NULL) {
    /* a bad image fails before allocating; out of memory, after (and
       leaks what it took: processes do not free memory yet) */
    kfree(desc);
    return MYNOS_ERR_INVALID;
  }
  desc->tss->pid = pid;
  desc->tss->tid = pid;
  processTable[PSLOT(pid)] = desc;
  TRACE(TRACE_SPAWN, ppid, pid, -1, 0, 0, desc->name, kstrlen(desc->name));
  return pid;
}


/* processes that ended, whose memory is still to be freed */
static process_descriptor_t * zombies = NULL;

/*
 * Ends the current process. It runs on the process's own kernel stack and
 * page directory, so it only releases what other processes can see (IPC,
 * semaphores) and queues the process: its memory is freed by reapZombies,
 * from another process, after the switch. The descriptor stays until the
 * parent collects the status (wait4), or goes at once if nobody can.
 */
void killProcess(int status) {
  tss_t * tss;
  process_queue_t * q;
  int port, channel;
  int i, n;
  process_descriptor_t * parent;
  process_descriptor_t * self = processTable[currProcess];

  TRACE(TRACE_EXIT, self->pid, -1, -1, 0, status, NULL, 0);
  self->isAlive = 0;
  numThreads -= processTable[currProcess]->numThreads;
  numProcesses--;
  
  tss = processTable[currProcess]->tss;
  while (tss) {
    timerQueueExtractThread(tss);
    q = tss->queue;
    if (q) pqExtractThread(q, tss);
    tss = tss->next;
  }

  // free process ports
  n = listNElem(processTable[currProcess]->portList);
  for (i = 0; i < n; i++) {
    port = (int)listExtract(processTable[currProcess]->portList);
    __OS_port_freePort(port);
  }

  // free process channels
  n = listNElem(processTable[currProcess]->channelList);
  for (i = 0; i < n; i++) {
    channel = (int)listExtract(processTable[currProcess]->channelList);
    __OS_ipc_freeChannel(channel);
  }


  /* threads waiting on futexes */
  futexForget(self->pid);

  /* semaphores: the threads' private ones and the children's */
  for (tss = self->tss; tss; tss = tss->next)
    __OS_sem_freeSemaphore(tss->privSem);
  __OS_sem_freeSemaphore(self->childSem);
  __OS_sem_freeProcessSemaphores(self->pid);
  __OS_irq_processEnded(self->pid);

  /* the children become orphans: nobody will wait for them */
  for (i = 1; i < (int)numProcess; i++) {
    process_descriptor_t * c = processTable[i];
    if (!c || c == self || c->ppid != self->pid) continue;
    c->ppid = 0;
    if (!c->isAlive && c->memFreed)
      freeProcessDescriptor(c->pid);
  }

  /* tell the parent, which may be waiting for it */
  self->exitStatus = status;
  parent = proc(self->ppid);
  if (self->ppid != 0 && parent && parent->isAlive)
    __OS_sem_V(parent->childSem);

  /* the memory: later, from elsewhere */
  self->pgdirPhys = (uint32_t)currThread->pgdir;
  self->memFreed = 0;
  self->nextZombie = zombies;
  zombies = self;
}

void freeProcessDescriptor(pid_t pid) {
  uint32_t slot = PSLOT(pid);
  if (slot == 0 || proc(pid) == NULL) return;
  kfree(processTable[slot]);
  processTable[slot] = NULL;
  generation[slot] = (generation[slot] + 1) % PID_GENERATIONS;
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

/*
 * Frees every frame of an ended process's address space, from another
 * process: its pages (program, heap, stacks, kernel stacks, process info;
 * shared or copy-on-write pages just lose a reference), its page tables,
 * its page directory and the page table that mirrors it. The kernel's
 * page tables and the shared RAM disk ones are not the process's.
 */
static void freeAddressSpace(process_descriptor_t * d) {
  uint32_t pdFrame = d->pgdirPhys >> 12;
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
  unsetFrame(((uint32_t)d->ptsMirror) >> 12);
}

/*
 * Frees the memory of the processes that ended, except the current one
 * (it may be the process that is ending, still on its own stack): called
 * by the scheduler, and by wait4 before it frees a child's descriptor.
 */
void reapZombies(void) {
  process_descriptor_t ** pz = &zombies;
  while (*pz) {
    process_descriptor_t * z = *pz;
    tss_t * t, * next;
    if (z == processTable[currProcess]) {
      pz = (process_descriptor_t **)&z->nextZombie;
      continue;
    }
    *pz = z->nextZombie;

    freeAddressSpace(z);
    for (t = z->tss; t; t = next) { next = t->next; kfree(t); }
    for (t = z->deadThreads; t; t = next) { next = t->next; kfree(t); }
    z->tss = z->deadThreads = NULL;
    __lmt_freeList(&(z->lmemmap));
    z->memFreed = 1;

    /* nobody will collect its status */
    if (z->ppid == 0 || z->reaped || !proc(z->ppid) ||
	!proc(z->ppid)->isAlive)
      freeProcessDescriptor(z->pid);
  }
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

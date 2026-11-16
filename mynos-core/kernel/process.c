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
  // set the end of linear space as allocated...
  __lmt_forceAllocation(&(desc->lmemmap), 
			USERMAXPAGE - (PROCESS_INFO_NPAGES +
				       KERNEL_STACK_NPAGES +
				       USER_STACK_NPAGES) + 1,
			PROCESS_INFO_NPAGES +
			KERNEL_STACK_NPAGES +
			USER_STACK_NPAGES);

  if ((newPD = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
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
  desc->ptsMirror = (void*)LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  kbzero(lastPT, PAGE_SIZE);

  /* allocate the page tables needed for info and stacks */
  if ((infoAndStacksPTs = 
       (uint32_t*)__OS_askPages(nInfoAndStacksPTs, 1, 0)) == NULL) return NULL;
  kbzero(infoAndStacksPTs, PAGE_SIZE * nInfoAndStacksPTs);

  lastButOnePT = infoAndStacksPTs + (PAGE_SIZE / sizeof(uint32_t)) * (nInfoAndStacksPTs - 1);

  if ((currPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  kbzero(currPT, PAGE_SIZE);
  newPD[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_USER | PF_READWRITE | PF_PRESENT;

  if ((currPF = (uint32_t*)__OS_askPages(npages_for_process, 1, 0)) == NULL) return NULL;

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
    kbzero(top, PAGE_SIZE);
    buildInitialStack(top, topUser, initialStack, argv, envp);
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(top)
      | PF_USER | PF_PRESENT | PF_READWRITE;
  }

  /* allocate the kernel stack */
  for (i = 0; i < KERNEL_STACK_NPAGES; i++) {
    if ((stackFrame = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    *(pun++) = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_PRESENT;
    /* at the end of this cycle stackData points to the last kernel
       stack page of the new process, mapped in the current process page */
    stackData = stackFrame;
  }

  /* allocate the process info space */
  for (i = 0; i < PROCESS_INFO_NPAGES; i++) {
    if ((currPF = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
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
  tss->tls_base = tss->tls_limit = tss->tls_pages = 0;

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

  tss->eflags = INITIAL_EFLAGS;  // iopl = 3
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
  if (ramdisk_present) {
    /* the RAM disk takes a whole page directory entry (4MB) right after the
       program: record it in the linear space map, or mmap could hand out
       addresses overlapping it */
    __lmt_forceAllocation(&(desc->lmemmap),
			  (_asm_last_kernel_page_dir_entry_used + 2) * PDPT_ENTRIES,
			  PDPT_ENTRIES);
    if ((currPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
    kbzero(currPT, PAGE_SIZE);
    newPD[_asm_last_kernel_page_dir_entry_used + 2] = 
      LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_USER | PF_READWRITE | PF_PRESENT;
    
    for (i = 0; i < ((ramdisk_len - 1) / PAGE_SIZE + 1); i++)
      currPT[i] = LINEAR_TO_PHYSICAL_ADDRESS(ramdisk + (PAGE_SIZE * i))
	| PF_USER | PF_PRESENT | PF_READWRITE;
    lastPT[_asm_last_kernel_page_dir_entry_used + 2] = 
      LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_PRESENT;
  }
#endif

  desc->exitStatus = 0;
  desc->reaped = 0;
  desc->childSem = __OS_sem_allocateSemaphore(0);

  /* ready to run: only now can the scheduler pick it */
  readyQueueInsert(tss);
  return desc;
}

/*
 * Starts a new process from an ELF image (a GRUB module, or a file a
 * process read: mynos_spawn). Returns its pid, or a MYNOS_ERR_* code.
 */
int createProcess(uint32_t * elf, uint32_t len, char ** argv, char ** envp,
		  pid_t ppid) {
  process_descriptor_t * desc;
  int pid;

  if (numProcess >= MAXPROCESSES) return MYNOS_ERR_FULL;
  desc = (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));
  if (desc == NULL) return MYNOS_ERR_FULL;
  pid = numProcess;
  desc->pid = pid;
  desc->ppid = ppid;
  if (spawnProcess(desc, elf, len, argv, envp) == NULL) {
    /* a bad image fails before allocating; out of memory, after (and
       leaks what it took: processes do not free memory yet) */
    kfree(desc);
    return MYNOS_ERR_INVALID;
  }
  desc->tss->pid = pid;
  processTable[pid] = desc;
  numProcess++;
  return pid;
}


void killProcess(int status) {
  tss_t * tss;
  process_queue_t * q;
  int port, channel;
  int i, n;
  process_descriptor_t * parent;
  /* TODO free sem for every threads */
  //__OS_sem_freeSemaphore((processTable[currProcess]->tss)->privSem);
  processTable[currProcess]->isAlive = 0;
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


  /* tell the parent, which may be waiting for it */
  processTable[currProcess]->exitStatus = status;
  __OS_sem_freeSemaphore(processTable[currProcess]->childSem);
  parent = processTable[processTable[currProcess]->ppid];
  if (processTable[currProcess]->ppid != 0 && parent && parent->isAlive)
    __OS_sem_V(parent->childSem);

  // TODO: free all process resources
  //kfree(processTable[currProcess]);
  //processTable[currProcess] = NULL;
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

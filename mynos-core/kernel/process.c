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
#include "mem.h"
#include "gdt.h"
#include "tss.h"
#include "sem.h"
#include "kutils.h"
#include "elf.h"
#include "process.h"
#include "video.h"
#include "dynalloc.h"

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

process_descriptor_t processTable[MAXPROCESSES];
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
 * Starting from the top of the linear address space, after the PD and
 * the PTs mapping, we should have a fixed-size space for process
 * informations (PROCESS_INFO_NPAGES), fixed-space kernel stack
 * (KERNEL_STACK_NPAGES), and than the user-space stack
 * (USER_STACK_NPAGES).
 */


process_descriptor_t * spawnProcess(process_descriptor_t * desc, 
				    uint32_t * test_start, uint32_t test_len) {
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

  numProcesses++;
  numThreads++;

  Elf32_Phdr elf_phdata[ELF_MAXSEG];
  Elf32_Ehdr elf_ex;
  uint32_t entryaddr, curraddr, size, baseaddr, lastaddr;

  /* new process linear addresses for info and stacks */
  uint32_t pinfoAddr;
  uint32_t kstackBottomAddr, ustackBottomAddr;

  /* last linear address usable (top - PTs and PD mapping) */
  uint32_t upperLimit = 0 - (0x400000 + 0x1000);

  /* initial kernel stack data of the new process */
  void * stackData;

  pinfoAddr  = upperLimit - PAGE_SIZE * PROCESS_INFO_NPAGES;
  kstackBottomAddr = pinfoAddr  - PAGE_SIZE * KERNEL_STACK_NPAGES;
  ustackBottomAddr = kstackBottomAddr - PAGE_SIZE * USER_STACK_NPAGES;

  nInfoAndStacksPTs = (LAST_PDPT_INDEX - 1) - __ADDRESS_PD_INDEX(ustackBottomAddr) + 1;

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
  kmemcpy(elf_phdata, test_start+elf_ex.e_phoff, size);
   
  for (i = 0; i < elf_ex.e_phnum; i++) {
      Elf32_Phdr *phdr;
      
      phdr = (Elf32_Phdr *) ((char *)test_start + elf_ex.e_phoff +  (elf_ex.e_phentsize * i));
      /* we consider only the segments to be loaded*/
      if (phdr->p_type != PT_LOAD) continue; 
      if (baseaddr == 0) baseaddr=phdr->p_vaddr;
      lastaddr = phdr->p_vaddr+phdr->p_memsz;
  }
  
  npages_for_process = ((lastaddr - baseaddr)>>12)+1;

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
      Elf32_Phdr *phdr;
      uint32_t memsz, filesz;
      ushort16_t startaddr;
      
      phdr = (Elf32_Phdr *) ((char *)test_start + elf_ex.e_phoff +  (elf_ex.e_phentsize * i));
      /* we consider only the segments to be loaded*/
      if (phdr->p_type != PT_LOAD) continue; 
      startaddr = phdr->p_vaddr;
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
  printk("Set linear2phis addr....\n");

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

  /* allocate-on-demand the user stack */
  for (i = 0; i < USER_STACK_NPAGES; i++)
    *(pun++) = PF_USER | PF_LOGICAL_PRESENT | PF_READWRITE;

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

  printk("Copied first shared entries....\n");
  lastPT[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_PRESENT;
  
  /* map the page directory in the process linear space */
  lastButOnePT[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(newPD) | PF_PRESENT;

  /* allocate a new tss */
  desc->tss = (tss_t*)kmalloc(sizeof(tss_t));

  tss = desc->tss;

  /* set the new process tss */
  tss->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(newPD);
  tss->io_bitmap_offset = sizeof(tss_t)<<16;
  tss->eip = (uint32_t)0x40000000;

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
  tss->esp = tss->ebp = ustackBottomAddr + PAGE_SIZE * USER_STACK_NPAGES - 16;
  tss->esp0 = tss->esp1 = tss->esp2 = kstackBottomAddr + PAGE_SIZE * KERNEL_STACK_NPAGES;
  tss->ss0 = tss->ss1 = tss->ss2 = GDT_OS_DATA_SEL;

  /* prepare the initial stack for the new process */
  initStack(((uint32_t)stackData) + PAGE_SIZE, tss);

  // IPC
  desc->isWaitingSender = -1;
  desc->isWaitingReceiver = -1;
  __OS_ipc_initChannelList(&(desc->channels));
  // end IPC
  // SEM
  desc->tss->isWaitingOnP = -1;

  // THREADS
  desc->numThreads = 1;
  desc->tss->next = desc->tss->prev = NULL;
  desc->tss->threadID = 0;
  // end THREADS
  desc->tss->timeToWake = 0;

  /* Private Semaphore initialized to 0, as soon as P is made it yields */
  desc->tss->privSem = __OS_sem_allocateSemaphore(0);

#ifdef RAMDISK
  if (ramdisk_present) {
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

  printk("SET TSS entry....\n");
  return desc;
}


void killProcess() {
  /* TODO free sem for every threads */
  //__OS_sem_freeSemaphore(processTable[currProcess].tss->privSem);
  processTable[currProcess].isAlive = 0;
  numThreads -= processTable[currProcess].numThreads;
  numProcesses--;
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
  stack->gs = GDT_USER_DATA_SEL + 3;
  
  tss->esp = tss->esp0;
  tss->eip = (uint32_t)startThread;
}

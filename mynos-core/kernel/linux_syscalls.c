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
#include "video.h"
#include "mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "kutils.h"
#include "linux_syscalls.h"
#include "dynalloc.h"
#include "sched.h"
#include "sem.h"

extern uint32_t currProcess;

typedef unsigned long int clock_t;
struct tms {
              clock_t tms_utime;  /* user time */
              clock_t tms_stime;  /* system time */
              clock_t tms_cutime; /* user time of children */
              clock_t tms_cstime; /* system time of children */
       };
void _linux_syscall_times(struct tms *buf) {
  static uint32_t tm = 0;
  tm += 10;
  buf->tms_utime = buf->tms_stime = tm;
}

void _linux_syscalls_trap_TRAP();
__asm__ (\
	 ".globl _linux_syscalls_trap_TRAP         \n"\
	 "_linux_syscalls_trap_TRAP:               \n"\
	 "   cmpl $1, %eax\n"\
	 "   je .linux_exit\n"\
	 "   cmpl $2, %eax\n"\
	 "   je .linux_fork\n"\
	 "   cmpl $3, %eax\n"\
	 "   je .linux_read\n"\
	 "   cmpl $4, %eax\n"\
	 "   je .linux_write\n"\
	 "   cmpl $5, %eax\n"\
	 "   je .linux_open\n"\
	 "   cmpl $6, %eax\n"\
	 "   je .linux_close\n"\
	 "   cmpl $20, %eax\n"\
	 "   je .linux_getpid\n"\
	 "   cmpl $43, %eax\n"\
	 "   je .linux_times\n"\
	 "   cmpl $64, %eax\n"\
	 "   je .linux_getppid\n"\
	 "   cmpl $90, %eax\n"\
	 "   je .linux_mmap\n"\
	 "   cmpl $91, %eax\n"\
	 "   je .linux_munmap\n"\
	 "   cmpl $140, %eax\n"\
	 "   je .linux_llseek\n"\
	 "   push %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 ".linux_exit:\n"\
	 "   pushl %ebx\n"\
	 "   call _linux_syscall_exit\n"\
	 "   popl %ebx\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_close:\n"\
	 "   pushl %ebx\n"\
	 "   call _linux_syscall_close\n"\
	 "   popl %ebx\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_fork:\n"\
	 "   call _linux_syscall_fork\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getpid:\n"\
	 "   call _linux_syscall_getpid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getppid:\n"\
	 "   call _linux_syscall_getppid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_read:\n"\
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _linux_syscall_read     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_write:\n"\
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _linux_syscall_write     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_open:\n"\
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _linux_syscall_open     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mmap:\n"\
	 "   pushl %ebx\n"
	 "   call _linux_syscall_mmap     \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_times:\n"\
	 "   pushl %ebx\n"
	 "   call _linux_syscall_times     \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_munmap:\n"\
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _linux_syscall_munmap     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_llseek:\n"\
	 "   pushl %edi\n"
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _linux_syscall_llseek     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"\
	 "   popl %edi\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".exit_linux_syscall:\n"\
	 "   iret                \n"\
	 );


void _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id) {
  printk("syscall ");
  print_uint(syscall_id);
  KPANIC(" is not yet implemented!");
}

void _linux_syscall_exit(int status) {
  printk("process ");
  print_int(currProcess);
  printk(" exited with code ");
  print_int(status);
  print_char('\n');
  killProcess();
  sched();
}

int _linux_syscall_open(char * pathname, int flags, int mode) {
  return 5;
}

int _linux_syscall_close(int fd) {
  return 0;
}

extern modinfo_t bytecode;
static void * pun = 0;
int _linux_syscall_read(int fd, const void *buf, size_t count) {
  if (!pun) pun = (void*)bytecode.start;

  kmemcpy((void*)buf, pun, count);
  pun += count;
  return count;
}

int _linux_syscall_llseek(uint32_t fd, ulong32_t offhi, ulong32_t offlow,
			  long long int * result, uint32_t whence) {
  long fava = (long)offlow;

  pun = (void*)((uint32_t)bytecode.start + bytecode.len +fava);
		//((offhi<<32) | offlow));
  return 0;
}

int _linux_syscall_write(int fd, const void *buf, size_t count) {
  int i;

  for (i = 0; i < count; i++)
    _print_char(((char*)buf)[i], CHAR_USER_ATTRIB);
  return count;
}

int _linux_syscall_getpid() {
  return currProcess;
}

int _linux_syscall_getppid() {
  return processTable[currProcess].ppid;
}

int _linux_syscall_munmap(void *start, size_t length) {
  uint32_t npages;
#ifdef DEBUG
  printk("munmap: ");
  print_ulong_hex((long32_t)start);
  print_char(' ');
  print_long((long32_t)length);
  print_char('\n');
#endif
  npages = (length - 1) / PAGE_SIZE + 1;
  if (__OS_releasePages(start, npages, 1, 1) == NULL)
    return -1;
  return 0;
}

void * _linux_syscall_mmap(struct mmap_args * args) {
  uint32_t npages;

#ifdef DEBUG
  printk("mmap: ");
  print_long((long32_t)args->start);
  print_char(' ');
  print_long((long32_t)args->length);
  print_char(' ');
  print_long((long32_t)args->prot);
  print_char(' ');
  print_long((long32_t)args->flags);
  print_char(' ');
  print_long((long32_t)args->fd);
  print_char(' ');
  print_long((long32_t)args->offset);
  print_char('\n');
#endif //DEBUG

  npages = (args->length - 1) / PAGE_SIZE + 1;
  return __OS_askPages(npages, 0, PF_READWRITE | PF_USER);
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
  for (i = 0; i < 1024; i++) {
    if ((ptp == 1022) && (i == 1023)) return 1; // this is the pd image
    pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(ptp, i);
    if (*pte & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PF is allocated
      flags = *pte & 0xFFF;
      if (*pte & PF_PRESENT) {
	if ((pf = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
	ptc[i] = LINEAR_TO_PHYSICAL_ADDRESS(pf) | flags;
		
	/* copy the page frame */
	kmemcpy((void*)pf, (void*)__MEM_LINEAR_ADDRESS(ptp, i, 0), 
		PAGE_SIZE);
	//DEALLOCATE(pf);
      } else
	ptc[i] = flags;
    } else
      ptc[i] = 0;
  }
  return 1;
}

/* copy all threads from current process. it returns the tss
   corrisponding to current thread, for further changes... see the code! */
static tss_t * copyThreads(process_descriptor_t * ddest,
			   process_descriptor_t * dorig,
			   uint32_t * pdc);

int _linux_syscall_fork() {
  uint32_t i;
  uint32_t * pde, flags;
  uint32_t * pdc, *ptc;
  uint32_t *lastPT;
  pid_t new_pid;
  int ret = 0;
  tss_t * mirror;  // this is the new process thread corrisponding to current

  if ((pdc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;

  pdc[1023] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | 
    PF_USER | PF_READWRITE | PF_PRESENT;

  /* copy the shared kernel space */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    pdc[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  /* copy the page dir entries, but not the last one (image for PTs...) */
  for (i = _asm_last_kernel_page_dir_entry_used + 1; i < 1023; i++) {
    pde = (uint32_t*)__GET_PAGE_DIR_ENTRY(i);
    /* this if should never be PF_LOGICAL_PRESENT because we don't allocate
       a page table logically */
    if (*pde & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PT is allocated
      flags = *pde & 0xFFF;
      if (*pde & PF_PRESENT) {
	if ((ptc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
	pdc[i] = LINEAR_TO_PHYSICAL_ADDRESS(ptc) | flags;
	
	/* copy the page table */
	if (copy_page_table(i, ptc) == -1) return -1;

	//DEALLOCATE(ptc);
      } else
	pdc[i] = flags;
    } else
      pdc[i] = 0;
  }

  /* set the PD pointer: now ptc is the last but one PT */
  ptc[1023] = LINEAR_TO_PHYSICAL_ADDRESS(pdc) | PF_PRESENT;
  kmemcpy((void*)lastPT, (void*)pdc, PAGE_SIZE);

  //DEALLOCATE(lastPT);
  //DEALLOCATE(pdc);

  new_pid = numProcess++;
    
  /* copy the whole structure */
  kmemcpy((void*)&(processTable[new_pid]), 
	  (void*)&(processTable[currProcess]),
	  sizeof(process_descriptor_t));
  
  /* copy the tsses */
  mirror = 
    copyThreads(&processTable[new_pid], &processTable[currProcess], pdc);

  processTable[new_pid].pid = new_pid;
  processTable[new_pid].ppid = currProcess;
  processTable[new_pid].isAlive = 1;
  // IPC
  processTable[new_pid].isWaitingSender = -1;
  processTable[new_pid].isWaitingReceiver = -1;
  // SEM
  
  __OS_ipc_initChannelList(&(processTable[new_pid].channels));
  
  /* copy the registers, except eip and esp */
  asm volatile("movl %%eax, %0":"=m"(mirror->eax));
  asm volatile("movl %%ebx, %0":"=m"(mirror->ebx));
  asm volatile("movl %%ecx, %0":"=m"(mirror->ecx));
  asm volatile("movl %%edx, %0":"=m"(mirror->edx));
  asm volatile("movl %%esi, %0":"=m"(mirror->esi));
  asm volatile("movl %%edi, %0":"=m"(mirror->edi));
  asm volatile("movl %%ebp, %0":"=m"(mirror->ebp));

  asm volatile("movw %%cs, %0":"=m"(mirror->cs));
  asm volatile("movw %%ds, %0":"=m"(mirror->ds));
  asm volatile("movw %%es, %0":"=m"(mirror->es));
  asm volatile("movw %%fs, %0":"=m"(mirror->fs));
  asm volatile("movw %%gs, %0":"=m"(mirror->gs));
  asm volatile("movw %%ss, %0":"=m"(mirror->ss));

  ret = new_pid;
  mirror->justForked = 1;
  
  /* copy eip and esp and call the scheduler */
  mirror->esp0 = currThread->esp0;
  asm volatile (
		"movl $1f, %0\n\t"\
		"movl %%esp, %1\n\t"\
		"call sched\n\t"\
		"1:\t"\
		:"=m"(mirror->eip),\
		"=m"(mirror->esp):);

  /* this process was just forked, restore some register */
  if (currThread->justForked) {
    currThread->justForked = 0;
    asm volatile("movl %0, %%ebp"::"m"(currThread->ebp));
  }

  // back from a task switch...
  return ret;
}

static tss_t * copyThreads(process_descriptor_t * ddest,
			   process_descriptor_t * dorig,
			   uint32_t * pdc) {
  tss_t * orig = processTable[currProcess].tss;
  tss_t * dest;
  tss_t * prevDest = NULL;
  tss_t * mirror;
  
  /* the first one */
  dest = ddest->tss = (tss_t*)kmalloc(sizeof(tss_t));
  
  while (dest != NULL) {
    kmemcpy((void*)dest, 
	    (void*)orig,
	    sizeof(tss_t));
    dest->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(pdc);
    dest->isWaitingOnP = -1;
    dest->privSem = __OS_sem_allocateSemaphore(0);
    dest->prev = prevDest;
    prevDest = dest;

    if (orig == currThread) mirror = dest;

    if (orig->next != NULL) {
      orig = orig->next;
      dest->next = (tss_t*)kmalloc(sizeof(tss_t));
      dest = dest->next;
    } else {
      dest = dest->next = NULL;
    }
  }

  return mirror;
}

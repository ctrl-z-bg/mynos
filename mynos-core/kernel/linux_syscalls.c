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
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "kutils.h"
#include "linux_syscalls.h"
#include "mem/dynalloc.h"
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
/* Linux system calls (int $0x80). Linux preserves every register except
   eax: all six argument registers are saved, and pushed in this order they
   are also the cdecl arguments of every handler (ebx first) and, for mmap2,
   a struct mmap_args. */
__asm__ (".pushsection .text\n" \
	 ".globl _linux_syscalls_trap_TRAP\n"\
	 "_linux_syscalls_trap_TRAP:\n"\
	 "   pushl %ebp\n"\
	 "   pushl %edi\n"\
	 "   pushl %esi\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
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
	 "   cmpl $29, %eax\n"\
	 "   je .linux_pause\n"\
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
	 "   cmpl $192, %eax\n"\
	 "   je .linux_mmap2\n"\
	 "   cmpl $243, %eax\n"\
	 "   je .linux_set_thread_area\n"\
	 "   cmpl $125, %eax\n"\
	 "   je .linux_mprotect\n"\
	 "   cmpl $146, %eax\n"\
	 "   je .linux_writev\n"\
	 "   cmpl $252, %eax\n"\
	 "   je .linux_exit\n"\
	 "   cmpl $258, %eax\n"\
	 "   je .linux_set_tid_address\n"\
	 "   cmpl $19, %eax\n"\
	 "   je .linux_lseek\n"\
	 "   cmpl $174, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $175, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $186, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $195, %eax\n"\
	 "   je .linux_stat64\n"\
	 "   cmpl $197, %eax\n"\
	 "   je .linux_fstat64\n"\
	 "   pushl %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_exit:\n"\
	 "   call _linux_syscall_exit\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_fork:\n"\
	 "   call _linux_syscall_fork\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_read:\n"\
	 "   call _linux_syscall_read\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_write:\n"\
	 "   call _linux_syscall_write\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_open:\n"\
	 "   call _linux_syscall_open\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_close:\n"\
	 "   call _linux_syscall_close\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getpid:\n"\
	 "   call _linux_syscall_getpid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_pause:\n"\
	 "   call _linux_syscall_pause\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_times:\n"\
	 "   call _linux_syscall_times\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getppid:\n"\
	 "   call _linux_syscall_getppid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mmap:\n"\
	 "   call _linux_syscall_mmap\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_munmap:\n"\
	 "   call _linux_syscall_munmap\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_llseek:\n"\
	 "   call _linux_syscall_llseek\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mmap2:\n"\
	 "   pushl %esp\n"\
	 "   call _linux_syscall_mmap\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_set_thread_area:\n"\
	 "   call _linux_syscall_set_thread_area\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mprotect:\n"\
	 "   call _linux_syscall_mprotect\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_writev:\n"\
	 "   call _linux_syscall_writev\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_set_tid_address:\n"\
	 "   call _linux_syscall_set_tid_address\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_nosignals:\n"\
	 "   call _linux_syscall_nosignals\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_lseek:\n"\
	 "   call _linux_syscall_lseek\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_stat64:\n"\
	 "   call _linux_syscall_stat64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_fstat64:\n"\
	 "   call _linux_syscall_fstat64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".exit_linux_syscall:\n"\
	 "   popl %ebx\n"\
	 "   popl %ecx\n"\
	 "   popl %edx\n"\
	 "   popl %esi\n"\
	 "   popl %edi\n"\
	 "   popl %ebp\n"\
	 "   iret\n"\
	 ".popsection\n");


/* writev (146): musl's stdio writes through it */
int _linux_syscall_writev(int fd, const struct iovec * iov, int iovcnt) {
  int i, total = 0;
  for (i = 0; i < iovcnt; i++) {
    int n = _linux_syscall_write(fd, iov[i].iov_base, iov[i].iov_len);
    if (n < 0) return total ? total : n;
    total += n;
  }
  return total;
}

/* rt_sigaction (174), rt_sigprocmask (175), sigaltstack (186): MyNOS
   delivers no signals yet, so accept the settings and ignore them. Runtimes
   (OCaml 5) refuse to start if they fail. */
int _linux_syscall_nosignals() {
  return 0;
}

/* mprotect (125): no page protections beyond read/write yet, accept it */
int _linux_syscall_mprotect(void * addr, size_t len, int prot) {
  return 0;
}

/* set_tid_address (258): called by musl at startup; one thread per
   process from Linux's point of view, so the tid is the pid */
int _linux_syscall_set_tid_address(int * tidptr) {
  return currProcess;
}

/* Thread-local storage: a single GDT slot (GDT_TLS_INDEX) shared by all
   threads, rewritten from the incoming thread's tss on every switch. */
void tls_load(void * t) {
  tss_t * thread = (tss_t *)t;
  if (thread->tls_limit == 0 && thread->tls_base == 0)
    gdt_set_entry(GDT_TLS_INDEX, 0, 0xFFFFF,
		  D_DATA + D_WRITE + D_BIG + D_BIG_LIM + D_DPL3);
  else
    gdt_set_entry(GDT_TLS_INDEX, thread->tls_base, thread->tls_limit,
		  D_DATA + D_WRITE + D_BIG + D_DPL3 +
		  (thread->tls_pages ? D_BIG_LIM : 0));
}

int _linux_syscall_set_thread_area(struct user_desc * u_info) {
  if (u_info->entry_number != (uint32_t)-1 &&
      u_info->entry_number != GDT_TLS_INDEX)
    return -22; /* EINVAL */

  currThread->tls_base = u_info->base_addr;
  currThread->tls_limit = u_info->limit & 0xFFFFF;
  currThread->tls_pages = (u_info->flags >> 4) & 1;
  u_info->entry_number = GDT_TLS_INDEX;
  tls_load(currThread);
  return 0;
}

/* unknown Linux system call: fail with -ENOSYS, as Linux does, so that
   libcs and runtimes can fall back. Report each number once. */
int32_t _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id) {
  static uint32_t reported[512 / 32];
  if (syscall_id >= 512 ||
      !(reported[syscall_id / 32] & (1u << (syscall_id % 32)))) {
    if (syscall_id < 512)
      reported[syscall_id / 32] |= 1u << (syscall_id % 32);
    printk("Linux syscall ");
    print_uint(syscall_id);
    printk(" not implemented (process ");
    print_uint(currProcess);
    printk("): -ENOSYS\n");
  }
  return -38; /* -ENOSYS */
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

int32_t _linux_syscall_pause() {
  privP();
  return -1;
}

/*
 * There is no filesystem behind the Linux file calls yet (mynos-nxa): every
 * open() opens the same read-only file, the OCaml bytecode passed as GRUB
 * module 1. These calls give it proper file semantics (a position, seeks
 * from start/current/end, a size) so that any libc and OCaml runtime can
 * read it.
 */
#define BYTECODE_FD 5
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

extern modinfo_t bytecode;
static uint32_t bytecode_pos = 0;

int _linux_syscall_open(char * pathname, int flags, int mode) {
  bytecode_pos = 0;
  return BYTECODE_FD;
}

int _linux_syscall_close(int fd) {
  return 0;
}

int _linux_syscall_read(int fd, const void *buf, size_t count) {
  if (fd < 3) return 0;   /* no stdin yet: end of file */
  if (bytecode_pos >= bytecode.len) return 0;
  if (count > bytecode.len - bytecode_pos)
    count = bytecode.len - bytecode_pos;
  kmemcpy((void*)buf, (char*)bytecode.start + bytecode_pos, count);
  bytecode_pos += count;
  return count;
}

static long long bytecode_seek(long long offset, uint32_t whence) {
  long long pos;
  switch (whence) {
  case SEEK_SET: pos = offset; break;
  case SEEK_CUR: pos = (long long)bytecode_pos + offset; break;
  case SEEK_END: pos = (long long)bytecode.len + offset; break;
  default: return -22; /* EINVAL */
  }
  if (pos < 0) return -22;
  bytecode_pos = (uint32_t)pos;
  return pos;
}

/* lseek (19) */
long _linux_syscall_lseek(int fd, long offset, uint32_t whence) {
  return (long)bytecode_seek(offset, whence);
}

/* _llseek (140): 64-bit offset in two halves, result written back */
int _linux_syscall_llseek(uint32_t fd, ulong32_t offhi, ulong32_t offlow,
			  long long int * result, uint32_t whence) {
  long long pos = bytecode_seek(((long long)offhi << 32) | offlow, whence);
  if (pos < 0) return (int)pos;
  *result = pos;
  return 0;
}

/* Linux i386 struct stat64 */
struct stat64 {
  unsigned long long st_dev;
  unsigned char      __pad0[4];
  unsigned long      __st_ino;
  unsigned int       st_mode;
  unsigned int       st_nlink;
  unsigned long      st_uid;
  unsigned long      st_gid;
  unsigned long long st_rdev;
  unsigned char      __pad3[4];
  long long          st_size;
  unsigned long      st_blksize;
  unsigned long long st_blocks;
  unsigned long      st_atime, st_atime_nsec;
  unsigned long      st_mtime, st_mtime_nsec;
  unsigned long      st_ctime, st_ctime_nsec;
  unsigned long long st_ino;
} __attribute__((packed));

static int bytecode_stat(struct stat64 * st) {
  kbzero(st, sizeof(struct stat64));
  st->st_mode = 0100755;          /* regular file, rwxr-xr-x */
  st->st_nlink = 1;
  st->st_size = bytecode.len;
  st->st_blksize = PAGE_SIZE;
  st->st_blocks = (bytecode.len + 511) / 512;
  st->__st_ino = st->st_ino = 1;
  return 0;
}

/* stat64 (195), fstat64 (197) */
int _linux_syscall_stat64(char * path, struct stat64 * st) {
  return bytecode_stat(st);
}

int _linux_syscall_fstat64(int fd, struct stat64 * st) {
  return bytecode_stat(st);
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
  return processTable[currProcess]->ppid;
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
  void * ret;

  npages = (args->length - 1) / PAGE_SIZE + 1;
  ret =__OS_askPages(npages, 0, PF_READWRITE | PF_USER);
  if (ret == NULL)
    ret = (void *)-12; /* -ENOMEM: libcs test for -4095..-1, not NULL */

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
  printk(" = ");
  print_uint_hex(ret);
  print_char('\n');
#endif //DEBUG

  return ret;
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
	  //DEALLOCATE(pf);
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
    } else
      ptc[i] = 0;
  }
  return 1;
}

/* copy all threads from current process. it returns the tss
   corrisponding to current thread, for further changes... see the code! */
static tss_t * copyThreads(process_descriptor_t * ddest,
			   process_descriptor_t * dorig,
			   uint32_t * pdc, pid_t pid);

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
  ptc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(pdc) | PF_PRESENT;
  kmemcpy((void*)lastPT, (void*)pdc, PAGE_SIZE);

  //DEALLOCATE(pdc);

  new_pid = numProcess++;
  numProcesses++;
  numThreads += processTable[currProcess]->numThreads;

  processTable[new_pid] = 
    (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));

  /* copy the whole structure */
  kmemcpy(processTable[new_pid], 
	  processTable[currProcess],
	  sizeof(process_descriptor_t));

  /* copy the linear space map */
  processTable[new_pid]->lmemmap = 
    __lmt_copyList(processTable[currProcess]->lmemmap);

  /* initialize the channel and port lists */
  listInit(processTable[new_pid]->channelList);
  listInit(processTable[new_pid]->portList);

  /* copy the tsses */
  mirror = 
    copyThreads(processTable[new_pid], processTable[currProcess], 
		pdc, new_pid);

  // TODO: other threads!!!
  readyQueueInsert(mirror);
#if 0
  // insert the threads into the readyQueue
  {
    tss_t * thread = processTable[new_pid]->tss;
    while (thread) {
      readyQueueInsert(thread);
      thread = thread->next;
    }
  }
#endif

  processTable[new_pid]->pid = new_pid;
  processTable[new_pid]->ppid = currProcess;
  processTable[new_pid]->isAlive = 1;

  processTable[new_pid]->ptsMirror = (void*)LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  //DEALLOCATE(lastPT);
  
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
			   uint32_t * pdc, pid_t pid) {
  tss_t * orig = processTable[currProcess]->tss;
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
    dest->privSem = __OS_sem_allocateSemaphore(0);
    dest->prev = prevDest;
    prevDest = dest;
    dest->pid = pid;

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

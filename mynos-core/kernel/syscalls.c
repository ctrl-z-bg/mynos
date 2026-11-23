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

#include "trace.h"
#include "mem/mem.h"
#include "global.h"
#include "video.h"
#include "syscalls.h"
#include "pic.h"
#include "pit.h"
#include "irq.h"
#include "services.h"
#include "stats.h"
#include "time.h"
#include "process.h"
#include "mynos.h"
#include "ipc/channel.h"

extern uint32_t currProcess;

void _mynos_syscalls_trap_TRAP();
__asm__ (".pushsection .text\n" \
	 ".globl _mynos_syscalls_trap_TRAP         \n"\
	 "_mynos_syscalls_trap_TRAP:               \n"\
	 /* the C functions may change ecx and edx: the caller gets them back
	    (only eax, the result, changes) */
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   cmpl $3, %eax\n"\
	 "   je .mynos_send\n"\
	 "   cmpl $4, %eax\n"\
	 "   je .mynos_recv\n"\
	 "   cmpl $5, %eax\n"\
	 "   je .mynos_freeChannel\n"\
	 "   cmpl $6, %eax\n"\
	 "   je .mynos_P\n"\
	 "   cmpl $7, %eax\n"\
	 "   je .mynos_tryP\n"\
	 "   cmpl $8, %eax\n"\
	 "   je .mynos_V\n"\
	 "   cmpl $9, %eax\n"\
	 "   je .mynos_semInit\n"\
	 "   cmpl $13, %eax\n"\
	 "   je .mynos_semFree\n"\
	 "   cmpl $10, %eax\n"\
	 "   je .mynos_driverRegister\n"\
	 "   cmpl $11, %eax\n"\
	 "   je .mynos_serviceRegister\n"\
	 "   cmpl $12, %eax\n"\
	 "   je .mynos_clientRegister\n"\
	 "   cmpl $20, %eax\n"\
	 "   je .mynos_allocatePort\n"\
	 "   cmpl $21, %eax\n"\
	 "   je .mynos_allocatePortP\n"\
	 "   cmpl $22, %eax\n"\
	 "   je .mynos_connectToPort\n"\
	 "   cmpl $23, %eax\n"\
	 "   je .mynos_listenPort\n"\
	 "   cmpl $24, %eax\n"\
	 "   je .mynos_freePort\n"\
	 "   cmpl $25, %eax\n"\
	 "   je .mynos_changePortOwner\n"\
	 "   cmpl $26, %eax\n"\
	 "   je .mynos_channelPeer\n"\
	 "   cmpl $27, %eax\n"\
	 "   je .mynos_processInfo\n"\
	 "   cmpl $28, %eax\n"\
	 "   je .mynos_mapPhysical\n"\
	 "   cmpl $29, %eax\n"\
	 "   je .mynos_dmaArea\n"\
	 "   cmpl $30, %eax\n"\
	 "   je .mynos_spawn\n"\
	 "   cmpl $31, %eax\n"\
	 "   je .mynos_log\n"\
	 "   cmpl $32, %eax\n"\
	 "   je .mynos_trace\n"\
	 "   cmpl $33, %eax\n"\
	 "   je .mynos_processes\n"\
	 "   cmpl $34, %eax\n"\
	 "   je .mynos_kill\n"\
	 "   cmpl $35, %eax\n"\
	 "   je .mynos_klog\n"\
	 "   cmpl $36, %eax\n"\
	 "   je .mynos_faults\n"\
	 "   cmpl $31, %eax\n"\
	 "   je .mynos_log\n"\
	 "   cmpl $100, %eax\n"\
	 "   je .mynos_enableIrq\n"\
	 "   cmpl $101, %eax\n"\
	 "   je .mynos_disableIrq\n"\
	 "   cmpl $200, %eax\n"\
	 "   je .mynos_createThread\n"\
	 "   cmpl $201, %eax\n"\
	 "   je .mynos_exitThread\n"\
	 "   cmpl $202, %eax\n"\
	 "   je .mynos_selfThread\n"\
	 "   cmpl $300, %eax\n"\
	 "   je .mynos_setTimer\n"\
	 "   cmpl $400, %eax\n"\
	 "   je .mynos_stats\n"\
	 "   push %eax\n"\
	 "   call _mynos_syscall_WRONGSYSCALL\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_send:\n"\
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_ipc_send     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_recv:\n"\
	 "   pushl %edi\n"
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_ipc_recv\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"
	 "   popl %esi\n"
	 "   popl %edi\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_freeChannel:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_ipc_freeChannel\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_P:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_userP  \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_tryP:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_userTryP  \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_V:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_userV  \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_semInit:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_allocateUserSemaphore\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_semFree:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_userFree\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_driverRegister:\n"\
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_driverRegister     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_serviceRegister:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_service_registerService\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_clientRegister:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_service_registerClient\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_allocatePort:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_port_allocPort\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_allocatePortP:\n"\
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_port_allocPortP\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_connectToPort:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_port_connectToPort\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_listenPort:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_port_listenPort\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_freePort:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_port_freePort\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_changePortOwner:\n"\
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_port_changeOwner\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_channelPeer:\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_channelPeer\n"\
	 "   popl  %ebx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_mapPhysical:\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_mapPhysical\n"\
	 "   popl  %ebx\n"\
	 "   popl  %ecx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_dmaArea:\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_dmaArea\n"\
	 "   popl  %ebx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_processInfo:\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_processInfo\n"\
	 "   popl  %ebx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_spawn:\n"\
	 "   pushl %edi\n"\
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _mynos_syscall_spawn\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"
	 "   popl %edi\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_kill:\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_kill\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_klog:\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_klog\n"\
	 "   addl $12, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_faults:\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_faults\n"\
	 "   addl $8, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_processes:\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_processes\n"\
	 "   addl $8, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_trace:\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_trace\n"\
	 "   addl $12, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_log:\n"\
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call _mynos_syscall_log\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_enableIrq:\n"\
	 "   pushw %bx\n"
	 "   call _mynos_syscall_enableIrq\n"\
	 "   popw %bx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_disableIrq:\n"\
	 "   pushw %bx\n"
	 "   call _mynos_syscall_disableIrq\n"\
	 "   popw %bx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_createThread:\n"\
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_threadCreate\n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_exitThread:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_threadExit\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_selfThread:\n"\
	 "   call __OS_threadSelf\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_setTimer:\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_setTimer\n"\
	 "   popl  %ebx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_stats:\n"\
	 "   pushl %ebx\n"\
	 "   call __OS_fillStats\n"\
	 "   popl  %ebx\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".exit_mynos_syscall:\n"\
	 "   popl %ecx\n"\
	 "   popl %edx\n"\
	 "   iret                \n"\
	 ".popsection\n");


/* unknown native system call: report it and fail the call */
int32_t _mynos_syscall_WRONGSYSCALL(uint32_t syscall_id) {
  printk("MyNOS syscall ");
  print_uint(syscall_id);
  printk(" doesn't exist (process ");
  print_uint(currProcess);
  printk(")\n");
  return MYNOS_ERR_INVALID;
}

/* sleep for at least usec microseconds (mynos_setTimer / mynos_sleep).
   It used to only store a wake-up time nobody read, in the wrong unit. */
/* spawn (30): start a new process, child of the caller, from an ELF image
   in the caller's memory, with arguments and environment (NULL-terminated
   vectors, either may be NULL). Returns the pid or a MYNOS_ERR_* code. */
int _mynos_syscall_spawn(uint32_t * elf, uint32_t len, char ** argv,
			 char ** envp, uint32_t privileges) {
  if (!__mem_userArea(elf, len) || __mem_userVector(argv, 1024, 4096) < 0 ||
      __mem_userVector(envp, 1024, 4096) < 0)
    return MYNOS_ERR_INVALID;
  /* a child gets at most its parent's privileges */
  if (privileges & ~processTable[currProcess]->privileges)
    return MYNOS_ERR_DENY;
  return createProcess(elf, len, argv, envp, CURRPID, privileges);
}

/* channelPeer (26): the pid of the process at the other end of one of the
   caller's channels (doc/decisions/identity-and-permissions.md); an error
   if the channel is not the caller's, or the other end freed it */
int _mynos_syscall_channelPeer(int32_t c) {
  unichannel_t * other = getMyWriteChannel(c);
  if (other == NULL || getMyReadChannel(c) == NULL) return MYNOS_ERR_INVALID;
  if (other->receiver < 0) return MYNOS_ERR_BROKEN;
  return other->receiver;
}

/* mapPhysical (28): npages of a device's memory (not RAM: a frame
   buffer) from physical address phys, mapped into the caller: their
   address. Drivers only (the io privilege). */
int _mynos_syscall_mapPhysical(uint32_t phys, uint32_t npages) {
  void * a;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  a = __OS_mapPhysical(phys, npages);
  return a ? (int)a : MYNOS_ERR_INVALID;
}

/* dmaArea (29): the DMA area (mem.c: 64 KB below 16 MB, for ISA DMA).
   what 0: mapped into the caller, its address; 1: its physical address,
   which the driver gives the DMA controller. Drivers only (the io
   privilege); MYNOS_ERR_INVALID if the boot found no place for it. */
int _mynos_syscall_dmaArea(uint32_t what) {
  void * a;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (__dma_area == 0) return MYNOS_ERR_INVALID;
  if (what == 1) return (int)__dma_area;
  a = __OS_mapDmaArea();
  return a ? (int)a : MYNOS_ERR_FULL;
}

/* processInfo (27): a process's privileges, with MYNOS_PROC_ALIVE while
   it runs; MYNOS_ERR_INVALID if there is no such pid (it ended and was
   collected, or never was) */
int _mynos_syscall_processInfo(pid_t pid) {
  process_descriptor_t * p = proc(pid);
  if (p == NULL) return MYNOS_ERR_INVALID;
  return (int)(p->privileges & 0xFF) | (p->isAlive ? MYNOS_PROC_ALIVE : 0);
}

/* log (31): write a message of a program to the kernel log (the log port,
   and the screen only while kernel messages are shown there) */
int _mynos_syscall_log(const char * s, uint32_t len) {
  uint32_t i;
  if (len > 1024) len = 1024;
  if (!__mem_userArea(s, len)) return MYNOS_ERR_INVALID;
  for (i = 0; i < len; i++)
    print_char(s[i]);
  return 0;
}

int32_t _mynos_syscall_setTimer(ulong32_t usec) {
  time_sleepUsec(usec);
  return 0;
}

/* enableIrq (100), disableIrq (101): the caller's own lines only */
int _mynos_syscall_enableIrq(ushort16_t n) {
  if (!__OS_irq_valid(n)) return MYNOS_ERR_INVALID;
  if (__OS_irq_owner(n) != CURRPID) return MYNOS_ERR_DENY;
  enable_irq(n);
  return 0;
}

int _mynos_syscall_disableIrq(ushort16_t n) {
  if (!__OS_irq_valid(n)) return MYNOS_ERR_INVALID;
  if (__OS_irq_owner(n) != CURRPID) return MYNOS_ERR_DENY;
  disable_irq(n);
  return 0;
}



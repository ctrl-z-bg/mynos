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
#include "syscalls.h"
#include "pic.h"
#include "pit.h"
#include "irq.h"
#include "services.h"
#include "stats.h"

extern uint32_t currProcess;

void _mynos_syscalls_trap_TRAP();
__asm__ (\
	 ".globl _mynos_syscalls_trap_TRAP         \n"\
	 "_mynos_syscalls_trap_TRAP:               \n"\
	 "   cmpl $3, %eax\n"\
	 "   je .mynos_send\n"\
	 "   cmpl $4, %eax\n"\
	 "   je .mynos_recv\n"\
	 "   cmpl $5, %eax\n"\
	 "   je .mynos_recvAll\n"\
	 "   cmpl $6, %eax\n"\
	 "   je .mynos_P\n"\
	 "   cmpl $7, %eax\n"\
	 "   je .mynos_tryP\n"\
	 "   cmpl $8, %eax\n"\
	 "   je .mynos_V\n"\
	 "   cmpl $9, %eax\n"\
	 "   je .mynos_semInit\n"\
	 "   cmpl $9, %eax\n"\
	 "   je .mynos_semFree\n"\
	 "   cmpl $10, %eax\n"\
	 "   je .mynos_driverRegister\n"\
	 "   cmpl $11, %eax\n"\
	 "   je .mynos_serviceRegister\n"\
	 "   cmpl $12, %eax\n"\
	 "   je .mynos_clientRegister\n"\
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
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_ipc_recv     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_recvAll:\n"\
	 "   pushl %esi\n"
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call __OS_ipc_recvAll     \n"\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"\
	 "   popl %esi\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_P:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_P     \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_tryP:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_tryP     \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_V:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_V     \n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_semInit:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_allocateSemaphore\n"\
	 "   popl %ebx\n"
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_semFree:\n"\
	 "   pushl %ebx\n"
	 "   call __OS_sem_freeSemaphore\n"\
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
	 "   iret                \n"\
	 );


void _mynos_syscall_WRONGSYSCALL(uint32_t syscall_id) {
  printk("syscall ");
  print_uint(syscall_id);
  KPANIC(" doesn't exist!!");
}

int32_t _mynos_syscall_setTimer(ulong32_t usec) {
  uint32_t ticks = usec / ONE_TICK_TIME;
  currThread->timeToWake = timerTicks + ticks;
  return 0;
}

int _mynos_syscall_enableIrq(ushort16_t n) {
  /* perform check ... */
  enable_irq(n);
  return 0;
}

int _mynos_syscall_disableIrq(ushort16_t n) {
  /* perform check ... */
  disable_irq(n);
  return 0;
}



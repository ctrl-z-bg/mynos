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
	 ".exit_mynos_syscall:\n"\
	 "   iret                \n"\
	 );


void _mynos_syscall_WRONGSYSCALL(uint32_t syscall_id) {
  printk("syscall ");
  print_uint(syscall_id);
  KPANIC(" doesn't exist!!");
}


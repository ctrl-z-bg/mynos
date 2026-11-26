/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The i386's ways into the kernel, in assembly (doc/decisions/arch.md):
 * the two system call gates, the page fault, the copy between kernel and
 * process that may fault, and a cloned thread's start. Each calls the
 * generic C handlers by name. Moved here from syscalls.c,
 * linux_syscalls.c, mem/mem.c and lthreads.c, unchanged.
 */

/* the native calls (int 0x81): syscalls.c's handlers, by number */
__asm__ (".pushsection .text\n" \
	 ".globl _mynos_syscalls_trap_TRAP         \n"\
	 "_mynos_syscalls_trap_TRAP:               \n"\
	 "   cld\n"  /* the caller may have DF = 1: the kernel's C needs 0 */\
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
	 "   cmpl $37, %eax\n"\
	 "   je .mynos_pager\n"\
	 "   cmpl $38, %eax\n"\
	 "   je .mynos_procstat\n"\
	 "   cmpl $39, %eax\n"\
	 "   je .mynos_dmaAlloc\n"\
	 "   cmpl $31, %eax\n"\
	 "   je .mynos_log\n"\
	 "   cmpl $100, %eax\n"\
	 "   je .mynos_enableIrq\n"\
	 "   cmpl $101, %eax\n"\
	 "   je .mynos_disableIrq\n"\
	 "   cmpl $103, %eax\n"\
	 "   je .mynos_pciConfig\n"\
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
	 ".mynos_pager:\n"\
	 "   pushl %edi\n"\
	 "   pushl %esi\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_pager\n"\
	 "   addl $20, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_pciConfig:\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_pciConfig\n"\
	 "   addl $12, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_dmaAlloc:\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_dmaAlloc\n"\
	 "   addl $8, %esp\n"\
	 "   jmp .exit_mynos_syscall\n"\
	 ".mynos_procstat:\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   call _mynos_syscall_procstat\n"\
	 "   addl $8, %esp\n"\
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

/* Linux's calls (int 0x80): linux_syscalls.c's handlers, by i386 number. Linux preserves every register except
   eax: all six argument registers are saved, and pushed in this order they
   are also the cdecl arguments of every handler (ebx first) and, for mmap2,
   a struct mmap_args */
__asm__ (".pushsection .text\n" \
	 ".globl _linux_syscalls_trap_TRAP\n"\
	 "_linux_syscalls_trap_TRAP:\n"\
	 "   cld\n"  /* the caller may have DF = 1: the kernel's C needs 0 */\
	 "   pushl %ebp\n"\
	 "   pushl %edi\n"\
	 "   pushl %esi\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   cmpl $1, %eax\n"\
	 "   je .linux_exit_thread\n"\
	 "   cmpl $120, %eax\n"\
	 "   je .linux_clone\n"\
	 "   cmpl $240, %eax\n"\
	 "   je .linux_futex\n"\
	 "   cmpl $422, %eax\n"\
	 "   je .linux_futex_time64\n"\
	 "   cmpl $224, %eax\n"\
	 "   je .linux_gettid\n"\
	 "   cmpl $158, %eax\n"\
	 "   je .linux_sched_yield\n"\
	 "   cmpl $242, %eax\n"\
	 "   je .linux_sched_getaffinity\n"\
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
	 "   cmpl $13, %eax\n"\
	 "   je .linux_time\n"\
	 "   cmpl $78, %eax\n"\
	 "   je .linux_gettimeofday\n"\
	 "   cmpl $162, %eax\n"\
	 "   je .linux_nanosleep\n"\
	 "   cmpl $265, %eax\n"\
	 "   je .linux_clock_gettime\n"\
	 "   cmpl $267, %eax\n"\
	 "   je .linux_clock_nanosleep\n"\
	 "   cmpl $403, %eax\n"\
	 "   je .linux_clock_gettime64\n"\
	 "   cmpl $407, %eax\n"\
	 "   je .linux_clock_nanosleep64\n"\
	 "   cmpl $37, %eax\n"\
	 "   je .linux_kill\n"\
	 "   cmpl $238, %eax\n"\
	 "   je .linux_tkill\n"\
	 "   cmpl $270, %eax\n"\
	 "   je .linux_tgkill\n"\
	 "   cmpl $174, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $175, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $186, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $163, %eax\n"\
	 "   je .linux_mremap\n"\
	 "   cmpl $122, %eax\n"\
	 "   je .linux_uname\n"\
	 "   cmpl $195, %eax\n"\
	 "   je .linux_stat64\n"\
	 "   cmpl $197, %eax\n"\
	 "   je .linux_fstat64\n"\
	 "   cmpl $7, %eax\n"\
	 "   je .linux_waitpid\n"\
	 "   cmpl $355, %eax\n"\
	 "   je .linux_getrandom\n"\
	 "   cmpl $54, %eax\n"\
	 "   je .linux_ioctl\n"\
	 "   cmpl $114, %eax\n"\
	 "   je .linux_wait4\n"\
	 "   cmpl $77, %eax\n"\
	 "   je .linux_getrusage\n"\
	 "   cmpl $24, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $47, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $49, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $50, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $199, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $200, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $201, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   cmpl $202, %eax\n"\
	 "   je .linux_getuid\n"\
	 "   pushl %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_exit:\n"\
	 "   call _linux_syscall_exit\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_exit_thread:\n"\
	 "   call _linux_syscall_exit_thread\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clone:\n"\
	 "   call _linux_syscall_clone\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_futex:\n"\
	 "   call _linux_syscall_futex\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_futex_time64:\n"\
	 "   call _linux_syscall_futex_time64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_gettid:\n"\
	 "   call _linux_syscall_gettid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_sched_yield:\n"\
	 "   call _linux_syscall_sched_yield\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_sched_getaffinity:\n"\
	 "   call _linux_syscall_sched_getaffinity\n"\
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
	 "   call _linux_syscall_old_mmap\n"\
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
	 ".linux_time:\n"\
	 "   call _linux_syscall_time\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_gettimeofday:\n"\
	 "   call _linux_syscall_gettimeofday\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_nanosleep:\n"\
	 "   call _linux_syscall_nanosleep\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_gettime:\n"\
	 "   call _linux_syscall_clock_gettime\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_nanosleep:\n"\
	 "   call _linux_syscall_clock_nanosleep\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_gettime64:\n"\
	 "   call _linux_syscall_clock_gettime64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_nanosleep64:\n"\
	 "   call _linux_syscall_clock_nanosleep64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_kill:\n"\
	 "   call _linux_syscall_kill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_tkill:\n"\
	 "   call _linux_syscall_kill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_tgkill:\n"\
	 "   call _linux_syscall_tgkill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_nosignals:\n"\
	 "   call _linux_syscall_nosignals\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_uname:\n"\
	 "   call _linux_syscall_uname\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mremap:\n"\
	 "   call _linux_syscall_mremap\n"\
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
	 ".linux_ioctl:\n"\
	 "   call _linux_syscall_ioctl\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getrandom:\n"\
	 "   call _linux_syscall_getrandom\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_waitpid:\n"\
	 "   call _linux_syscall_waitpid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_wait4:\n"\
	 "   call _linux_syscall_wait4\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getrusage:\n"\
	 "   call _linux_syscall_getrusage\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getuid:\n"\
	 "   call _linux_syscall_getuid\n"\
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

/* the page fault: _page_fault_handler (mem.c) with the faulting address,
   the error code and the saved registers */
__asm__ (".pushsection .text\n" \
	 ".globl _page_fault_handler_TRAP \n"\
	 "_page_fault_handler_TRAP:       \n"\
	 "   cld                          \n"  /* the C code needs DF = 0 */\
	 "   pushal                       \n"  /* save all registers */\
	 "   movl %esp, %ebx              \n"  /* the frame: registers, error code, eip */\
	 "   pushl %ebx                   \n"\
	 "   pushl 32(%ebx)               \n"  /* push error code */\
	 "   movl %cr2, %eax              \n"\
	 "   pushl %eax                   \n"  /* push faulting address */\
	 "   call _page_fault_handler     \n"  /* call the ISR handler */\
	 "   addl $12, %esp               \n"  /* address, error code, frame */\
	 "   popal                        \n"\
	 "   addl $4, %esp                \n"  /* the error code */\
	 "   iret                         \n"\
	 ".popsection\n");

/* copy_user (mem.c): a copy whose fault resumes at copy_user_fault */
__asm__ (".pushsection .text\n"
	 ".globl copy_user\n"
	 "copy_user:\n"
	 "   pushl %esi\n"
	 "   pushl %edi\n"
	 "   movl 12(%esp), %edi\n"
	 "   movl 16(%esp), %esi\n"
	 "   movl 20(%esp), %ecx\n"
	 "   cld\n"
	 ".globl copy_user_insn\n"
	 "copy_user_insn:\n"
	 "   rep movsb\n"
	 "   xorl %eax, %eax\n"
	 "copy_user_out:\n"
	 "   popl %edi\n"
	 "   popl %esi\n"
	 "   ret\n"
	 ".globl copy_user_fault\n"
	 "copy_user_fault:\n"
	 "   movl $-1, %eax\n"
	 "   jmp copy_user_out\n"
	 ".popsection\n");

/* a new clone thread's first instructions (lthreads.c's clone_stack_t) */
__asm__ (".pushsection .text\n" ".globl startClonedThread \n" \
	 "startClonedThread: \n"\
	 "  popw %gs\n"\
	 "  popw %fs\n"\
	 "  popw %es\n"\
	 "  popw %ds\n"\
	 "  popal\n"\
	 "  iret\n" ".popsection\n");


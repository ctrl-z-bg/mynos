#include "global.h"
#include "video.h"
#include "linux_syscalls.h"

extern uint32_t currProcess;

void _linux_syscalls_trap_TRAP();
__asm__ (\
	 ".globl _linux_syscalls_trap_TRAP         \n"\
	 "_linux_syscalls_trap_TRAP:               \n"\
	 "   cmpl $4, %eax\n"\
	 "   je .linux_write\n"\
	 "   cmpl $20, %eax\n"\
	 "   je .linux_getpid\n"\
	 "   push %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 ".linux_getpid:\n"\
	 "   call _linux_syscall_getpid\n"\
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
	 ".exit_linux_syscall:\n"\
	 "   iret                \n"\
	 );


void _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id) {
  printk("syscall ");
  print_uint(syscall_id);
  KPANIC(" is not yet implemented!");
}

void _linux_syscall_write(int fd, const void *buf, size_t count) {
  int i;

  for (i = 0; i < count; i++)
    print_char(((char*)buf)[i]);

}

int _linux_syscall_getpid() {
  return currProcess;
}


#include "global.h"
#include "video.h"
#include "mem.h"
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
	 "   cmpl $90, %eax\n"\
	 "   je .linux_mmap\n"\
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
	 ".linux_mmap:\n"\
	 "   pushl %ebx\n"
	 "   call _linux_syscall_mmap     \n"\
	 "   popl %ebx\n"
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

void * _linux_syscall_mmap(struct mmap_args * args) {
  uint32_t npages;

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

  npages = (args->length - 1) / PAGE_SIZE + 1;
  return __OS_askPages(npages, 0, PF_READWRITE | PF_USER);
}

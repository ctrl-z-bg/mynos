#include "global.h"
#include "video.h"
#include "mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "kutils.h"
#include "linux_syscalls.h"

extern uint32_t currProcess;

void _linux_syscalls_trap_TRAP();
__asm__ (\
	 ".globl _linux_syscalls_trap_TRAP         \n"\
	 "_linux_syscalls_trap_TRAP:               \n"\
	 "   cmpl $1, %eax\n"\
	 "   je .linux_exit\n"\
	 "   cmpl $2, %eax\n"\
	 "   je .linux_fork\n"\
	 "   cmpl $4, %eax\n"\
	 "   je .linux_write\n"\
	 "   cmpl $5, %eax\n"\
	 "   je .linux_open\n"\
	 "   cmpl $20, %eax\n"\
	 "   je .linux_getpid\n"\
	 "   cmpl $64, %eax\n"\
	 "   je .linux_getppid\n"\
	 "   cmpl $90, %eax\n"\
	 "   je .linux_mmap\n"\
	 "   push %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 ".linux_exit:\n"\
	 "   pushl %ebx\n"\
	 "   call _linux_syscall_exit\n"\
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
	 ".exit_linux_syscall:\n"\
	 "   iret                \n"\
	 );


void _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id) {
  printk("syscall ");
  print_uint(syscall_id);
  KPANIC(" is not yet implemented!");
}

void _linux_syscall_exit(int status) {
  struct {long a ,b;} tmp = {0, 0};
    
  printk("process ");
  print_int(currProcess);
  printk(" exited with code ");
  print_int(status);
  print_char('\n');
  killProcess();
  currProcess = 0;
  tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
  __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
}

int _linux_syscall_open(char * pathname, int flags, int mode) {
  return -1;
}

void _linux_syscall_write(int fd, const void *buf, size_t count) {
  int i;

  for (i = 0; i < count; i++)
    print_char(((char*)buf)[i]);

}

int _linux_syscall_getpid() {
  return currProcess;
}

int _linux_syscall_getppid() {
  return processTable[currProcess].ppid;
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

int _linux_syscall_fork() {
  uint32_t i;
  uint32_t * pde, flags;
  uint32_t * pdc, *ptc;
  uint32_t *lastPT;
  uint32_t new_pid;
  int ret;

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
  processTable[new_pid].pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(pdc);

  processTable[currProcess].isForking = new_pid;

  { // set the tssd for the new process
    ushort16_t tssd_gdt_sel;
    tssd_gdt_sel = gdt_get_free_index();
    gdt_set_entry(tssd_gdt_sel, 
		  LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)&processTable[new_pid]),
		  sizeof(tss_t), D_TSS);
    processTable[new_pid].tssd_gdt_selector = tssd_gdt_sel << 3;
  }


  {   // tasksw to idle process
    struct {long a ,b;} tmp = {0, 0};
    
    currProcess = 0;
    tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
    __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
  }

  // back from a task switch...
  ret = (int)processTable[currProcess].isForking;
  processTable[currProcess].isForking = 0;

  return ret;
}


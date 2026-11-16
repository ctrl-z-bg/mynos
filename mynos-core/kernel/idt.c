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

#include "pic.h"
#include "macro_gdt.h"
#include "gdt.h"
#include "idt.h"
#include "video.h"
#include "io.h"
#include "irq.h"

#include "process.h"
#include "sched.h"

extern void int_null();

desc_table(IDT, 256)
{
};

struct {
    unsigned short limit __attribute__ ((packed));
    union DT_entry *idt __attribute__ ((packed));
} loadidt = {
(256 * sizeof(union DT_entry) - 1), IDT};

/* coprocessor not available */
TRAP_WRAPPER(int7);
void int7_handler() {
  __asm__ volatile ("clts");
}

extern void _page_fault_handler_TRAP();   /* see mem.c */
extern void _linux_syscalls_trap_TRAP();  /* see linux_syscalls.c */
extern void _mynos_syscalls_trap_TRAP();  /* see linux_syscalls.c */

void init_idt() {
  int count = 0;

  for (count = 16; count < 256; count++)
    set_vector(int_null, count, D_PRESENT + D_INT);
  
  set_vector(_int0, 0, D_PRESENT + D_INT);
  set_vector(_int1, 1, D_PRESENT + D_INT);
  set_vector(_int2, 2, D_PRESENT + D_INT);
  set_vector(_int3, 3, D_PRESENT + D_INT);
  set_vector(_int4, 4, D_PRESENT + D_INT);
  set_vector(_int5, 5, D_PRESENT + D_INT);
  set_vector(_int6, 6, D_PRESENT + D_INT);
  set_vector(int7_TRAP, 7, D_PRESENT + D_INT);
  set_vector(_int8, 8, D_PRESENT + D_INT);
  set_vector(_int9, 9, D_PRESENT + D_INT);
  set_vector(_int10, 10, D_PRESENT + D_INT);
  set_vector(_int12, 12, D_PRESENT + D_INT);
  set_vector(_int13, 13, D_PRESENT + D_INT);
  set_vector(_page_fault_handler_TRAP, 14, D_PRESENT + D_INT);
  set_vector(_int15, 15, D_PRESENT + D_INT);
  set_vector(_int16, 16, D_PRESENT + D_INT);

  set_vector(_linux_syscalls_trap_TRAP, 0x80, D_PRESENT + D_INT + D_DPL3);

  set_vector(_mynos_syscalls_trap_TRAP, 0x90, D_PRESENT + D_INT + D_DPL3);

  /* this is for the external driver */
  __OS_initExternalIRQs();

  asm("lidt (%0)                 \n"	/* Load the IDT                */
      "pushfl                    \n"	/* Clear the NT flag           */
      "andl $0xffffbfff,(%%esp)  \n" "popfl                     \n":
      :	"r"((char *) &loadidt)
      );
  asm("sti");
}

void set_vector(void *handler, unsigned char interrupt,
		unsigned short control_major) {
  unsigned short codesegment = GDT_OS_CODE_SEL;
  asm volatile ("movw %%cs,%0":"=g" (codesegment));
  
  IDT[interrupt].gate.offset_low =
    (unsigned short) (((unsigned long) handler) & 0xffff);
  IDT[interrupt].gate.selector = codesegment;
  IDT[interrupt].gate.access = control_major;
  IDT[interrupt].gate.offset_high =
    (unsigned short) (((unsigned long) handler) >> 16);
}

asm(".pushsection .text\n" ".globl int_null        \n" 
    "int_null:              \n" 
    "   iret                \n"	/* Exit interrupt                   */
    ".popsection\n");

/*
 * CPU exceptions. The handlers are installed directly in the IDT (no
 * wrapper), so on entry the stack holds what the CPU pushed: for exceptions
 * without an error code, [eip, cs, ...], which a C function sees as its
 * return address and first argument; with an error code, [error, eip, cs]:
 * eip and cs are its first and second arguments.
 *
 * An exception raised in user mode (cs & 3) terminates that process, as a
 * fatal signal would on Unix. An exception in the kernel stops the system.
 */
static void exception(const char * what, uint32_t eip, uint32_t cs) {
  if ((cs & 3) == 3) {
    printk("process ");
    print_ulong(currProcess);
    printk(" killed: ");
    printk((char *)what);
    printk(" at ");
    print_ulong_hex(eip);
    print_char('\n');
    killProcess(SIGNAL_STATUS(SIGSEGV));
    sched();         /* switches to another process, never returns */
  }
  kernel_on_screen = 1;
  printk((char *)what);
  printk(" in the kernel at ");
  print_ulong_hex(eip);
  printk(" (process ");
  print_ulong(currProcess);
  printk(")\n");
  while (1);
}

void _int0(uint32_t cs) {
  exception("int0: Divide Error", (uint32_t)__builtin_return_address(0), cs);
}

void _int1(uint32_t cs) {
  exception("int1: Debug exception", (uint32_t)__builtin_return_address(0), cs);
}

void _int2() {
  printk("int2: unknown error\n");
  while (1);
}

void _int3(uint32_t cs) {
  exception("int3: Breakpoint", (uint32_t)__builtin_return_address(0), cs);
}

void _int4(uint32_t cs) {
  exception("int4: Overflow", (uint32_t)__builtin_return_address(0), cs);
}

void _int5(uint32_t cs) {
  exception("int5: Bounds check", (uint32_t)__builtin_return_address(0), cs);
}

void _int6(uint32_t cs) {
  exception("int6: Invalid opcode", (uint32_t)__builtin_return_address(0), cs);
}

/*
void _int7() {
  printk("int7: Coprocessor not available\n");
  while (1);
}
*/

void _int8() {
  printk("int8: Double fault\n");
  while (1);
}

void _int9() {
  printk("int9: Coprocessor Segment overrun\n");
  while (1);
}

void _int10(uint32_t eip, uint32_t cs) {
  exception("int10: Invalid TSS", eip, cs);
}

void _int11(uint32_t eip, uint32_t cs) {
  exception("int11: Segment not present", eip, cs);
}

void _int12(uint32_t eip, uint32_t cs) {
  exception("int12: Stack exception", eip, cs);
}

void _int13(uint32_t eip, uint32_t cs) {
  exception("int13: General Protection", eip, cs);
}

/*
void _int14() {
  printk("int14: Page fault\n");
  while (1);
}
*/

void _int15() {
  printk("in15: Unknown error\n");
  while (1);
}

void _int16(uint32_t cs) {
  exception("int16: Coprocessor error", (uint32_t)__builtin_return_address(0), cs);
}

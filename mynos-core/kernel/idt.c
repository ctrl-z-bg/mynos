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

#ifdef IPC
#include "ipc.h"

void sendTo1_handler() {
  int a = 4;
  if (__OS_ipc_send(1, (char *)&a, 4, IPC_FLAGS_NOBLOCK) < 0)
    printk("spedizione impossibile");
  else
    printk("spedito");
}
void recvFrom2_handler() {
  int a;
  int pid;
  if (__OS_ipc_recvAll(&pid, (char *)&a, 4, 0) < 0)
    printk("ricezione impossibile");
  else {
    printk("ricevuto ");
    print_ulong((ulong32_t)a);
    printk("da ");
    print_ulong((ulong32_t)pid);
  }
}
TRAP_WRAPPER(sendTo1);
TRAP_WRAPPER(recvFrom2);
#endif //IPC

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

#ifdef IPC
  set_vector(sendTo1_TRAP, 0x81, D_PRESENT + D_INT + D_DPL3);
  set_vector(recvFrom2_TRAP, 0x82, D_PRESENT + D_INT + D_DPL3);
#endif
  set_vector(_mynos_syscalls_trap_TRAP, 0x90, D_PRESENT + D_INT + D_DPL3);


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

asm(".globl int_null        \n" 
    "int_null:              \n" 
    "   iret                \n"	/* Exit interrupt                   */
    );

void _int0() {
  printk("int0: Divide Error\n");
  while (1);
}

void _int1() {
  printk("int1: Debug exception\n");
  while (1);
}

void _int2() {
  printk("int2: unknown error\n");
  while (1);
}

void _int3() {
  printk("int3: Breakpoint\n");
  while (1);
}

void _int4() {
  printk("int4: Overflow\n");
  while (1);
}

void _int5() {
  printk("int 5: Bounds check\n");
  while (1);
}

void _int6() {
  printk("int6: Invalid opcode\n");
  while (1);
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

void _int10() {
  printk("int10: Invalid TSS\n");
  while (1);
}

void _int11() {
  printk("int11: Segment not present\n");
  while (1);
}

void _int12() {
  printk("int12: Stack exception\n");
  while (1);
}

void _int13() {
  printk("int13: General Protection\n");
  while (1);
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

void _int16() {
  printk("int16: Coprocessor error\n");
  while (1);
}

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

extern void int_null();

desc_table(IDT, 256)
{
};

struct {
    unsigned short limit __attribute__ ((packed));
    union DT_entry *idt __attribute__ ((packed));
} loadidt = {
(256 * sizeof(union DT_entry) - 1), IDT};

//TRAP_WRAPPER(stupidTrap);

void stupidTrap_TRAP();
__asm__ (\
	 ".globl stupidTrap_TRAP         \n"\
	 "stupidTrap_TRAP:               \n"\
	 "   pushl %edx\n"
	 "   pushl %ecx\n"
	 "   pushl %ebx\n"
	 "   call stupidTrap_handler    \n"     /* call the ISR handler */\
	 "   popl %ebx\n"
	 "   popl %ecx\n"
	 "   popl %edx\n"
	 "   iret                \n"\
	 );

/* coprocessor not available */
TRAP_WRAPPER(int7);
void int7_handler() {
  __asm__ volatile ("clts");
}

void _int14_ISR();
__asm__ (\
	 ".globl _int14_ISR         \n"\
	 "_int14_ISR:               \n"\
	 "   movl %cr2, %eax        \n"\
	 "   pushl %eax             \n"\
	 "   call _int14    \n"     /* call the ISR handler */\
	 "   iret                \n"\
	 );

void _int14(uint32_t addr, uint32_t errcode) {
  print_char('\n');
  print_char('\n');
  printk("You tried to access the address ");
  print_uint_hex(addr);
  print_char('\n');
  printk("and you got the errorcode ");
  print_uint_hex(errcode & 7);
  print_char('\n');
  printk("It means ");
  if (errcode & 1)
    printk("page present ");
  else
    printk("not present ");

  if (errcode & 2)
    printk("on a write ");
  else
    printk("on a read ");

  if (errcode & 4)
    printk("in user mode\n");
  else
    printk("in superuser mode\n");
  print_char('\n');

  printk("int14: Page fault\n");
  while (1);
}


extern uint32_t currProcess;
void stupidTrap_handler(int fd, const void *buf, size_t count) {
  int i;

#if 1
  printk("I'm the process ");
  print_ulong((uint32_t)currProcess);
  printk(" ");
#endif

  for (i = 0; i < count; i++)
    print_char(((char*)buf)[i]);

  print_char('\n');
}

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
  set_vector(_int14_ISR, 14, D_PRESENT + D_INT);
  set_vector(_int15, 15, D_PRESENT + D_INT);
  set_vector(_int16, 16, D_PRESENT + D_INT);

  set_vector(stupidTrap_TRAP, 0x80, D_PRESENT + D_INT + D_DPL3);

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

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

#ifndef __IDT_H__
#define __IDT_H__

#define ISR_WRAPPER(NAME) \
  void NAME##_ISR();\
  __asm__ (\
   ".globl "#NAME"_ISR     \n"\
   #NAME"_ISR:             \n"\
   "   pushal              \n"\
   "   call "#NAME"_handler\n"     /* call the ISR handler */\
   "   movb $0x20, %al     \n"     /* send the EOI to master PIC */\
   "   outb %al, $0x20     \n"\
   "   popal               \n"\
   "   iret                \n"\
)

#define TRAP_WRAPPER(NAME) \
  void NAME##_TRAP();\
  __asm__ (\
   ".globl "#NAME"_TRAP    \n"\
   #NAME"_TRAP:            \n"\
   "   pushal              \n"\
   "   call "#NAME"_handler\n"     /* call the TRAP handler */\
   "   popal               \n"\
   "   iret                \n"\
);

void set_vector(void *handler, unsigned char interrupt, unsigned short control_major);
void init_idt();

void int_null();

void _int0();
void _int1();
void _int2();
void _int3();
void _int4();
void _int5();
void _int6();
void _int7();
void _int8();
void _int9();
void _int10();
void _int11();
void _int12();
void _int13();
void _int14(uint32_t addr, uint32_t errcode);
extern void _page_fault_handler(uint32_t addr, uint32_t errcode);
void _int15();
void _int16();

#endif

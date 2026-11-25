/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's interrupts: 16-byte gates; the stubs of entry.asm save every
   general register on the kernel stack (struct frame), call C, and go
   back with iretq. */

#ifndef __IDT_H__
#define __IDT_H__

/* what an entry into the kernel leaves on its stack, from rsp upwards */
struct frame {
  uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
  uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
  uint64_t vector, error;
  uint64_t rip, cs, rflags, rsp, ss;           /* the processor's */
};

/* a handler of an external interrupt, called from a stub NAME_TRAP that
   saves the registers (as the i386's TRAP_WRAPPER) */
#define TRAP_WRAPPER(NAME) \
  void NAME##_TRAP(); \
  __asm__ (".pushsection .text\n" \
   ".globl "#NAME"_TRAP\n" \
   #NAME"_TRAP:\n" \
   "   pushq $0\n" \
   "   pushq $0\n" \
   "   jmp interrupt_common_"#NAME"\n" \
   "interrupt_common_"#NAME":\n" \
   "   cld\n" \
   "   pushq %rax; pushq %rbx; pushq %rcx; pushq %rdx; pushq %rsi; pushq %rdi; pushq %rbp\n" \
   "   pushq %r8; pushq %r9; pushq %r10; pushq %r11; pushq %r12; pushq %r13; pushq %r14; pushq %r15\n" \
   "   testb $3, 144(%rsp)\n" \
   "   jz 1f\n" \
   "   swapgs\n" \
   "1: call "#NAME"_handler\n" \
   "   jmp trap_return\n" \
   ".popsection\n")

void set_vector(void * handler, unsigned char interrupt, unsigned short control_major);
void init_idt(void);

extern void _page_fault_handler(vaddr_t addr, uint32_t errcode, unsigned long * frame);

#endif

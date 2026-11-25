/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The ways into the kernel on AArch64 (entry.S): every exception, from
   EL0 or EL1, leaves a struct frame on the thread's kernel stack (SP_EL1)
   and calls arm_trap (idt.c). The PC's vector numbers stay as names:
   set_vector keeps a handler per number, which the GIC's dispatch calls
   for MyNOS's lines (M_VEC + line). */

#ifndef __IDT_H__
#define __IDT_H__

struct frame {
  uint64_t x[31];                       /* x0-x30: 0..240 */
  uint64_t sp;                          /* 248: SP_EL0, the process's stack */
  uint64_t pc;                          /* 256: ELR_EL1 (ARCH_FRAME_IP: 32) */
  uint64_t pstate;                      /* 264: SPSR_EL1 */
  uint64_t esr, far;                    /* 272, 280 */
  uint64_t vector, pad;                 /* 288: the vector table's entry */
};

/* an interrupt's handler, called from the GIC's dispatch (the kernel
   entered already, by entry.S) */
#define TRAP_WRAPPER(NAME) \
  void NAME##_handler(); \
  void NAME##_TRAP(void) { NAME##_handler(); }

void set_vector(void * handler, unsigned char interrupt, unsigned short control_major);
void init_idt(void);

extern void _page_fault_handler(vaddr_t addr, uint32_t errcode, unsigned long * frame);

#endif

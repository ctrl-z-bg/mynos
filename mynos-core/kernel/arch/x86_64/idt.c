/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's IDT (doc/decisions/x86-64.md): 256 gates of 16 bytes. The
   processor's exceptions and MyNOS's native calls (int 0x90) come
   through entry.asm's stubs to x86_trap; the external interrupts through
   the TRAP_WRAPPER stubs of irq.c and pit.c. */

#include "global.h"
#include "idt.h"
#include "gdt.h"
#include "video.h"
#include "process.h"
#include "sched.h"
#include "mem/mem.h"

struct gate {
  uint16_t off_low, selector;
  uint8_t ist, type;
  uint16_t off_mid;
  uint32_t off_high, zero;
} __attribute__((packed));

static struct gate idt[256] __attribute__((aligned(16)));
static struct { uint16_t limit; uint64_t base; } __attribute__((packed)) idtr;

/* control: the i386's (D_INT or D_TRAP, D_PRESENT, D_DPL3), whose high
   byte is the gate's type byte here too */
void set_vector(void * handler, unsigned char n, unsigned short control)
{
  uint64_t h = (uint64_t)handler;
  idt[n].off_low = h & 0xFFFF;
  idt[n].selector = GDT_OS_CODE_SEL;
  idt[n].ist = 0;
  idt[n].type = control >> 8;
  idt[n].off_mid = (h >> 16) & 0xFFFF;
  idt[n].off_high = h >> 32;
  idt[n].zero = 0;
}

extern void * exception_stubs[32];
extern void native_call_entry(void);
extern void int_null(void);
void __OS_initExternalIRQs(void);
void arch_init_calls(void);

/* another processor's: the same IDT (smp.c) */
void idt_load(void)
{
  __asm__ volatile ("lidt %0" : : "m"(idtr));
}

void init_idt(void)
{
  int i;
  for (i = 32; i < 256; i++)
    set_vector(int_null, i, D_INT + D_PRESENT);
  for (i = 0; i < 32; i++)
    set_vector(exception_stubs[i], i, D_INT + D_PRESENT);
  /* MyNOS's native calls: reachable from user mode */
  set_vector(native_call_entry, 0x90, D_INT + D_PRESENT + D_DPL3);
  idtr.limit = sizeof idt - 1;
  idtr.base = (uint64_t)idt;
  /* the drivers' interrupts (irq.c) */
  __OS_initExternalIRQs();
  __asm__ volatile ("lidt %0" : : "m"(idtr));
  arch_init_calls();
  __asm__ volatile ("sti");
}

static char * names[32] = {
  "divide error", "debug", "NMI", "breakpoint", "overflow", "bound",
  "invalid opcode", "no FPU", "double fault", "coprocessor segment",
  "invalid TSS", "segment not present", "stack fault",
  "general protection", "page fault", "15", "x87 error", "alignment",
  "machine check", "SIMD error" };

extern void _mynos_native_call(struct frame * f);

/* every exception, and the native calls */
void x86_trap(struct frame * f)
{
  uint64_t cr2;
  if (f->vector == 0x90) {
    _mynos_native_call(f);
    return;
  }
  if (f->vector == 14) {
    __asm__ volatile ("movq %%cr2, %0" : "=r"(cr2));
    _page_fault_handler(cr2, f->error, (unsigned long *)f);
    return;
  }
  if (f->vector == 7) {                /* the FPU, after a task switch */
    __asm__ volatile ("clts");
    return;
  }
  if ((f->cs & 3) == 3) {              /* a process's fault: it ends */
    printk("process ");
    print_ulong(CURRPID);
    printk(" killed: ");
    printk(f->vector < 20 ? names[f->vector] : "exception");
    printk(" at ");
    print_ulong_hex(f->rip);
    print_char('\n');
    killProcess(SIGNAL_STATUS(f->vector == 13 ? 11 : 4));
    sched();
    return;
  }
  kernel_on_screen = 1;
  printk("\nkernel exception: ");
  printk(f->vector < 20 ? names[f->vector] : "?");
  printk(" at ");
  print_ulong_hex(f->rip);
  printk(", error ");
  print_ulong_hex(f->error);
  print_char('\n');
  KPANIC("exception");
}

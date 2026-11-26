/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The exceptions on AArch64 (doc/decisions/aarch64.md, choice 6): entry.S
   saves the registers and calls arm_trap with the vector table's entry:
   a call (svc), a fault, an interrupt (the GIC's). */

#include "global.h"
#include "idt.h"
#include "pic.h"
#include "pit.h"
#include "video.h"
#include "process.h"
#include "sched.h"
#include "mem/mem.h"

static void (*handlers[256])(void);

void set_vector(void * handler, unsigned char n, unsigned short control)
{
  (void)control;
  handlers[n] = (void (*)(void))handler;
}

extern char exception_vectors[];
void __OS_initExternalIRQs(void);
void arch_init_calls(void);

void init_idt(void)
{
  __asm__ volatile ("msr vbar_el1, %0; isb" : : "r"(exception_vectors));
  __OS_initExternalIRQs();
  arch_init_calls();
  arch_irq_enable();
}

/* the vector table's entries (entry.S) */
#define V_EL1_SYNC  4
#define V_EL1_IRQ   5
#define V_EL0_SYNC  8
#define V_EL0_IRQ   9

/* the exception's class (ESR_EL1's bits 26-31) */
#define EC_SVC64      0x15
#define EC_IABT_LOW   0x20
#define EC_IABT_CUR   0x21
#define EC_DABT_LOW   0x24
#define EC_DABT_CUR   0x25

extern void _mynos_native_call(struct frame * f);
extern void arm_linux_syscall(struct frame * f);
extern char copy_user_insn[], copy_user_end[];

static void irq(void)
{
  uint32_t iar = gic_ack(), id = iar & 0x3FF;
  if (id >= 1020) return;                         /* spurious */
  /* the end first: a handler may switch threads (sched), and the GIC
     would keep this processor's lower interrupts back until it came
     back. The kernel runs with interrupts masked meanwhile */
  gic_eoi(iar);
  if (id == GIC_TIMER) {
    if (arch_cpu()->id == 0) pit_handler();
    else ap_timer_handler();
    return;
  }
  if (id < 16) {                                  /* an IPI (smp.c): a thread */
    sched();                                      /* may be ready, a process ended */
    return;
  }
  if (id >= GIC_SPI_BASE && id < GIC_SPI_BASE + 16 &&
      handlers[M_VEC + id - GIC_SPI_BASE])
    handlers[M_VEC + id - GIC_SPI_BASE]();
}

/* a fault on memory, as x86's error code: present (a permission fault),
   write, user */
static void page_fault(struct frame * f, int user)
{
  uint32_t ec = f->esr >> 26, dfsc = f->esr & 0x3F, err = 0;
  if ((dfsc & 0x3C) != 0x04) err |= 1;            /* not a translation fault */
  if ((ec == EC_DABT_LOW || ec == EC_DABT_CUR) && (f->esr & (1 << 6)) &&
      !(f->esr & (1 << 8)))
    err |= 2;                                     /* a write (not a cache op) */
  if (user) err |= 4;
  /* a jump to nothing (a null function pointer): where it came from */
  if (user && f->pc < 0x1000) {
    printk("process ");
    print_ulong(CURRPID);
    printk(": a jump to ");
    print_ulong_hex(f->pc);
    printk(" from ");
    print_ulong_hex(f->x[30]);
    print_char('\n');
  }
  /* copy_user's loop (entry.S): its faults resume as the i386's single
     instruction's (mem.c's copy_user_fixup) */
  if (!user && f->pc >= (uint64_t)copy_user_insn && f->pc < (uint64_t)copy_user_end)
    f->pc = (uint64_t)copy_user_insn;
  _page_fault_handler(f->far, err, (unsigned long *)f);
}

static void process_fault(struct frame * f, const char * what)
{
  printk("process ");
  print_ulong(CURRPID);
  printk(" killed: ");
  printk((char *)what);
  printk(" at ");
  print_ulong_hex(f->pc);
  printk(" (ESR ");
  print_ulong_hex(f->esr);
  printk(")\n");
  killProcess(SIGNAL_STATUS(4));
  sched();
}

static void arm_trap_body(struct frame * f);

/* a process ended by another processor while this one ran its thread
   (or waited for the big lock to enter for it): the thread goes no
   further, into the kernel or back (as x86-64's entry and trap_return) */
void arm_trap(struct frame * f)
{
  int user = f->vector == V_EL0_SYNC || f->vector == V_EL0_IRQ;
  if (user) smp_leave_if_dead();
  arm_trap_body(f);
  if (user) smp_leave_if_dead();
}

static void arm_trap_body(struct frame * f)
{
  uint32_t ec = f->esr >> 26;
  switch (f->vector) {
  case V_EL0_IRQ:
  case V_EL1_IRQ:
    irq();
    return;
  case V_EL0_SYNC:
    /* the thread's TLS as EL0 left it (musl sets TPIDR_EL0 itself): a
       call that copies the thread (threadAlloc) copies it right */
    __asm__ volatile ("mrs %0, tpidr_el0" : "=r"(currThread->fs_base));
    if (ec == EC_SVC64) {
      if ((f->esr & 0xFFFF) == 0x90) _mynos_native_call(f);
      else arm_linux_syscall(f);
      return;
    }
    if (ec == EC_DABT_LOW || ec == EC_IABT_LOW) {
      page_fault(f, 1);
      return;
    }
    process_fault(f, ec == 0 ? "undefined instruction" : "exception");
    return;
  case V_EL1_SYNC:
    if (ec == EC_DABT_CUR) {
      page_fault(f, 0);
      return;
    }
    break;
  }
  kernel_on_screen = 1;
  printk("\nkernel exception: vector ");
  print_ulong(f->vector);
  printk(", ESR ");
  print_ulong_hex(f->esr);
  printk(", at ");
  print_ulong_hex(f->pc);
  printk(", address ");
  print_ulong_hex(f->far);
  print_char('\n');
  KPANIC("exception");
}

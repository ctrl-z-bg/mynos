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

#include "mem/mem.h"
#include "global.h"
#include "pic.h"
#include "io.h"
#include "video.h"
#include "idt.h"
#include "gdt.h"
#include "sem.h"
#include "irq.h"
#include "services.h"
#include "process.h"
#include "sched.h"
#include "trace.h"
#include "mynos.h"

/*
 * Interrupts for drivers in user space. A driver registers for an IRQ
 * (mynos_driverRegister) and gets a semaphore; every interrupt of that
 * line is acknowledged here (EOI to the PICs) and V'd on the semaphore,
 * and the driver, waiting with P, then talks to its device. If the CPU was
 * idle, the driver runs at once instead of at the next timer tick.
 *
 * IRQ 0 is the timer (pit.c), IRQ 2 the cascade of the second PIC: they
 * cannot be taken. An interrupt nobody registered for is masked. When a
 * driver ends, its IRQs are masked and freed.
 *
 * Until 2026 only IRQs 1, 3 and 4 had handlers, and the driver sent the
 * EOI itself from user space (consoled, keyboardd and seriald still do:
 * once the kernel has acknowledged, that EOI finds nothing in service and
 * does nothing).
 */

#define NIRQ 16

static int irqSem[NIRQ];
static int irqOwner[NIRQ];             /* pid, or -1 */
static uint32_t irqCount[NIRQ];

static void irq_dispatch(int n) {
  if (n >= 8) outportb(S_PIC, EOI);
  outportb(M_PIC, EOI);
  irqCount[n]++;
  if (irqOwner[n] < 0) {               /* nobody wants it */
    disable_irq(n);
    return;
  }
  TRACE(TRACE_IRQ, irqOwner[n], currProcess, -1, 0, n, NULL, 0);
  __OS_sem_V(irqSem[n]);
  /* the idle thread was running: give the CPU to the driver now */
  if (currThread->pid == 0) sched();
}

#define IRQ(n) TRAP_WRAPPER(irq##n); \
  void irq##n##_handler() { irq_dispatch(n); }
IRQ(1) IRQ(3) IRQ(4) IRQ(5) IRQ(6) IRQ(7) IRQ(8) IRQ(9) IRQ(10)
IRQ(11) IRQ(12) IRQ(13) IRQ(14) IRQ(15)

void __OS_initExternalIRQs() {
  void (*handlers[NIRQ])() = {
    0, irq1_TRAP, 0, irq3_TRAP, irq4_TRAP, irq5_TRAP, irq6_TRAP, irq7_TRAP,
    irq8_TRAP, irq9_TRAP, irq10_TRAP, irq11_TRAP, irq12_TRAP, irq13_TRAP,
    irq14_TRAP, irq15_TRAP };
  int i;
  for (i = 0; i < NIRQ; i++) {
    irqOwner[i] = -1;
    if (handlers[i])
      set_vector(handlers[i], (i < 8 ? M_VEC : S_VEC - 8) + i, D_PRESENT + D_INT);
  }
}

/* can a process take this line? */
int __OS_irq_valid(uint32_t irq) {
  return irq < NIRQ && irq != 0 && irq != 2;
}

int __OS_driverRegister(char * name, uint32_t irq,
			uint32_t * io, uint32_t * mem) {
  int sem;
  if (!__OS_irq_valid(irq)) return MYNOS_ERR_INVALID;
  if (irqOwner[irq] >= 0 && irqOwner[irq] != (int)currProcess &&
      processTable[irqOwner[irq]] && processTable[irqOwner[irq]]->isAlive)
    return MYNOS_ERR_BUSY;
  if (__OS_service_registerService(name) == -1) return -1;
  if ((sem = __OS_sem_allocateSemaphore(0)) < 0) return sem;
  if (irqOwner[irq] >= 0) __OS_sem_freeSemaphore(irqSem[irq]);
  irqSem[irq] = sem;
  irqOwner[irq] = currProcess;
  return sem;
}

/* a process ended: its interrupts are nobody's */
void __OS_irq_processEnded(int pid) {
  int i;
  for (i = 0; i < NIRQ; i++)
    if (irqOwner[i] == pid) {
      disable_irq(i);
      __OS_sem_freeSemaphore(irqSem[i]);
      irqOwner[i] = -1;
    }
}

uint32_t __OS_irq_count(int n) {
  return (n >= 0 && n < NIRQ) ? irqCount[n] : 0;
}

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
#include "random.h"
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
/* a PCI line may be shared: up to NSHARE drivers on one level-triggered
   line (virtio's devices, mynos-btq.2); an ISA line has one */
#define NSHARE 4

static int irqSem[NIRQ][NSHARE];
static int irqOwner[NIRQ][NSHARE];     /* pid, or -1 */
static int irqLevel[NIRQ];             /* registered as a PCI line */
static uint32_t irqCount[NIRQ];

static int irq_owned(int n) {
  int k;
  for (k = 0; k < NSHARE; k++) if (irqOwner[n][k] >= 0) return 1;
  return 0;
}

static void irq_dispatch(int n) {
  int k, any = 0;
  /* a level-triggered line stays asserted until the driver has talked to
     its device: masked here, unmasked by the driver (enableIrq) when it
     has. Else the PIC raises it again at once, for ever. */
  if (irqLevel[n]) disable_irq(n);
  if (n >= 8) outportb(S_PIC, EOI);
  outportb(M_PIC, EOI);
  irqCount[n]++;
  random_event(n);
  for (k = 0; k < NSHARE; k++)
    if (irqOwner[n][k] >= 0) {
      TRACE(TRACE_IRQ, irqOwner[n][k], CURRPID, -1, 0, n, NULL, 0);
      __OS_sem_V(irqSem[n][k]);
      any = 1;
    }
  if (!any) {                          /* nobody wants it */
    disable_irq(n);
    return;
  }
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
  int i, k;
  for (i = 0; i < NIRQ; i++) {
    for (k = 0; k < NSHARE; k++) irqOwner[i][k] = -1;
    irqLevel[i] = 0;
    if (handlers[i])
      set_vector(handlers[i], (i < 8 ? M_VEC : S_VEC - 8) + i, D_PRESENT + D_INT);
  }
}

/* can a process take this line? */
int __OS_irq_valid(uint32_t irq) {
  return irq < NIRQ && irq != 0 && irq != 2;
}

/* does this process hold this line? */
int __OS_irq_owns(uint32_t irq, int pid) {
  int k;
  if (irq >= NIRQ) return 0;
  for (k = 0; k < NSHARE; k++) if (irqOwner[irq][k] == pid) return 1;
  return 0;
}

/* driverRegister (10): a line for the calling driver, which needs the io
   privilege; the semaphore the kernel V's at each interrupt is returned,
   and belongs to the driver. With MYNOS_IRQ_PCI the line is a PCI one,
   level-triggered: shared by up to NSHARE such drivers, and masked at
   each interrupt until a driver unmasks it (enableIrq), having talked to
   its device. Without it (ISA), a line has one driver. */
int __OS_driverRegister(char * name, uint32_t irq,
			uint32_t * io, uint32_t * mem) {
  int sem, k, free = -1, live = 0;
  int pci = (irq & MYNOS_IRQ_PCI) != 0;
  irq &= ~MYNOS_IRQ_PCI;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (!__OS_irq_valid(irq)) return MYNOS_ERR_INVALID;
  /* (until 2026 the name also went into the kernel's service table of
     2002, never freed: a driver restarted a thousand times could not
     register. The name is only for people: the registry has the names) */
  (void)name;
  for (k = 0; k < NSHARE; k++) {
    int o = irqOwner[irq][k];
    if (o == CURRPID) { free = k; break; }      /* again: a new semaphore */
    if (o >= 0 && proc(o) && proc(o)->isAlive) live++;
    else if (free < 0) free = k;
  }
  if (free < 0 || (live > 0 && irqOwner[irq][free] != CURRPID &&
		    !(pci && irqLevel[irq])))
    return MYNOS_ERR_BUSY;
  if (live == 0) irqLevel[irq] = pci;
  if ((sem = __OS_sem_allocateSemaphore(0)) < 0) return sem;
  if (irqOwner[irq][free] >= 0) __OS_sem_freeSemaphore(irqSem[irq][free]);
  __OS_sem_setOwner(sem, CURRPID);
  irqSem[irq][free] = sem;
  irqOwner[irq][free] = CURRPID;
  return sem;
}

/* a process ended: its interrupts are nobody's; a line nobody holds any
   more is masked */
void __OS_irq_processEnded(int pid) {
  int i, k;
  for (i = 0; i < NIRQ; i++)
    for (k = 0; k < NSHARE; k++)
      if (irqOwner[i][k] == pid) {
	__OS_sem_freeSemaphore(irqSem[i][k]);
	irqOwner[i][k] = -1;
	if (!irq_owned(i)) disable_irq(i);
      }
}

uint32_t __OS_irq_count(int n) {
  return (n >= 0 && n < NIRQ) ? irqCount[n] : 0;
}

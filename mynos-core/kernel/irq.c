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

#include "global.h"
#include "pic.h"
#include "io.h"
#include "video.h"
#include "idt.h"
#include "gdt.h"
#include "sem.h"
#include "irq.h"
#include "services.h"

#define NUMSEM 20

/* drivers processes semaphores */
static int irqSemTable[NUMSEM];

/* trap wrappers */
TRAP_WRAPPER(irq1);
TRAP_WRAPPER(irq3);
TRAP_WRAPPER(irq4);

/* the handlers */
void irq1_handler() {
  __OS_sem_V(irqSemTable[1]);
}

void irq3_handler() {
  __OS_sem_V(irqSemTable[3]);
}

void irq4_handler() {
  __OS_sem_V(irqSemTable[4]);
}

/* the init function */
void __OS_initExternalIRQs() {
  set_vector(irq1_TRAP, M_VEC+1, D_PRESENT + D_INT); /* IRQ1 Handler */
  set_vector(irq3_TRAP, M_VEC+3, D_PRESENT + D_INT); /* IRQ4 Handler */
  set_vector(irq4_TRAP, M_VEC+4, D_PRESENT + D_INT); /* IRQ4 Handler */
}

int __OS_driverRegister(char * name, uint32_t irq, 
			uint32_t * io, uint32_t * mem) {
  if (__OS_service_registerService(name) == -1) return -1;
  return (irqSemTable[irq] = __OS_sem_allocateSemaphore(0));
}



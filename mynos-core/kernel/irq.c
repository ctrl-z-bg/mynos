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

/* trap wrappers */
TRAP_WRAPPER(irq1);
TRAP_WRAPPER(irq4);

/* drivers processes semaphores */
static int irq1_sem = 3;
static int irq4_sem = 4;

/* the handlers */
void irq1_handler() {
    __OS_sem_V(irq1_sem);
}

void irq4_handler() {
  __OS_sem_V(irq4_sem);
}

/* the init function */
void __OS_initExternalIRQs() {
  set_vector(irq1_TRAP, M_VEC+1, D_PRESENT + D_INT); /* IRQ1 Handler */
  set_vector(irq4_TRAP, M_VEC+4, D_PRESENT + D_INT); /* IRQ4 Handler */
}


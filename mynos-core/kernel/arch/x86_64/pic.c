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

#include "io.h"
#include "pic.h"

ushort16_t irq_mask = 0xFFFF;        /* All IRQs disabled initially */

void init_pics() {
  /* send the ICW1 to the pics */
  outportb(M_PIC, ICW1);
  outportb(S_PIC, ICW1);

  /* send the ICW2 to the pics */
  outportb(M_PIC+1, M_ICW2);
  outportb(S_PIC+1, S_ICW2);

  /* send the ICW3 to the pics */
  outportb(M_PIC+1, M_ICW3);
  outportb(S_PIC+1, S_ICW3);

  /* send the ICW4 to the pics */
  outportb(M_PIC+1, ICW4);
  outportb(S_PIC+1, ICW4);

  /* disable all irqs */
  outportb(M_IMR, 0xff);
  outportb(S_IMR, 0xff);
}

/* enables irq irq_no */
void enable_irq(ushort16_t irq_no) {
  irq_mask &= ~(1 << irq_no);
  if(irq_no >= 8)
    irq_mask &= ~(1 << 2);
  
  outportb(M_IMR, irq_mask & 0xFF);
  outportb(S_IMR, (irq_mask >> 8) & 0xFF);
}

/* disables irq irq_no */
void disable_irq(ushort16_t irq_no) {
  irq_mask |= (1 << irq_no);
  if((irq_mask & 0xFF00)==0xFF00)
    irq_mask |= (1 << 2);
  
  outportb(M_IMR, irq_mask & 0xFF);
  outportb(S_IMR, (irq_mask >> 8) & 0xFF);
}

void enable_all_irqs() {
  irq_mask = 0;
  outportb(M_IMR, 0);
  outportb(S_IMR, 0);
}
void disable_all_irqs() {
  irq_mask = 0xFFFF;
  outportb(M_IMR, 0xFF);
  outportb(S_IMR, 0xFF);
}

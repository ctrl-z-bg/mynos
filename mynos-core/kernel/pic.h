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

/* this file has functions to control the 8259 Programmable Interrupt
   Controllers */

#ifndef __PIC_H__
#define __PIC_H__

#include "global.h"

/* define the two PIC ports */
#define M_PIC      0x20             /* master pic port */
#define M_IMR      0x21             /* master Interrupt Mask Register*/
#define S_PIC      0xA0             /* slave pic port */
#define S_IMR      0xA1             /* master Interrupt Mask Register*/

#define EOI        0x20             /* End Of Interrupt */

#define M_VEC      0x20             /* Vector for master pic: irqs mapped
				       from int 32 to int 39 */
#define S_VEC      0x28             /* Vector for slave pic: irqs mapped 
				       from int 40 to int 47 */

/* Initalization Command Words */
#define ICW1       0x11             /* we'll send ICW4 too in cascaded mode */
#define M_ICW2     M_VEC            /* master pic ICW2 is the master vector */
#define S_ICW2     S_VEC            /* slave pic ICW2 is the slave vector */
#define M_ICW3     0x04             /* the IR2 is connected to a slave pic */
#define S_ICW3     0x02             /* the same information for the slave */
#define ICW4       0x01             /* 8086 mode */

/* Operation Control Word 3 (OCW3) */
#define OCW3_IRR   0x0A             /* read the Interrupt Request Register */
#define OCW3_ISR   0x0B             /* read the In Service Register */

void init_pics();
void enable_irq(ushort16_t irq_num);
void disable_irq(ushort16_t irq_num);

void enable_all_irqs();
void disable_all_irqs();

#endif

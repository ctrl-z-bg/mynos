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

/* this file has functions to control the Intel 8253 Programmable Interval 
   Timer */

#ifndef __PIT_H__
#define __PIT_H__

#include "global.h"

/* PIT input frequency */
#define PIT_INPUT_Hz     1193181

/* PIT right frequency */
//#define PIT_FREQ 18.21
#define PIT_FREQ 100

/* PIT ports */
#define PIT_CHANNEL_0    0x40
#define PIT_CHANNEL_1    0x41
#define PIT_CHANNEL_2    0x42
#define PIT_CONTROL_WORD 0x43

/* PIT Control Word fields */
/* bit 0 (BCD) */
#define PIT_CW_BCD       0x1         /* BCD 4 decades */
#define PIT_CW_BIN16     0x0         /* Binary 16 bit */
/* bit 1,2,3 (MODE) */
#define PIT_CW_MODE0     0x0         /* Interrupt on Terminal Count */
#define PIT_CW_MODE1     0x2         /* Programmable One-Shot       */
#define PIT_CW_MODE2     0x4         /* Rate Generator              */
#define PIT_CW_MODE3     0x6         /* Square Wave Rate Generator  */
#define PIT_CW_MODE4     0x8         /* Software Triggered Strobe   */
#define PIT_CW_MODE5     0xA         /* Hardware Triggered Strobe   */
/* bit 4,5 (READ/LOAD OPTIONS) */
#define PIT_CW_RW_LATCH  0x0         /* Counter Latching            */
#define PIT_CW_RW_LSB    0x10        /* Read/Load LSB only          */
#define PIT_CW_RW_MSB    0x20        /* Read/Load MSB only          */
#define PIT_CW_RW_BOTH   0x30        /* Read/Load LSB then MSB      */
/* bit 6,7 (SELECT COUNTER) */
#define PIT_SEL_CH0      0x0         /* Select Counter 0            */
#define PIT_SEL_CH1      0x40        /* Select Counter 1            */
#define PIT_SEL_CH2      0x80        /* Select Counter 2            */

void init_pit(int freq, unsigned char channel);
void pit_ISR();
void pit_handler();

#endif

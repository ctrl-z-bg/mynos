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

#include "pit.h"
#include "idt.h"
#include "io.h"
#include "video.h"
#include "kutils.h"
#include "sched.h"

void init_pit(int freq, unsigned char channel) {
  unsigned int temp;

  temp = PIT_INPUT_Hz/freq;
  outportb(PIT_CONTROL_WORD, (channel*0x40) + PIT_CW_RW_BOTH + PIT_CW_MODE3);
  outportb((0x40+channel), (unsigned char)temp);
  outportb((0x40+channel), (unsigned char)(temp>>8));
  //outportb(0x40, 0x9c);     /* 1193182 / 100  (low word). */
  //outportb(0x40, 0x2e);     /* 1193182 / 100  (high word). */
}

/* we can't use ISR_WRAPPER(pit) because it send EOI to pic, but we have to
   do it inside pit_handler, so we write a special (minimal) pit_ISR */
void pit_ISR();
__asm__ (\
	 ".globl pit_ISR         \n"\
	 "pit_ISR:               \n"\
	 "   pushal              \n"\
	 "   call pit_handler    \n"     /* call the ISR handler */\
	 "   popal               \n"\
	 "   iret                \n"\
	 );


uint32_t timerTicks = 0;
void pit_handler() {
  timerTicks++;

  outportb(0x20, 0x20);
  
  sched();
}

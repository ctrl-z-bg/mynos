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

void init_pit(float freq, unsigned char channel) {
  unsigned int temp;

  temp = PIT_INPUT_Hz/freq;
  outportb(PIT_CONTROL_WORD, (channel*0x40) + PIT_CW_RW_BOTH + PIT_CW_MODE3);
  outportb((0x40+channel), temp);
  outportb((0x40+channel), (temp>>8));
}

ISR_WRAPPER(pit);

void pit_handler() {
  asm("int $0x1C"); /* Extra timer interrupt, 
		       used by floppy for timeout etc.. */
}


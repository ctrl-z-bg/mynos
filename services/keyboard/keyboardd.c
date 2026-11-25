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

#include <mynos.h>
#include <stdlib.h>

#include <stdio.h>
#include <unistd.h>

#include "keymap.h"

void keyb_handler(void);

int main()
{
  int sem;

  /* no PC keyboard controller (AArch64: its ports read 0xFF): nothing to
     drive, and its line is another device's there */
  if (inportb(0x64) == 0xFF) {
    mynos_log("keyboardd: no PC keyboard controller\n");
    return 0;
  }
  sem = mynos_driverRegister("keyboard", 1, NULL, NULL);
  mynos_log("keyboardd: sem = %d\n", sem);

  mynos_enableIrq(1);

  led_status = 0; /* All leds off */
  setleds();

  while(1) {
    mynos_P(sem);
    keyb_handler();
  }
}

void keyb_handler(void)
{
	unsigned int key = inportb(0x60);
	unsigned int key_ascii = keymap_translate(key);

	outportb(0x20, 0x20);

	if(key_ascii != 0)
	{
		if(key_ascii <= 0xFF)
		{
		  char c = (char)key_ascii;

		  keyboard_buffer[keyboard_buffer_size] = key_ascii;
		  keyboard_buffer_size++;
		  write(1, &c, 1);
		  outportb(0x3F8, c);
		}
		else
		{
			keyboard_buffer[keyboard_buffer_size] = (key_ascii & 0xFF);
			keyboard_buffer[keyboard_buffer_size+1] = (key_ascii & 0xFF00);
			keyboard_buffer_size += 2;
		}
	}

}

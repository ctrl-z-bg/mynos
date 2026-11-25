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

#define PORT1 0x3F8

static int bufferin = 0;

static char buffer[1025];

void serial_handler(void);
void initSerial();

int main()
{
  int sem;

  /* no UART at COM1 (AArch64: its ports read 0xFF, "a byte waiting" for
     ever): nothing to drive, and line 4 is another device's there */
  if (inportb(PORT1 + 5) == 0xFF) {
    mynos_log("seriald: no serial port at COM1\n");
    return 0;
  }
  sem = mynos_driverRegister("serial", 4, NULL, NULL);
  initSerial();
  mynos_log("seriald: sem = %d\n", sem);

  mynos_enableIrq(4);

  while(1) {
    mynos_P(sem);
    serial_handler();
  }
  return 0;
}

void initSerial() {
  outportb(PORT1 + 1, 0);     /* turn off interrupts - port 1 */
  outportb(PORT1 + 3, 0x80);    /* set DLAB on */

  //outportb(PORT1 + 0, 0x03);    /* set baud rate to 38400 bps (low byte) */
  //outportb(PORT1 + 0, 0x30);    /* set baud rate to 2400 bps (low byte) */
  outportb(PORT1 + 0, 0x60);    /* set baud rate to 1200 bps (low byte) */

  outportb(PORT1 + 1, 0x00);    /* set baud rate (high byte) */

  outportb(PORT1 + 3, 0x03);    /* 8 bits, no parity, 1 stop bit */
  //outportb(PORT1 + 3, 0x02);    /* 7 bits, no parity, 1 stop bit */

  outportb(PORT1 + 2, 0xC7);    /* FIFO control register */
  outportb(PORT1 + 4, 0x0B);    /* turn on DTR, RTS and OUT2 */
  outportb(PORT1 + 1, 0x01);    /* interrupt when data received */
}

void serial_handler(void) {
  char c;
  char asd;

  do {
    c = inportb(PORT1 + 5);
    if (c & 1) {
      asd = buffer[bufferin] = inportb(PORT1);
      bufferin++;
      if (bufferin == 1024) bufferin = 0;
      write(1, &asd, 1);
    }
  } while (c & 1);
  outportb(0x20, 0x20);
}

// to read serial mouse data
void _serial_handler(void) {
  char c;
  char asd;
  int n = 1;
  int i = 1;
  //char x, y;
  static char left = 1;  // pressed is zero
  static char right = 1;

  do {
    c = inportb(PORT1 + 5);
    if (c & 1) {
      asd = buffer[bufferin] = inportb(PORT1);
      bufferin++;
      if (bufferin == 1024) bufferin = 0;
      //putchar(asd);

      // wait for the first byte
      printf("%d\n", i++);
      if (asd & 0x40) {
	n = 1;
	left  = (asd & 0x20)?'1':'0';
	right = (asd & 0x10)?'1':'0';
	printf("%c %c\n", left, right);
      }
      
      switch (n) {
      case 1:
	left  = (asd & 0x20)?'1':'0';
	right = (asd & 0x10)?'1':'0';
	//printf("%c %c\n", left, right);
	n = 2;
	break;
      case 2:
	n = 3;
	break;
      case 3:
	n = 1;
	break;
      default: break;
      }


    }
  } while (c & 1);

  puts("\n\n");
  outportb(0x20, 0x20);
}

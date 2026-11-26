/*
  MyNOS
  Copyright (C) 2002
  Cesare Zavattari (zavattari@tin.it)

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

#ifndef __IO_H__
#define __IO_H__

/* Input a byte from a port */
unsigned char inportb(unsigned short port);

/* Output a byte to a port */
void outportb(unsigned short port, unsigned char value);

/* Output a word to a port */
void outportw(unsigned short port, unsigned short value);
unsigned short inportw(unsigned short port);

#endif

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

#ifndef __VIDEO_H__
#define __VIDEO_H__

#include "global.h"

#define BASE_VIDEO 0xB8000
#define END_VIDEO  0xB8F9E
#define COLUMNS 80
#define ROWS    25

void printk(char *s);
void print_ulong(ulong32_t n);
#define print_uint(N) print_ulong((uint32_t)N)

void print_ulong_hex(ulong32_t n);
#define print_uint_hex(N) print_ulong_hex((uint32_t)N)

void print_char(char c);

void clear_screen();
void scroll_screen();

#endif

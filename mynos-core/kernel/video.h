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

/* kernel messages will be printed in green */
#define CHAR_KERNEL_ATTRIB 0xA
/* user messages will be printed in gray */
#define CHAR_USER_ATTRIB 0x7

void printk(char *s);
void video_font_init(void);     /* the glyphs VGA's font lacks (video.c) */
void print_ulong(ulong32_t n);
#define print_uint(N) print_ulong((ulong32_t)N)
#define print_ushort(N) print_ulong((ulong32_t)N)

void print_long(long32_t n);
#define print_int(N) print_long((long32_t)N)
#define print_short(N) print_long((long32_t)N)

void print_ulong_hex(ulong32_t n);
#define print_uint_hex(N) print_ulong_hex((ulong32_t)N)
#define print_uint_hex(N) print_ulong_hex((ulong32_t)N)

void _print_char(char c, char attrib);
#define print_char(C) _print_char(C, CHAR_KERNEL_ATTRIB)

void clear_screen();
void scroll_screen();

#endif

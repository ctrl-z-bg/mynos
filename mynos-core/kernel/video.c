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

#include "video.h"
#include "io.h"

/* void update_cursor(int row, int col)
 * by Dark Fiber
 * taken from alt.os.development FAQ
 */
static void update_cursor(uint32_t row, uint32_t col)
{
  ushort16_t position=(row*80) + col;
  
  // cursor LOW port to vga INDEX register
  outportb(0x3D4, 0x0F);
  outportb(0x3D5, (ubyte_t)(position&0xFF));
  // cursor HIGH port to vga INDEX register
  outportb(0x3D4, 0x0E);
  outportb(0x3D5, (ubyte_t)((position>>8)&0xFF));
}

/* to print a digit */
#define ZERO 48

/* to convert a number to a string */
#define MAX_INT_LEN 11

char *video = (char *)BASE_VIDEO;


void printk(char * s) {
  while (*s) {
    print_char(*(s++));
  }
}

void print_long(long32_t n) {
  if (n < 0) {
    print_char('-');
    n = -n;
  }
  print_ulong((ulong32_t)n);
}

void print_ulong(ulong32_t n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  tmp = n;
  do {
    q = tmp / 10;
    r = tmp % 10;
    *curr_char = r + ZERO;
    curr_char--;
    tmp = q;
  } while (q);

  printk(curr_char + 1);
}
 
void print_ulong_hex(ulong32_t n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  printk("0x");
  tmp = n;
  do {
    q = tmp / 16;
    r = tmp % 16;
    if (r < 10)
      *curr_char = r + ZERO;
    else
      *curr_char = (r - 10) + 65;

    curr_char--;
    tmp = q;
  } while (q);

  printk(curr_char + 1);
}
 
void _print_char(char c, char attrib) {
  uint32_t cursor;
  if (video >= (char*)END_VIDEO) {
    scroll_screen();
    video -= 0xA0;
  }
  if (c == '\n') {
    uint32_t tmp = (uint32_t)video;
    tmp -= BASE_VIDEO;
    tmp = tmp / 0xA0;
    tmp = tmp * 0xA0;
    tmp += BASE_VIDEO + 0xA0;
    video = (char *)tmp;
  if (video >= (char*)END_VIDEO) {
    scroll_screen();
    video -= 0xA0;
  }
  } else {
    *video = c;
    *(video + 1) = attrib;
    video = video + 2;
  }
  /* move the cursor */
  cursor = ((uint32_t)(video - BASE_VIDEO) / 2);
  update_cursor(cursor / 80, cursor % 80);
}

void clear_screen() {
  char * i;
  for (i = (char*)BASE_VIDEO; i <= (char*)END_VIDEO; i++) {
    *(i++) = ' ';
    *i = 0x7;
  }
  video = (char*)BASE_VIDEO;
  outportb(0x3d4, 0x0f);		/* Set the cursor to the	*/
  outportb(0x3d5, 0);			/* upper-left corner of the	*/
  outportw(0x3d4, 0x0e);		/* screen			*/
  outportb(0x3d5, 0);
}

void scroll_screen() {
  uint32_t i;
  char * dest = (char*)BASE_VIDEO;
  char * source = (char*)BASE_VIDEO + 0xA0;
  uint32_t nchars = COLUMNS*ROWS;

  for (i = 0; i < nchars; i++) {
    *dest = *source;
    *(dest+1) = *(source+1);
    dest += 2;
    source += 2;
  }

  /* now dest points to the last row */
  for (i = 0; i < COLUMNS; i++) {
    *dest = ' ';
    dest += 2;
  }
}


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

#include "kutils.h"
#include "video.h"

/* copies and fills four bytes at a time (rep movsl, rep stosl), then the
   rest: a page fault zeroes or copies a whole page (mynos-4d6: a byte at
   a time, they were two thirds of its cost). Forward only, as before:
   not for overlapping areas. */
void* kmemcpy(void* dst, const void* src, size_t count) {
  int d0, d1, d2;
  __asm__ volatile ("rep movsl\n\t"
                    "movl %4, %%ecx\n\t"
                    "rep movsb"
                    : "=&c"(d0), "=&D"(d1), "=&S"(d2)
                    : "0"(count / 4), "g"(count & 3), "1"(dst), "2"(src)
                    : "memory");
  return dst;
}

void* kmemset(void * dst, int s, size_t count) {
  int d0, d1;
  uint32_t v = (s & 0xFF) * 0x01010101u;
  __asm__ volatile ("rep stosl\n\t"
                    "movl %3, %%ecx\n\t"
                    "rep stosb"
                    : "=&c"(d0), "=&D"(d1)
                    : "0"(count / 4), "g"(count & 3), "1"(dst), "a"(v)
                    : "memory");
  return dst;
}

void kbzero(void *s, size_t n) {
  kmemset(s,0,n);
}

int katoi(const char* s) {
  long int v=0;
  int sign=1;
  while ( *s == ' '  ||  (unsigned int)(*s - 9) < 5u) s++;
  switch (*s) {
  case '-': sign=-1;
  case '+': ++s;
  }
  while ((unsigned int) (*s - '0') < 10u) {
    v=v*10+*s-'0'; ++s;
  }
  return sign==-1?-v:v;
}

int kmemcmp(const void *dst, const void *src, size_t count) {
  register int r;
  register const char *d=dst;
  register const char *s=src;
  while (count--) {
    if ((r=(*d - *s)))
      return r;
    ++d;
    ++s;
  }
  return 0;
}

int kstrlen(const char * s) {
  char * p = (char*)s;
  while (*p)
    p++;
  return (p - s);
}

void ktableFull(const char * table, int * said) {
  if (*said) return;
  *said = 1;
  printk("kernel: the ");
  printk((char *)table);
  printk(" table is full\n");
}

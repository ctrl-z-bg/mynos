/*
  MyNOS
  Copyright (C) 2002, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* the kernel's memcpy and memset, as fast as the i386 makes them */

#include "global.h"
#include "kutils.h"

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


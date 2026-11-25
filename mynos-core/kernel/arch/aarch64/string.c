/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* the kernel's memcpy and memset on AArch64: words when they can, bytes
   for the rest (gcc's builtins would call memcpy, which the kernel does
   not have) */

#include "global.h"
#include "kutils.h"

void* kmemcpy(void* dst, const void* src, size_t count) {
  unsigned char * d = dst;
  const unsigned char * s = src;
  if ((((vaddr_t)d | (vaddr_t)s) & 7) == 0) {
    for (; count >= 8; count -= 8, d += 8, s += 8)
      *(volatile uint64_t *)d = *(const uint64_t *)s;
  }
  while (count--) *d++ = *s++;
  return dst;
}

void* kmemset(void * dst, int c, size_t count) {
  unsigned char * d = dst;
  if (((vaddr_t)d & 7) == 0) {
    uint64_t v = (unsigned char)c;
    v |= v << 8; v |= v << 16; v |= v << 32;
    for (; count >= 8; count -= 8, d += 8) *(volatile uint64_t *)d = v;
  }
  while (count--) *(volatile unsigned char *)d++ = (unsigned char)c;
  return dst;
}

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* the kernel's memcpy and memset on x86-64: rep movsb and rep stosb,
   which recent processors run as fast as anything */

#include "global.h"
#include "kutils.h"

void* kmemcpy(void* dst, const void* src, size_t count) {
  void * d = dst;
  __asm__ volatile ("rep movsb" : "+D"(d), "+S"(src), "+c"(count) : : "memory");
  return dst;
}

void* kmemset(void * dst, int s, size_t count) {
  void * d = dst;
  __asm__ volatile ("rep stosb" : "+D"(d), "+c"(count) : "a"(s) : "memory");
  return dst;
}

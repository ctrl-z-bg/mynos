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

void* kmemcpy(void* dst, const void* src, size_t count) {
  register char *d=dst;
  register const char *s=src;
  ++count;
  while (--count) {
    *d = *s;
    ++d; ++s;
  }
  return dst;
}

void* kmemset(void * dst, int s, size_t count) {
    register char * a = dst;
    count++;
    while (--count)
	*a++ = s;
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

#include "video.h"
#include "keyboard.h"
void kreadStr(char * s, uint32_t bufsize) {
  int i = 0;

  for (i = 0; i < (bufsize-1); i++) {
    s[i] = getch();
    print_char(s[i]);
    if (s[i] == '\n') {
      s[i] = '\0';
      return;
    }
  }

  s[bufsize-1] = '\0';
  print_char('\n');
}
    

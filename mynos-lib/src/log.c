/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* mynos_log: messages of services go to the kernel log (native call 31),
   which leaves the screen to the shell once the system has started. */

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <mynos.h>
#include "syscall.h"

void mynos_log(const char * fmt, ...)
{
  char buf[256];
  va_list ap;
  int n;

  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if (n > (int)sizeof(buf) - 2) n = sizeof(buf) - 2;
  if (n == 0 || buf[n - 1] != '\n') buf[n++] = '\n';
  __mynos_syscall(31, (int)buf, n, 0, 0, 0);
}

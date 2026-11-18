/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The event recorder's system call (native 32): see mynos.h. */

#include <mynos.h>
#include "syscall.h"

int mynos_trace(int op, void * arg1, unsigned int arg2) {
  return __mynos_syscall(32, op, (int)arg1, (int)arg2, 0, 0);
}

/* processes (native 33) */
int mynos_processes(mynos_process_t * buf, int max) {
  return __mynos_syscall(33, (int)buf, max, 0, 0, 0);
}


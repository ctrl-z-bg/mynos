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

/* kill (native 34) */
int mynos_kill(int pid) {
  return __mynos_syscall(34, pid, 0, 0, 0, 0);
}

/* the kernel's log (native 35) */
int mynos_klog(unsigned int from, char * buf, unsigned int max) {
  return __mynos_syscall(35, (int)from, (int)buf, (int)max, 0, 0);
}

/* the page faults resolved (native 36) */
int mynos_faults(int pid, unsigned int out[2]) {
  return __mynos_syscall(36, pid, (int)out, 0, 0, 0);
}

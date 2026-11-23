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

/* the external pager (native 37) */
int mynos_pagerRegister(void) {
  return __mynos_syscall(37, MYNOS_PAGER_REGISTER, 0, 0, 0, 0);
}

void * mynos_pagerRegion(int pid, unsigned int npages, unsigned int token, int writable) {
  int page = __mynos_syscall(37, MYNOS_PAGER_REGION, pid, (int)npages, (int)token, writable);
  return page <= 0 ? (void *)0 : (void *)((unsigned int)page << 12);
}

int mynos_pagerNext(mynos_pager_fault_t * f) {
  return __mynos_syscall(37, MYNOS_PAGER_NEXT, (int)f, 0, 0, 0);
}

int mynos_pagerSupply(int pid, void * addr, void * src) {
  return __mynos_syscall(37, MYNOS_PAGER_SUPPLY, pid, (int)addr, (int)src, 0);
}


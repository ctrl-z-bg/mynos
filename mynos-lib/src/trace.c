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
  return __mynos_syscall(32, op, (long)arg1, (long)arg2, 0, 0);
}

/* processes (native 33) */
int mynos_processes(mynos_process_t * buf, int max) {
  return __mynos_syscall(33, (long)buf, max, 0, 0, 0);
}

/* kill (native 34) */
int mynos_kill(int pid) {
  return __mynos_syscall(34, pid, 0, 0, 0, 0);
}

/* the kernel's log (native 35) */
int mynos_klog(unsigned int from, char * buf, unsigned int max) {
  return __mynos_syscall(35, (long)from, (long)buf, (long)max, 0, 0);
}

/* the page faults resolved (native 36) */
int mynos_faults(int pid, unsigned int out[2]) {
  return __mynos_syscall(36, pid, (long)out, 0, 0, 0);
}

/* the external pager (native 37) */
int mynos_pagerRegister(void) {
  return __mynos_syscall(37, MYNOS_PAGER_REGISTER, 0, 0, 0, 0);
}

void * mynos_pagerRegion(int pid, unsigned int npages, unsigned int token, int writable) {
  int page = __mynos_syscall(37, MYNOS_PAGER_REGION, pid, (long)npages, (long)token, writable);
  return page <= 0 ? (void *)0 : (void *)((unsigned long)page << 12);
}

int mynos_pagerNext(mynos_pager_fault_t * f) {
  return __mynos_syscall(37, MYNOS_PAGER_NEXT, (long)f, 0, 0, 0);
}

int mynos_pagerSupply(int pid, void * addr, void * src) {
  return __mynos_syscall(37, MYNOS_PAGER_SUPPLY, pid, (long)addr, (long)src, 0);
}

/* a process's statistics (native 38) */
int mynos_procstat(int pid, unsigned int out[6]) {
  return __mynos_syscall(38, pid, (long)out, 0, 0, 0);
}

int mynos_pagerQuery(int pid, void * addr) {
  return __mynos_syscall(37, MYNOS_PAGER_QUERY, pid, (long)addr, 0, 0);
}

int mynos_pagerEvict(int pid, void * addr, void * dst, unsigned int token, int writable) {
  return __mynos_syscall(37, MYNOS_PAGER_EVICT, pid, (long)addr, (long)dst,
                         (int)((token << 1) | (writable ? 1 : 0)));
}

int mynos_pagerCopy(int pid, void * addr, void * dst) {
  return __mynos_syscall(37, MYNOS_PAGER_COPY, pid, (long)addr, (long)dst, 0);
}


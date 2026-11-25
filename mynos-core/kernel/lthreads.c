/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * Linux threads (mynos-l9h): what a C library's pthreads need, and through
 * them OCaml 5's domains.
 *   - clone (120), with CLONE_VM | CLONE_THREAD: a new MyNOS thread in the
 *     calling process, which returns from the system call with eax = 0 on
 *     the stack it was given, all other registers as the caller's (musl's
 *     __clone keeps the function to call in ebp), and its own TLS;
 *   - exit (1) ends the calling thread; exit_group (252) the process;
 *   - futex (240, and 422 with a 64-bit timeout): wait, wake, requeue;
 *   - gettid (224), set_tid_address (258), sched_yield (158).
 * The threads share one CPU: they run in turn, not in parallel.
 */

#include "global.h"
#include "video.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "threads.h"
#include "sched.h"
#include "sem.h"
#include "kutils.h"
#include "linux_syscalls.h"
#include "time.h"

#define CLONE_VM             0x00000100
#define CLONE_THREAD         0x00010000
#define CLONE_SETTLS         0x00080000
#define CLONE_PARENT_SETTID  0x00100000
#define CLONE_CHILD_CLEARTID 0x00200000
#define CLONE_CHILD_SETTID   0x01000000

#define ENOSYS    38
#define EAGAIN    11
#define EINVAL    22
#define EFAULT    14
#define ETIMEDOUT 110
#define ENOMEM    12

/* ---- futex ---- */

#define FUTEX_WAIT         0
#define FUTEX_WAKE         1
#define FUTEX_REQUEUE      3
#define FUTEX_CMP_REQUEUE  4
#define FUTEX_WAIT_BITSET  9
#define FUTEX_WAKE_BITSET  10
#define FUTEX_CMD_MASK     0x7F   /* without PRIVATE (128), CLOCK_REALTIME */
#define FUTEX_CLOCK_REALTIME 256

/* threads waiting on a futex word: (process, address) */
#define MAXFUTEXWAITERS 256
static struct {
  tss_t * thread;          /* NULL: free entry */
  pid_t pid;
  int32_t * addr;
  int timed;               /* waiting with a timeout */
} waiters[MAXFUTEXWAITERS];

static int futexWake(int32_t * addr, int n) {
  int i, woken = 0;
  for (i = 0; i < MAXFUTEXWAITERS && woken < n; i++)
    if (waiters[i].thread && waiters[i].pid == CURRPID &&
	waiters[i].addr == addr) {
      tss_t * t = waiters[i].thread;
      waiters[i].thread = NULL;
      woken++;
      /* a waiter whose timeout expired was woken by the timer already:
	 waking it twice would leave its private semaphore at 1 */
      if (!waiters[i].timed || timerQueueExtractThread(t) != NULL)
	privV(t);
    }
  return woken;
}

/* forget the waiters of a process that ended */
void futexForget(pid_t pid) {
  int i;
  for (i = 0; i < MAXFUTEXWAITERS; i++)
    if (waiters[i].thread && waiters[i].pid == pid)
      waiters[i].thread = NULL;
}

/* timeout in milliseconds, rounded up; -1 for none */
static int32_t futexWait(int32_t * addr, int32_t val, int32_t ms) {
  int i;
  if (*addr != val) return -EAGAIN;
  if (ms == 0) return -ETIMEDOUT;
  for (i = 0; i < MAXFUTEXWAITERS && waiters[i].thread; i++) ;
  if (i == MAXFUTEXWAITERS) return -ENOMEM;
  waiters[i].thread = currThread;
  waiters[i].pid = CURRPID;
  waiters[i].addr = addr;
  waiters[i].timed = ms > 0;
  if (ms > 0) timerQueueInsert(currThread, ms);
  privP();
  if (waiters[i].thread == currThread) {   /* still waiting: timed out */
    waiters[i].thread = NULL;
    return -ETIMEDOUT;
  }
  return 0;
}

static int32_t futexRequeue(int32_t * addr, int n, int nmove,
			    int32_t * addr2) {
  int i, woken = futexWake(addr, n), moved = 0;
  for (i = 0; i < MAXFUTEXWAITERS && moved < nmove; i++)
    if (waiters[i].thread && waiters[i].pid == CURRPID &&
	waiters[i].addr == addr) {
      waiters[i].addr = addr2;
      moved++;
    }
  return woken + moved;
}

static int32_t futex(int32_t * addr, int op, int32_t val, vaddr_t arg4,
		     int32_t * addr2, int32_t val3, int ts64) {
  int32_t ms = -1;
  int cmd = op & FUTEX_CMD_MASK;

  if (!__mem_userArea(addr, sizeof *addr)) return -EFAULT;
  if (addr2 && (cmd == FUTEX_REQUEUE || cmd == FUTEX_CMP_REQUEUE) &&
      !__mem_userArea(addr2, sizeof *addr2))
    return -EFAULT;
  switch (cmd) {
  case FUTEX_WAIT:
  case FUTEX_WAIT_BITSET:
    if (arg4) {
      if (!__mem_userArea((void *)arg4, ts64 ? 16 : 8)) return -EFAULT;
      /* a struct timespec (time_t of 32 or 64 bits): the low 32 bits of
	 the seconds are enough for a timeout */
      int32_t sec = ((int32_t *)arg4)[0];
      int32_t nsec = ((int32_t *)arg4)[ts64 ? 2 : 1];
      if (cmd == FUTEX_WAIT_BITSET) {     /* an absolute time */
	uint32_t now_s, now_ns;
	time_now((op & FUTEX_CLOCK_REALTIME) ? CLOCK_REALTIME
					     : CLOCK_MONOTONIC,
		 &now_s, &now_ns);
	sec -= (int32_t)now_s;
	nsec -= (int32_t)now_ns;
	while (nsec < 0) { nsec += 1000000000; sec--; }
	if (sec < 0) sec = nsec = 0;
      }
      if (sec < 0 || nsec < 0) return -EINVAL;
      ms = sec > 1000000 ? 1000000000 : sec * 1000 + (nsec + 999999) / 1000000;
    }
    return futexWait(addr, val, ms);
  case FUTEX_WAKE:
  case FUTEX_WAKE_BITSET:
    return futexWake(addr, val);
  case FUTEX_CMP_REQUEUE:
    if (*addr != val3) return -EAGAIN;
    /* fall through */
  case FUTEX_REQUEUE:
    return futexRequeue(addr, val, (int)arg4, addr2);
  default:
    return -ENOSYS;
  }
}

int32_t _linux_syscall_futex(int32_t * addr, int op, int32_t val,
			     vaddr_t arg4, int32_t * addr2, int32_t val3) {
  return futex(addr, op, val, arg4, addr2, val3, 0);
}

int32_t _linux_syscall_futex_time64(int32_t * addr, int op, int32_t val,
				    vaddr_t arg4, int32_t * addr2,
				    int32_t val3) {
  return futex(addr, op, val, arg4, addr2, val3, 1);
}

/* ---- clone, exit, thread ids ---- */

extern void _linux_syscall_exit(int status);

/* exit (1): the calling thread ends; the process with its last thread */
void _linux_syscall_exit_thread(int status) {
  if (processTable[currProcess]->numThreads <= 1) {
    _linux_syscall_exit(status);
    return;
  }
  if (currThread->clearTid &&          /* pthread_join waits on it */
      __mem_userArea(currThread->clearTid, sizeof(int32_t))) {
    *currThread->clearTid = 0;
    futexWake(currThread->clearTid, 0x7FFFFFFF);
  }
  __OS_threadExit((void *)(long)status);
}

int32_t _linux_syscall_gettid(void) {
  return currThread->tid;
}

int32_t _linux_syscall_set_tid_address(int32_t * tidptr) {
  if (tidptr && !__mem_userArea(tidptr, sizeof *tidptr)) return -EFAULT;
  currThread->clearTid = tidptr;
  return currThread->tid;
}

int32_t _linux_syscall_sched_yield(void) {
  sched();
  return 0;
}

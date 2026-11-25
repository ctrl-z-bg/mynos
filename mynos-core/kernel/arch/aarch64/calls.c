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
 * AArch64's system calls (doc/decisions/aarch64.md, choice 6): MyNOS's
 * native calls (svc #0x90) and Linux's (svc #0), the number in x8, the
 * arguments in x0-x5, the result in x0. Linux's AArch64 numbers are the
 * "generic" ones: openat, newfstatat, clone (fork too), no open, stat,
 * fork or time. The handlers are x86-64's (calls.c there), with small
 * adapters where the ABIs differ.
 */

#include "global.h"
#include "idt.h"
#include "tss.h"
#include "video.h"
#include "process.h"
#include "threads.h"
#include "sched.h"
#include "mem/mem.h"
#include "mynos.h"
#include "kutils.h"
#include "io.h"
#include "pit.h"

extern uint32_t timerTicks;

void arch_init_calls(void) { }

typedef long (*call_t)(long, long, long, long, long, long);
#define C(f) ((call_t)(f))

/* ---- the native calls: the numbers of arch/i386/entry.c ---- */

extern int __OS_ipc_send(), __OS_ipc_recv(), __OS_ipc_freeChannel();
extern int __OS_sem_userP(), __OS_sem_userTryP(), __OS_sem_userV();
extern int __OS_sem_allocateUserSemaphore(), __OS_sem_userFree();
extern int __OS_driverRegister(), __OS_service_registerService(), __OS_service_registerClient();
extern int __OS_port_allocPort(), __OS_port_allocPortP(), __OS_port_connectToPort();
extern int __OS_port_listenPort(), __OS_port_freePort(), __OS_port_changeOwner();
extern int _mynos_syscall_channelPeer(), _mynos_syscall_processInfo();
extern long _mynos_syscall_mapPhysical(), _mynos_syscall_dmaArea(), _mynos_syscall_dmaAlloc();
extern int _mynos_syscall_spawn(), _mynos_syscall_log(), _mynos_syscall_trace();
extern int _mynos_syscall_processes(), _mynos_syscall_kill(), _mynos_syscall_klog();
extern int _mynos_syscall_faults(), _mynos_syscall_pager(), _mynos_syscall_procstat();
extern int _mynos_syscall_enableIrq(), _mynos_syscall_disableIrq();
extern int _mynos_syscall_setTimer();
extern int __OS_threadCreate();
extern void __OS_threadExit(void *), __OS_fillStats(void *);

/* port I/O (102): no ports on ARM; a driver's inportb and outportb come
   here, and the machine's devices answer the few ports io.c knows (COM2
   on the UART: the console's serial input). op 0 reads, 1 writes. The io
   privilege only: as `in` and `out` on the PC, without it the process
   ends (the PC's protection fault, signal 11) */
static long native_portio(long op, long port, long value)
{
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO)) {
    printk("process ");
    print_ulong(CURRPID);
    printk(" killed: port I/O without the io privilege\n");
    killProcess(SIGNAL_STATUS(11));
    sched();
    return MYNOS_ERR_DENY;                       /* not reached */
  }
  if (op == 0) return inportb((unsigned short)port);
  outportb((unsigned short)port, (unsigned char)value);
  return 0;
}

static long native_threadExit(long r) { __OS_threadExit((void *)r); return 0; }
static long native_fillStats(long p) { __OS_fillStats((void *)p); return 0; }

static const struct { int n; call_t f; int wide; } natives[] = {
  { 3, C(__OS_ipc_send) }, { 4, C(__OS_ipc_recv) }, { 5, C(__OS_ipc_freeChannel) },
  { 6, C(__OS_sem_userP) }, { 7, C(__OS_sem_userTryP) }, { 8, C(__OS_sem_userV) },
  { 9, C(__OS_sem_allocateUserSemaphore) }, { 13, C(__OS_sem_userFree) },
  { 10, C(__OS_driverRegister) }, { 11, C(__OS_service_registerService) },
  { 12, C(__OS_service_registerClient) },
  { 20, C(__OS_port_allocPort) }, { 21, C(__OS_port_allocPortP) },
  { 22, C(__OS_port_connectToPort) }, { 23, C(__OS_port_listenPort) },
  { 24, C(__OS_port_freePort) }, { 25, C(__OS_port_changeOwner) },
  { 26, C(_mynos_syscall_channelPeer) }, { 27, C(_mynos_syscall_processInfo) },
  { 28, C(_mynos_syscall_mapPhysical), 1 }, { 29, C(_mynos_syscall_dmaArea), 1 },
  { 30, C(_mynos_syscall_spawn) }, { 31, C(_mynos_syscall_log) },
  { 32, C(_mynos_syscall_trace) }, { 33, C(_mynos_syscall_processes) },
  { 34, C(_mynos_syscall_kill) }, { 35, C(_mynos_syscall_klog) },
  { 36, C(_mynos_syscall_faults) }, { 37, C(_mynos_syscall_pager) },
  { 38, C(_mynos_syscall_procstat) }, { 39, C(_mynos_syscall_dmaAlloc), 1 },
  { 100, C(_mynos_syscall_enableIrq) }, { 101, C(_mynos_syscall_disableIrq) },
  { 102, C(native_portio) },
  { 200, C(__OS_threadCreate) }, { 201, C(native_threadExit), 1 },
  { 202, C(__OS_threadSelf) }, { 300, C(_mynos_syscall_setTimer) },
  { 400, C(native_fillStats), 1 },
};

/* the entry's frame of the call being served (fork, clone need it) */
struct frame * current_frame;

void _mynos_native_call(struct frame * f)
{
  unsigned i;
  current_frame = f;
  for (i = 0; i < sizeof natives / sizeof natives[0]; i++)
    if (natives[i].n == (int)f->x[8]) {
      long r = natives[i].f(f->x[0], f->x[1], f->x[2], f->x[3], f->x[4], 0);
      f->x[0] = natives[i].wide ? (uint64_t)r : (uint64_t)(long)(int)r;
      return;
    }
  f->x[0] = (uint64_t)(long)MYNOS_ERR_INVALID;
}

/* ---- Linux's calls (AArch64's numbers) ---- */

extern void * _linux_syscall_mmap(void * args);
extern long _linux_syscall_lseek(int fd, long offset, uint32_t whence);
extern int _linux_syscall_fork(), _linux_syscall_read(), _linux_syscall_write();
extern int _linux_syscall_open(), _linux_syscall_close();
extern int _linux_syscall_getpid(), _linux_syscall_getppid();
extern int _linux_syscall_munmap(), _linux_syscall_mprotect(), _linux_syscall_mremap();
extern int _linux_syscall_writev(), _linux_syscall_kill(), _linux_syscall_tgkill();
extern int _linux_syscall_nosignals(), _linux_syscall_uname(), _linux_syscall_wait4();
extern int _linux_syscall_getrandom(), _linux_syscall_ioctl(), _linux_syscall_getuid();
extern int _linux_syscall_clock_gettime64(), _linux_syscall_clock_nanosleep64();
extern int _linux_syscall_futex_time64(), _linux_syscall_gettid(), _linux_syscall_sched_yield();
extern int _linux_syscall_sched_getaffinity();
extern int _linux_syscall_set_tid_address();
extern void _linux_syscall_exit(int), _linux_syscall_exit_thread(int);
extern int _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id);
extern long arch_clone(long flags, long stack, long ptid, long ctid, long tls);

static long l_mmap(long addr, long len, long prot, long flags, long fd, long off)
{
  struct {
    unsigned long * start; unsigned long length; int prot, flags, fd; long offset;
  } a = { (unsigned long *)addr, len, prot, flags, fd, off >> 12 };
  return (long)_linux_syscall_mmap(&a);
}

/* openat: paths are absolute or the process's own (no directories in
   the kernel) */
static long l_openat(long dirfd, long path, long flags, long mode)
{
  (void)dirfd;
  return _linux_syscall_open(path, flags, mode);
}

/* fstat, newfstatat: the generic struct stat (AArch64's); as on the
   others, only the bytecode open() gives is a file here */
#define BYTECODE_FD 5
struct stat_g {
  uint64_t dev, ino;
  uint32_t mode, nlink, uid, gid;
  uint64_t rdev, pad1;
  int64_t size;
  int32_t blksize, pad2;
  int64_t blocks;
  int64_t times[6];
  uint32_t unused[2];
};
static long fill_stat(long st)
{
  extern modinfo_t bytecode;
  struct stat_g * s = (struct stat_g *)st;
  if (!__mem_userArea(s, sizeof *s)) return -14;
  kbzero(s, sizeof *s);
  s->ino = 1;
  s->nlink = 1;
  s->mode = 0100755;
  s->size = bytecode.len;
  s->blksize = PAGE_SIZE;
  s->blocks = (bytecode.len + 511) / 512;
  return 0;
}
static long l_fstat(long fd, long st) { return fd == BYTECODE_FD ? fill_stat(st) : -9; }
static long l_newfstatat(long dirfd, long path, long st, long flags) { return fill_stat(st); }

static long l_gettimeofday(long tv, long tz)
{
  long ts[2];
  long r = _linux_syscall_clock_gettime64(0, ts);
  if (r < 0 || !tv) return r;
  if (!__mem_userArea((void *)tv, 16)) return -14;
  ((long *)tv)[0] = ts[0];
  ((long *)tv)[1] = ts[1] / 1000;
  return 0;
}
static long l_nanosleep(long req, long rem)
{
  return _linux_syscall_clock_nanosleep64(1, 0, req, rem);
}
static long l_futex(long addr, long op, long val, long ts, long addr2, long val3)
{
  return _linux_syscall_futex_time64(addr, op, val, ts, addr2, val3);
}
static long l_exit(long s) { _linux_syscall_exit_thread(s); return 0; }
static long l_exit_group(long s) { _linux_syscall_exit(s); return 0; }
static long l_getrusage(long who, long ru)
{
  long * r = (long *)ru, t, i;
  if (!__mem_userArea(r, 144)) return -14;
  if (who != 0 && who != -1 && who != 1) return -22;
  t = who == -1 ? 0 : (long)processTable[currProcess]->cpuTicks;
  for (i = 0; i < 18; i++) r[i] = 0;
  r[0] = t / PIT_FREQ;
  r[1] = (t % PIT_FREQ) * (1000000 / PIT_FREQ);
  return 0;
}
static long l_times(long buf)
{
  if (buf) {
    long * b = (long *)buf;
    if (!__mem_userArea(b, 32)) return -14;
    b[0] = USER_TICKS(processTable[currProcess]->cpuTicks);
    b[1] = b[2] = b[3] = 0;
  }
  return USER_TICKS(timerTicks);
}
static long l_brk(long addr) { (void)addr; return 0; }
static long l_readlinkat(long dirfd, long path, long buf, long size) { return -2; }

/* clone: AArch64's arguments are flags, stack, ptid, tls, ctid. Without
   CLONE_VM it is fork (musl's fork: clone(SIGCHLD, 0)) */
#define CLONE_VM 0x00000100
static long l_clone(long flags, long stack, long ptid, long tls, long ctid)
{
  if (!(flags & CLONE_VM)) {
    if (stack) return -22;
    return _linux_syscall_fork();
  }
  return arch_clone(flags, stack, ptid, ctid, tls);
}

static const struct { int n; call_t f; int wide; } linux_calls[] = {
  { 29, C(_linux_syscall_ioctl) }, { 56, C(l_openat) }, { 57, C(_linux_syscall_close) },
  { 62, C(_linux_syscall_lseek), 1 }, { 63, C(_linux_syscall_read) },
  { 64, C(_linux_syscall_write) }, { 66, C(_linux_syscall_writev) },
  { 78, C(l_readlinkat) }, { 79, C(l_newfstatat) }, { 80, C(l_fstat) },
  { 93, C(l_exit) }, { 94, C(l_exit_group) },
  { 96, C(_linux_syscall_set_tid_address) }, { 98, C(l_futex) },
  { 101, C(l_nanosleep) }, { 113, C(_linux_syscall_clock_gettime64) },
  { 115, C(_linux_syscall_clock_nanosleep64) }, { 124, C(_linux_syscall_sched_yield) },
  { 123, C(_linux_syscall_sched_getaffinity) },
  { 129, C(_linux_syscall_kill) }, { 130, C(_linux_syscall_kill) },
  { 131, C(_linux_syscall_tgkill) }, { 132, C(_linux_syscall_nosignals) },
  { 134, C(_linux_syscall_nosignals) }, { 135, C(_linux_syscall_nosignals) },
  { 153, C(l_times), 1 }, { 160, C(_linux_syscall_uname) },
  { 165, C(l_getrusage) }, { 169, C(l_gettimeofday) },
  { 172, C(_linux_syscall_getpid) }, { 173, C(_linux_syscall_getppid) },
  { 174, C(_linux_syscall_getuid) }, { 175, C(_linux_syscall_getuid) },
  { 176, C(_linux_syscall_getuid) }, { 177, C(_linux_syscall_getuid) },
  { 178, C(_linux_syscall_gettid) },
  { 214, C(l_brk), 1 }, { 215, C(_linux_syscall_munmap) },
  { 216, C(_linux_syscall_mremap) }, { 220, C(l_clone) },
  { 222, C(l_mmap), 1 }, { 226, C(_linux_syscall_mprotect) },
  { 260, C(_linux_syscall_wait4) }, { 278, C(_linux_syscall_getrandom) },
};

void arm_linux_syscall(struct frame * f)
{
  unsigned i;
  current_frame = f;
  for (i = 0; i < sizeof linux_calls / sizeof linux_calls[0]; i++)
    if (linux_calls[i].n == (int)f->x[8]) {
      long r = linux_calls[i].f(f->x[0], f->x[1], f->x[2], f->x[3], f->x[4], f->x[5]);
      f->x[0] = linux_calls[i].wide ? r : (long)(int)r;
      return;
    }
  f->x[0] = (long)_linux_syscall_NOTIMPLEMENTED(f->x[8]);
}

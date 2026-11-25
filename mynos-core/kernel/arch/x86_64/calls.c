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
 * x86-64's system calls (doc/decisions/x86-64.md, choice 6): MyNOS's
 * native calls (int 0x90) and Linux's (syscall), by number, to the
 * generic handlers; the arguments in rdi, rsi, rdx, r10, r8, r9, the
 * result in rax. Where Linux's x86-64 ABI differs from the i386's that
 * the handlers were written for (mmap, stat, the times, clone, TLS), a
 * small adapter here.
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
#include "pit.h"

#define MSR_EFER  0xC0000080
#define MSR_STAR  0xC0000081
#define MSR_LSTAR 0xC0000082
#define MSR_FMASK 0xC0000084
#define MSR_FS_BASE 0xC0000100

static void wrmsr(uint32_t msr, uint64_t v)
{
  __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}
static uint64_t rdmsr(uint32_t msr)
{
  uint32_t lo, hi;
  __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
  return lo | ((uint64_t)hi << 32);
}

extern void syscall_entry(void);
extern uint32_t timerTicks;

/* the syscall instruction: on (EFER.SCE), its entry, the kernel's code
   selector, interrupts and the direction flag off on entry */
void arch_init_calls(void)
{
  wrmsr(MSR_EFER, rdmsr(MSR_EFER) | 1);
  wrmsr(MSR_STAR, (uint64_t)0x08 << 32);
  wrmsr(MSR_LSTAR, (uint64_t)syscall_entry);
  wrmsr(MSR_FMASK, 0x600);
}

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
  { 200, C(__OS_threadCreate) }, { 201, C(native_threadExit), 1 },
  { 202, C(__OS_threadSelf) }, { 300, C(_mynos_syscall_setTimer) },
  { 400, C(native_fillStats), 1 },
};

/* the entry's frame of the call being served (fork, clone need it) */
struct frame * current_frame;

void _mynos_native_call(struct frame * f)
{
  unsigned i;
  smp_leave_if_dead();
  current_frame = f;
  for (i = 0; i < sizeof natives / sizeof natives[0]; i++)
    if (natives[i].n == (int)f->rax) {
      long r = natives[i].f(f->rdi, f->rsi, f->rdx, f->r10, f->r8, 0);
      /* the handlers return int, but those of addresses: sign extended */
      f->rax = natives[i].wide ? (uint64_t)r : (uint64_t)(long)(int)r;
      return;
    }
  f->rax = (uint64_t)(long)MYNOS_ERR_INVALID;
}

/* ---- Linux's calls (x86-64 numbers) ---- */

extern void * _linux_syscall_mmap(void * args);
extern long _linux_syscall_lseek(int fd, long offset, uint32_t whence);
extern int _linux_syscall_fork(), _linux_syscall_read(), _linux_syscall_write();
extern int _linux_syscall_open(), _linux_syscall_close();
extern int _linux_syscall_getpid(), _linux_syscall_getppid(), _linux_syscall_pause();
extern int _linux_syscall_munmap(), _linux_syscall_mprotect(), _linux_syscall_mremap();
extern int _linux_syscall_writev(), _linux_syscall_kill(), _linux_syscall_tgkill();
extern int _linux_syscall_nosignals(), _linux_syscall_uname(), _linux_syscall_wait4();
extern int _linux_syscall_getrandom(), _linux_syscall_ioctl(), _linux_syscall_getuid();
extern int _linux_syscall_clock_gettime64(), _linux_syscall_clock_nanosleep64();
extern int _linux_syscall_futex_time64(), _linux_syscall_gettid(), _linux_syscall_sched_yield();
extern int _linux_syscall_set_tid_address();
extern void _linux_syscall_exit(int), _linux_syscall_exit_thread(int);
extern int _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id);

/* mmap: x86-64's has its six arguments in registers, the offset in
   bytes; the handler (mmap2's) takes a structure, the offset in pages */
static long l_mmap(long addr, long len, long prot, long flags, long fd, long off)
{
  struct {
    unsigned long * start; unsigned long length; int prot, flags, fd; long offset;
  } a = { (unsigned long *)addr, len, prot, flags, fd, off >> 12 };
  return (long)_linux_syscall_mmap(&a);
}

/* stat, fstat, newfstatat: x86-64's struct stat; as on the i386, only
   the bytecode open() gives (linux_syscalls.c) is a file here */
#define BYTECODE_FD 5
struct stat_x {
  uint64_t dev, ino, nlink;
  uint32_t mode, uid, gid, pad0;
  uint64_t rdev;
  int64_t size, blksize, blocks;
  uint64_t times[6];
  int64_t reserved[3];
};
static long fill_stat(long st)
{
  extern modinfo_t bytecode;
  struct stat_x * s = (struct stat_x *)st;
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
static long l_stat(long path, long st) { return fill_stat(st); }
static long l_newfstatat(long dirfd, long path, long st, long flags) { return fill_stat(st); }

/* the times: x86-64's timeval and timespec are pairs of 64-bit numbers */
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
static long l_time(long t)
{
  long ts[2];
  _linux_syscall_clock_gettime64(0, ts);
  if (t) {
    if (!__mem_userArea((void *)t, 8)) return -14;
    *(long *)t = ts[0];
  }
  return ts[0];
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
/* getrusage and times: the process's CPU time, as on the i386
   (linux_syscalls.c), in x86-64's layouts (longs of 8 bytes) */
static long l_getrusage(long who, long ru)
{
  long * r = (long *)ru, t, i;
  if (!__mem_userArea(r, 144)) return -14;
  if (who != 0 && who != -1 && who != 1) return -22;
  t = who == -1 ? 0 : (long)processTable[currProcess]->cpuTicks;
  for (i = 0; i < 18; i++) r[i] = 0;
  r[0] = t / PIT_FREQ;                                  /* ru_utime */
  r[1] = (t % PIT_FREQ) * (1000000 / PIT_FREQ);
  return 0;
}
static long l_times(long buf)
{
  if (buf) {
    long * b = (long *)buf;
    if (!__mem_userArea(b, 32)) return -14;
    b[0] = USER_TICKS(processTable[currProcess]->cpuTicks);  /* tms_utime */
    b[1] = b[2] = b[3] = 0;
  }
  return USER_TICKS(timerTicks);
}

/* brk: no heap of that kind; 0, the break that never moves, and musl's
   malloc takes its memory with mmap. readlink: no /proc, where ocamlrun
   looks for its own name (/proc/self/exe). Both answered quietly: known
   calls, not unknown ones */
static long l_brk(long addr) { (void)addr; return 0; }
static long l_readlink(long path, long buf, long size) { return -2; }

/* arch_prctl: the thread's TLS is FS's base */
static long l_arch_prctl(long code, long addr)
{
  if (code == 0x1002) {                         /* ARCH_SET_FS */
    currThread->fs_base = addr;
    wrmsr(MSR_FS_BASE, addr);
    return 0;
  }
  if (code == 0x1003) {                         /* ARCH_GET_FS */
    if (!__mem_userArea((void *)addr, 8)) return -14;
    *(long *)addr = currThread->fs_base;
    return 0;
  }
  return -22;
}

extern long arch_clone(long flags, long stack, long ptid, long ctid, long tls);

static const struct { int n; call_t f; int wide; } linux_calls[] = {
  { 0, C(_linux_syscall_read) }, { 1, C(_linux_syscall_write) },
  { 2, C(_linux_syscall_open) }, { 3, C(_linux_syscall_close) },
  { 4, C(l_stat) }, { 5, C(l_fstat) }, { 6, C(l_stat) },
  { 8, C(_linux_syscall_lseek), 1 }, { 9, C(l_mmap), 1 },
  { 10, C(_linux_syscall_mprotect) }, { 11, C(_linux_syscall_munmap) },
  { 13, C(_linux_syscall_nosignals) }, { 14, C(_linux_syscall_nosignals) },
  { 16, C(_linux_syscall_ioctl) }, { 20, C(_linux_syscall_writev) },
  { 24, C(_linux_syscall_sched_yield) }, { 25, C(_linux_syscall_mremap) },
  { 12, C(l_brk), 1 }, { 89, C(l_readlink) },
  { 34, C(_linux_syscall_pause) }, { 35, C(l_nanosleep) },
  { 39, C(_linux_syscall_getpid) }, { 56, C(arch_clone) },
  { 57, C(_linux_syscall_fork) }, { 60, C(l_exit) },
  { 61, C(_linux_syscall_wait4) }, { 62, C(_linux_syscall_kill) },
  { 63, C(_linux_syscall_uname) }, { 96, C(l_gettimeofday) },
  { 98, C(l_getrusage) }, { 100, C(l_times), 1 },
  { 102, C(_linux_syscall_getuid) }, { 104, C(_linux_syscall_getuid) },
  { 107, C(_linux_syscall_getuid) }, { 108, C(_linux_syscall_getuid) },
  { 110, C(_linux_syscall_getppid) }, { 131, C(_linux_syscall_nosignals) },
  { 158, C(l_arch_prctl) }, { 186, C(_linux_syscall_gettid) },
  { 200, C(_linux_syscall_kill) }, { 201, C(l_time), 1 },
  { 202, C(l_futex) }, { 218, C(_linux_syscall_set_tid_address) },
  { 228, C(_linux_syscall_clock_gettime64) },
  { 230, C(_linux_syscall_clock_nanosleep64) }, { 231, C(l_exit_group) },
  { 234, C(_linux_syscall_tgkill) }, { 262, C(l_newfstatat) },
  { 318, C(_linux_syscall_getrandom) },
};

void x86_syscall(struct frame * f)
{
  unsigned i;
  smp_leave_if_dead();
  current_frame = f;
  for (i = 0; i < sizeof linux_calls / sizeof linux_calls[0]; i++)
    if (linux_calls[i].n == (int)f->rax) {
      long r = linux_calls[i].f(f->rdi, f->rsi, f->rdx, f->r10, f->r8, f->r9);
      f->rax = linux_calls[i].wide ? r : (long)(int)r;
      return;
    }
  f->rax = (long)_linux_syscall_NOTIMPLEMENTED(f->rax);
}

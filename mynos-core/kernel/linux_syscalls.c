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

#include "trace.h"
#include "global.h"
#include "video.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "kutils.h"
#include "linux_syscalls.h"
#include "mem/dynalloc.h"
#include "sched.h"
#include "sem.h"
#include "time.h"
#include "random.h"

extern uint32_t currProcess;

typedef unsigned long int clock_t;
struct tms {
              clock_t tms_utime;  /* user time */
              clock_t tms_stime;  /* system time */
              clock_t tms_cutime; /* user time of children */
              clock_t tms_cstime; /* system time of children */
       };
/* a pointer from the process: its own memory, or -EFAULT (the kernel
   could write into itself through a pointer below the user space, where
   no page fault stops it) */
#define USER(P, N) do { if (!__mem_userArea((P), (N))) return -14; } while (0)

void _linux_syscall_times(struct tms *buf) {
  static uint32_t tm = 0;
  if (!__mem_userArea(buf, sizeof(struct tms))) return;
  tm += 10;
  buf->tms_utime = buf->tms_stime = tm;
}

void _linux_syscalls_trap_TRAP();
/* Linux system calls (int $0x80). Linux preserves every register except
   eax: all six argument registers are saved, and pushed in this order they
   are also the cdecl arguments of every handler (ebx first) and, for mmap2,
   a struct mmap_args. */
__asm__ (".pushsection .text\n" \
	 ".globl _linux_syscalls_trap_TRAP\n"\
	 "_linux_syscalls_trap_TRAP:\n"\
	 "   pushl %ebp\n"\
	 "   pushl %edi\n"\
	 "   pushl %esi\n"\
	 "   pushl %edx\n"\
	 "   pushl %ecx\n"\
	 "   pushl %ebx\n"\
	 "   cmpl $1, %eax\n"\
	 "   je .linux_exit_thread\n"\
	 "   cmpl $120, %eax\n"\
	 "   je .linux_clone\n"\
	 "   cmpl $240, %eax\n"\
	 "   je .linux_futex\n"\
	 "   cmpl $422, %eax\n"\
	 "   je .linux_futex_time64\n"\
	 "   cmpl $224, %eax\n"\
	 "   je .linux_gettid\n"\
	 "   cmpl $158, %eax\n"\
	 "   je .linux_sched_yield\n"\
	 "   cmpl $2, %eax\n"\
	 "   je .linux_fork\n"\
	 "   cmpl $3, %eax\n"\
	 "   je .linux_read\n"\
	 "   cmpl $4, %eax\n"\
	 "   je .linux_write\n"\
	 "   cmpl $5, %eax\n"\
	 "   je .linux_open\n"\
	 "   cmpl $6, %eax\n"\
	 "   je .linux_close\n"\
	 "   cmpl $20, %eax\n"\
	 "   je .linux_getpid\n"\
	 "   cmpl $29, %eax\n"\
	 "   je .linux_pause\n"\
	 "   cmpl $43, %eax\n"\
	 "   je .linux_times\n"\
	 "   cmpl $64, %eax\n"\
	 "   je .linux_getppid\n"\
	 "   cmpl $90, %eax\n"\
	 "   je .linux_mmap\n"\
	 "   cmpl $91, %eax\n"\
	 "   je .linux_munmap\n"\
	 "   cmpl $140, %eax\n"\
	 "   je .linux_llseek\n"\
	 "   cmpl $192, %eax\n"\
	 "   je .linux_mmap2\n"\
	 "   cmpl $243, %eax\n"\
	 "   je .linux_set_thread_area\n"\
	 "   cmpl $125, %eax\n"\
	 "   je .linux_mprotect\n"\
	 "   cmpl $146, %eax\n"\
	 "   je .linux_writev\n"\
	 "   cmpl $252, %eax\n"\
	 "   je .linux_exit\n"\
	 "   cmpl $258, %eax\n"\
	 "   je .linux_set_tid_address\n"\
	 "   cmpl $19, %eax\n"\
	 "   je .linux_lseek\n"\
	 "   cmpl $13, %eax\n"\
	 "   je .linux_time\n"\
	 "   cmpl $78, %eax\n"\
	 "   je .linux_gettimeofday\n"\
	 "   cmpl $162, %eax\n"\
	 "   je .linux_nanosleep\n"\
	 "   cmpl $265, %eax\n"\
	 "   je .linux_clock_gettime\n"\
	 "   cmpl $267, %eax\n"\
	 "   je .linux_clock_nanosleep\n"\
	 "   cmpl $403, %eax\n"\
	 "   je .linux_clock_gettime64\n"\
	 "   cmpl $407, %eax\n"\
	 "   je .linux_clock_nanosleep64\n"\
	 "   cmpl $37, %eax\n"\
	 "   je .linux_kill\n"\
	 "   cmpl $238, %eax\n"\
	 "   je .linux_tkill\n"\
	 "   cmpl $270, %eax\n"\
	 "   je .linux_tgkill\n"\
	 "   cmpl $174, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $175, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $186, %eax\n"\
	 "   je .linux_nosignals\n"\
	 "   cmpl $195, %eax\n"\
	 "   je .linux_stat64\n"\
	 "   cmpl $197, %eax\n"\
	 "   je .linux_fstat64\n"\
	 "   cmpl $7, %eax\n"\
	 "   je .linux_waitpid\n"\
	 "   cmpl $355, %eax\n"\
	 "   je .linux_getrandom\n"\
	 "   cmpl $54, %eax\n"\
	 "   je .linux_ioctl\n"\
	 "   cmpl $114, %eax\n"\
	 "   je .linux_wait4\n"\
	 "   pushl %eax\n"\
	 "   call _linux_syscall_NOTIMPLEMENTED\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_exit:\n"\
	 "   call _linux_syscall_exit\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_exit_thread:\n"\
	 "   call _linux_syscall_exit_thread\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clone:\n"\
	 "   call _linux_syscall_clone\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_futex:\n"\
	 "   call _linux_syscall_futex\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_futex_time64:\n"\
	 "   call _linux_syscall_futex_time64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_gettid:\n"\
	 "   call _linux_syscall_gettid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_sched_yield:\n"\
	 "   call _linux_syscall_sched_yield\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_fork:\n"\
	 "   call _linux_syscall_fork\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_read:\n"\
	 "   call _linux_syscall_read\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_write:\n"\
	 "   call _linux_syscall_write\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_open:\n"\
	 "   call _linux_syscall_open\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_close:\n"\
	 "   call _linux_syscall_close\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getpid:\n"\
	 "   call _linux_syscall_getpid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_pause:\n"\
	 "   call _linux_syscall_pause\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_times:\n"\
	 "   call _linux_syscall_times\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getppid:\n"\
	 "   call _linux_syscall_getppid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mmap:\n"\
	 "   call _linux_syscall_old_mmap\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_munmap:\n"\
	 "   call _linux_syscall_munmap\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_llseek:\n"\
	 "   call _linux_syscall_llseek\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mmap2:\n"\
	 "   pushl %esp\n"\
	 "   call _linux_syscall_mmap\n"\
	 "   addl $4, %esp\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_set_thread_area:\n"\
	 "   call _linux_syscall_set_thread_area\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_mprotect:\n"\
	 "   call _linux_syscall_mprotect\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_writev:\n"\
	 "   call _linux_syscall_writev\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_set_tid_address:\n"\
	 "   call _linux_syscall_set_tid_address\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_time:\n"\
	 "   call _linux_syscall_time\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_gettimeofday:\n"\
	 "   call _linux_syscall_gettimeofday\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_nanosleep:\n"\
	 "   call _linux_syscall_nanosleep\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_gettime:\n"\
	 "   call _linux_syscall_clock_gettime\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_nanosleep:\n"\
	 "   call _linux_syscall_clock_nanosleep\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_gettime64:\n"\
	 "   call _linux_syscall_clock_gettime64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_clock_nanosleep64:\n"\
	 "   call _linux_syscall_clock_nanosleep64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_kill:\n"\
	 "   call _linux_syscall_kill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_tkill:\n"\
	 "   call _linux_syscall_kill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_tgkill:\n"\
	 "   call _linux_syscall_tgkill\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_nosignals:\n"\
	 "   call _linux_syscall_nosignals\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_lseek:\n"\
	 "   call _linux_syscall_lseek\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_stat64:\n"\
	 "   call _linux_syscall_stat64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_fstat64:\n"\
	 "   call _linux_syscall_fstat64\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_ioctl:\n"\
	 "   call _linux_syscall_ioctl\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_getrandom:\n"\
	 "   call _linux_syscall_getrandom\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_waitpid:\n"\
	 "   call _linux_syscall_waitpid\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".linux_wait4:\n"\
	 "   call _linux_syscall_wait4\n"\
	 "   jmp .exit_linux_syscall\n"\
	 ".exit_linux_syscall:\n"\
	 "   popl %ebx\n"\
	 "   popl %ecx\n"\
	 "   popl %edx\n"\
	 "   popl %esi\n"\
	 "   popl %edi\n"\
	 "   popl %ebp\n"\
	 "   iret\n"\
	 ".popsection\n");


/* writev (146): musl's stdio writes through it */
int _linux_syscall_writev(int fd, const struct iovec * iov, int iovcnt) {
  int i, total = 0;
  if (iovcnt < 0 || iovcnt > 1024) return -22;
  USER(iov, iovcnt * sizeof(struct iovec));
  for (i = 0; i < iovcnt; i++) {
    int n = _linux_syscall_write(fd, iov[i].iov_base, iov[i].iov_len);
    if (n < 0) return total ? total : n;
    total += n;
  }
  return total;
}

/* ---- time (time.c has the clocks and the sleeping) ---- */

struct timespec32 { int32_t tv_sec; int32_t tv_nsec; };
struct timespec64 { long long tv_sec; long long tv_nsec; };
struct timeval32  { int32_t tv_sec; int32_t tv_usec; };

#define TIMER_ABSTIME 1

/* time (13) */
int _linux_syscall_time(int32_t * t) {
  uint32_t sec, nsec;
  if (t) USER(t, sizeof *t);
  time_now(CLOCK_REALTIME, &sec, &nsec);
  if (t) *t = sec;
  return sec;
}

/* gettimeofday (78) */
int _linux_syscall_gettimeofday(struct timeval32 * tv, void * tz) {
  uint32_t sec, nsec;
  if (tv) USER(tv, sizeof *tv);
  time_now(CLOCK_REALTIME, &sec, &nsec);
  if (tv) { tv->tv_sec = sec; tv->tv_usec = nsec / 1000; }
  return 0;
}

/* clock_gettime (265) and its time64 variant (403), used by musl on i386 */
int _linux_syscall_clock_gettime(uint32_t clock, struct timespec32 * ts) {
  uint32_t sec, nsec;
  USER(ts, sizeof *ts);
  time_now(clock, &sec, &nsec);
  ts->tv_sec = sec; ts->tv_nsec = nsec;
  return 0;
}

int _linux_syscall_clock_gettime64(uint32_t clock, struct timespec64 * ts) {
  uint32_t sec, nsec;
  USER(ts, sizeof *ts);
  time_now(clock, &sec, &nsec);
  ts->tv_sec = sec; ts->tv_nsec = nsec;
  return 0;
}

/* sleep until (absolute) or for (relative) sec + nsec on a clock */
static int sleep_for(uint32_t clock, int flags, uint32_t sec, uint32_t nsec) {
  if (flags & TIMER_ABSTIME) {
    uint32_t now_s, now_ns;
    time_now(clock, &now_s, &now_ns);
    if (sec < now_s || (sec == now_s && nsec <= now_ns))
      return 0;
    if (nsec < now_ns) { nsec += 1000000000; sec--; }
    sec -= now_s; nsec -= now_ns;
  }
  time_sleepTicks(time_toTicks(sec, nsec));
  return 0;
}

/* nanosleep (162); the remaining time is always 0: no signals interrupt */
int _linux_syscall_nanosleep(struct timespec32 * req, struct timespec32 * rem) {
  USER(req, sizeof *req);
  if (rem) USER(rem, sizeof *rem);
  if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000)
    return -22; /* EINVAL */
  sleep_for(CLOCK_MONOTONIC, 0, req->tv_sec, req->tv_nsec);
  if (rem) { rem->tv_sec = 0; rem->tv_nsec = 0; }
  return 0;
}

/* clock_nanosleep (267) and its time64 variant (407) */
int _linux_syscall_clock_nanosleep(uint32_t clock, int flags,
				   struct timespec32 * req,
				   struct timespec32 * rem) {
  if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000)
    return -22;
  return sleep_for(clock, flags, req->tv_sec, req->tv_nsec);
}

int _linux_syscall_clock_nanosleep64(uint32_t clock, int flags,
				     struct timespec64 * req,
				     struct timespec64 * rem) {
  if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000)
    return -22;
  return sleep_for(clock, flags, (uint32_t)req->tv_sec,
		   (uint32_t)req->tv_nsec);
}

/* kill (37), tkill (238), tgkill (270). No signal delivery yet: a signal a
   process sends to itself (what abort() and raise() do) terminates it, as
   the default action of a fatal signal would; signal 0 only checks that
   the target exists. Signals to other processes are not supported. */
int _linux_syscall_kill(int pid, int sig) {
  /* oneself: the process (pid) or one of its threads (tkill, tgkill) */
  if (pid != 0 && pid != (int)currProcess) {
    tss_t * t;
    for (t = processTable[currProcess]->tss; t && t->tid != pid; t = t->next) ;
    if (!t) return -1; /* -EPERM */
  }
  if (sig == 0)
    return 0;
  printk("process ");
  print_ulong(currProcess);
  printk(" killed by signal ");
  print_int(sig);
  print_char('\n');
  killProcess(SIGNAL_STATUS(sig));
  sched();         /* switches to another process, never returns */
  return 0;
}

int _linux_syscall_tgkill(int tgid, int tid, int sig) {
  return _linux_syscall_kill(tid, sig);
}

/* rt_sigaction (174), rt_sigprocmask (175), sigaltstack (186): MyNOS
   delivers no signals yet, so accept the settings and ignore them. Runtimes
   (OCaml 5) refuse to start if they fail. */
int _linux_syscall_nosignals() {
  return 0;
}

/* mprotect (125): no page protections beyond read/write yet, accept it */
int _linux_syscall_mprotect(void * addr, size_t len, int prot) {
  return 0;
}


/* Thread-local storage: a single GDT slot (GDT_TLS_INDEX) shared by all
   threads, rewritten from the incoming thread's tss on every switch. */
void tls_load(void * t) {
  tss_t * thread = (tss_t *)t;
  if (thread->tls_limit == 0 && thread->tls_base == 0)
    gdt_set_entry(GDT_TLS_INDEX, 0, 0xFFFFF,
		  D_DATA + D_WRITE + D_BIG + D_BIG_LIM + D_DPL3);
  else
    gdt_set_entry(GDT_TLS_INDEX, thread->tls_base, thread->tls_limit,
		  D_DATA + D_WRITE + D_BIG + D_DPL3 +
		  (thread->tls_pages ? D_BIG_LIM : 0));
}

int _linux_syscall_set_thread_area(struct user_desc * u_info) {
  USER(u_info, sizeof *u_info);
  if (u_info->entry_number != (uint32_t)-1 &&
      u_info->entry_number != GDT_TLS_INDEX)
    return -22; /* EINVAL */

  currThread->tls_base = u_info->base_addr;
  currThread->tls_limit = u_info->limit & 0xFFFFF;
  currThread->tls_pages = (u_info->flags >> 4) & 1;
  u_info->entry_number = GDT_TLS_INDEX;
  tls_load(currThread);
  return 0;
}

/* unknown Linux system call: fail with -ENOSYS, as Linux does, so that
   libcs and runtimes can fall back. Report each number once. */
int32_t _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id) {
  static uint32_t reported[512 / 32];
  if (syscall_id >= 512 ||
      !(reported[syscall_id / 32] & (1u << (syscall_id % 32)))) {
    if (syscall_id < 512)
      reported[syscall_id / 32] |= 1u << (syscall_id % 32);
    printk("Linux syscall ");
    print_uint(syscall_id);
    printk(" not implemented (process ");
    print_uint(currProcess);
    printk("): -ENOSYS\n");
  }
  return -38; /* -ENOSYS */
}

void _linux_syscall_exit(int status) {
  /* a normal end is silent: the parent gets the status (waitpid) */
  if (status != 0) {
    printk("process ");
    print_int(currProcess);
    printk(" exited with code ");
    print_int(status);
    print_char('\n');
  }
  killProcess(EXIT_STATUS(status));
  sched();
}

/*
 * waitpid (7) and wait4 (114, what musl uses): wait for a child to end and
 * collect its status. pid > 0 waits for that child, -1 (or 0: there are no
 * process groups) for any. The only option is WNOHANG; rusage is not filled.
 */
#define WNOHANG 1
#define ECHILD 10

int _linux_syscall_wait4(int pid, int * status, int options, void * rusage) {
  process_descriptor_t * self = processTable[currProcess];
  if (status) USER(status, sizeof *status);
  while (1) {
    int i, children = 0;
    for (i = 1; i < (int)numProcess; i++) {
      process_descriptor_t * p = processTable[i];
      if (!p || p->ppid != (int)currProcess || p->reaped) continue;
      if (pid > 0 && i != pid) continue;
      children++;
      if (!p->isAlive) {
	if (status) *status = p->exitStatus;
	/* free its memory now (if not done yet), then its descriptor */
	reapZombies();
	if (p->memFreed)
	  freeProcessDescriptor(i);
	else
	  p->reaped = 1;   /* the reaper will free it */
	return i;
      }
    }
    if (!children) return -ECHILD;
    if (options & WNOHANG) return 0;
    /* V'd once for every child that ends: check again then */
    __OS_sem_P(self->childSem);
  }
}

/* ioctl (54): only the window size of the screen, for fds 0-2 (isatty
   asks it). The terminal settings are libmynos's (fileio.c), with the
   console service. */
int _linux_syscall_ioctl(int fd, uint32_t req, unsigned short * arg) {
  if (fd >= 0 && fd <= 2 && req == 0x5413 /* TIOCGWINSZ */) {
    USER(arg, 4 * sizeof *arg);
    arg[0] = 25;          /* rows */
    arg[1] = 80;          /* columns */
    arg[2] = arg[3] = 0;
    return 0;
  }
  return -25;             /* -ENOTTY */
}

/* getrandom (355): the kernel's random numbers (random.c), at most 256
   bytes per call, as Linux allows */
int _linux_syscall_getrandom(unsigned char * buf, uint32_t len,
			     uint32_t flags) {
  if (len > 256) len = 256;
  USER(buf, len);
  random_get(buf, len);
  return len;
}

int _linux_syscall_waitpid(int pid, int * status, int options) {
  return _linux_syscall_wait4(pid, status, options, NULL);
}

int32_t _linux_syscall_pause() {
  privP();
  return -1;
}

/*
 * There is no filesystem behind the Linux file calls yet (mynos-nxa): every
 * open() opens the same read-only file, the OCaml bytecode passed as GRUB
 * module 1. These calls give it proper file semantics (a position, seeks
 * from start/current/end, a size) so that any libc and OCaml runtime can
 * read it.
 */
#define BYTECODE_FD 5
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

extern modinfo_t bytecode;
static uint32_t bytecode_pos = 0;

int _linux_syscall_open(char * pathname, int flags, int mode) {
  bytecode_pos = 0;
  return BYTECODE_FD;
}

int _linux_syscall_close(int fd) {
  return 0;
}

int _linux_syscall_read(int fd, const void *buf, size_t count) {
  if (fd < 3) return 0;   /* no stdin yet: end of file */
  USER(buf, count);
  if (bytecode_pos >= bytecode.len) return 0;
  if (count > bytecode.len - bytecode_pos)
    count = bytecode.len - bytecode_pos;
  kmemcpy((void*)buf, (char*)bytecode.start + bytecode_pos, count);
  bytecode_pos += count;
  return count;
}

static long long bytecode_seek(long long offset, uint32_t whence) {
  long long pos;
  switch (whence) {
  case SEEK_SET: pos = offset; break;
  case SEEK_CUR: pos = (long long)bytecode_pos + offset; break;
  case SEEK_END: pos = (long long)bytecode.len + offset; break;
  default: return -22; /* EINVAL */
  }
  if (pos < 0) return -22;
  bytecode_pos = (uint32_t)pos;
  return pos;
}

/* lseek (19) */
long _linux_syscall_lseek(int fd, long offset, uint32_t whence) {
  return (long)bytecode_seek(offset, whence);
}

/* _llseek (140): 64-bit offset in two halves, result written back */
int _linux_syscall_llseek(uint32_t fd, ulong32_t offhi, ulong32_t offlow,
			  long long int * result, uint32_t whence) {
  long long pos = bytecode_seek(((long long)offhi << 32) | offlow, whence);
  if (pos < 0) return (int)pos;
  *result = pos;
  return 0;
}

/* Linux i386 struct stat64 */
struct stat64 {
  unsigned long long st_dev;
  unsigned char      __pad0[4];
  unsigned long      __st_ino;
  unsigned int       st_mode;
  unsigned int       st_nlink;
  unsigned long      st_uid;
  unsigned long      st_gid;
  unsigned long long st_rdev;
  unsigned char      __pad3[4];
  long long          st_size;
  unsigned long      st_blksize;
  unsigned long long st_blocks;
  unsigned long      st_atime, st_atime_nsec;
  unsigned long      st_mtime, st_mtime_nsec;
  unsigned long      st_ctime, st_ctime_nsec;
  unsigned long long st_ino;
} __attribute__((packed));

static int bytecode_stat(struct stat64 * st) {
  kbzero(st, sizeof(struct stat64));
  st->st_mode = 0100755;          /* regular file, rwxr-xr-x */
  st->st_nlink = 1;
  st->st_size = bytecode.len;
  st->st_blksize = PAGE_SIZE;
  st->st_blocks = (bytecode.len + 511) / 512;
  st->__st_ino = st->st_ino = 1;
  return 0;
}

/* stat64 (195), fstat64 (197) */
int _linux_syscall_stat64(char * path, struct stat64 * st) {
  USER(st, sizeof *st);
  return bytecode_stat(st);
}

int _linux_syscall_fstat64(int fd, struct stat64 * st) {
  USER(st, sizeof *st);
  return bytecode_stat(st);
}

int _linux_syscall_write(int fd, const void *buf, size_t count) {
  int i;

  USER(buf, count);
  for (i = 0; i < count; i++)
    _print_char(((char*)buf)[i], CHAR_USER_ATTRIB);
  return count;
}

int _linux_syscall_getpid() {
  return currProcess;
}

int _linux_syscall_getppid() {
  return processTable[currProcess]->ppid;
}

int _linux_syscall_munmap(void *start, size_t length) {
  uint32_t npages;
#ifdef DEBUG
  printk("munmap: ");
  print_ulong_hex((long32_t)start);
  print_char(' ');
  print_long((long32_t)length);
  print_char('\n');
#endif
  if (length == 0 || (uint32_t)start < USER_AREA_START ||
      (uint32_t)start + length < (uint32_t)start ||
      (uint32_t)start + length > USER_AREA_END)
    return -22;
  npages = (length - 1) / PAGE_SIZE + 1;
  if (__OS_releasePages(start, npages, 1, 1) == NULL)
    return -1;
  return 0;
}

/* mmap2 (192) passes the arguments in registers: args points to them on
   the kernel stack (the system call entry pushed them); the old mmap (90)
   passes a pointer to a struct in the process's memory */
void * _linux_syscall_mmap(struct mmap_args * args);

void * _linux_syscall_old_mmap(struct mmap_args * args) {
  if (!__mem_userArea(args, sizeof *args)) return (void *)-14;
  return _linux_syscall_mmap(args);
}

void * _linux_syscall_mmap(struct mmap_args * args) {
  uint32_t npages;
  void * ret;

  if (args->length == 0) return (void *)-22;
  npages = (args->length - 1) / PAGE_SIZE + 1;
  ret =__OS_askPages(npages, 0, PF_READWRITE | PF_USER);
  if (ret == NULL)
    ret = (void *)-12; /* -ENOMEM: libcs test for -4095..-1, not NULL */

#ifdef DEBUG
  printk("mmap: ");
  print_long((long32_t)args->start);
  print_char(' ');
  print_long((long32_t)args->length);
  print_char(' ');
  print_long((long32_t)args->prot);
  print_char(' ');
  print_long((long32_t)args->flags);
  print_char(' ');
  print_long((long32_t)args->fd);
  print_char(' ');
  print_long((long32_t)args->offset);
  printk(" = ");
  print_uint_hex(ret);
  print_char('\n');
#endif //DEBUG

  return ret;
}

/* it returns:
   1: on success
   0: error
   something else: address for the PD image
*/
static uint32_t copy_page_table(uint32_t ptp, uint32_t * ptc) {
  uint32_t i;
  uint32_t * pte, flags;
  uint32_t * pf;

  /* copy the page table entries */
  for (i = 0; i <= LAST_PDPT_INDEX; i++) {
    if ((ptp == (LAST_PDPT_INDEX - 1)) && (i == LAST_PDPT_INDEX)) return 1; // this is the pd image
    pte = (uint32_t*)__GET_PAGE_TABLE_ENTRY(ptp, i);
    if (*pte & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PF is allocated
      flags = *pte & 0xFFF;
      if (*pte & PF_PRESENT) {  // the page is really allocated

	/* if the page is a superuser page then copy it (in 386 arch
	   ro check is not done in superuser mode, so cow cannot work) */
	if (!(*pte & PF_USER)) {
	  if ((pf = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
	  ptc[i] = LINEAR_TO_PHYSICAL_ADDRESS(pf) | flags;
	  
	  /* copy the page frame */
	  kmemcpy((void*)pf, (void*)__MEM_LINEAR_ADDRESS(ptp, i, 0), 
		  PAGE_SIZE);
	  /* drop the kernel alias: the frame is the child's alone */
	  __OS_releasePages(pf, 1, 0, 0);
	} else {   // ok, it's a user page
	  /* the page is set as cow only if: it's not shared, it's not RO,
	     it's not already cow */
	  if (!(*pte & PF_SHARED) && (*pte & PF_READWRITE) && !(*pte & PF_COW)) {
	    *pte |= PF_COW;
	    *pte = *pte & ~PF_READWRITE;  // to have the fault on write!
	    INVALIDATE_THE_CACHE(__MEM_LINEAR_ADDRESS(ptp, i, 0));
	  }
	  /* anyway copy the pte...*/
	  ptc[i] = *pte;
	  /* ... and increment the page references counter */
	  pmem_set((*pte)>>12);
	}
      } else  // logical allocated
	ptc[i] = flags;
    } else
      ptc[i] = 0;
  }
  return 1;
}

/* copy all threads from current process. it returns the tss
   corrisponding to current thread, for further changes... see the code! */
static tss_t * copyThreads(process_descriptor_t * ddest,
			   process_descriptor_t * dorig,
			   uint32_t * pdc, pid_t pid);

int _linux_syscall_fork() {
  uint32_t i;
  uint32_t * pde, flags;
  uint32_t * pdc, *ptc, *prevPtc = NULL;
  uint32_t *lastPT;
  pid_t new_pid;
  int ret = 0;
  tss_t * mirror;  // this is the new process thread corrisponding to current

  /* the pid first: nothing to undo if there is none */
  if ((new_pid = allocPid()) < 0) return -11;   /* -EAGAIN */
  if ((pdc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;

  pdc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | 
    PF_USER | PF_READWRITE | PF_PRESENT;

  /* copy the shared kernel space */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    pdc[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  /* copy the page dir entries, but not the last one (image for PTs...) */
  for (i = _asm_last_kernel_page_dir_entry_used + 1; i < LAST_PDPT_INDEX; i++) {
    pde = (uint32_t*)__GET_PAGE_DIR_ENTRY(i);
    /* this if should never be PF_LOGICAL_PRESENT because we don't allocate
       a page table logically */
    if (*pde & (PF_PRESENT | PF_LOGICAL_PRESENT)) {   // this PT is allocated
      flags = *pde & 0xFFF;
      if (*pde & PF_PRESENT) {
	if ((ptc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -1;
	pdc[i] = LINEAR_TO_PHYSICAL_ADDRESS(ptc) | flags;
	
	/* copy the page table */
	if (copy_page_table(i, ptc) == -1) return -1;

	/* the kernel aliases of the child's structures are dropped once
	   they are built: the last page table still has to be written */
	if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	prevPtc = ptc;
      } else
	pdc[i] = flags;
    } else
      pdc[i] = 0;
  }

  /* set the PD pointer: now ptc is the last but one PT */
  ptc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(pdc) | PF_PRESENT;
  kmemcpy((void*)lastPT, (void*)pdc, PAGE_SIZE);
  __OS_releasePages(ptc, 1, 0, 0);

  numProcesses++;
  numThreads += processTable[currProcess]->numThreads;

  processTable[new_pid] = 
    (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));

  /* copy the whole structure */
  kmemcpy(processTable[new_pid], 
	  processTable[currProcess],
	  sizeof(process_descriptor_t));

  /* copy the linear space map */
  processTable[new_pid]->lmemmap = 
    __lmt_copyList(processTable[currProcess]->lmemmap);

  /* initialize the channel and port lists */
  listInit(processTable[new_pid]->channelList);
  listInit(processTable[new_pid]->portList);

  /* copy the tsses */
  mirror = 
    copyThreads(processTable[new_pid], processTable[currProcess], 
		pdc, new_pid);

  // TODO: other threads!!!
  readyQueueInsert(mirror);
#if 0
  // insert the threads into the readyQueue
  {
    tss_t * thread = processTable[new_pid]->tss;
    while (thread) {
      readyQueueInsert(thread);
      thread = thread->next;
    }
  }
#endif

  processTable[new_pid]->pid = new_pid;
  processTable[new_pid]->ppid = currProcess;
  TRACE(TRACE_SPAWN, currProcess, new_pid, -1, 0, 0, processTable[new_pid]->name,
	kstrlen(processTable[new_pid]->name));
  processTable[new_pid]->isAlive = 1;
  processTable[new_pid]->exitStatus = 0;
  processTable[new_pid]->reaped = 0;
  processTable[new_pid]->childSem = __OS_sem_allocateSemaphore(0);
  processTable[new_pid]->deadThreads = NULL;   /* the parent's are its own */
  processTable[new_pid]->memFreed = 0;
  processTable[new_pid]->nextZombie = NULL;

  processTable[new_pid]->ptsMirror = (void*)LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  __OS_releasePages(lastPT, 1, 0, 0);
  __OS_releasePages(pdc, 1, 0, 0);
  
  /* copy the registers, except eip and esp */
  asm volatile("movl %%eax, %0":"=m"(mirror->eax));
  asm volatile("movl %%ebx, %0":"=m"(mirror->ebx));
  asm volatile("movl %%ecx, %0":"=m"(mirror->ecx));
  asm volatile("movl %%edx, %0":"=m"(mirror->edx));
  asm volatile("movl %%esi, %0":"=m"(mirror->esi));
  asm volatile("movl %%edi, %0":"=m"(mirror->edi));
  asm volatile("movl %%ebp, %0":"=m"(mirror->ebp));

  asm volatile("movw %%cs, %0":"=m"(mirror->cs));
  asm volatile("movw %%ds, %0":"=m"(mirror->ds));
  asm volatile("movw %%es, %0":"=m"(mirror->es));
  asm volatile("movw %%fs, %0":"=m"(mirror->fs));
  asm volatile("movw %%gs, %0":"=m"(mirror->gs));
  asm volatile("movw %%ss, %0":"=m"(mirror->ss));

  ret = new_pid;
  mirror->justForked = 1;
  
  /* copy eip and esp and call the scheduler */
  mirror->esp0 = currThread->esp0;
  asm volatile (
		"movl $1f, %0\n\t"\
		"movl %%esp, %1\n\t"\
		"call sched\n\t"\
		"1:\t"\
		:"=m"(mirror->eip),\
		"=m"(mirror->esp):);

  /* this process was just forked, restore some register */
  if (currThread->justForked) {
    currThread->justForked = 0;
    /* the child did not come back through switchTo's segment pops: %gs
       still caches the previous thread's descriptor. Reload it, so that its
       TLS (set_thread_area, copied from the parent) is in effect. */
    if (currThread->tls_base || currThread->tls_limit)
      asm volatile("movw %w0, %%gs" :: "r"((GDT_TLS_INDEX << 3) | 3));
    else
      asm volatile("movw %w0, %%gs" :: "r"(GDT_USER_DATA_SEL + 3));
    asm volatile("movl %0, %%ebp"::"m"(currThread->ebp));
  }

  // back from a task switch...
  return ret;
}

static tss_t * copyThreads(process_descriptor_t * ddest,
			   process_descriptor_t * dorig,
			   uint32_t * pdc, pid_t pid) {
  tss_t * orig = processTable[currProcess]->tss;
  tss_t * dest;
  tss_t * prevDest = NULL;
  tss_t * mirror;
  
  /* the first one */
  dest = ddest->tss = (tss_t*)kmalloc(sizeof(tss_t));
  
  while (dest != NULL) {
    kmemcpy((void*)dest, 
	    (void*)orig,
	    sizeof(tss_t));
    dest->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(pdc);
    dest->privSem = __OS_sem_allocateSemaphore(0);
    dest->tid = pid;          /* only the calling thread will run */
    dest->clearTid = NULL;
    dest->prev = prevDest;
    prevDest = dest;
    dest->pid = pid;

    if (orig == currThread) mirror = dest;

    if (orig->next != NULL) {
      orig = orig->next;
      dest->next = (tss_t*)kmalloc(sizeof(tss_t));
      dest = dest->next;
    } else {
      dest = dest->next = NULL;
    }
  }

  return mirror;
}

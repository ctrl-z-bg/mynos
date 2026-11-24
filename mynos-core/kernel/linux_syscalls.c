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
#include "pit.h"
#include "random.h"
#include "softtaskswitch.h"

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

/* times (43): the process's CPU time, all of it counted as user time, in
   Linux's USER_HZ ticks (100 a second; the PIT's are 1000); the
   children's is not kept. Returns the ticks since boot. */
int _linux_syscall_times(struct tms *buf) {
  if (buf) {
    USER(buf, sizeof *buf);
    buf->tms_utime = USER_TICKS(processTable[currProcess]->cpuTicks);
    buf->tms_stime = buf->tms_cutime = buf->tms_cstime = 0;
  }
  return USER_TICKS(timerTicks);
}

/* getrusage (77): the same CPU time; RUSAGE_CHILDREN (-1) gets zero, and
   the other fields (memory, faults, switches) are zero */
struct rusage32 {
  int32_t ru_utime_sec, ru_utime_usec, ru_stime_sec, ru_stime_usec;
  int32_t ru_other[14];
};
int _linux_syscall_getrusage(int who, struct rusage32 * ru) {
  uint32_t t, i;
  USER(ru, sizeof *ru);
  if (who != 0 && who != -1 && who != 1) return -22;   /* EINVAL */
  t = who == -1 ? 0 : processTable[currProcess]->cpuTicks;
  ru->ru_utime_sec = t / PIT_FREQ;
  ru->ru_utime_usec = (t % PIT_FREQ) * (1000000 / PIT_FREQ);
  ru->ru_stime_sec = ru->ru_stime_usec = 0;
  for (i = 0; i < 14; i++) ru->ru_other[i] = 0;
  return 0;
}

/* getuid, getgid, geteuid, getegid and their 32-bit variants: MyNOS has
   no users (doc/decisions/identity-and-permissions.md); everyone is 0 */
int _linux_syscall_getuid() {
  return 0;
}

void _linux_syscalls_trap_TRAP();
/* Linux system calls: the entry, by i386 number, is in arch/i386/entry.c */



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
  USER(req, sizeof *req);
  if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000)
    return -22;
  return sleep_for(clock, flags, req->tv_sec, req->tv_nsec);
}

int _linux_syscall_clock_nanosleep64(uint32_t clock, int flags,
				     struct timespec64 * req,
				     struct timespec64 * rem) {
  USER(req, sizeof *req);
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
  if (pid != 0 && pid != CURRPID) {
    tss_t * t;
    for (t = processTable[currProcess]->tss; t && t->tid != pid; t = t->next) ;
    if (!t) return -1; /* -EPERM */
  }
  if (sig == 0)
    return 0;
  printk("process ");
  print_ulong(CURRPID);
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

/* uname (122): the system's name and version (tools/version.sh) */
struct new_utsname { char f[6][65]; };
int _linux_syscall_uname(struct new_utsname * u) {
  static const char * fields[6] =
    { "MyNOS", "mynos", MYNOS_VERSION, "#1", "i386", "" };
  int i, j;
  USER(u, sizeof *u);
  for (i = 0; i < 6; i++) {
    for (j = 0; fields[i][j] && j < 64; j++) u->f[i][j] = fields[i][j];
    for (; j < 65; j++) u->f[i][j] = 0;
  }
  return 0;
}

/* mremap (163): a mapping is never grown or moved in place; -ENOMEM, and
   musl's realloc allocates anew and copies, as it does on Linux when a
   mapping cannot grow (answered quietly: not an unknown call) */
int _linux_syscall_mremap() {
  return -12;
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
    print_uint(CURRPID);
    printk("): -ENOSYS\n");
  }
  return -38; /* -ENOSYS */
}

void _linux_syscall_exit(int status) {
  /* a normal end is silent: the parent gets the status (waitpid) */
  if (status != 0) {
    printk("process ");
    print_int(CURRPID);
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
      if (!p || p->ppid != CURRPID || p->reaped) continue;
      if (pid > 0 && p->pid != pid) continue;
      children++;
      if (!p->isAlive) {
	/* after waiting: copied, the memory may be gone (another thread) */
	if (status && copy_to_user(status, &p->exitStatus, sizeof *status) < 0)
	  return -14;   /* -EFAULT */
	/* free its memory now (if not done yet), then its descriptor */
	reapZombies();
	pid = p->pid;
	if (p->memFreed)
	  freeProcessDescriptor(pid);
	else
	  p->reaped = 1;   /* the reaper will free it */
	return pid;
      }
    }
    if (!children) return -ECHILD;
    if (options & WNOHANG) return 0;
    /* woken when a child ends, with every other thread of ours that
       waits (each may wait for another child): check again then */
    {
      int k;
      for (k = 0; k < CHILD_WAITERS && self->childWaiting[k]; k++) ;
      if (k < CHILD_WAITERS) {
	self->childWaiting[k] = currThread;
	__OS_sem_P(currThread->privSem);
      } else
	__OS_sem_P(self->childSem);
    }
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
   bytes per call (Linux gives more; a caller asking for more gets a short
   count and asks again, as it must for any read) */
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

/* pause (29): sleeps until a signal; with no signal handlers there is
   none to wake it, so it sleeps for good (Linux returns -EINTR after a
   handler ran: the value is that one, for the record) */
int32_t _linux_syscall_pause() {
  privP();
  return -4;              /* -EINTR */
}

/*
 * The kernel's own file calls serve one read-only file, the OCaml bytecode
 * passed as GRUB module 1: every open() opens it. Files are libmynos's
 * (fileio.c, over the file services), which answers open, read, stat and
 * the rest before the kernel sees them; it passes only the bytecode's name
 * (mynos_bytecode) through, when ocamlrun runs the module. These calls give
 * that file proper semantics (a position, seeks from start/current/end, a
 * size).
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
  long long pos;
  USER(result, sizeof *result);
  pos = bytecode_seek(((long long)offhi << 32) | offlow, whence);
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

/* stat64 describes the file open() would open, the bytecode, whatever
   the path; fstat64 only the descriptor open() returned */
int _linux_syscall_fstat64(int fd, struct stat64 * st) {
  USER(st, sizeof *st);
  if (fd != BYTECODE_FD) return -9;      /* -EBADF */
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
  return CURRPID;
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
  /* the RAM disk is every process's: not to be unmapped (mynos-q5b) */
  if (__OS_touchesRamdisk((uint32_t)start, npages * PAGE_SIZE))
    return -22;
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
    } else if (IS_PAGER_ENTRY(*pte))
      ptc[i] = *pte;   /* the external pager's: the child asks it too */
    else
      ptc[i] = 0;
  }
  return 1;
}

/* the child's only thread: a copy of the calling one */
static tss_t * copyThread(process_descriptor_t * ddest,
			  uint32_t * pdc, pid_t pid);

/* a fork that ran out of memory: the child's address space built so far
   is freed (its page tables, the pages they took or referenced, the
   directory and its mirror); the parent's pages left copy-on-write become
   writable again at their next write, as their only user's */
static int forkFailed(uint32_t * pdc, uint32_t * lastPT, uint32_t * ptc) {
  uint32_t pdFrame = LINEAR_TO_PHYSICAL_ADDRESS(pdc) >> 12;
  uint32_t mirrorFrame = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) >> 12;
  if (ptc) __OS_releasePages(ptc, 1, 0, 0);
  __OS_releasePages(lastPT, 1, 0, 0);
  __OS_releasePages(pdc, 1, 0, 0);
  __OS_freeSpaceFrames(pdFrame, mirrorFrame);
  return -12;                                   /* -ENOMEM */
}

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
  if ((pdc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return -12;
  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) {
    __OS_releasePages(pdc, 1, 1, 0);
    return -12;                                 /* -ENOMEM */
  }
  kbzero(pdc, PAGE_SIZE);   /* a failure frees what the entries name */

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
	if ((ptc = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) {
	  if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	  return forkFailed(pdc, lastPT, NULL);
	}
	kbzero(ptc, PAGE_SIZE);
	pdc[i] = LINEAR_TO_PHYSICAL_ADDRESS(ptc) | flags;
	
	/* copy the page table */
	if (copy_page_table(i, ptc) == -1) {
	  if (prevPtc) __OS_releasePages(prevPtc, 1, 0, 0);
	  return forkFailed(pdc, lastPT, ptc);
	}

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
  ptc[LAST_PDPT_INDEX] = LINEAR_TO_PHYSICAL_ADDRESS(pdc) | PF_READWRITE | PF_PRESENT;
  kmemcpy((void*)lastPT, (void*)pdc, PAGE_SIZE);
  __OS_releasePages(ptc, 1, 0, 0);

  numProcesses++;
  numThreads++;

  processTable[PSLOT(new_pid)] = 
    (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));

  /* copy the whole structure */
  kmemcpy(processTable[PSLOT(new_pid)], 
	  processTable[currProcess],
	  sizeof(process_descriptor_t));

  /* copy the linear space map */
  processTable[PSLOT(new_pid)]->lmemmap = 
    __lmt_copyList(processTable[currProcess]->lmemmap);

  /* initialize the channel and port lists */
  listInit(processTable[PSLOT(new_pid)]->channelList);
  listInit(processTable[PSLOT(new_pid)]->portList);

  /* the child has one thread, a copy of the caller (POSIX: the other
     threads are not in the child) */
  mirror = copyThread(processTable[PSLOT(new_pid)], pdc, new_pid);
  processTable[PSLOT(new_pid)]->numThreads = 1;
  readyQueueInsert(mirror);

  processTable[PSLOT(new_pid)]->pid = new_pid;
  processTable[PSLOT(new_pid)]->ppid = CURRPID;
  TRACE(TRACE_SPAWN, CURRPID, new_pid, -1, 0, 0, processTable[PSLOT(new_pid)]->name,
	kstrlen(processTable[PSLOT(new_pid)]->name));
  processTable[PSLOT(new_pid)]->isAlive = 1;
  processTable[PSLOT(new_pid)]->exitStatus = 0;
  processTable[PSLOT(new_pid)]->cpuTicks = 0;
  processTable[PSLOT(new_pid)]->faultsAlloc = 0;
  processTable[PSLOT(new_pid)]->faultsCow = 0;
  kbzero(processTable[PSLOT(new_pid)]->childWaiting,
	 sizeof processTable[PSLOT(new_pid)]->childWaiting);
  processTable[PSLOT(new_pid)]->reaped = 0;
  processTable[PSLOT(new_pid)]->childSem = __OS_sem_allocateSemaphore(0);
  processTable[PSLOT(new_pid)]->deadThreads = NULL;   /* the parent's are its own */
  processTable[PSLOT(new_pid)]->memFreed = 0;
  processTable[PSLOT(new_pid)]->nextZombie = NULL;

  processTable[PSLOT(new_pid)]->ptsMirror = (void*)LINEAR_TO_PHYSICAL_ADDRESS(lastPT);
  __OS_releasePages(lastPT, 1, 0, 0);
  __OS_releasePages(pdc, 1, 0, 0);
  
  /* copy the registers, except eip and esp */
  ARCH_FORK_SAVE_REGISTERS(mirror);

  ret = new_pid;
  mirror->justForked = 1;
  
  /* copy eip and esp and call the scheduler */
  mirror->esp0 = currThread->esp0;
  ARCH_FORK_SWITCH(mirror);

  /* this process was just forked, restore some register */
  if (currThread->justForked) {
    currThread->justForked = 0;
    /* the child did not come back through switchTo's segment pops: %gs
       still caches the previous thread's descriptor. Reload it, so that its
       TLS (set_thread_area, copied from the parent) is in effect. */
    ARCH_FORK_CHILD_RESUME(currThread);
  }

  // back from a task switch...
  return ret;
}

static tss_t * copyThread(process_descriptor_t * ddest,
			  uint32_t * pdc, pid_t pid) {
  tss_t * dest;

  /* the child goes on with the parent's floating-point state */
  fpu_save(currThread);

  dest = ddest->tss = (tss_t*)kmalloc(sizeof(tss_t));
  kmemcpy((void*)dest, (void*)currThread, sizeof(tss_t));
  dest->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(pdc);
  dest->privSem = __OS_sem_allocateSemaphore(0);
  dest->semHeld = 0;
  dest->tid = pid;          /* the child's first thread: its pid */
  dest->clearTid = NULL;
  dest->queue = NULL;
  dest->timeToWake = 0;
  dest->prev = dest->next = NULL;
  dest->pid = pid;
  return dest;
}

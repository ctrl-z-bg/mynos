/* Stress test of the kernel: many processes, IPC of every size, timers that
   expire together, semaphores, invalid arguments, and a check that the
   memory comes back. Run it as a MyNOS module with its RAM disk (it starts
   copies of itself from there): see tools/run-tests.sh.

     stress [N]                the test, its rounds N times (default 1)
     stress client PORT SIZE   a child: sends SIZE bytes to PORT, checks the
                               reply, exits 0 when it is right
     stress badptr PORT        a child: passes bad pointers to the kernel
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <mynos.h>

static int failures = 0;

static void check(const char * what, int ok) {
  printf("stress: %-44s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

static int repeat = 1;

static unsigned int free_pages(void) {
  mynos_stats_t st;
  mynos_stats(&st);
  return st.freeppages;
}

/* the byte at position i of a message of size n */
static unsigned char pattern(unsigned int n, unsigned int i) {
  return (unsigned char)(i * 7 + n * 13 + (i >> 8));
}

static unsigned int checksum(const unsigned char * p, unsigned int n) {
  unsigned int s = n, i;
  for (i = 0; i < n; i++) s = s * 31 + p[i];
  return s;
}

/* ---- children ---- */

static int client(int port, unsigned int size) {
  unsigned char * buf = malloc(size ? size : 1);
  mynos_msg_t * msg;
  unsigned int i, sum;
  int ch, ok;

  for (i = 0; i < size; i++) buf[i] = pattern(size, i);
  sum = checksum(buf, size);
  ch = mynos_connectToPort(port);
  if (ch < 0) return 10;
  if ((i = mynos_send(ch, buf, size, 0)) < 0) {
    printf("stress: client of %u bytes: send gives %d\n", size, (int)i);
    return 11;
  }
  if (mynos_recv(ch, &msg, 0, 0) < 0) return 12;
  ok = msg->size == sizeof(unsigned int) &&
       *(unsigned int *)msg->start == sum;
  mynos_freeMsg(&msg);
  mynos_freeChannel(ch);
  free(buf);
  return ok ? 0 : 13;
}

/* raw system calls (the library's wrappers would touch the pointers
   first, in user mode) */
#if defined(__aarch64__)
static long native(long n, long a, long b, long c) {
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  __asm__ volatile ("svc #0x90" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
  return x0;
}
static long linux3(long n, long a, long b, long c) {
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x3 __asm__("x3") = 0;
  __asm__ volatile ("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
  return x0;
}
/* Linux's numbers on AArch64 (the generic ones) */
#define NR_clock_gettime 113
#define NR_write 64
#define NR_nanosleep 101
#define NR_wait 260                             /* wait4 */
#define NR_getrandom 278
#define NR_futex 98
#define NR_munmap 215
#elif defined(__x86_64__)
static long native(long n, long a, long b, long c) {
  long ret = n;
  __asm__ volatile ("int $0x90" : "+a"(ret), "+D"(a), "+S"(b), "+d"(c)
                    : : "memory", "r10", "r8");
  return ret;
}
static long linux3(long n, long a, long b, long c) {
  long ret;
  __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a), "S"(b), "d"(c)
                    : "rcx", "r11", "memory");
  return ret;
}
/* Linux's numbers on x86-64 */
#define NR_clock_gettime 228
#define NR_write 1
#define NR_nanosleep 35
#define NR_wait 61                              /* wait4 */
#define NR_getrandom 318
#define NR_futex 202
#define NR_munmap 11
#else
static long native(long n, long a, long b, long c) {
  long ret = n;
  __asm__ volatile ("int $0x90" : "+a"(ret), "+b"(a), "+c"(b), "+d"(c)
                    : : "memory", "esi", "edi");
  return ret;
}
static long linux3(long n, long a, long b, long c) {
  long ret = n;
  __asm__ volatile ("int $0x80" : "+a"(ret), "+b"(a), "+c"(b), "+d"(c)
                    : : "memory");
  return ret;
}
/* Linux's numbers on the i386 */
#define NR_clock_gettime 265
#define NR_write 4
#define NR_nanosleep 162
#define NR_wait 7                               /* waitpid */
#define NR_getrandom 355
#define NR_futex 240
#define NR_munmap 91
#endif

/* bad pointers: the kernel must refuse them (or end this process), never
   fault itself or write into its own memory. Each refused call counts. */
static int badptr(int port) {
  int ch = mynos_connectToPort(port), refused = 0, calls = 0;
  void * kernel = (void *)0x00200000;          /* the kernel's code */
  void * unmapped = (void *)0x7f000000;        /* user space, nothing there */
#define R(e) do { calls++; if ((e) < 0) refused++; \
                  else printf("stress: badptr accepted: %s\n", #e); } while (0)
  if (ch < 0) return 10;
  R(mynos_send(ch, kernel, 100, 0));
  R(mynos_send(ch, unmapped, 100, 0));
  R(mynos_send(ch, unmapped, 4, 0));               /* a short message */
  R(mynos_send(ch, (void *)0xfffff000, 0x2000, 0)); /* wraps around */
  R(mynos_send(ch, (void *)0xffbfd000, 100, 0));   /* the kernel stack */
  R(native(4, ch, (long)kernel, 0));               /* recv into the kernel */
  R(native(4, ch, (long)unmapped, 0));
  R(native(31, (long)kernel, 10, 0));              /* log from the kernel */
  R(native(30, (long)kernel, 4096, 0));            /* spawn the kernel */
  R(native(11, (long)kernel, 0, 0));               /* serviceRegister */
  R(native(12, (long)unmapped, 0, 0));             /* clientRegister */
  R(native(10, (long)"x", 1000, 0));               /* driverRegister irq */
  R(native(100, 300, 0, 0));                       /* enableIrq */
  R(linux3(NR_clock_gettime, 0, (long)kernel, 0));              /* clock_gettime */
  R(linux3(NR_write, 1, (long)kernel, 50));               /* write */
  R(linux3(NR_write, 1, (long)unmapped, 50));
  R(linux3(NR_nanosleep, (long)kernel, 0, 0));              /* nanosleep */
  R(linux3(NR_wait, -1, (long)kernel, 0));               /* waitpid */
  R(linux3(NR_getrandom, (long)kernel, 16, 0));             /* getrandom */
  R(linux3(NR_futex, (long)kernel, 0, 1));              /* futex */
  R(linux3(NR_munmap, (long)kernel, 4096, 0));            /* munmap the kernel */
  native(400, (long)kernel, 0, 0);                 /* stats: no result */
#undef R
  mynos_freeChannel(ch);
  return refused == calls ? 0 : 20;
}

/* ---- permissions (doc/decisions/identity-and-permissions.md) ---- */

static int spawn_child(char ** argv);

/* a child without privileges: no IRQ, no semaphore of another process
   (the parent's, given in argv), no port taken by number; it tells its pid
   to the parent through a connection, whose other end the parent checks */
static int unprivileged(int port, int sem) {
  int ch, pid = getpid(), bad = 0;
  if (mynos_driverRegister("x", 5, NULL, NULL) != MYNOS_ERR_DENY) bad |= 1;
  if (mynos_V(sem) != MYNOS_ERR_DENY) bad |= 2;
  if (mynos_freeSem(sem) != MYNOS_ERR_DENY) bad |= 4;
  if (mynos_allocPortP(1) != MYNOS_ERR_DENY) bad |= 8;
  if (mynos_spawnPriv("stress", NULL, NULL, MYNOS_PRIV_IO) != MYNOS_ERR_DENY)
    bad |= 16;
  /* a name in the registry: ours while we run */
  if (mynos_registryRegister("stress-name") < 0) bad |= 32;
  if ((ch = mynos_connectToPort(port)) < 0) return 100;
  mynos_send(ch, &pid, sizeof pid, 0);
  {
    mynos_msg_t * go;                 /* the parent checks the name first */
    if (mynos_recv(ch, &go, 0, 0) >= 0) mynos_freeMsg(&go);
  }
  mynos_freeChannel(ch);
  return bad;
}

/* port I/O without the privilege: the process ends (protection fault) */
static int unprivileged_io(void) {
#if defined(__aarch64__)
  native(102, 0, 0x70, 0);      /* no ports: the kernel's port I/O call */
#else
  unsigned char v;
  __asm__ volatile ("inb $0x70, %0" : "=a"(v));
#endif
  return 0;                     /* not reached */
}

static int permissions(int port, char * ps) {
  int ok = 1, st, pid, ch, peer, sem = mynos_initSem(1);
  char ss[16];
  char * argv[] = { "stress", "unpriv", ps, ss, NULL };
  char * argv_io[] = { "stress", "unpriv-io", NULL };
  mynos_msg_t * msg;
#define C(what, e) do { if (!(e)) { printf("stress: permissions: %s\n", what); ok = 0; } } while (0)
  snprintf(ss, sizeof ss, "%d", sem);
  pid = spawn_child(argv);
  ch = mynos_listenPort(port);
  peer = mynos_channelPeer(ch);
  C("a connection from the child", ch >= 0 && mynos_recv(ch, &msg, 0, 0) >= 0);
  C("channelPeer names the child", peer == pid && *(int *)msg->start == pid);
  mynos_freeMsg(&msg);
  C("a registered name is its owner's while it runs",
    mynos_registryRegister("stress-name") < 0);
  mynos_send(ch, &ok, sizeof ok, 0);
  /* (it may have ended already, not collected yet: then not ALIVE) */
  C("the child has no privileges",
    mynos_processInfo(pid) >= 0 && (mynos_processInfo(pid) & 0xFF) == 0);
  mynos_freeChannel(ch);
  C("the child was refused everything",
    waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 0);
  if (WIFEXITED(st) && WEXITSTATUS(st)) printf("stress: refusals missing: %x\n", WEXITSTATUS(st));
  C("an ended process is not found by its pid",
    mynos_processInfo(pid) == MYNOS_ERR_INVALID);
  {
    int p = mynos_registryRegister("stress-name");
    C("and its name is free again", p >= 0 && mynos_registryLookUp("stress-name") == p);
  }
  C("this process has the io privilege",
    mynos_processInfo(getpid()) == (MYNOS_PROC_ALIVE | MYNOS_PRIV_IO));
  C("the semaphore is still ours", mynos_P(sem) == 0 && mynos_freeSem(sem) == 0);
  C("the kernel's semaphores are not ours", mynos_V(0) == MYNOS_ERR_DENY);
  pid = spawn_child(argv_io);
  C("port I/O without the privilege ends the process",
    pid >= 0 && waitpid(pid, &st, 0) == pid && WIFSIGNALED(st));
  {
    int pid2 = spawn_child(argv_io);
    C("pids are not reused", pid2 >= 0 && pid2 != pid);
    waitpid(pid2, &st, 0);
  }
#undef C
  return ok;
}

/* ---- a page that goes away while the kernel waits to write into it ---- */

static long native5(long n, long a, long b, long c, long d, long e) {
#if defined(__aarch64__)
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x3 __asm__("x3") = d;
  register long x4 __asm__("x4") = e;
  __asm__ volatile ("svc #0x90" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
                    : "memory");
  return x0;
#else
  long ret = n;
  __asm__ volatile ("int $0x90" : "+a"(ret), "+b"(a), "+c"(b), "+d"(c),
                    "+S"(d), "+D"(e) : : "memory");
  return ret;
#endif
}

/* the child: connect, wait, send a short message */
static int late_sender(int port) {
  int ch = mynos_connectToPort(port), x = 42;
  if (ch < 0) return 1;
  mynos_sleep(300000);
  mynos_send(ch, &x, sizeof x, 0);
  mynos_freeChannel(ch);
  return 0;
}

static int unmap_ch, unmap_result, unmap_done;
static void * unmap_page;
static char unmap_stack[8192];

static void * unmap_receiver(void * arg) {
  (void)arg;
  /* recv (4) with the message's description in unmap_page */
  unmap_result = native5(4, unmap_ch, (long)unmap_page, 0, 0, 0);
  mynos_V(unmap_done);
  return NULL;
}

/* recv waits; meanwhile this thread unmaps the page where the kernel will
   write the message's description: the call fails, the process lives
   (copy_to_user; before, the kernel's fault ended the process) */
static int unmapped_recv(int port, char * ps) {
  char * argv[] = { "stress", "late", ps, NULL };
  int pid, st;
  unmap_page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (unmap_page == MAP_FAILED) return 0;
  ((char *)unmap_page)[0] = 1;            /* allocated */
  unmap_done = mynos_initSem(0);
  pid = spawn_child(argv);
  unmap_ch = mynos_listenPort(port);
  mynos_threadCreate(unmap_receiver, NULL, unmap_stack + sizeof unmap_stack, 0);
  mynos_sleep(100000);                    /* the receiver waits in recv */
  munmap(unmap_page, 4096);
  mynos_P(unmap_done);
  mynos_freeSem(unmap_done);
  mynos_freeChannel(unmap_ch);
  waitpid(pid, &st, 0);
  if (unmap_result != MYNOS_ERR_INVALID)
    printf("stress: recv into an unmapped page: %d\n", unmap_result);
  return unmap_result == MYNOS_ERR_INVALID;
}

/* ---- the test ---- */

static int spawn_child(char ** argv) {
  return mynos_spawn("stress", argv, NULL);
}

/* the parent's side of a client: accept, receive, check the bytes against
   the pattern of the size received (clients come in any order), reply
   with their checksum */
static int serve(int port) {
  mynos_msg_t * msg;
  unsigned int sum, i;
  const unsigned char * p;
  int ch = mynos_listenPort(port), ok = 1;
  if (ch < 0) return 0;
  if (mynos_recv(ch, &msg, 0, 0) < 0) { mynos_freeChannel(ch); return 0; }
  p = msg->start;
  for (i = 0; i < msg->size; i++)
    if (p[i] != pattern(msg->size, i)) { ok = 0; break; }
  sum = checksum(p, msg->size);
  mynos_freeMsg(&msg);
  mynos_send(ch, &sum, sizeof sum, 0);
  mynos_freeChannel(ch);
  return ok;
}

static const unsigned int sizes[] = {
  1, 7, 8, 9, 100, 1000, 4095, 4096, 4097, 8191, 8192, 8193, 12000, 16384,
  20000, 65536
};
#define NSIZES (sizeof sizes / sizeof sizes[0])
#define BATCH 4

/* rounds of BATCH clients at once; returns how many went wrong */
static int ipc_rounds(int port, int rounds) {
  int r, k, bad = 0;
  for (r = 0; r < rounds; r++) {
    int pids[BATCH];
    if (repeat > 1 && r % 25 == 0)
      printf("stress: IPC round %d, %u free pages\n", r, free_pages());
    unsigned int sz[BATCH];
    for (k = 0; k < BATCH; k++) {
      char ps[16], ss[16];
      char * argv[] = { "stress", "client", ps, ss, NULL };
      sz[k] = sizes[(r * BATCH + k) % NSIZES];
      snprintf(ps, sizeof ps, "%d", port);
      snprintf(ss, sizeof ss, "%u", sz[k]);
      pids[k] = spawn_child(argv);
      if (pids[k] < 0) { printf("stress: spawn of a client: %d\n", pids[k]); bad++; }
    }
    /* clients connect in any order: each served message checks itself */
    for (k = 0; k < BATCH; k++)
      if (pids[k] >= 0 && !serve(port)) {
        printf("stress: a message arrived wrong\n");
        bad++;
      }
    for (k = 0; k < BATCH; k++) {
      int st;
      if (pids[k] < 0) continue;
      if (waitpid(pids[k], &st, 0) != pids[k] || !WIFEXITED(st) ||
          WEXITSTATUS(st) != 0) {
        printf("stress: client of %u bytes: status %x\n", sz[k], st);
        bad++;
      }
    }
  }
  return bad;
}

/* ---- timers and threads ---- */

#define NTHREADS 16
static char stacks[NTHREADS][8192];
static int done_sem, count_sem;
static volatile int woken;
static unsigned long delay[NTHREADS];

static void * sleeper(void * arg) {
  int i = (int)arg;
  mynos_sleep(delay[i]);
  mynos_P(count_sem);
  woken++;
  mynos_V(count_sem);
  mynos_V(done_sem);
  return NULL;
}

/* this process's threads, as the kernel counts them (a thread counts
   until it has really ended) */
static unsigned int threads_now(void) {
  unsigned int st[6];
  return mynos_procstat(getpid(), st) == 0 ? st[4] : 0;
}

static int timer_round(int same) {
  int i, ms;
  unsigned int base = threads_now();
  woken = 0;
  for (i = 0; i < NTHREADS; i++) {
    /* the same deadline for all, or three groups of equal ones */
    delay[i] = same ? 30000 : 20000 + (i % 3) * 10000;
    if (mynos_threadCreate(sleeper, (void *)i, stacks[i] + sizeof stacks[i],
                           0) < 0)
      return 0;
  }
  for (i = 0; i < NTHREADS; i++) mynos_P(done_sem);
  /* the threads ended, not only counted: each said so (done_sem) before
     returning on its stack, which the next round gives a new thread. On
     several processors a thread was still returning while the next round
     wrote its stack's first frame: it returned to 0xC (mynos-4dz) */
  for (ms = 0; ms < 2000 && threads_now() > base; ms++) mynos_sleep(1000);
  return woken == NTHREADS;
}

static int ping, pong;
static volatile int pings;
static char pstack[8192];

static void * ponger(void * arg) {
  int n = (int)arg, i;
  for (i = 0; i < n; i++) { mynos_P(ping); pings++; mynos_V(pong); }
  return NULL;
}

static int pingpong(int n) {
  int i, ms;
  unsigned int base = threads_now();
  pings = 0;
  ping = mynos_initSem(0);
  pong = mynos_initSem(0);
  mynos_threadCreate(ponger, (void *)n, pstack + sizeof pstack, 0);
  for (i = 0; i < n; i++) { mynos_V(ping); mynos_P(pong); }
  /* (ponger ended, not only done: its stack is the next one's) */
  for (ms = 0; ms < 2000 && threads_now() > base; ms++) mynos_sleep(1000);
  mynos_freeSem(ping);
  mynos_freeSem(pong);
  return pings == n;
}

/* ---- invalid arguments ---- */


static int invalid_args(void) {
  int ok = 1;
#define T(e) do { int r_ = (e) < 0; if (!r_) printf("stress: not refused: %s\n", #e); ok &= r_; } while (0)
  mynos_msg_t * msg;
  char c = 0;
  T(mynos_freeChannel(-1));
  T(mynos_freeChannel(99999));
  T(mynos_send(-5, &c, 1, 0));
  T(mynos_send(77777, &c, 1, 0));
  T(mynos_recv(12345, &msg, 0, 1));
  T(mynos_recv(-2, &msg, 0, 1));
  T(mynos_P(-1));
  T(mynos_V(100000));
  T(mynos_freeSem(-3));
  T(mynos_freeSem(55555));
  T(mynos_connectToPort(-1));
  T(mynos_connectToPort(5000));
  T(mynos_listenPort(9999));
  T(mynos_listenPort(-9));
  T(mynos_freePort(-2));
  T(mynos_freePort(4000));
  T(mynos_changePortOwner(-1, 5));
  T(mynos_changePortOwner(3000, 5));
  T(mynos_spawn("no-such-program", NULL, NULL));
  return ok;
#undef T
}

/* native system call numbers that do not exist */
static int unknown_syscalls(void) {
  static const long nums[] = { 0, 1, 2, 14, 19, 26, 29, 32, 99, 102, 199,
                               203, 299, 301, 399, 401, 1000, 65536, -1 };
  unsigned int i;
  for (i = 0; i < sizeof nums / sizeof nums[0]; i++)
    native(nums[i], 0x12345678, -1, 0);
  return 1;      /* surviving is the check */
}

static int test(void) {
  unsigned int base, after;
  int port, i, st, pid;
  char ps[16];

  done_sem = mynos_initSem(0);
  count_sem = mynos_initSem(1);
  port = mynos_allocPort();
  check("allocPort", port >= 0);
  snprintf(ps, sizeof ps, "%d", port);

  /* a first round of everything: the kernel heap and the free lists grow
     to their working size */
  ipc_rounds(port, NSIZES / BATCH);
  timer_round(1);
  pingpong(10);
  base = free_pages();

  check("IPC: 120 clients, 1 B to 64 KB, 4 at a time",
        ipc_rounds(port, 30 * repeat) == 0);
  {
    int ok = 1;
    for (i = 0; i < 20 * repeat; i++) ok &= timer_round(i & 1);
    check("timers: 20 x 16 threads, equal deadlines", ok);
  }
  check("semaphores: 5000 ping-pongs between threads",
        pingpong(5000 * repeat));
  check("invalid arguments are refused", invalid_args());
  check("unknown system calls are refused", unknown_syscalls());
  {
    char * argv[] = { "stress", "badptr", ps, NULL };
    pid = spawn_child(argv);
    /* the child sends bad pointers; serve its connection with a timeout */
    {
      int ch = mynos_listenPort(port);
      mynos_msg_t * msg;
      for (i = 0; i < 4; i++)
        if (mynos_recv(ch, &msg, 0, 50) >= 0) mynos_freeMsg(&msg);
      mynos_freeChannel(ch);
    }
    check("bad pointers are refused, the kernel lives",
          pid >= 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) &&
          WEXITSTATUS(st) == 0);
  }
  check("permissions: privileges, owners, channelPeer",
        permissions(port, ps));
  check("a page unmapped while recv waits: an error, not the end",
        unmapped_recv(port, ps));
  check("the system still starts programs after it",
        ipc_rounds(port, 2) == 0);

  after = free_pages();
  printf("stress: free pages %u before, %u after\n", base, after);
  check("memory comes back (within 4 pages)", after + 4 >= base);
  mynos_freePort(port);
  return failures;
}

int main(int argc, char ** argv) {
  if (argc == 4 && !strcmp(argv[1], "client"))
    return client(atoi(argv[2]), (unsigned int)atoi(argv[3]));
  if (argc == 3 && !strcmp(argv[1], "badptr"))
    return badptr(atoi(argv[2]));
  if (argc == 4 && !strcmp(argv[1], "unpriv"))
    return unprivileged(atoi(argv[2]), atoi(argv[3]));
  if (argc == 3 && !strcmp(argv[1], "late"))
    return late_sender(atoi(argv[2]));
  if (argc == 2 && !strcmp(argv[1], "unpriv-io"))
    return unprivileged_io();
  if (argc == 2 && atoi(argv[1]) > 0) repeat = atoi(argv[1]);
  if (test() == 0) printf("stress: all checks passed\n");
  else printf("stress: %d checks failed\n", failures);
  return 0;
}

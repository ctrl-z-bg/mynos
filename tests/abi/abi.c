/* Checks for the system call fixes made while porting to gcc 14.
   Run it as a MyNOS module (see tools/run-tests.sh). */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <mynos.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <sys/auxv.h>

static int failures = 0;

/* a new thread's TLS starts as the program's image says: zeros here. The
   kernel's auxiliary vector was empty, musl found no PT_TLS and took the
   TLS block as empty: a new thread's TLS lay on its stack's top, where
   pthread_create writes (Gfx's clip, read as on, drew nothing) */
static __thread long tls_zeros[16];
static void * tls_reader(void * unused) {
  long n = 0;
  int i;
  for (i = 0; i < 16; i++) if (tls_zeros[i]) n++;
  return (void *)n;
}

/* raw Linux system call with no arguments */
#if defined(__aarch64__)
static long linux_syscall0(long n) {
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0");
  __asm__ volatile ("svc #0" : "=r"(x0) : "r"(x8) : "memory");
  return x0;
}
/* raw Linux system call with three arguments */
static long linux_syscall3(long n, long a, long b, long c) {
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  __asm__ volatile ("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
  return x0;
}
#define NR_gettid 178
#define NR_uname 160
#elif defined(__x86_64__)
static long linux_syscall0(long n) {
  long ret;
  __asm__ volatile ("syscall" : "=a"(ret) : "a"(n) : "rcx", "r11", "memory");
  return ret;
}
#define NR_gettid 186
#define NR_uname 63
#else
static long linux_syscall0(long n) {
  long ret = n;
  __asm__ volatile ("int $0x80" : "+a"(ret) : : "memory");
  return ret;
}
#define NR_gettid 224
#define NR_uname 122
#endif

static void check(const char * what, int ok) {
  printf("abi: %-40s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

/* a long message's pages are copy-on-write in the sender and the
   receiver: a write by the kernel into the sender's buffer (a system call
   that returns a value there) must not reach the message (mynos-bvz) */
static char cow_buf[8192] __attribute__((aligned(4096)));
static int cow_port, cow_sem, cow_ok = -1;

/* a message larger than the receiver's free linear space is refused, not
   mapped into the kernel's memory (mynos-py9); the i386 only, below */
#if !defined(__x86_64__) && !defined(__aarch64__)
static int big_port, big_sem;

static void * big_listener(void * unused) {
  int ch = mynos_listenPort(big_port);
  mynos_P(big_sem);
  if (ch >= 0) mynos_freeChannel(ch);
  return NULL;
}
#endif

/* a thread waiting in recv is woken when the other end is freed
   (mynos-3bb) */
static int wake_port, wake_result = 1, wake_done;

static void * wake_waiter(void * unused) {
  mynos_msg_t * msg;
  int ch = mynos_listenPort(wake_port);
  wake_result = mynos_recv(ch, &msg, 0, 0);      /* no timeout */
  mynos_freeChannel(ch);
  wake_done = 1;
  return NULL;
}

/* a live connector, after one that ended in the queue (mynos-blv); it
   keeps its end until the listener has looked at the channel (on several
   processors it would free it at once) */
static int queue_port, queue_sem;

static void * queue_connector(void * unused) {
  int ch = mynos_connectToPort(queue_port);
  mynos_P(queue_sem);
  if (ch >= 0) mynos_freeChannel(ch);
  return NULL;
}

static void * cow_receiver(void * unused) {
  mynos_msg_t * msg;
  int ch = mynos_listenPort(cow_port), i;
  if (ch < 0 || mynos_recv(ch, &msg, 0, 0) < 0) return NULL;
  mynos_P(cow_sem);                       /* the sender has written */
  cow_ok = msg->size == sizeof cow_buf;
  for (i = 0; i < (int)sizeof cow_buf; i++)
    if (((char *)msg->start)[i] != 'x') cow_ok = 0;
  mynos_freeMsg(&msg);
  mynos_freeChannel(ch);
  return NULL;
}


/* the external pager (mynos-vzp): this program is its own pager, in a
   thread; the pages it gives hold their token in the first word, and a
   letter of it in the rest */
#define FAIL_TOKEN 500          /* answered with no page */
#define SLOW_TOKEN 300          /* answered after 200 ms */
static volatile int pager_stop, pager_served;
static int pager_sem;
/* a page taken back (evicted), given again as it was */
static unsigned char saved_page[4096];
static volatile unsigned saved_token = 0xFFFFFFFF;

static void * pager_thread(void * unused) {
  char * page = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  mynos_pager_fault_t f;
  while (1) {
    mynos_P(pager_sem);
    if (pager_stop) break;
    while (mynos_pagerNext(&f) == 1) {
      pager_served++;
      if (f.token == FAIL_TOKEN) { mynos_pagerSupply(f.pid, (void *)f.addr, NULL); continue; }
      if (f.token == saved_token) {
        memcpy(page, saved_page, 4096);
        mynos_pagerSupply(f.pid, (void *)f.addr, page);
        continue;
      }
      if (f.token == SLOW_TOKEN) mynos_sleep(200000);
      memset(page, 'A' + f.token % 26, 4096);
      *(unsigned *)page = f.token;
      mynos_pagerSupply(f.pid, (void *)f.addr, page);
    }
  }
  return NULL;
}

static volatile unsigned slow_seen[2];
static char * slow_region;
static void * slow_reader(void * i) {
  slow_seen[(long)i] = *(volatile unsigned *)slow_region;
  return NULL;
}

/* a page's first word, read in a child: its exit status, 255 if killed */
static int child_reads(volatile unsigned * at, unsigned * value) {
  int st = 0;
  pid_t pid = fork();
  if (pid == 0) _exit(*at == *value ? 0 : 1);
  waitpid(pid, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

static void pager_checks(void) {
  char * r, * w;
  pthread_t t, s1, s2;
  int st, served;
  unsigned v;

  /* the pager ends while a process waits for its page: that process ends
     (C waits for a page of a region that P, the pager, gives it) */
  {
    int port1 = mynos_allocPort(), port2 = mynos_allocPort(), ch1, ch2;
    pid_t c, p;
    mynos_msg_t * m;
    if ((c = fork()) == 0) {
      int ch = mynos_connectToPort(port2);
      volatile char * at;
      if (mynos_recv(ch, &m, 0, 0) < 0) _exit(2);
      at = *(char **)m->start;
      (void)*at;                        /* waits; the pager never answers */
      _exit(0);
    }
    if ((p = fork()) == 0) {
      int ch = mynos_connectToPort(port1);
      char * at;
      if (mynos_pagerRegister() < 0) _exit(2);
      at = mynos_pagerRegion(c, 1, 900, 0);
      mynos_send(ch, &at, sizeof at, 0);
      mynos_sleep(300000);              /* C is waiting by now */
      _exit(at ? 0 : 3);
    }
    ch1 = mynos_listenPort(port1);
    ch2 = mynos_listenPort(port2);
    if (mynos_recv(ch1, &m, 0, 0) >= 0) {
      mynos_send(ch2, m->start, m->size, 0);
      mynos_freeMsg(&m);
    }
    waitpid(c, &st, 0);
    check("pager: its end ends who waits for it", WIFSIGNALED(st));
    waitpid(p, &st, 0);
    check("pager: a region of another process", WIFEXITED(st) && WEXITSTATUS(st) == 0);
    mynos_freeChannel(ch1); mynos_freeChannel(ch2);
    mynos_freePort(port1); mynos_freePort(port2);
  }

  pager_sem = mynos_pagerRegister();
  check("pager: register", pager_sem >= 0);
  if (pager_sem < 0) return;
  pthread_create(&t, NULL, pager_thread, NULL);

  r = mynos_pagerRegion(getpid(), 4, 100, 0);
  check("pager: a region", r != NULL);
  if (r == NULL) return;
  v = *(volatile unsigned *)(r + 2 * 4096);
  check("pager: a page given at its first use",
        v == 102 && r[2 * 4096 + 100] == 'A' + 102 % 26 && pager_served == 1);
  v = *(volatile unsigned *)(r + 2 * 4096 + 8);
  check("pager: once given, no more faults", pager_served == 1);
  v = 103;
  check("pager: a child asks too (fork keeps the region)",
        child_reads((volatile unsigned *)(r + 3 * 4096), &v) == 0 && pager_served == 2);
  {
    pid_t pid = fork();
    if (pid == 0) { r[0] = 1; _exit(0); }          /* read-only */
    waitpid(pid, &st, 0);
    check("pager: a write to a read-only region ends the process",
          WIFSIGNALED(st) && pager_served == 2);
  }
  {
    char * f = mynos_pagerRegion(getpid(), 1, FAIL_TOKEN, 0);
    v = FAIL_TOKEN;
    check("pager: no page given ends the process",
          f && child_reads((volatile unsigned *)f, &v) == 255);
  }
  w = mynos_pagerRegion(getpid(), 2, 200, 1);
  if (w) w[4096 + 5] = 'z';
  check("pager: a writable region", w && *(unsigned *)(w + 4096) == 201 &&
        w[4096 + 5] == 'z' && w[4096 + 6] == 'A' + 201 % 26);
  slow_region = mynos_pagerRegion(getpid(), 1, SLOW_TOKEN, 0);
  served = pager_served;
  pthread_create(&s1, NULL, slow_reader, (void *)0);
  pthread_create(&s2, NULL, slow_reader, (void *)1);
  pthread_join(s1, NULL); pthread_join(s2, NULL);
  check("pager: two threads, one page asked once",
        slow_seen[0] == SLOW_TOKEN && slow_seen[1] == SLOW_TOKEN && pager_served == served + 1);
  {
    pid_t pid = fork();
    if (pid == 0) _exit(mynos_pagerRegister() == MYNOS_ERR_BUSY ? 0 : 1);
    waitpid(pid, &st, 0);
    check("pager: one at a time", WIFEXITED(st) && WEXITSTATUS(st) == 0);
  }
  check("pager: munmap a region", munmap(r, 4 * 4096) == 0);

  /* a page used, written, seen (query), copied, taken back (evict) and
     given again as it was: a child's, since the pager does not look at
     its own pages */
  {
    int port = mynos_allocPort(), ch, q1, q2, q3, q4, cp, ev;
    pid_t c;
    mynos_msg_t * m;
    char * at;
    char * b1 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    char * b2 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if ((c = fork()) == 0) {
      int k = mynos_connectToPort(port);
      char * p;
      if (mynos_recv(k, &m, 0, 0) < 0) _exit(2);
      p = *(char **)m->start;
      mynos_freeMsg(&m);
      strcpy(p + 10, "written");            /* a fault, the page given, written */
      mynos_send(k, "w", 1, 0);
      if (mynos_recv(k, &m, 0, 0) < 0) _exit(3);   /* taken back meanwhile */
      mynos_freeMsg(&m);
      _exit(strcmp(p + 10, "written") == 0 && *(unsigned *)p == 700 ? 0 : 1);
    }
    ch = mynos_listenPort(port);
    at = mynos_pagerRegion(c, 1, 700, 1);
    mynos_send(ch, &at, sizeof at, 0);
    if (mynos_recv(ch, &m, 0, 0) >= 0) mynos_freeMsg(&m);
    q1 = mynos_pagerQuery(c, at);
    q2 = mynos_pagerQuery(c, at);
    cp = mynos_pagerCopy(c, at, b1);
    q3 = mynos_pagerQuery(c, at);
    memcpy(saved_page, b1, 4096);
    saved_token = 700;
    ev = mynos_pagerEvict(c, at, b2, 700, 1);
    q4 = mynos_pagerQuery(c, at);
    check("pager: query: there, used, written", q1 == 7);
    check("pager: query again: its use forgotten", q2 == 5);
    check("pager: copy: the page, its writes forgotten",
          cp == 0 && strcmp(b1 + 10, "written") == 0 && q3 == 1);
    check("pager: evict: taken back, the frame ours",
          ev == 0 && strcmp(b2 + 10, "written") == 0 && q4 == 0);
    mynos_send(ch, "g", 1, 0);
    waitpid(c, &st, 0);
    check("pager: given again as it was", WIFEXITED(st) && WEXITSTATUS(st) == 0);
    check("pager: not its own pages", mynos_pagerQuery(getpid(), b1) == 0);
    mynos_freeChannel(ch);
    mynos_freePort(port);
  }
  pager_stop = 1;
  mynos_V(pager_sem);
  pthread_join(t, NULL);
}


/* two threads, each waiting for a child of its own: the end of one child
   must wake its thread, whoever waits longer (a Studio's agent waited for
   a program that asked Studio for a build, whose service thread waited
   for ocamlc: a lost wakeup, both for ever) */
static pid_t long_child;
static void * wait_long(void * unused) {
  int st;
  waitpid(long_child, &st, 0);
  return NULL;
}

static void wait_checks(void) {
  pthread_t t;
  pid_t quick;
  int st;
  struct timespec a, b;
  long ms;
  if ((long_child = fork()) == 0) { mynos_sleep(1500000); _exit(0); }
  pthread_create(&t, NULL, wait_long, NULL);
  mynos_sleep(100000);                    /* that thread waits first */
  if ((quick = fork()) == 0) { mynos_sleep(100000); _exit(0); }
  clock_gettime(CLOCK_MONOTONIC, &a);
  waitpid(quick, &st, 0);
  clock_gettime(CLOCK_MONOTONIC, &b);
  ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000;
  printf("abi: the quick child waited for %ld ms\n", ms);
  check("two threads waiting for two children: each is woken", ms < 1000);
  pthread_join(t, NULL);
}

/* The direction flag (2026-11-24): a program may set DF (std) and be
   interrupted, or call the kernel, with it set; the kernel's string copies
   (rep movs) need it clear. Before every entry did cld, the timer's switch
   copied a TLS descriptor backwards over the user data segment's, and the
   next process to load 0x23 faulted in the kernel (NetSurf on Slashdot). */
#if defined(__i386__) || defined(__x86_64__)
static volatile int df_stop;

/* spin with DF set, in assembly only (C code may not run with DF = 1) */
static void df_spin(void) {
  __asm__ volatile("std");
  while (!df_stop) __asm__ volatile("pause");
  __asm__ volatile("cld");
}

static void * df_spinner(void * a) { (void)a; df_spin(); return NULL; }

static void direction_flag_checks(void) {
  struct utsname u1, u2;
  struct timespec t0, t1;
  pthread_t t;
  int r;
  uname(&u1);
  memset(&u2, 0, sizeof u2);
  /* the system call itself with DF set: the kernel copies the names */
#ifdef __x86_64__
  __asm__ volatile("std\n\tsyscall\n\tcld" : "=a"(r) : "a"(NR_uname), "D"(&u2) : "rcx", "r11", "memory");
#else
  __asm__ volatile("std\n\tint $0x80\n\tcld" : "=a"(r) : "a"(NR_uname), "b"(&u2) : "memory");
#endif
  check("DF set: a system call's copies go forward",
        r == 0 && strcmp(u1.sysname, u2.sysname) == 0 && strcmp(u1.release, u2.release) == 0);
  /* two threads switched by the timer with DF set, for 300 ms */
  df_stop = 0;
  pthread_create(&t, NULL, df_spinner, NULL);
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if ((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000 > 300) break;
    __asm__ volatile("std\n\tpause\n\tpause\n\tcld");
  }
  df_stop = 1;
  pthread_join(t, NULL);
  /* a corrupt user data descriptor faults the next load of 0x23: fork
     and wait, which switch through other processes and back */
  r = fork();
  if (r == 0) _exit(7);
  {
    int st = 0;
    waitpid(r, &st, 0);
    check("DF set across timer switches: the system goes on",
          WIFEXITED(st) && WEXITSTATUS(st) == 7);
  }
}

#endif

/* thread ids (2026-11-24): mynos_threadSelf is gettid, in the first
   thread (the pid) and in another; fork's child has one thread, the
   caller's copy, however many the parent has */
static int tid_sem;
static volatile int tid_seen, tid_gettid;
static void * tid_thread(void * a) {
  (void)a;
  tid_seen = mynos_threadSelf();
  tid_gettid = (int)linux_syscall0(NR_gettid);
  mynos_P(tid_sem);                       /* alive while the parent forks */
  return NULL;
}

static void thread_id_checks(void) {
  pthread_t t;
  unsigned int ps[6];
  int st = 0;
  pid_t c;
  check("threadSelf: the first thread's is the pid",
        mynos_threadSelf() == getpid() &&
        mynos_threadSelf() == (int)linux_syscall0(NR_gettid));
  tid_sem = mynos_initSem(0);
  pthread_create(&t, NULL, tid_thread, NULL);
  while (!tid_seen) mynos_sleep(10000);
  check("threadSelf: another thread's is its gettid",
        tid_seen == tid_gettid && tid_seen != getpid());
  if ((c = fork()) == 0) {
    /* procstat's fifth word: the threads of the process */
    int n = mynos_procstat(getpid(), ps) == 0 ? (int)ps[4] : -1;
    _exit(n == 1 && mynos_threadSelf() == getpid() ? 0 : 1);
  }
  waitpid(c, &st, 0);
  check("fork: the child has one thread, the caller's",
        WIFEXITED(st) && WEXITSTATUS(st) == 0);
  mynos_V(tid_sem);
  pthread_join(t, NULL);
  mynos_freeSem(tid_sem);
}

int main(int argc, char ** argv) {
  long r;
  int sem;

  /* initial stack */
  /* the module's command line (tools/run-tests.sh: "tests/abi/abi one
     two") is its argv */
  check("argc/argv from the kernel",
        argc == 3 && argv[0] != NULL && !strcmp(argv[1], "one") &&
        !strcmp(argv[2], "two") && argv[3] == NULL);

  /* unknown Linux syscall: -ENOSYS, not a kernel panic */
  r = linux_syscall0(400);
  check("unknown Linux syscall gives -ENOSYS", r == -ENOSYS);

  {
    pthread_t t;
    void * nonzero = (void *)-1;
    int i;
    for (i = 0; i < 16; i++) tls_zeros[i] = 0x5A5A;
    check("the auxiliary vector: the program's headers, random bytes",
          getauxval(AT_PHDR) != 0 && getauxval(AT_PHNUM) != 0 && getauxval(AT_RANDOM) != 0);
    if (pthread_create(&t, NULL, tls_reader, NULL) == 0) pthread_join(t, &nonzero);
    check("a new thread's TLS starts at zero", nonzero == NULL);
  }

  /* TLS: errno lives in thread-local storage */
  errno = 1234;
  check("errno (TLS) is writable", errno == 1234);

  /* semaphores: freeSem has its own syscall number */
  sem = mynos_initSem(1);
  check("initSem", sem >= 0);
  check("freeSem", mynos_freeSem(sem) == 0);

  /* clocks and sleeping */
  {
    struct timespec t0, t1, rt, d = { 0, 200000000 };
    long ms;
    clock_gettime(CLOCK_REALTIME, &rt);
    check("realtime clock is after 2020", rt.tv_sec > 1577836800);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    nanosleep(&d, NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    printf("abi: nanosleep(200ms) took %ld ms\n", ms);
    check("nanosleep(200ms) sleeps 200..400 ms", ms >= 200 && ms < 400);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    mynos_sleep(100000);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    check("mynos_sleep(100ms) sleeps 100..300 ms", ms >= 100 && ms < 300);
  }

  /* pointers into the kernel are refused (-EFAULT), never followed
     (mynos-3po): the kernel is linked at 2 MB */
  {
    void * kernel = (void *)0x200000;
    long r;
#if defined(__aarch64__)
    r = linux_syscall3(101 /* nanosleep */, (long)kernel, 0, 0);
    check("nanosleep refuses a request in the kernel", r == -14);
    r = linux_syscall3(115 /* clock_nanosleep */, CLOCK_MONOTONIC, 0, (long)kernel);
    check("clock_nanosleep refuses a request in the kernel", r == -14);
#elif defined(__x86_64__)
    asm volatile("syscall" : "=a"(r)
                 : "a"(35 /* nanosleep */), "D"(kernel), "S"(0) : "rcx", "r11", "memory");
    check("nanosleep refuses a request in the kernel", r == -14);
    asm volatile("syscall" : "=a"(r)
                 : "a"(230 /* clock_nanosleep */), "D"(CLOCK_MONOTONIC), "S"(0), "d"(kernel)
                 : "rcx", "r11", "memory");
    check("clock_nanosleep refuses a request in the kernel", r == -14);
#else
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(140), "b"(0), "c"(0), "d"(0), "S"(kernel), "D"(0) : "memory");
    check("_llseek refuses a result pointer into the kernel", r == -14);
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(267), "b"(CLOCK_MONOTONIC), "c"(0), "d"(kernel), "S"(0) : "memory");
    check("clock_nanosleep refuses a request in the kernel", r == -14);
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(407), "b"(CLOCK_MONOTONIC), "c"(0), "d"(kernel), "S"(0) : "memory");
    check("clock_nanosleep (time64) refuses a request in the kernel", r == -14);
#endif
  }

  {
    pthread_t t;
    int ch;
    memset(cow_buf, 'x', sizeof cow_buf);
    cow_port = mynos_allocPort();
    cow_sem = mynos_initSem(0);
    pthread_create(&t, NULL, cow_receiver, NULL);
    ch = mynos_connectToPort(cow_port);
    mynos_send(ch, cow_buf, sizeof cow_buf, 0);
    clock_gettime(CLOCK_REALTIME, (struct timespec *)cow_buf);  /* the kernel writes */
    mynos_V(cow_sem);
    pthread_join(t, NULL);
    check("a kernel write keeps a sent message intact", cow_ok == 1);
    check("and reaches the sender's own copy", cow_buf[0] != 'x' || cow_buf[1] != 'x');
    mynos_freeChannel(ch);
  }

#if !defined(__x86_64__) && !defined(__aarch64__)
  /* (the i386 only: its 3 GB of user space are filled with 64 MB
     reservations; x86-64's 512 GB are not, and the page tables of a
     try would fill a small machine's memory) */
  {
    enum { CHUNK = 64 << 20, MAXCHUNKS = 64 };
    void * chunk[MAXCHUNKS];
    int n = 0, ch, r, i;
    pthread_t t;
    big_port = mynos_allocPort();
    big_sem = mynos_initSem(0);
    pthread_create(&t, NULL, big_listener, NULL);
    ch = mynos_connectToPort(big_port);
    /* reserve the whole linear space (pages are taken on use: this costs
       only page tables), then give 64 MB back */
    while (n < MAXCHUNKS) {
      void * p = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      if (p == MAP_FAILED) break;
      chunk[n++] = p;
    }
    munmap(chunk[--n], CHUNK);
    r = mynos_send(ch, chunk[0], 2 * CHUNK, MYNOS_IPC_NONBLOCK);
    check("a message larger than the free space is refused", n > 2 && r < 0);
    mynos_V(big_sem);
    pthread_join(t, NULL);
    for (i = 0; i < n; i++) munmap(chunk[i], CHUNK);
    mynos_freeChannel(ch);
    check("and the system goes on", getpid() > 0);
  }
#endif

  /* the RAM disk's pages (MYNOS_RAMDISK up, when there is one) are every
     process's: munmap refuses them (mynos-q5b) */
  check("munmap refuses the RAM disk",
        munmap((void *)MYNOS_RAMDISK, 4096) == -1 && errno == EINVAL);

  /* the last page directory entry of the kernel's gigabyte (0x3FC00000)
     is empty: it used to point at physical page 0 with the user bit, and
     the page fault handler saves EAX there, so a program could map any
     frame for itself (mynos-vm8). A child tries; it must be ended. */
  {
    int st = 0;
    pid_t pid = fork();
    if (pid == 0) {
      volatile char * fresh = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      /* EAX = 7 (frame 0, present, writable, user) at a page fault the
         kernel resolves (a fresh page, allocated on use) */
#if defined(__i386__) || defined(__x86_64__)
      asm volatile("movl $7, %%eax\n\tmovb $1, (%0)" :: "r"(fresh) : "eax", "memory");
#else
      *fresh = 1;
#endif
      (void)*(volatile int *)0x3FC00000;
      _exit(0);
    }
    waitpid(pid, &st, 0);
    check("no user mapping below 1 GB", pid > 0 && WIFSIGNALED(st));
  }

  {
    pthread_t t;
    int ch, i;
    wake_port = mynos_allocPort();
    pthread_create(&t, NULL, wake_waiter, NULL);
    ch = mynos_connectToPort(wake_port);
    mynos_sleep(100000);                 /* the waiter is in recv */
    mynos_freeChannel(ch);
    for (i = 0; i < 20 && !wake_done; i++) mynos_sleep(100000);
    check("recv is woken when the other end is freed",
          wake_done && wake_result == MYNOS_ERR_BROKEN);
    if (wake_done) pthread_join(t, NULL);
  }

  {
    pthread_t t;
    int st, ch;
    pid_t child;
    queue_port = mynos_allocPort();
    queue_sem = mynos_initSem(0);
    child = fork();
    if (child == 0) {                    /* queued, never listened to */
      mynos_connectToPort(queue_port);
      _exit(0);
    }
    mynos_sleep(200000);
    mynos_kill(child);
    waitpid(child, &st, 0);
    pthread_create(&t, NULL, queue_connector, NULL);
    ch = mynos_listenPort(queue_port);
    check("listen skips a connector that has ended",
          ch >= 0 && mynos_channelPeer(ch) == getpid());
    mynos_V(queue_sem);
    if (ch >= 0) mynos_freeChannel(ch);
    pthread_join(t, NULL);
    mynos_freeSem(queue_sem);
  }

  /* one recording at a time, its starter's (mynos-kwe) */
  {
    unsigned w[9];
    char ev[MYNOS_TRACE_EVENT_SIZE];
    int st = 0;
    pid_t child;
    mynos_trace(MYNOS_TRACE_FREE, NULL, 0);          /* none left over */
    check("start a recording", mynos_trace(MYNOS_TRACE_START, NULL, 0) == 0);
    if ((child = fork()) == 0) {
      int bits = 0;
      if (mynos_trace(MYNOS_TRACE_START, NULL, 0) == MYNOS_ERR_BUSY) bits |= 1;
      if (mynos_trace(MYNOS_TRACE_STOP, NULL, 0) == MYNOS_ERR_DENY) bits |= 2;
      if (mynos_trace(MYNOS_TRACE_READ, ev, 1) == MYNOS_ERR_DENY) bits |= 4;
      if (mynos_trace(MYNOS_TRACE_FREE, NULL, 0) == MYNOS_ERR_DENY) bits |= 8;
      _exit(bits);
    }
    waitpid(child, &st, 0);
    check("another process may not start, stop, read or free it",
          WIFEXITED(st) && WEXITSTATUS(st) == 15);
    check("and the recording goes on",
          mynos_trace(MYNOS_TRACE_INFO, w, 0) == 0 && w[0] == 1);
    mynos_trace(MYNOS_TRACE_STOP, NULL, 0);
    mynos_trace(MYNOS_TRACE_FREE, NULL, 0);
    if ((child = fork()) == 0) {                      /* starts, never frees */
      mynos_trace(MYNOS_TRACE_START, NULL, 0);
      _exit(0);
    }
    waitpid(child, &st, 0);
    check("a recording whose owner ended is free to take",
          mynos_trace(MYNOS_TRACE_START, NULL, 0) == 0);
    mynos_trace(MYNOS_TRACE_STOP, NULL, 0);
    mynos_trace(MYNOS_TRACE_FREE, NULL, 0);
  }

  wait_checks();
  pager_checks();
#if defined(__i386__) || defined(__x86_64__)
  direction_flag_checks();             /* x86's direction flag */
#endif
  thread_id_checks();

  printf("abi: %s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
  return failures;
}

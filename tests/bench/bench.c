/* Measures for the external pager's decision (mynos-0ho, phase 0 of
   mynos-vzp): what a page fault costs as the kernel resolves it today, and
   what the pieces of a fault sent to a pager in user space would cost (a
   system call, a switch between threads, an IPC round trip between
   processes, a page carried by a message, a page read from a file).

   bench [FILE...]   the times in processor cycles (rdtsc) and in
                     microseconds; with FILEs, 4 KB reads from each.
   Each figure is the median of 5 runs. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <mynos.h>

#define PAGE 4096
#define RUNS 5

static inline unsigned long long rdtsc(void) {
  unsigned lo, hi;
  __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
  return ((unsigned long long)hi << 32) | lo;
}

static double mhz;                    /* the TSC's rate */

static int cmp(const void * a, const void * b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

static double median(double * v, int n) {
  qsort(v, n, sizeof *v, cmp);
  return v[n / 2];
}

static void report(const char * what, double cycles) {
  printf("bench: %-34s %10.0f cycles %9.2f us\n", what, cycles, cycles / mhz);
}

/* ---- a system call: getpid, raw (int 0x80, 20) ---- */
static double one_syscall(void) {
  int i, n = 20000;
  unsigned long long t = rdtsc();
  for (i = 0; i < n; i++) {
    long r = 20;
    __asm__ volatile ("int $0x80" : "+a"(r) : : "memory");
  }
  return (double)(rdtsc() - t) / n;
}

/* ---- a fresh page: allocated on its first use ---- */
#define NPAGES 1024
static double alloc_on_use(unsigned * faults) {
  unsigned before[2], after[2];
  char * p = mmap(NULL, NPAGES * PAGE, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  unsigned long long t;
  int i;
  if (p == MAP_FAILED) { printf("bench: mmap failed\n"); exit(1); }
  mynos_faults(getpid(), before);
  t = rdtsc();
  for (i = 0; i < NPAGES; i++) p[i * PAGE] = 1;
  t = rdtsc() - t;
  mynos_faults(getpid(), after);
  *faults = after[0] - before[0];
  munmap(p, NPAGES * PAGE);
  return (double)t / NPAGES;
}

/* ---- a page written after fork: copied on write ---- */
/* a child's result, to its parent: a message (no pipes in MyNOS's C) */
static double result_from(int ch) {
  mynos_msg_t * m;
  double r = -1;
  if (mynos_recv(ch, &m, 0, 0) >= 0) {
    if (m->size == sizeof r) memcpy(&r, m->start, sizeof r);
    mynos_freeMsg(&m);
  }
  return r;
}

static char * cow_buf;
static double copy_on_write(void) {
  int port = mynos_allocPort(), ch, st, i;
  double r;
  pid_t child;
  for (i = 0; i < NPAGES; i++) cow_buf[i * PAGE] = 2;     /* present */
  if ((child = fork()) == 0) {
    unsigned long long t = rdtsc();
    for (i = 0; i < NPAGES; i++) cow_buf[i * PAGE] = 3;
    r = (double)(rdtsc() - t) / NPAGES;
    ch = mynos_connectToPort(port);
    mynos_send(ch, &r, sizeof r, 0);
    _exit(0);
  }
  ch = mynos_listenPort(port);
  r = result_from(ch);
  waitpid(child, &st, 0);
  mynos_freeChannel(ch);
  mynos_freePort(port);
  return r;
}

/* ---- IPC between two processes: a round trip ---- */
#define ROUNDS 5000
static double ipc_round_trip(int size) {
  static char page[PAGE] __attribute__((aligned(PAGE)));
  int port = mynos_allocPort(), st, i;
  double r = 0;
  pid_t child;
  memset(page, 'p', sizeof page);
  if ((child = fork()) == 0) {
    /* the client: sends, waits for the answer */
    mynos_msg_t * m;
    int ch = mynos_connectToPort(port);
    unsigned long long t;
    for (i = 0; i < 50; i++) {                   /* warm up */
      mynos_send(ch, page, size, 0);
      mynos_recv(ch, &m, 0, 0); mynos_freeMsg(&m);
    }
    t = rdtsc();
    for (i = 0; i < ROUNDS; i++) {
      mynos_send(ch, page, size, 0);
      mynos_recv(ch, &m, 0, 0); mynos_freeMsg(&m);
    }
    r = (double)(rdtsc() - t) / ROUNDS;
    mynos_send(ch, &r, sizeof r, 0);
    mynos_freeChannel(ch);
    _exit(0);
  }
  {
    /* the server: answers each message with 4 bytes */
    mynos_msg_t * m;
    int ch = mynos_listenPort(port);
    for (i = 0; i < ROUNDS + 50; i++) {
      if (mynos_recv(ch, &m, 0, 0) < 0) break;
      mynos_freeMsg(&m);
      mynos_send(ch, "ok", 4, 0);
    }
    r = result_from(ch);
    waitpid(child, &st, 0);
    mynos_freeChannel(ch);
    mynos_freePort(port);
  }
  return r;
}

/* ---- two threads of a process, waking each other: a switch ---- */
static int sem_a, sem_b;
static void * pong(void * n) {
  int i;
  for (i = 0; i < (int)(long)n; i++) { mynos_P(sem_a); mynos_V(sem_b); }
  return NULL;
}
static double thread_switch(void) {
  pthread_t t;
  int i, n = 10000;
  unsigned long long c;
  sem_a = mynos_initSem(0); sem_b = mynos_initSem(0);
  pthread_create(&t, NULL, pong, (void *)(long)n);
  c = rdtsc();
  for (i = 0; i < n; i++) { mynos_V(sem_a); mynos_P(sem_b); }
  c = rdtsc() - c;
  pthread_join(t, NULL);
  mynos_freeSem(sem_a); mynos_freeSem(sem_b);
  return (double)c / n / 2;               /* two switches a round */
}

/* ---- 4 KB read from a file, sequential and at random offsets ---- */
static double file_read(const char * path, int random) {
  static char buf[PAGE];
  int fd = open(path, O_RDONLY), i, n = 64;
  off_t size;
  unsigned long long t;
  if (fd < 0) return -1;
  size = lseek(fd, 0, SEEK_END);
  if (size < PAGE) { close(fd); return -1; }
  lseek(fd, 0, SEEK_SET);
  t = rdtsc();
  for (i = 0; i < n; i++) {
    off_t at = random ? (off_t)((rand() % (size / PAGE)) * PAGE) : (off_t)((i % (size / PAGE)) * PAGE);
    lseek(fd, at, SEEK_SET);
    if (read(fd, buf, PAGE) <= 0) break;
  }
  t = rdtsc() - t;
  close(fd);
  return (double)t / n;
}

int main(int argc, char ** argv) {
  double v[RUNS];
  unsigned faults = 0;
  int r, a;
  struct timespec t0, t1;
  unsigned long long c0, c1;

  /* the TSC's rate, against the kernel's clock (10 ms ticks: 1 s) */
  clock_gettime(CLOCK_MONOTONIC, &t0);
  c0 = rdtsc();
  mynos_sleep(1000000);
  c1 = rdtsc();
  clock_gettime(CLOCK_MONOTONIC, &t1);
  mhz = (double)(c1 - c0) /
        ((t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) / 1e3);
  printf("bench: the TSC runs at %.0f MHz\n", mhz);

  for (r = 0; r < RUNS; r++) v[r] = one_syscall();
  report("a system call (getpid)", median(v, RUNS));

  for (r = 0; r < RUNS; r++) v[r] = alloc_on_use(&faults);
  report("a page allocated on use", median(v, RUNS));
  printf("bench:   (%u faults counted for %d pages)\n", faults, NPAGES);

  cow_buf = mmap(NULL, NPAGES * PAGE, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  for (r = 0; r < RUNS; r++) v[r] = copy_on_write();
  report("a page copied on write", median(v, RUNS));

  for (r = 0; r < RUNS; r++) v[r] = ipc_round_trip(4);
  report("IPC round trip, 4 bytes", median(v, RUNS));
  for (r = 0; r < RUNS; r++) v[r] = ipc_round_trip(PAGE);
  report("IPC round trip, a 4 KB page", median(v, RUNS));

  for (r = 0; r < RUNS; r++) v[r] = thread_switch();
  report("a switch between threads", median(v, RUNS));

  for (a = 1; a < argc; a++) {
    char what[64];
    for (r = 0; r < RUNS; r++) v[r] = file_read(argv[a], 0);
    snprintf(what, sizeof what, "read 4 KB, %s", argv[a]);
    report(what, median(v, RUNS));
    for (r = 0; r < RUNS; r++) v[r] = file_read(argv[a], 1);
    snprintf(what, sizeof what, "read 4 KB at random, %s", argv[a]);
    report(what, median(v, RUNS));
  }
  {
    unsigned all[2];
    mynos_faults(0, all);
    printf("bench: faults since boot: %u allocated on use, %u copy-on-write\n",
           all[0], all[1]);
  }
  printf("bench: done\n");
  return 0;
}

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

static int failures = 0;

/* raw Linux system call with no arguments */
static long linux_syscall0(long n) {
  long ret = n;
  __asm__ volatile ("int $0x80" : "+a"(ret) : : "memory");
  return ret;
}

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
   mapped into the kernel's memory (mynos-py9) */
static int big_port, big_sem;

static void * big_listener(void * unused) {
  int ch = mynos_listenPort(big_port);
  mynos_P(big_sem);
  if (ch >= 0) mynos_freeChannel(ch);
  return NULL;
}

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

/* a live connector, after one that ended in the queue (mynos-blv) */
static int queue_port;

static void * queue_connector(void * unused) {
  int ch = mynos_connectToPort(queue_port);
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
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(140), "b"(0), "c"(0), "d"(0), "S"(kernel), "D"(0) : "memory");
    check("_llseek refuses a result pointer into the kernel", r == -14);
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(267), "b"(CLOCK_MONOTONIC), "c"(0), "d"(kernel), "S"(0) : "memory");
    check("clock_nanosleep refuses a request in the kernel", r == -14);
    asm volatile("int $0x80" : "=a"(r)
                 : "a"(407), "b"(CLOCK_MONOTONIC), "c"(0), "d"(kernel), "S"(0) : "memory");
    check("clock_nanosleep (time64) refuses a request in the kernel", r == -14);
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

  /* the RAM disk's pages (0x40400000 up, when there is one) are every
     process's: munmap refuses them (mynos-q5b) */
  check("munmap refuses the RAM disk",
        munmap((void *)0x40400000, 4096) == -1 && errno == EINVAL);

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
      asm volatile("movl $7, %%eax\n\tmovb $1, (%0)" :: "r"(fresh) : "eax", "memory");
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
    if (ch >= 0) mynos_freeChannel(ch);
    pthread_join(t, NULL);
  }

  printf("abi: %s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
  return failures;
}

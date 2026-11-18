/* Checks for the system call fixes made while porting to gcc 14.
   Run it as a MyNOS module (see tools/run-tests.sh). */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <mynos.h>
#include <pthread.h>

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

  printf("abi: %s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
  return failures;
}

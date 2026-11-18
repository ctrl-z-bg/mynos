/* Checks for the system call fixes made while porting to gcc 14.
   Run it as a MyNOS module (see tools/run-tests.sh). */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <mynos.h>

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

  printf("abi: %s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
  return failures;
}

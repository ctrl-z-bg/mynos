/* Checks for the system call fixes made while porting to gcc 14.
   Run it as a MyNOS module (see tools/run-tests.sh). */
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <mynos.h>

static int failures = 0;

/* raw Linux system call with no arguments (dietlibc has no syscall()) */
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
  check("argc/argv from the kernel", argc == 1 && argv[0] != NULL);

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

  printf("abi: %s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
  return failures;
}

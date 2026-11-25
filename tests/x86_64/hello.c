/* The first program of MyNOS on x86-64 (mynos-btq.3): no C library, two
   calls of each kind: MyNOS's log (native 31, int 0x90), Linux's write
   (1) and getpid (39), a fork, and exit_group (231). */

static long native(long n, long a, long b)
{
  long r = n;
  __asm__ volatile ("int $0x90" : "+a"(r) : "D"(a), "S"(b) : "memory", "rcx", "r11");
  return r;
}

static long linux3(long n, long a, long b, long c)
{
  long r;
  __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c)
                    : "rcx", "r11", "memory");
  return r;
}

static int len(const char * s) { int n = 0; while (s[n]) n++; return n; }
static void say(const char * s) { native(31, (long)s, len(s)); }

void _start(void)
{
  char msg[] = "hello64: pid ?\n";
  long pid = linux3(39, 0, 0, 0);
  long child;
  say("hello64: a 64-bit program, through int 0x90\n");
  linux3(1, 1, (long)"hello64: and through syscall (write)\n", 37);
  msg[13] = '0' + pid % 10;
  say(msg);
  child = linux3(57, 0, 0, 0);
  if (child == 0) {
    say("hello64: the child of fork\n");
    linux3(231, 0, 0, 0);
  }
  say(child > 0 ? "hello64: the parent of fork\n" : "hello64: fork failed\n");
  for (;;) linux3(231, 0, 0, 0);
}

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Each thread has its own floating-point state (mynos-t6p). Two threads
   keep values in the x87 registers (and in the SSE registers, if the
   processor has them) and their own rounding mode, while each spins long
   enough to be preempted many times; then each checks that it finds
   everything as it left it. Without the kernel saving the FPU at context
   switches, the other thread's FNINIT and loads change them. */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROUNDS 12
#define SPIN 20000000

static int has_sse2;

struct result { int x87_bad, cw_bad, sse_bad; };

static void * worker(void * arg)
{
  int id = (int)arg;
  struct result * r = calloc(1, sizeof *r);
  double in[3] = { 1.5 + id, 2.25 + id, 3.125 + id }, out[3];
  /* thread 0: round toward zero; thread 1: round to nearest */
  unsigned short cw = id == 0 ? 0x0F7F : 0x037F, cw_out;
  int round;
  for (round = 0; round < ROUNDS; round++) {
    asm volatile("fninit\n\t"
                 "fldcw %4\n\t"
                 "fldl %3\n\t" "fldl 8+%3\n\t" "fldl 16+%3\n\t"
                 "movl %5, %%ecx\n"
                 "1:\tdecl %%ecx\n\tjnz 1b\n\t"
                 "fstpl 16+%0\n\t" "fstpl 8+%0\n\t" "fstpl %0\n\t"
                 "fnstcw %1\n\t"
                 : "=m"(out), "=m"(cw_out), "+m"(cw)
                 : "m"(in), "m"(cw), "i"(SPIN)
                 : "ecx", "memory");
    if (memcmp(in, out, sizeof in)) r->x87_bad++;
    if (cw_out != cw) r->cw_bad++;
    if (has_sse2) {
      double s_in = 7.75 * (id + 1), s_out = 0;
      asm volatile("movsd %1, %%xmm3\n\t"
                   "movl %2, %%ecx\n"
                   "1:\tdecl %%ecx\n\tjnz 1b\n\t"
                   "movsd %%xmm3, %0\n\t"
                   : "=m"(s_out) : "m"(s_in), "i"(SPIN) : "ecx", "memory");   /* xmm3: the compiler does not use SSE here */
      if (s_out != s_in) r->sse_bad++;
    }
  }
  return r;
}

int main(void)
{
  unsigned a = 1, b, c, d;
  pthread_t t[2];
  struct result * r[2];
  int i, ok = 1;
  asm volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
  has_sse2 = (d >> 26) & 1;
  for (i = 0; i < 2; i++) pthread_create(&t[i], NULL, worker, (void *)i);
  for (i = 0; i < 2; i++) pthread_join(t[i], (void **)&r[i]);
  for (i = 0; i < 2; i++) {
    printf("fpu: thread %d: x87 registers %s, control word %s, SSE %s\n", i,
           r[i]->x87_bad ? "CHANGED" : "kept", r[i]->cw_bad ? "CHANGED" : "kept",
           !has_sse2 ? "absent" : r[i]->sse_bad ? "CHANGED" : "kept");
    if (r[i]->x87_bad || r[i]->cw_bad || r[i]->sse_bad) ok = 0;
  }
  printf(ok ? "fpu: all checks passed\n" : "fpu: some checks failed\n");
  return 0;
}

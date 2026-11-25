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
   switches, the other thread's FNINIT and loads change them. On AArch64
   the same with the floating-point and SIMD registers (d16-d18, all of
   v19) and FPCR's rounding mode. */

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
#if defined(__aarch64__)
  /* thread 0: round toward zero (FPCR.RMode 3); thread 1: to nearest */
  unsigned long fpcr = id == 0 ? 3ul << 22 : 0, fpcr_out;
  double v_in[2] = { 7.75 * (id + 1), -0.5 * (id + 1) }, v_out[2];
  (void)cw; (void)cw_out;
  for (round = 0; round < ROUNDS; round++) {
    asm volatile("msr fpcr, %[fpcr]\n\t"
                 "ldr d16, [%[in]]\n\t" "ldr d17, [%[in], #8]\n\t" "ldr d18, [%[in], #16]\n\t"
                 "ld1 {v19.2d}, [%[vin]]\n\t"
                 "mov x9, %[spin]\n"
                 "1:\tsubs x9, x9, #1\n\tb.ne 1b\n\t"
                 "str d16, [%[out]]\n\t" "str d17, [%[out], #8]\n\t" "str d18, [%[out], #16]\n\t"
                 "st1 {v19.2d}, [%[vout]]\n\t"
                 "mrs %[fo], fpcr\n\t"
                 "msr fpcr, xzr"
                 : [fo] "=&r"(fpcr_out)
                 : [fpcr] "r"(fpcr), [in] "r"(in), [out] "r"(out), [vin] "r"(v_in),
                   [vout] "r"(v_out), [spin] "r"((long)SPIN)
                 : "x9", "v16", "v17", "v18", "v19", "memory");
    if (memcmp(in, out, sizeof in)) r->x87_bad++;
    if (fpcr_out != fpcr) r->cw_bad++;
    if (memcmp(v_in, v_out, sizeof v_in)) r->sse_bad++;
  }
#else
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
#endif
  return r;
}

int main(void)
{
  pthread_t t[2];
  struct result * r[2];
  int i, ok = 1;
#if defined(__aarch64__)
  has_sse2 = 1;                         /* SIMD: always there */
#else
  unsigned a = 1, b, c, d;
  asm volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
  has_sse2 = (d >> 26) & 1;
#endif
  for (i = 0; i < 2; i++) pthread_create(&t[i], NULL, worker, (void *)i);
  for (i = 0; i < 2; i++) pthread_join(t[i], (void **)&r[i]);
  for (i = 0; i < 2; i++) {
#if defined(__aarch64__)
    printf("fpu: thread %d: FP registers %s, FPCR %s, SIMD %s\n", i,
#else
    printf("fpu: thread %d: x87 registers %s, control word %s, SSE %s\n", i,
#endif
           r[i]->x87_bad ? "CHANGED" : "kept", r[i]->cw_bad ? "CHANGED" : "kept",
           !has_sse2 ? "absent" : r[i]->sse_bad ? "CHANGED" : "kept");
    if (r[i]->x87_bad || r[i]->cw_bad || r[i]->sse_bad) ok = 0;
  }
  printf(ok ? "fpu: all checks passed\n" : "fpu: some checks failed\n");
  return 0;
}

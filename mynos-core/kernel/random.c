/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The kernel's random numbers (mynos-dhp).
 *
 * Entropy: the processor's time-stamp counter at every timer tick and
 * every interrupt (keys, network frames...), whose low bits depend on
 * when things really happen; at boot, the real-time clock and, when the
 * processor has them, RDSEED/RDRAND. Events go into a buffer of 16 words;
 * a full buffer is mixed into the pool, 8 words, with the SHA-256
 * compression function (pool = compress(pool, events)).
 *
 * Output: each 32-byte block is compress(pool, {counter, tag, the time
 * stamp counter now}); after a request the pool is replaced by another
 * compression of itself ("fast key erasure"), so that what was returned
 * cannot be computed again from a later state.
 */

#include "random.h"
#include "time.h"
#include "video.h"

static uint32_t pool[8] = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};
static uint32_t events[16];
static uint32_t nevents = 0;
static uint32_t counter = 0;

/* ---- the SHA-256 compression function (FIPS 180-4) ---- */

static const uint32_t K[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

/* st = st + rounds(st, block) */
static void compress(uint32_t * st, const uint32_t * block) {
  uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
  int i;
  for (i = 0; i < 16; i++) w[i] = block[i];
  for (i = 16; i < 64; i++) {
    uint32_t s0 = ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3);
    uint32_t s1 = ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  a = st[0]; b = st[1]; c = st[2]; d = st[3];
  e = st[4]; f = st[5]; g = st[6]; h = st[7];
  for (i = 0; i < 64; i++) {
    t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g))
      + K[i] + w[i];
    t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    h = g; g = f; f = e; e = d + t1;
    d = c; c = b; b = a; a = t1 + t2;
  }
  st[0] += a; st[1] += b; st[2] += c; st[3] += d;
  st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

/* ---- the processor ---- */

static uint32_t tsc(void) {
  uint32_t lo, hi;
  __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
  return lo ^ (hi << 21);
}

static uint32_t save_cli(void) {
  uint32_t flags;
  __asm__ volatile ("pushfl; popl %0; cli" : "=r"(flags) : : "memory");
  return flags;
}

static void restore(uint32_t flags) {
  __asm__ volatile ("pushl %0; popfl" : : "r"(flags) : "memory", "cc");
}

static void cpuid(uint32_t leaf, uint32_t * b, uint32_t * c) {
  uint32_t a = leaf, d;
  __asm__ volatile ("cpuid" : "+a"(a), "=b"(*b), "=c"(*c), "=d"(d) : "c"(0));
}

/* RDRAND/RDSEED into eax (as bytes: old assemblers do not know them);
   1 if the processor gave a value */
static int rdrand(uint32_t * v) {
  uint32_t x; ubyte_t ok;
  __asm__ volatile (".byte 0x0f, 0xc7, 0xf0; setc %1" : "=a"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}

static int rdseed(uint32_t * v) {
  uint32_t x; ubyte_t ok;
  __asm__ volatile (".byte 0x0f, 0xc7, 0xf8; setc %1" : "=a"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}

/* ---- the pool ---- */

/* interrupts are off */
static void add(uint32_t x) {
  events[nevents++] = x;
  if (nevents == 16) {
    compress(pool, events);
    nevents = 0;
  }
}

void random_event(uint32_t what) {
  uint32_t flags = save_cli();
  add(tsc() ^ (what << 24));
  restore(flags);
}

void random_init(void) {
  uint32_t b, c, v, i, n = 0, max;
  uint32_t flags = save_cli();
  add(tsc());
  time_now(CLOCK_REALTIME, &v, &b);
  add(v);
  cpuid(0, &max, &c);
  cpuid(1, &b, &c);
  if (c & (1 << 30))                    /* RDRAND */
    for (i = 0; i < 64; i++)
      if (rdrand(&v)) { add(v); n++; }
  if (max >= 7) {
    cpuid(7, &b, &c);
    if (b & (1 << 18))                  /* RDSEED */
      for (i = 0; i < 64; i++)
        if (rdseed(&v)) { add(v); n++; }
  }
  for (i = 0; i < 16; i++) add(tsc());
  restore(flags);
  printk(n ? "Random numbers: time stamps and the processor's generator\n"
           : "Random numbers: time stamps (no RDRAND in this processor)\n");
}

void random_get(ubyte_t * buf, uint32_t len) {
  uint32_t block[16], out[8], i, j, flags;
  flags = save_cli();
  add(tsc());
  for (i = 0; i < 16; i++) block[i] = 0;
  while (len > 0) {
    block[0] = ++counter;
    block[1] = 0x6f757470;              /* "outp" */
    block[2] = tsc();
    for (i = 0; i < 8; i++) out[i] = pool[i];
    compress(out, block);
    for (i = 0; i < 32 && len > 0; i++, len--)
      *buf++ = (ubyte_t)(out[i / 4] >> (8 * (i % 4)));
  }
  block[0] = ++counter;
  block[1] = 0x6e657874;                /* "next" */
  for (j = 0; j < nevents; j++) block[2 + j % 14] ^= events[j];
  compress(pool, block);
  restore(flags);
}

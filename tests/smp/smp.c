/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Several processors at once (doc/decisions/smp.md, mynos-btq.5): what
   crosses the big kernel lock. Threads of one process on different
   processors
   - add to one counter with atomic instructions, and to another under a
     kernel semaphore: no addition is lost;
   - fault on the same fresh pages at the same moment: each fault is
     resolved once, nobody is killed;
   - map, write, check and unmap memory, over and over: the TLB shootdowns
     on munmap;
   while a thread writes without pause into a buffer the main thread
   forks from: each child's copy must not change under it (the parent's
   pages became copy-on-write: a processor that kept a writable
   translation would write into the child's page).
   On one processor the same checks pass: nothing runs at once. */

#include <mynos.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define THREADS 4

static int failures;

static void check(const char * what, int ok) {
  printf("smp: %-46s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

/* ---- counters ---- */

#define ATOMIC_ADDS 200000
#define SEM_ADDS 2000
static long atomic_count, sem_count;
static int count_sem;

static void * counter(void * unused) {
  int i;
  for (i = 0; i < ATOMIC_ADDS; i++) __atomic_fetch_add(&atomic_count, 1, __ATOMIC_RELAXED);
  for (i = 0; i < SEM_ADDS; i++) {
    mynos_P(count_sem);
    sem_count++;
    mynos_V(count_sem);
  }
  return NULL;
}

/* ---- the same fresh pages, faulted together ---- */

#define FAULT_PAGES 64
static char * fault_area;
static volatile int fault_go;

static void * faulter(void * arg) {
  long id = (long)arg;
  int i;
  while (!fault_go) ;
  for (i = 0; i < FAULT_PAGES; i++)
    __atomic_fetch_add((int *)(fault_area + i * 4096 + 64 * id), 1, __ATOMIC_RELAXED);
  return NULL;
}

/* ---- map, write, check, unmap ---- */

#define MAP_ROUNDS 150
#define MAP_PAGES 8

static void * mapper(void * arg) {
  long id = (long)arg, bad = 0;
  int r, i;
  for (r = 0; r < MAP_ROUNDS; r++) {
    unsigned * p = mmap(NULL, MAP_PAGES * 4096, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return (void *)1000L;
    for (i = 0; i < MAP_PAGES * 1024; i += 256) p[i] = (unsigned)(id << 24 | r << 8 | i >> 8);
    for (i = 0; i < MAP_PAGES * 1024; i += 256)
      if (p[i] != (unsigned)(id << 24 | r << 8 | i >> 8)) bad++;
    munmap(p, MAP_PAGES * 4096);
  }
  return (void *)bad;
}

/* ---- fork while a thread writes ---- */

#define BUF_PAGES 8
#define FORKS 20
static volatile unsigned buf[BUF_PAGES * 1024];
static volatile int writing = 1;

static void * writer(void * unused) {
  unsigned n = 0;
  int i;
  while (writing) {
    n++;
    for (i = 0; i < BUF_PAGES * 1024; i += 128) buf[i] = n;
  }
  return NULL;
}

/* the child: its copy, read twice some time apart, is the same */
static int child_view_stable(void) {
  static unsigned first[BUF_PAGES * 1024 / 128];
  int i, k, changed = 0;
  for (i = 0, k = 0; i < BUF_PAGES * 1024; i += 128) first[k++] = buf[i];
  mynos_sleep(20000);
  for (i = 0, k = 0; i < BUF_PAGES * 1024; i += 128)
    if (buf[i] != first[k++]) changed++;
  return changed;
}

int main(void) {
  pthread_t t[THREADS], w;
  long i, bad;

  /* the processors, as programs see them (sched_getaffinity: musl's
     sysconf, nproc, OCaml's Domain.recommended_domain_count) */
  printf("smp: %ld processors\n", sysconf(_SC_NPROCESSORS_ONLN));

  /* counters */
  count_sem = mynos_initSem(1);
  for (i = 0; i < THREADS; i++) pthread_create(&t[i], NULL, counter, NULL);
  for (i = 0; i < THREADS; i++) pthread_join(t[i], NULL);
  check("atomic additions from 4 threads, none lost",
        atomic_count == (long)THREADS * ATOMIC_ADDS);
  check("additions under a semaphore, none lost", sem_count == (long)THREADS * SEM_ADDS);
  mynos_freeSem(count_sem);

  /* the same pages, faulted at once */
  fault_area = mmap(NULL, FAULT_PAGES * 4096, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  for (i = 0; i < THREADS; i++) pthread_create(&t[i], NULL, faulter, (void *)i);
  fault_go = 1;
  for (i = 0; i < THREADS; i++) pthread_join(t[i], NULL);
  bad = 0;
  for (i = 0; i < FAULT_PAGES * THREADS; i++)
    if (*(int *)(fault_area + (i / THREADS) * 4096 + 64 * (i % THREADS)) != 1) bad++;
  check("fresh pages faulted together, each resolved", bad == 0);
  munmap(fault_area, FAULT_PAGES * 4096);

  /* map and unmap; meanwhile, fork while a thread writes */
  pthread_create(&w, NULL, writer, NULL);
  for (i = 0; i < THREADS - 1; i++) pthread_create(&t[i], NULL, mapper, (void *)i);
  {
    int unstable = 0, st;
    for (i = 0; i < FORKS; i++) {
      pid_t c = fork();
      if (c == 0) _exit(child_view_stable() ? 1 : 0);
      if (c < 0 || waitpid(c, &st, 0) != c || !WIFEXITED(st) || WEXITSTATUS(st))
        unstable++;
    }
    check("a child's copy does not change under it", unstable == 0);
  }
  bad = 0;
  for (i = 0; i < THREADS - 1; i++) {
    void * r;
    pthread_join(t[i], &r);
    bad += (long)r;
  }
  writing = 0;
  pthread_join(w, NULL);
  check("memory mapped, written and unmapped by 3 threads", bad == 0);

  printf(failures ? "smp: SOME CHECKS FAILED\n" : "smp: all checks passed\n");
  return failures != 0;
}

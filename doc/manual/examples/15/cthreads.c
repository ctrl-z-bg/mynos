/* cthreads.c: POSIX threads, and MyNOS's own */
#include <stdio.h>
#include <pthread.h>
#include <mynos.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static long counter = 0;

static void * add(void * arg)
{
  int i;
  for (i = 0; i < 10000; i++) {
    pthread_mutex_lock(&lock);
    counter++;
    pthread_mutex_unlock(&lock);
  }
  return arg;
}

static int done;                         /* a MyNOS semaphore */
static char stack[16384];
static long squares;

/* a native thread shares its creator's TLS: no C library calls here */
static void * native(void * arg)
{
  long i, n = (long)arg;
  for (i = 1; i <= n; i++) squares += i * i;
  mynos_V(done);
  return NULL;
}

int main(void)
{
  pthread_t t[3];
  int i;

  for (i = 0; i < 3; i++) pthread_create(&t[i], NULL, add, NULL);
  for (i = 0; i < 3; i++) pthread_join(t[i], NULL);
  printf("pthreads: counter %ld\n", counter);

  done = mynos_initSem(0);
  mynos_threadCreate(native, (void *)100, stack + sizeof stack, 0);
  mynos_P(done);                         /* wait for it */
  mynos_freeSem(done);
  printf("native thread: squares %ld\n", squares);
  return 0;
}

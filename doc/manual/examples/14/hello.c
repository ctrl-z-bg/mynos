/* hello.c: a C program for MyNOS */
#include <stdio.h>
#include <unistd.h>
#include <mynos.h>

int main(int argc, char ** argv)
{
  mynos_stats_t st;
  int i;

  mynos_stats(&st);
  printf("hello from pid %d, parent %d\n", getpid(), getppid());
  printf("%u processes, %u threads, %u KB free\n",
         st.numProcesses, st.numThreads, st.freeppages * 4);
  for (i = 1; i < argc; i++)
    printf("argument %d: %s\n", i, argv[i]);
  mynos_log("hello: %d arguments", argc - 1);
  return 0;
}

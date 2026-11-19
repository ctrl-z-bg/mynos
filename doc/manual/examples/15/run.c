/* run.c: start a program, wait for it; start another, end it */
#include <stdio.h>
#include <sys/wait.h>
#include <mynos.h>

int main(void)
{
  char * argv1[] = { "ocamlrun", "worker.byte", "4", NULL };
  char * argv2[] = { "ocamlrun", "worker.byte", "forever", NULL };
  char * env[] = { "GREETING=from C", NULL };
  int pid, st, info;

  pid = mynos_spawn("ocamlrun", argv1, env);
  if (pid < 0) { printf("run: spawn: %d\n", pid); return 1; }
  waitpid(pid, &st, 0);
  if (WIFEXITED(st)) printf("run: %d exited with %d\n", pid, WEXITSTATUS(st));

  pid = mynos_spawn("ocamlrun", argv2, NULL);
  mynos_sleep(500000);                     /* half a second */
  info = mynos_processInfo(pid);        /* negative: no such process */
  printf("run: %d alive: %s\n", pid,
         info >= 0 && (info & MYNOS_PROC_ALIVE) ? "yes" : "no");
  mynos_kill(pid);
  waitpid(pid, &st, 0);
  if (WIFSIGNALED(st)) printf("run: %d killed by signal %d\n", pid, WTERMSIG(st));
  return 0;
}

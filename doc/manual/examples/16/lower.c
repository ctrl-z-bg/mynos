/* lower.c: a client of "upper" */
#include <stdio.h>
#include <string.h>
#include <mynos.h>

int main(int argc, char ** argv)
{
  char * text = argc > 1 ? argv[1] : "hello, world";
  mynos_msg_t * msg;
  int port = -1, ch, r, tries;

  /* at boot the service may not have registered yet: try for 2 s */
  for (tries = 0; tries < 20; tries++) {
    if ((port = mynos_registryLookUp("upper")) >= 0) break;
    mynos_sleep(100000);
  }
  if (port < 0) { printf("lower: no service \"upper\"\n"); return 1; }

  if ((ch = mynos_connectToPort(port)) < 0) return 1;
  if (mynos_send(ch, text, strlen(text), 0) < 0) return 1;
  r = mynos_recv(ch, &msg, 0, 2000);       /* the reply, within 2 s */
  if (r == MYNOS_ERR_EXPIRED)
    printf("lower: no answer\n");
  else if (r >= 0) {
    printf("lower: %.*s\n", (int)msg->size, (char *)msg->start);
    mynos_freeMsg(&msg);
  }
  mynos_freeChannel(ch);
  return 0;
}

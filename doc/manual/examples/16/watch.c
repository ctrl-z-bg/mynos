/* watch.c: a client of "ticker": it watches its own page change */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mynos.h>

int main(void)
{
  char * page;
  mynos_msg_t * msg;
  int ch, port = -1, tries;

  for (tries = 0; tries < 20 && port < 0; tries++) {
    port = mynos_registryLookUp("ticker");
    if (port < 0) mynos_sleep(100000);
  }
  if (port < 0 || posix_memalign((void **)&page, 4096, 4096)) return 1;
  strcpy(page, "nothing yet");
  ch = mynos_connectToPort(port);
  mynos_send(ch, page, 4096, MYNOS_IPC_SHARED);
  /* wait for the reply in steps of 300 ms, looking at the page meanwhile */
  while (mynos_recv(ch, &msg, 0, 300) == MYNOS_ERR_EXPIRED)
    printf("watch: the page says \"%s\"\n", page);
  printf("watch: reply \"%.*s\", the page says \"%s\"\n",
         (int)msg->size, (char *)msg->start, page);
  mynos_freeMsg(&msg);
  mynos_freeChannel(ch);
  return 0;
}

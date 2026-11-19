/* ticker.c: a service that writes into its client's memory. The client
   sends a page with MYNOS_IPC_SHARED; the service writes a line in it
   five times, then answers "done". */
#include <stdio.h>
#include <mynos.h>

int main(void)
{
  int port = mynos_registryRegister("ticker");
  for (;;) {
    mynos_msg_t * msg;
    int ch = mynos_listenPort(port), i;
    if (ch < 0) continue;
    if (mynos_recv(ch, &msg, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    for (i = 1; i <= 5; i++) {
      snprintf(msg->start, msg->size, "tick %d from the service", i);
      mynos_sleep(200000);
    }
    mynos_send(ch, "done", 4, 0);
    mynos_freeMsg(&msg);                     /* unmaps the shared page */
    mynos_freeChannel(ch);
  }
}

/* upper.c: a service of raw messages. It registers the name "upper"
   and answers every message with the same bytes in capitals. */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <mynos.h>

int main(void)
{
  int port = mynos_registryRegister("upper");
  if (port < 0) {
    printf("upper: cannot register (%d)\n", port);
    return 1;
  }
  for (;;) {
    mynos_msg_t * msg;
    char * reply;
    unsigned int i;
    int ch = mynos_listenPort(port);       /* wait for a client */
    if (ch < 0) continue;
    /* a client that connects and sends nothing must not stop us: 1 s */
    if (mynos_recv(ch, &msg, 0, 1000) < 0) {
      mynos_freeChannel(ch);
      continue;
    }
    mynos_log("upper: %u bytes from pid %d", msg->size, mynos_channelPeer(ch));
    if ((reply = malloc(msg->size + 1)) != NULL) {
      for (i = 0; i < msg->size; i++)
        reply[i] = toupper(((unsigned char *)msg->start)[i]);
      mynos_send(ch, reply, msg->size, 0);
      free(reply);
    }
    mynos_freeMsg(&msg);
    mynos_freeChannel(ch);
  }
}

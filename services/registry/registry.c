/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <mynos.h>

#if 0
  {
    mynos_stats_t stats;
    mynos_stats(&stats);
    printf("++ %d", stats.freeppages);
  }
#endif

struct table_entry_s {
  char name[MAXNAMELEN+1];
  int port;
  struct table_entry_s * next;
};

static struct {
  int sem;
  struct table_entry_s * head;
} registry;
  
void initRegistry() {
  registry.sem = mynos_initSem(1);
  registry.head = NULL;
}

int insertIntoRegistry(char * name, int port) {
  struct table_entry_s * el;

  mynos_P(registry.sem);
  el = (struct table_entry_s *)malloc(sizeof(struct table_entry_s));
  el->port = port;
  strcpy(el->name, name);
  el->next = registry.head;
  registry.head = el;
  mynos_V(registry.sem);

  return 0;
}

int registryLookUp(char * name) {
  int ret = MYNOS_ERR_INVALID;
  struct table_entry_s * pun;
  mynos_P(registry.sem);
  pun = registry.head;
  if (pun && !strcmp(pun->name, name))
    ret = pun->port;
  else
    if (pun)
      while (pun->next) {
	if (!strcmp((pun->next)->name, name)) {
	  ret = (pun->next)->port;
	  break;
	}
	pun = pun->next;
      }
  mynos_V(registry.sem);
  return ret;
}

/* serve one request on a new channel. Requests are served one at a time
   by the main thread: they are short, and the 2004 version's thread per
   request leaked its stack (and used the C library from threads that
   share their creator's TLS, mynos-l9h) */
static void serve(int channel) {
  mynos_msg_t * msg;
  mynos_reg_cmd_t * cmd;
  int ret;
  int port;

  /* a client that connects and sends nothing must not stop the registry */
  ret = mynos_recv(channel, &msg, 0, 1000);
  if (ret < 0) {
    printf("Warning registry: invalid recv (%d)\n", ret);
    mynos_freeChannel(channel);
    return;
  }
  
  if (msg->size != sizeof(mynos_reg_cmd_t)) {
    printf("Warning registry: invalid message size\n");
    ret = MYNOS_ERR_INVALID;
    mynos_send(channel, &ret, sizeof(int), 0);
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
    return;
  }

  cmd = (mynos_reg_cmd_t*)(msg->start);
  
  // put a secure limit to the name length
  cmd->name[MAXNAMELEN] = 0;

  //printf("Service %s by process %d command %d\n", cmd->name, cmd->arg1, cmd->cmd);

  switch (cmd->cmd)
    {
    case MYNOS_REGISTRY_REGISTER:
      if (registryLookUp(cmd->name) < 0) { // is not already present
	port = mynos_allocPort();
	ret = port;
	if (port < 0) {
	  printf("Warning registry: allocPort result is %d\n", port);
	  break;
	}
	mynos_changePortOwner(port, cmd->arg1);
	insertIntoRegistry(cmd->name, port);
      } else {
	printf("Warning registry: name %s is already present\n", cmd->name);
	ret = MYNOS_ERR_INVALID;
      }
      break;
    case MYNOS_REGISTRY_LOOKUP:
      ret = registryLookUp(cmd->name);
      break;
    }
  
  // BE AWARE SENDING STUFF ON THE STACK!!!
  mynos_send(channel, &ret, sizeof(int), 0);
  mynos_freeMsg(&msg);
  mynos_freeChannel(channel);
}

int main() {
  int port;
  int channel;
  int req = 1;

  initRegistry();

  printf("Registry: registering my port\n");
  port = mynos_allocPortP(MYNOS_PORT_REGISTRY);
  if (port < 0) {
    printf("Error registry allocating port: %d\n", port);
    exit(-1);
  }

  printf("Registry: waiting requests\n");
  while (1) {
    req++;
    // wait for connection
    channel = mynos_listenPort(port);
    if (channel < 0)
      printf("Warning registry listening port: %d\n", channel);
    else {
      serve(channel);
    }
  }

  return 0;
}

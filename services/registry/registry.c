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

/* a name, its port, and the process that registered it: the name is its
   own while it runs, free again when it ends
   (doc/decisions/identity-and-permissions.md) */
struct table_entry_s {
  char name[MAXNAMELEN+1];
  int port;
  int owner;
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

int insertIntoRegistry(char * name, int port, int owner) {
  struct table_entry_s * el;

  mynos_P(registry.sem);
  el = (struct table_entry_s *)malloc(sizeof(struct table_entry_s));
  el->port = port;
  el->owner = owner;
  strcpy(el->name, name);
  el->next = registry.head;
  registry.head = el;
  mynos_V(registry.sem);

  return 0;
}

/* the port of a name; the entries of processes that ended are dropped on
   the way */
int registryLookUp(char * name) {
  int ret = MYNOS_ERR_INVALID;
  struct table_entry_s ** pp, * e;
  mynos_P(registry.sem);
  pp = &registry.head;
  while ((e = *pp) != NULL) {
    int info = mynos_processInfo(e->owner);
    if (info < 0 || !(info & MYNOS_PROC_ALIVE)) {
      *pp = e->next;
      free(e);
      continue;
    }
    if (!strcmp(e->name, name)) {
      ret = e->port;
      break;
    }
    pp = &e->next;
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
    mynos_log("Warning registry: invalid recv (%d)\n", ret);
    mynos_freeChannel(channel);
    return;
  }
  
  if (msg->size != sizeof(mynos_reg_cmd_t)) {
    mynos_log("Warning registry: invalid message size\n");
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
	/* the caller is the one at the other end of the channel (the pid
	   in the request, arg1, is not to be trusted) */
	int owner = mynos_channelPeer(channel);
	port = mynos_allocPort();
	ret = port;
	if (port < 0 || owner < 0) {
	  mynos_log("Warning registry: allocPort %d, caller %d\n", port, owner);
	  if (port >= 0) mynos_freePort(port);
	  ret = port < 0 ? port : owner;
	  break;
	}
	mynos_changePortOwner(port, owner);
	insertIntoRegistry(cmd->name, port, owner);
      } else {
	mynos_log("Warning registry: name %s is already present\n", cmd->name);
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

  mynos_log("Registry: registering my port\n");
  port = mynos_allocPortP(MYNOS_PORT_REGISTRY);
  if (port < 0) {
    mynos_log("Error registry allocating port: %d\n", port);
    exit(-1);
  }

  mynos_log("Registry: waiting requests\n");
  while (1) {
    req++;
    // wait for connection
    channel = mynos_listenPort(port);
    if (channel < 0)
      mynos_log("Warning registry listening port: %d\n", channel);
    else {
      serve(channel);
    }
  }

  return 0;
}

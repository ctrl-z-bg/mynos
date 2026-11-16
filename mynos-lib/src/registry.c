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

#include "../include/mynos.h"

#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

/* All services start together at boot, so a client can run before the
   registry has opened its port: retry for up to two seconds. */
static int connectToRegistry(void) {
  int channel, tries;
  for (tries = 0; tries < 200; tries++) {
    channel = mynos_connectToPort(MYNOS_PORT_REGISTRY);
    if (channel != MYNOS_ERR_INVALID)
      return channel;
    mynos_sleep(10000);
  }
  return channel;
}

int mynos_registryRegister(char * name) {
  mynos_reg_cmd_t cmd;
  int channel;
  mynos_msg_t * msg;
  int port;

  if (strlen(name) > MAXNAMELEN) {
    printf("register lib: service name too long\n");
    return MYNOS_ERR_INVALID;
  }

  /* get a channel connecting to the registry server */
  channel = connectToRegistry();
  if (channel < 0) return channel;

  cmd.cmd = MYNOS_REGISTRY_REGISTER;
  strcpy(cmd.name, name);
  cmd.arg1 = getpid();
  
  /* send the request */
  mynos_send(channel, &cmd, sizeof(mynos_reg_cmd_t), 0);

  /* wait the response */
  mynos_recv(channel, &msg, 0, 0);

  port = *((int*)(msg->start));

  /* free the allocated stuff */
  mynos_freeMsg(&msg);
  mynos_freeChannel(channel);
  return port;
}

int mynos_registryLookUp(char * name) {
  mynos_reg_cmd_t cmd;
  int channel;
  mynos_msg_t * msg;
  int port;

  if (strlen(name) > MAXNAMELEN) {
    printf("register lib: service name too long\n");
    return MYNOS_ERR_INVALID;
  }

  channel = connectToRegistry();
  if (channel < 0) return channel;

  cmd.cmd = MYNOS_REGISTRY_LOOKUP;
  strcpy(cmd.name, name);
  
  mynos_send(channel, &cmd, sizeof(mynos_reg_cmd_t), 0);
  mynos_recv(channel, &msg, 0, 0);
  port = *((int*)(msg->start));
  mynos_freeMsg(&msg);
  mynos_freeChannel(channel);
  return port;
}



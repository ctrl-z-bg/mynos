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
#include "../include/mynos_wire.h"

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

/* a registry/1 request (mynos_registry.h): the reply's reader on Ok (the
   caller frees *msg), MYNOS_ERR_INVALID on an Error reply, or another error */
static int registry_call(wire_writer * w, wire_reader * r, mynos_msg_t ** msg)
{
  int channel;
  if (w->error) { wire_writer_free(w); return MYNOS_ERR_FULL; }
  channel = connectToRegistry();
  if (channel < 0) { wire_writer_free(w); return channel; }
  mynos_send(channel, w->buf, w->len, 0);
  wire_writer_free(w);
  if (mynos_recv(channel, msg, 0, 0) < 0) {
    mynos_freeChannel(channel);
    return MYNOS_ERR_BROKEN;
  }
  mynos_freeChannel(channel);
  wire_reader_init(r, (*msg)->start, (*msg)->size);
  if (wire_get_int(r) != 0) {           /* Error: taken, not found, invalid */
    mynos_freeMsg(msg);
    return MYNOS_ERR_INVALID;
  }
  return 0;
}

static void registry_start(wire_writer * w, int kind)
{
  wire_writer_init(w);
  wire_put_cstring(w, REGISTRY_PROTOCOL);
  wire_put_int(w, kind);
}

/* register or look up a name: its port, or an error */
static int name_request(int kind, const char * name)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  int ret;
  long long port;

  if (strlen(name) > MAXNAMELEN) return MYNOS_ERR_INVALID;
  registry_start(&w, kind);
  wire_put_cstring(&w, name);
  if ((ret = registry_call(&w, &r, &msg)) < 0) return ret;
  port = wire_get_int(&r);
  ret = r.error ? MYNOS_ERR_INVALID : (int)port;
  mynos_freeMsg(&msg);
  return ret;
}

int mynos_registryRegister(char * name) {
  return name_request(REGISTRY_REGISTER, name);
}

int mynos_registryLookUp(char * name) {
  return name_request(REGISTRY_LOOKUP, name);
}

/* the names registered by live processes, at most max: how many */
int mynos_registryList(mynos_reg_entry_t * buf, int max) {
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  long long n, i;
  int ret;

  registry_start(&w, REGISTRY_LIST);
  if ((ret = registry_call(&w, &r, &msg)) < 0) return ret;
  n = wire_get_int(&r);
  for (i = 0; i < n && !r.error; i++) {
    char name[64];
    wire_get_cstring(&r, name, sizeof name);
    long long port = wire_get_int(&r), owner = wire_get_int(&r);
    if (r.error || i >= max) continue;
    memset(&buf[i], 0, sizeof buf[i]);
    strncpy(buf[i].name, name, sizeof buf[i].name - 1);
    buf[i].port = (int)port;
    buf[i].owner = (int)owner;
  }
  ret = r.error ? MYNOS_ERR_INVALID : (int)(n < max ? n : max);
  mynos_freeMsg(&msg);
  return ret;
}

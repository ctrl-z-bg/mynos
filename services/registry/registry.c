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
#include <mynos_wire.h>
#include <unistd.h>

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

/* ---- registry/1 (mynos_registry.h): typed IPC ---- */

static void send_reply(int channel, wire_writer * w)
{
  if (!w->error) mynos_send(channel, w->buf, w->len, 0);
  wire_writer_free(w);
}

static void reply_error(int channel, const char * m)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_error(&w, m);
  send_reply(channel, &w);
}

static void reply_int(int channel, int v)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, v);
  send_reply(channel, &w);
}

static const wire_request_doc requests[] = {
  { 0, "register", "name:S", "I",
    "Register a name: a new port, the caller's; the name is the caller's while it "
    "runs." },
  { 1, "lookup", "name:S", "I", "The port of a name." },
  { 1, "list", "U", "L<(name:S,port:I,owner:I)>",
    "Every name, with its port and the process that registered it." },
};

static void describe(int channel)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, REGISTRY_PROTOCOL,
    "The names of the services (the registry, in C since 2002): a name gives a port "
    "to connect to. The registry itself answers at a well-known port.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(channel, &w);
}

/* the live entries (the others dropped on the way, as in a lookup) */
static void registryList(int channel) {
  struct table_entry_s ** pp, * e;
  wire_writer w;
  int n = 0;
  mynos_P(registry.sem);
  pp = &registry.head;
  while ((e = *pp) != NULL) {
    int info = mynos_processInfo(e->owner);
    if (info < 0 || !(info & MYNOS_PROC_ALIVE)) { *pp = e->next; free(e); continue; }
    n++;
    pp = &e->next;
  }
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, n);
  for (e = registry.head; e != NULL; e = e->next) {
    wire_put_cstring(&w, e->name);
    wire_put_int(&w, e->port);
    wire_put_int(&w, e->owner);
  }
  mynos_V(registry.sem);
  send_reply(channel, &w);
}

/* serve one request on a new channel. Requests are served one at a time
   by the main thread: they are short, and the 2004 version's thread per
   request leaked its stack (and used the C library from threads that
   share their creator's TLS, mynos-l9h) */
static void serve(int channel) {
  mynos_msg_t * msg;
  wire_reader r;
  const char * id;
  unsigned int n;
  char name[MAXNAMELEN + 1];
  long long kind;

  /* a client that connects and sends nothing must not stop the registry */
  if (mynos_recv(channel, &msg, 0, 1000) < 0) {
    mynos_freeChannel(channel);
    return;
  }
  wire_reader_init(&r, msg->start, msg->size);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n)) {
    describe(channel);
  } else if (r.error || n != strlen(REGISTRY_PROTOCOL) || memcmp(id, REGISTRY_PROTOCOL, n)) {
    reply_error(channel, "invalid: the registry speaks " REGISTRY_PROTOCOL);
  } else {
    kind = wire_get_int(&r);
    if (kind == REGISTRY_LIST) {
      registryList(channel);
    } else {
      wire_get_cstring(&r, name, sizeof name);   /* a name too long: an error */
      if (r.error || (kind != REGISTRY_REGISTER && kind != REGISTRY_LOOKUP))
        reply_error(channel, "invalid: a request of registry/1, a name of 20 bytes at most");
      else if (kind == REGISTRY_LOOKUP) {
        int port = registryLookUp(name);
        if (port < 0) reply_error(channel, "not_found: no such name");
        else reply_int(channel, port);
      } else if (registryLookUp(name) >= 0) {
        mynos_log("Warning registry: name %s is already present\n", name);
        reply_error(channel, "exists: the name is taken");
      } else {
        /* the caller is the one at the other end of the channel */
        int owner = mynos_channelPeer(channel);
        int port = mynos_allocPort();
        if (port < 0 || owner < 0) {
          mynos_log("Warning registry: allocPort %d, caller %d\n", port, owner);
          if (port >= 0) mynos_freePort(port);
          reply_error(channel, "invalid: no port");
        } else {
          mynos_changePortOwner(port, owner);
          insertIntoRegistry(name, port, owner);
          reply_int(channel, port);
        }
      }
    }
  }
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

  /* itself, by name: so that it can be described like any service */
  insertIntoRegistry("registry", port, getpid());

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

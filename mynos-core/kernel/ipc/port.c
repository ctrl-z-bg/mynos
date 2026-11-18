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

#include "trace.h"
#include "port.h"
#include "kutils.h"
#include "mem/dynalloc.h"
#include "sem.h"
#include "process.h"
#include "channel.h"
#include "video.h"
#include "mynos.h"

#define MAXPORTS 10000

// the ports table
static struct {
  uint32_t free;
  port_t * table[MAXPORTS];
} pTable;

void initPortTable() {
  pTable.free = MAXPORTS;
  kbzero(pTable.table, MAXPORTS * sizeof(port_t*));
}

/* Port ids carry a generation (doc/decisions/identity-and-permissions.md):
   id = slot + MAXPORTS * generation, so that the id of a freed port does
   not name a later one. Well-known ports (below MYNOS_FIRST_FREE_PORT:
   the registry's, 0) keep generation 0: their number is their id. */
#define PORT_GENERATIONS (0x40000000 / MAXPORTS)  /* below 2^30: OCaml's max_int on i386 */
static uint32_t portGeneration[MAXPORTS];

port_t * getPort(int32_t p) {
  port_t * port;
  if (p < 0) return NULL;
  port = pTable.table[p % MAXPORTS];
  return (port && port->id == p) ? port : NULL;
}

/* a free slot for a port. Slots below MYNOS_FIRST_FREE_PORT are well
   known: given out too, a program that allocated a port before the
   registry started took port 0, and the registry ended (at boot, now and
   then, the stress test hung). */
int32_t getFreePort() {
  static uint32_t i = MYNOS_FIRST_FREE_PORT;
  uint32_t n;
  for (n = MYNOS_FIRST_FREE_PORT; n < MAXPORTS; n++) {
    if (pTable.table[i] == NULL) return i;
    if (++i == MAXPORTS) i = MYNOS_FIRST_FREE_PORT;
  }
  {
    static int said = 0;
    ktableFull("port", &said);
  }
  return MYNOS_ERR_FULL;
}

static int32_t newPort(uint32_t slot) {
  port_t * p = kmalloc(sizeof(port_t));
  if (p == NULL) return MYNOS_ERR_FULL;
  pTable.free--;
  initPort(p, CURRPID);
  p->id = slot + MAXPORTS * portGeneration[slot];
  pTable.table[slot] = p;
  listInsert(processTable[currProcess]->portList, (void*)p->id);
  return p->id;
}

/* allocPort (20): a port of the caller */
int32_t __OS_port_allocPort(void) {
  int slot = getFreePort();
  if (slot < 0) return slot;
  return newPort(slot);
}

/* allocPortP (21): a well-known port, by number, for a privileged
   process (the registry) */
int32_t __OS_port_allocPortP(int32_t port) {
  if (port < 0 || port >= MYNOS_FIRST_FREE_PORT) return MYNOS_ERR_INVALID;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (pTable.table[port] != NULL) return MYNOS_ERR_BUSY;
  return newPort(port);
}

void initPort(port_t * p, pid_t pid) {
  p->owner = pid;
  p->locked = 0;
  p->sem = __OS_sem_allocateSemaphore(0);
  p->free = MAXREQ;
  p->wrP = p->rdP = 0;
  kbzero(p->queue, MAXREQ * sizeof(req_t*));
}

/* a connector still waiting: its process is alive (a request of a process
   that ended is left in the queue; its thread, semaphore and stack are
   gone: mynos-blv) */
static int reqAlive(req_t * req) {
  process_descriptor_t * d = proc(req->pid);
  return d != NULL && d->isAlive;
}

int32_t __OS_port_freePort(int32_t p) {
  port_t * port = getPort(p);
  if (port == NULL) return MYNOS_ERR_INVALID;
  if (port->owner != processTable[currProcess]->pid)
    return MYNOS_ERR_DENY;
  if (port->locked) return MYNOS_ERR_BUSY;
  pTable.free++;

  listExtractElem(processTable[currProcess]->portList, (void*)p, NULL);

  /* as when its owner ends: the processes queued to connect are told
     (MYNOS_ERR_BROKEN) instead of waiting for ever */
  __OS_port_freeDead(p);
  return 0;
}

/* a port of a process that ended (endProcess): freed whatever its owner
   was doing with it (it may have died listening on it: a locked port, which
   freePort refuses). The processes waiting to connect get MYNOS_ERR_BROKEN
   instead of waiting for ever: their client looks the service up again. */
void __OS_port_freeDead(int32_t p) {
  port_t * port = getPort(p);
  req_t * req;
  if (port == NULL) return;
  while ((req = nextReq(port)) != NULL) {
    if (reqAlive(req)) {
      *(req->chan) = MYNOS_ERR_BROKEN;
      __OS_sem_V(req->sem);
    }
    kfree(req);
  }
  pTable.free++;
  __OS_sem_freeSemaphore(port->sem);
  kfree(port);
  pTable.table[p % MAXPORTS] = NULL;
  if (p % MAXPORTS >= MYNOS_FIRST_FREE_PORT)
    portGeneration[p % MAXPORTS] =
      (portGeneration[p % MAXPORTS] + 1) % PORT_GENERATIONS;
}

int32_t __OS_port_changeOwner(int32_t port, pid_t newpid) {
  port_t * p = getPort(port);
  if (p == NULL) return MYNOS_ERR_INVALID;
  if (proc(newpid) == NULL || !proc(newpid)->isAlive)
    return MYNOS_ERR_INVALID;
  if (p->owner != processTable[currProcess]->pid) return MYNOS_ERR_DENY;

  listExtractElem(processTable[currProcess]->portList, (void*)port, NULL);
  listInsert(proc(newpid)->portList, (void*)port);

  p->owner = newpid;
  return 0;
}

int32_t __OS_port_connectToPort(int32_t p) {
  port_t * port = getPort(p);
  uint32_t * pun;
  req_t * req;

  if (port == NULL) return MYNOS_ERR_INVALID;
  if (port->free == 0) return MYNOS_ERR_BUSY;
  
  req = kmalloc(sizeof(req_t));
  req->pid = processTable[currProcess]->pid;
  req->sem = currThread->privSem;
  req->chan = &(currThread->lastChannel);
  pun = &(port->wrP);
  while (port->queue[*pun] != NULL) *pun = ((*pun) + 1) % MAXREQ;
  port->queue[*pun] = req;
  port->free--;
  __OS_sem_V(port->sem);  // wake up the port owner
  privP();
  return currThread->lastChannel;
}

int32_t __OS_port_listenPort(int32_t p) {
  port_t * port = getPort(p);
  req_t * req;
  int32_t channel;

  if (port == NULL) return MYNOS_ERR_INVALID;
  if (port->owner != processTable[currProcess]->pid) return MYNOS_ERR_DENY;
  if (port->locked) return MYNOS_ERR_BUSY;
  LOCK_PORT(port);
  for (;;) {                        /* one V on port->sem per request */
    __OS_sem_P(port->sem);
    req = nextReq(port);
    if (req == NULL) KPANIC("PANIC IN listenPort!");
    if (reqAlive(req)) break;
    kfree(req);                     /* its connector has ended */
  }
  channel = allocChannel(processTable[currProcess]->pid, req->pid);
  TRACE(TRACE_CONNECT, req->pid, CURRPID, channel, 0, p, NULL, 0);
  *(req->chan) = channel < 0 ? channel : channel + 1;  /* the other end */
  __OS_sem_V(req->sem);
  kfree(req);   /* (it was never freed: one leak per connection) */
  UNLOCK_PORT(port);
  return channel;
}

req_t * nextReq(port_t * port) {
  uint32_t * p;
  req_t * req;

  if (port->free == MAXREQ) return NULL;  // no message
  p = &(port->rdP);
  while (port->queue[*p] == NULL) (*p) = ((*p)+1) % MAXREQ;
  req = port->queue[*p];
  port->queue[*p] = NULL;
  port->free++;
  return req;
}

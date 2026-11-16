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

port_t * getPort(int32_t p) {
  if ((p < 0) || (p >= MAXPORTS)) return NULL;
  return pTable.table[p];
}

int32_t getFreePort() {
  static uint32_t i = 0;
  if (pTable.free == 0) return MYNOS_ERR_FULL;
  
  while (pTable.table[i] != NULL) i = (i + 1) % MAXPORTS;
  return i;
}

int32_t __OS_port_allocPort(pid_t pid) {
  int p = getFreePort();
  if (p < 0) return p;
  return __OS_port_allocPortP(p, pid);
}

int32_t __OS_port_allocPortP(int32_t port, pid_t pid) {
  port_t * p;

  if (pTable.table[port] != NULL)
    return MYNOS_ERR_BUSY;

  pTable.free--;
  p = kmalloc(sizeof(port_t));
  initPort(p, pid);
  pTable.table[port] = p;

  // insert this port into the pid's port list
  listInsert(processTable[pid]->portList, (void*)port);

  return port;
}

void initPort(port_t * p, pid_t pid) {
  p->owner = pid;
  p->locked = 0;
  p->sem = __OS_sem_allocateSemaphore(0);
  p->free = MAXREQ;
  p->wrP = p->rdP = 0;
  kbzero(p->queue, MAXREQ * sizeof(req_t*));
}

int32_t __OS_port_freePort(int32_t p) {
  port_t * port = getPort(p);
  if (port == NULL) return MYNOS_ERR_INVALID;
  if (port->owner != processTable[currProcess]->pid)
    return MYNOS_ERR_DENY;
  if (port->locked) return MYNOS_ERR_BUSY;
  pTable.free++;

  listExtractElem(processTable[currProcess]->portList, (void*)p, NULL);

  // TODO free the req queue
  __OS_sem_freeSemaphore(port->sem);
  kfree(port);
  pTable.table[p] = NULL;
  return 0;
}

int32_t __OS_port_changeOwner(int32_t port, pid_t newpid) {
  port_t * p = pTable.table[port];
  if (p == NULL) return MYNOS_ERR_INVALID;
  if (p->owner != processTable[currProcess]->pid) return MYNOS_ERR_DENY;

  listExtractElem(processTable[currProcess]->portList, (void*)port, NULL);
  listInsert(processTable[newpid]->portList, (void*)port);

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
  __OS_sem_P(port->sem);
  req = nextReq(port);
  if (req == NULL) KPANIC("PANIC IN listenPort!");
  channel = allocChannel(processTable[currProcess]->pid, req->pid);
  *(req->chan) = channel;
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

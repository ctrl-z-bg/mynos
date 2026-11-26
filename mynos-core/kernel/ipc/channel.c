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
#include "channel.h"
#include "msg.h"
#include "mem/dynalloc.h"
#include "kutils.h"
#include "sem.h"
#include "sched.h"
#include "process.h"
#include "mynos.h"
#include "video.h"

// the channels table
static struct {
  uint32_t free;
  channel_t * table[MAXCNLS];
} cTable;

void initChannelTable() {
  cTable.free = MAXCNLS;
  kbzero(cTable.table, MAXCNLS * sizeof(channel_t*));
}

/* Each end of a channel has its own id: 2 * (slot + MAXCNLS * generation)
   + side, side 0 for the end of the process that listened, 1 for the one
   that connected. The end is known from the id, not from the caller's pid,
   so two threads of one process can talk over a channel (mynos-9e1). The
   generation, as for pids and ports, keeps a freed channel's ids, kept by
   mistake, from naming a later channel; ids stay below 2^30, OCaml's
   max_int on i386. */
#define CHANNEL_GENERATIONS (0x40000000 / (2 * MAXCNLS))
static uint32_t generation[MAXCNLS];

#define SLOT(c) (((uint32_t)(c) >> 1) % MAXCNLS)

/* a free slot */
int32_t getFreeChannel() {
  static uint32_t i = 0;
  static int said = 0;
  if (cTable.free == 0) { ktableFull("channel", &said); return MYNOS_ERR_FULL; }
  
  while (cTable.table[i] != NULL) i = (i + 1) % MAXCNLS;
  return i;
}

channel_t * getChannel(uint32_t c) {
  /* an id from a process: any value (unsigned, so negatives too) */
  channel_t * channel;
  if (c > 0x7fffffff) return NULL;
  channel = cTable.table[SLOT(c)];
  return (channel && channel->id == (int32_t)(c & ~1u)) ? channel : NULL;
}

unichannel_t * allocUnichannel(pid_t p) {
  unichannel_t * c = kmalloc(sizeof(unichannel_t));
  c->receiver = p;
  c->free = MAXMSGS;
  c->sem = -1;
  c->waiter = NULL;
  c->timed = 0;
  c->locked = 0;
  c->wrP = 0;
  c->rdP = 0;
  kbzero(c->msg, MAXMSGS * sizeof(msg_t*));
  return c;
}

int32_t allocChannel(pid_t p1, pid_t p2) {
  channel_t * c;
  int slot = getFreeChannel(), id;
  if (slot < 0)
    return slot;
  id = 2 * (slot + MAXCNLS * generation[slot]);
  c = kmalloc(sizeof(channel_t));
  c->id = id;
  c->c1 = allocUnichannel(p1);
  c->c2 = allocUnichannel(p2);
  cTable.table[slot] = c;
  cTable.free--;

  // insert this channel into the each process channel list
  listInsert(proc(p1)->channelList, (void*)(long)id);
  listInsert(proc(p2)->channelList, (void*)(long)(id + 1));

  return id;   /* p1's end; p2's is id + 1 */
}

/* the end c names, if it is the caller's (its process reads from it) */
unichannel_t * getMyReadChannel(uint32_t c) {
  channel_t * channel = getChannel(c);
  unichannel_t * mine;
  if (channel == NULL) return NULL;
  mine = (c & 1) ? channel->c2 : channel->c1;
  return mine->receiver == CURRPID ? mine : NULL;
}

/* the other end, where the caller's messages go */
unichannel_t * getMyWriteChannel(uint32_t c) {
  channel_t * channel = getChannel(c);
  if (getMyReadChannel(c) == NULL) return NULL;
  return (c & 1) ? channel->c1 : channel->c2;
}

void freeUnichannel(unichannel_t * c) {
  int i;
  for (i = 0; i < MAXMSGS; i++) 
    if (c->msg[i] != NULL) freeMsg(c->msg[i]);
  kfree(c);
}

void freeChannel(channel_t * c) {
  freeUnichannel(c->c1);
  freeUnichannel(c->c2);
  kfree(c);
}

int32_t insertMsgIntoChannel(unichannel_t * channel, msg_t * msg) {
  uint32_t * p = &(channel->wrP);
  if (channel->free == 0)
    return MYNOS_ERR_FULL;
  while (channel->msg[*p] != NULL) (*p) = ((*p)+1) % MAXMSGS;
  channel->msg[*p] = msg;
  channel->free--;
  return 0;
}

msg_t * nextMsg(unichannel_t * channel) {
  uint32_t * p;
  msg_t * msg;

  if (channel->free == MAXMSGS) return NULL;  // no message
  p = &(channel->rdP);
  while (channel->msg[*p] == NULL) (*p) = ((*p)+1) % MAXMSGS;
  msg = channel->msg[*p];
  channel->msg[*p] = NULL;
  channel->free++;
  return msg;
}

int32_t isChannelBroken(int32_t c) {
  unichannel_t * chan = getMyWriteChannel(c);
  return (chan->receiver == -1);
}

int32_t __OS_ipc_freeChannel(int32_t c) {
  channel_t * chan = getChannel(c);
  unichannel_t * uc, * w;
  int32_t broken;

  // check if I'm a channel partner
  uc = getMyReadChannel(c);

  if (uc == NULL) return MYNOS_ERR_INVALID;

  if (trace_on) {
    unichannel_t * other = getMyWriteChannel(c);
    trace_event(TRACE_FREE, CURRPID, other ? other->receiver : -1,
		TRACE_CHANNEL(c), 0, 0, NULL, 0);
  }

  // check if broken BEFORE erasing the receiver field
  // it could interfer with isChannelBroken 
  broken = isChannelBroken(c);
  w = getMyWriteChannel(c);        /* (only while this end is still mine) */
  uc->receiver = -1;

  /* wake whoever waits on the other side (mynos-3bb): a thread in recv
     on the other direction finds no message and gets MYNOS_ERR_BROKEN; a
     sender waiting for this side to take its message is released (its
     next recv finds the channel broken) */
  {
    uint32_t i;
    if (w && w->sem != -1) {
      /* once (ipc.c's send): not if its timer woke it already */
      if (!w->timed || timerQueueExtractThread(w->waiter) != NULL)
	__OS_sem_V(w->sem);
      w->sem = -1;
    }
    for (i = 0; i < MAXMSGS; i++)
      if (uc->msg[i] && uc->msg[i]->sem != -1) {
	__OS_sem_V(uc->msg[i]->sem);
	uc->msg[i]->sem = -1;
      }
  }
  
#ifdef DEBUG
  printk("process ");
  print_int(currProcess);
  printk(" frees channel ");
  print_int(c);
#endif

  // it is no longer mine (this was done only by the last side to free
  // it: the other one kept the id in its list, one leak per channel)
  listExtractElem(processTable[currProcess]->channelList, (void*)(long)c, NULL);

  // check if the other partner freed the channel too
  if (!broken) {
#ifdef DEBUG
    printk(" but other side didn't it yet\n");
#endif
    return 0;
  }

#ifdef DEBUG
    printk(" and I'm the last referent one: let's free it!\n");
#endif

  freeChannel(chan);
  cTable.table[SLOT(c)] = NULL;
  generation[SLOT(c)] = (generation[SLOT(c)] + 1) % CHANNEL_GENERATIONS;
  cTable.free++;

  return 0;
}

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

int32_t getFreeChannel() {
  static uint32_t i = 0;
  if (cTable.free == 0) return MYNOS_ERR_FULL;
  
  while (cTable.table[i] != NULL) i = (i + 1) % MAXCNLS;
  return i;
}

channel_t * getChannel(uint32_t c) {
  /* an id from a process: any value (unsigned, so negatives too) */
  if (c >= MAXCNLS) return NULL;
  return cTable.table[c];
}

unichannel_t * allocUnichannel(pid_t p) {
  unichannel_t * c = kmalloc(sizeof(unichannel_t));
  c->receiver = p;
  c->free = MAXMSGS;
  c->sem = -1;
  c->locked = 0;
  c->wrP = 0;
  c->rdP = 0;
  kbzero(c->msg, MAXMSGS * sizeof(msg_t*));
  return c;
}

int32_t allocChannel(pid_t p1, pid_t p2) {
  channel_t * c;
  int id = getFreeChannel();
  if (id < 0)
    return id;
  c = kmalloc(sizeof(channel_t));
  c->c1 = allocUnichannel(p1);
  c->c2 = allocUnichannel(p2);
  cTable.table[id] = c;
  cTable.free--;

  // insert this channel into the each process channel list
  listInsert(processTable[p1]->channelList, (void*)id);
  listInsert(processTable[p2]->channelList, (void*)id);

  return id;
}

unichannel_t * getMyWriteChannel(uint32_t c) {
  channel_t * channel = getChannel(c);
  if (channel == NULL) return NULL;
  if (channel->c1->receiver == processTable[currProcess]->pid)
    return channel->c2;
  if (channel->c2->receiver == processTable[currProcess]->pid)
    return channel->c1;
  return NULL;
}

unichannel_t * getMyReadChannel(uint32_t c) {
  channel_t * channel = getChannel(c);
  if (channel == NULL) return NULL;
  if (channel->c1->receiver == processTable[currProcess]->pid)
    return channel->c1;
  if (channel->c2->receiver == processTable[currProcess]->pid)
    return channel->c2;
  return NULL;
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
  unichannel_t * uc;
  int32_t broken;

  // check if I'm a channel partner
  uc = getMyReadChannel(c);

  if (uc == NULL) return MYNOS_ERR_INVALID;
  if (uc->receiver != processTable[currProcess]->pid)
    return MYNOS_ERR_DENY;

  if (trace_on) {
    unichannel_t * other = getMyWriteChannel(c);
    trace_event(TRACE_FREE, currProcess, other ? other->receiver : -1, c,
		0, 0, NULL, 0);
  }

  // check if broken BEFORE erasing the receiver field
  // it could interfer with isChannelBroken 
  broken = isChannelBroken(c);
  uc->receiver = -1;
  
#ifdef DEBUG
  printk("process ");
  print_int(currProcess);
  printk(" frees channel ");
  print_int(c);
#endif

  // it is no longer mine (this was done only by the last side to free
  // it: the other one kept the id in its list, one leak per channel)
  listExtractElem(processTable[currProcess]->channelList, (void*)c, NULL);

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
  cTable.table[c] = NULL;
  cTable.free++;

  return 0;
}

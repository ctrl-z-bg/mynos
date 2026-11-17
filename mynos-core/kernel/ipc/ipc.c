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
#include "ipc.h"
#include "msg.h"
#include "port.h"
#include "channel.h"
#include "mem/dynalloc.h"
#include "mem/externalmem.h"
#include "mem/mem.h"
#include "process.h"
#include "kutils.h"
#include "sem.h"
#include "sched.h"

void initIPC() {
  initPortTable();
  initChannelTable();
}

int32_t __OS_ipc_send(int32_t c, void * start, uint32_t size,
		      uint32_t flags) {
  uint32_t spage, tpage;  // start and terminal pages
  int32_t destpage;
  int32_t destpageaddr;
  msg_t * msg;
  uint32_t uintstart = (uint32_t)start;
  unichannel_t * channel;
  int32_t tmp;
  int32_t justSync = (start == NULL);

  // check if the channel exists
  if (getChannel(c) == NULL) return MYNOS_ERR_INVALID;

  // the message must be the sender's own memory
  if (!justSync && !__mem_userArea(start, size)) return MYNOS_ERR_INVALID;

  // check if this end is mine
  if (getMyReadChannel(c) == NULL) return MYNOS_ERR_DENY;

  // check if the channel is broken
  if (isChannelBroken(c)) return MYNOS_ERR_BROKEN;

  channel = getMyWriteChannel(c);

  /* the pages of the message: tpage is the page of its last byte (it was
     the page after the end: a message ending at a page boundary mapped one
     page more into the receiver, which never unmapped it) */
  spage = uintstart >> 12;
  tpage = size ? (uintstart + size - 1) >> 12 : spage;
  

  // use external page mapping only if the message is big enaugh or shared
  if (!justSync && ((size > MYNOS_SHORT_MESSAGE_SIZE) ||
		    (flags & MYNOS_IPC_SHARED))) {
    destpage =  __OS_mapPagesTo(channel->receiver, spage, tpage - spage + 1,
				flags);
    if (destpage < 0) return destpage;
    destpageaddr = destpage << 12;
  }

  TRACE(TRACE_SEND, CURRPID, channel->receiver, TRACE_CHANNEL(c), size, 0,
	justSync ? NULL : start, size);
  msg = kmalloc(sizeof(msg_t));

  // set the msg->start field
  msg->isShort = 0;
  if (!justSync) {
    if ((size > MYNOS_SHORT_MESSAGE_SIZE) || (flags & MYNOS_IPC_SHARED))
      msg->start = (void*)(destpageaddr + (uintstart - (spage<<12)));
    else {   // short message
      kmemcpy(msg->shortmsg, start, size);
      msg->start = msg->shortmsg;
      msg->isShort = 1;
    }
  } else
    msg->start = NULL;
  // set the msg->size field
  msg->size = size;

  if ((!justSync) && (flags & MYNOS_IPC_SHARED))
    msg->shared = 1;
  else
    msg->shared = 0;

  msg->sem = -1;

  tmp = insertMsgIntoChannel(channel, msg);
  if (tmp < 0) {
    kfree(msg);
    return tmp;
  }

  if (channel->sem == -1) {  // the receiver is not waiting
    if (!(flags & MYNOS_IPC_NONBLOCK)) {
      msg->sem = currThread->privSem;
      privP();
    }
  } else { // the receiver is waiting
    __OS_sem_V(channel->sem);
    channel->sem = -1;   // he's no longer waiting
  }

  return 0;
}

int32_t __OS_ipc_recv(int32_t c, mynos_msg_t * mmsg, 
		      void * shortmsg, uint32_t flags, uint32_t timeout) {
  unichannel_t * rc;
  msg_t * msg;
  int timeron = (timeout > 0);

  /* the kernel writes the message's description there: the receiver's
     own memory, not the kernel's */
  if ((mmsg && !__mem_userArea(mmsg, sizeof(mynos_msg_t))) ||
      (shortmsg && !__mem_userArea(shortmsg, MYNOS_SHORT_MESSAGE_SIZE)))
    return MYNOS_ERR_INVALID;

  // this end must be mine
  if (getChannel(c) == NULL) return MYNOS_ERR_INVALID;
  rc = getMyReadChannel(c);
  if (rc == NULL) return MYNOS_ERR_DENY;

  // check if the channel is locked
  if (rc->locked) return MYNOS_ERR_BUSY;

  // else lock it!
  LOCK_CHANNEL(rc);

  msg = nextMsg(rc);

  // if no more message then check if channel is broken, otw wait
  if (msg == NULL) {
    if (isChannelBroken(c)) { UNLOCK_CHANNEL(rc); return MYNOS_ERR_BROKEN; }
    rc->sem = currThread->privSem;
    
    // timer on?
    if (timeron)
      timerQueueInsert(currThread, timeout);

    privP();

    // if timer expired (so no one sent a message), I'm no longer waiting
    if (timeron && (timerQueueExtractThread(currThread) == NULL)) {
      rc->sem = -1;
      UNLOCK_CHANNEL(rc);
      return MYNOS_ERR_EXPIRED;
    }

    msg = nextMsg(rc);
  }

  if (msg == NULL) { UNLOCK_CHANNEL(rc); return MYNOS_ERR_BROKEN; }

  if (trace_on) {
    unichannel_t * other = getMyWriteChannel(c);
    trace_event(TRACE_RECV, CURRPID, other ? other->receiver : -1,
		TRACE_CHANNEL(c),
		msg->size, 0, NULL, 0);
  }

  // check if sender his waiting
  if (msg->sem != -1) {
    __OS_sem_V(msg->sem);
  }

  /* the description into the receiver's memory: it may have waited, and
     another of its threads may have unmapped that memory meanwhile, so
     copied with copy_to_user, which fails instead of faulting */
  if (mmsg != NULL) {
    mynos_msg_t m;
    int bad = 0;
    m.isShort = 0;
    if (!(msg->isShort)) {
      m.start = msg->start;
    } else {
      if (shortmsg) {
	bad = copy_to_user(shortmsg, msg->shortmsg, msg->size) < 0;
	m.start = shortmsg;
	m.isShort = 1;
      } else
	m.start = NULL;
    }
    m.size = msg->size;
    if (bad || copy_to_user(mmsg, &m, sizeof m) < 0) {
      freeMsg(msg);
      UNLOCK_CHANNEL(rc);
      return MYNOS_ERR_INVALID;
    }
  }

  freeMsg(msg);

  // unlock the channel
  UNLOCK_CHANNEL(rc);

  return 0;
}



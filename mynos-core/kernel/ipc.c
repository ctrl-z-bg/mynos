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

#include "ipc.h"
#include "dynalloc.h"
#include "kutils.h"
#include "tss.h"
#include "process.h"
#include "video.h"

#ifdef IPC

#define MAXCHANNELS 20

void __OS_ipc_initChannelList(channelList_t * list) {
  uint32_t i;
  list->channels = (channel_t**)kmalloc(MAXCHANNELS * sizeof(channel_t*));
  for (i = 0; i < MAXCHANNELS; i++)
    (list->channels)[i] = NULL;
  list->sender = -1;
}

void __OS_ipc_destroyChannelList(channelList_t * list) {
  uint32_t i;

  for (i = 0; i < MAXCHANNELS; i++)
    if ((list->channels)[i] != NULL)
      __OS_ipc_destroyChannel((list->channels)[i]);
  kfree(list->channels);
}

void __OS_ipc_destroyChannelIntoList(channelList_t * list, channel_t * c) {
  uint32_t i;
  
  for (i = 0; i < MAXCHANNELS; i++)
    if ((list->channels)[i] == c) {
      __OS_ipc_destroyChannel(c);
      (list->channels)[i] = NULL;
    }
}

int32_t __OS_ipc_insertIntoList(channelList_t * list, channel_t * c) {
  static int32_t id = 0;
  int32_t start;

  start = id;
  do {
    if ((list->channels)[id] == NULL)
      break;
    id = (id + 1) % MAXCHANNELS;
  } while (id != start);
  if ((list->channels)[id] != NULL)
    return -1;
  (list->channels)[id] = c;
  return 0;
}

channel_t * __OS_ipc_searchSender(channelList_t * list, pid_t sender) {
  int32_t start;
  int32_t found;
  
  start = list->recIdx;
  do {
    if (((list->channels)[list->recIdx] != NULL) &&
	(!sender || ((list->channels)[list->recIdx]->sender == sender))) {
      found = 1;
      break;
    }
    list->recIdx = (list->recIdx + 1) % MAXCHANNELS;
  } while (list->recIdx != start);
  if (!found)
    return NULL;
  return (list->channels)[list->recIdx];
}

channel_t * __OS_ipc_createChannel(uint32_t size,
				   pid_t sender) {
  channel_t * c;
  c = (channel_t*)kmalloc(sizeof(channel_t));
  if (c == NULL) return NULL;
  c->buf = (char*)kmalloc(size);
  if (c->buf == NULL) return NULL;
  c->bufsize = size;
  c->msgsize = 0;
  c->sender = sender;
  c->senderBlocked = 0;
  return c;
}

channel_err_t __OS_ipc_writeToChannel(channel_t * c, 
				      char * buf, uint32_t size) {
  /* TODO: checks on buffer permissions */
  if (size > c->bufsize)
    return CHANNEL_ERR_OVERFLOW;
  kmemcpy((void*)(c->buf), (void*)buf, size);
  c->msgsize = size;
  return CHANNEL_ERR_OK;
}

int __OS_ipc_readFromChannel(channel_t * c, char * buf, 
			     uint32_t maxsize,
			     pid_t * sender) {
  /* TODO: checks on buffer permissions */
  if (maxsize != 0)  // zero means no control
    if (maxsize < c->msgsize)
      return -1;
  kmemcpy((void*)buf, (void*)c->buf, c->msgsize);
  if (sender) *sender = c->sender;
  return c->msgsize;
}

void __OS_ipc_destroyChannel(channel_t * c) {
  kfree(c->buf);
  kfree(c);
}

/* the old data will be lost */
channel_err_t __OS_ipc_resizeChannel(channel_t * c, uint32_t size) {
  kfree(c->buf);
  c->buf = (char*)kmalloc(size);
  if (c->buf == NULL) return CHANNEL_ERR_NOMEM;
  c->bufsize = size;
  c->msgsize = 0;
  return CHANNEL_ERR_OK;
}

void __OS_ipc_zeroChannel(channel_t * c) {
  c->msgsize = 0;
}

int __OS_ipc_send(pid_t dest, char * buf, uint32_t size, uint32_t flags) {
  tss_t * rtss;         // receiver tss
  tss_t * stss;         // sender tss
  channelList_t * list; // receiver channel list
  channel_t * c;        // new channel

  if ((dest >= MAXPROCESSES) || (dest < 0) || (!processTable[dest].isAlive))
    return -1;
  rtss = &(processTable[dest]);
  stss = &(processTable[currProcess]);
  list = &(rtss->channels);

  // LOCK rec list

  /* the receiver is waiting for me or anyone */
  if ((rtss->isWaitingSender == currProcess) ||
      (rtss->isWaitingSender == 0)) {
    (rtss->channels).sender = currProcess;  // It was me who woke the recv
    rtss->isWaitingSender = -1;             // let's wake up the recv
  }

  /* create the channel... */
  if ((c = __OS_ipc_createChannel(size, currProcess)) == NULL) {
    // UNLOCK rec list
    return -1;
  }
  /* ... and insert it into the list */
  if (__OS_ipc_insertIntoList(list, c) < 0) {
    // UNLOCK rec list
    __OS_ipc_destroyChannel(c);
    return -1;
  }
  
  /* fill the channel */
  if (__OS_ipc_writeToChannel(c, buf, size) != CHANNEL_ERR_OK) {
    // UNLOCK rec list
    return -1;
  }
  
  if (!(flags & IPC_FLAGS_NOBLOCK)) {
    stss->isWaitingReceiver = dest;
    c->senderBlocked = 1;           // the receiver will see I'm blocked
  }

  // UNLOCK rec list
  {   // tasksw to idle process
    struct {long a ,b;} tmp = {0, 0};
    
    currProcess = 0;
    tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
    __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
  }

  return 0;
}

int __OS_ipc_recv(pid_t sender, char * buf, uint32_t size, uint32_t flags) {
  tss_t * rtss;         // receiver tss
  tss_t * stss;         // sender tss
  channelList_t * list; // receiver channel list
  channel_t * c;
  int32_t done = 0;

  while (!done) {
    if ((sender >= MAXPROCESSES) || (sender < 0))
      return -1;
    
    rtss = &(processTable[currProcess]);
    list = &(rtss->channels);
    stss = &(processTable[sender]);
    
    // LOCK rec list
    c = __OS_ipc_searchSender(list, sender);
    
    if (c == NULL) {
      /* if I'm not blocking and there is no message for me return err */
      if (flags & IPC_FLAGS_NOBLOCK) {
	// UNLOCK rec list
	return -1;
      }
      rtss->isWaitingSender = sender;
    } else { // c is not null
      /* the msg is longer than we expected */
      if (__OS_ipc_readFromChannel(c, buf, size, NULL) < 0) {
	__OS_ipc_destroyChannelIntoList(list, c);
	// UNLOCK rec list
	return -1;
      }
      __OS_ipc_destroyChannelIntoList(list, c);
      done = 1;
      
      if (c->senderBlocked) {
	// LOCK sender list
	stss->isWaitingReceiver = -1;
	// UNLOCK sender list
      }
    }  
    
    // UNLOCK rec list
    {   // tasksw to idle process
      struct {long a ,b;} tmp = {0, 0};
      
      currProcess = 0;
      tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
      __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
    }
  }     // while (!done)

  return 0;
}

int __OS_ipc_recvAll(pid_t * sender, char * buf, uint32_t size, 
		     uint32_t flags) {
  tss_t * rtss;         // receiver tss
  tss_t * stss;         // sender tss
  channelList_t * list; // receiver channel list
  channel_t * c;
  int32_t done = 0;

  while (!done) {
    rtss = &(processTable[currProcess]);
    list = &(rtss->channels);
    
    // LOCK rec list
    if ((rtss->channels).sender != -1) {
      *sender = (rtss->channels).sender;
      c = __OS_ipc_searchSender(list, *sender);
    } else
      c = __OS_ipc_searchSender(list, 0);
    
    /* this should be true only if nobody woke me and the list is empty */
    if (c == NULL) {
      /* if I'm not blocking and there is no message for me return err */
      if (flags & IPC_FLAGS_NOBLOCK) {
	// UNLOCK rec list
	return -1;
      }
      rtss->isWaitingSender = 0;
    } else { // c is not null
      /* the msg is longer than we expected */
      if (__OS_ipc_readFromChannel(c, buf, size, sender) < 0) {
	__OS_ipc_destroyChannelIntoList(list, c);
	// UNLOCK rec list
	return -1;
      }
      __OS_ipc_destroyChannelIntoList(list, c);
      done = 1;

      if (c->senderBlocked) {
	stss = &(processTable[*sender]);
	// LOCK sender list
	stss->isWaitingReceiver = -1;
	// UNLOCK sender list
      }
    }  
    
    // UNLOCK rec list
    {   // tasksw to idle process
      struct {long a ,b;} tmp = {0, 0};
      
      currProcess = 0;
      tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
      __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
    }
  }     // while (!done)

  return 0;
}

#endif // IPC

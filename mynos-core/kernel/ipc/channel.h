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

#ifndef __CHANNEL_H__
#define __CHANNEL_H__

#include "global.h"
#include "msg.h"

#define LOCK_CHANNEL(p)   {p->locked = 1;}
#define UNLOCK_CHANNEL(p) {p->locked = 0;}

// max channels
#define MAXCNLS 4096

// max messages per channel
#define MAXMSGS 10

typedef struct {
  pid_t receiver;
  int32_t locked; // if someone is already reading
  int32_t sem;  // receiver's semaphore
  int32_t free;
  uint32_t wrP; // pointer to write into the list
  uint32_t rdP;  // pointer to read from the list
  msg_t * msg[MAXMSGS];
} unichannel_t;  // unidirectional channel

typedef struct {
  int32_t id;     // slot + MAXCNLS * generation
  unichannel_t * c1;
  unichannel_t * c2;
} channel_t;

void initChannelTable();
int32_t allocChannel(pid_t p1, pid_t p2);
channel_t * getChannel(uint32_t c);
unichannel_t * getMyWriteChannel(uint32_t c);
unichannel_t * getMyReadChannel(uint32_t c);
int32_t insertMsgIntoChannel(unichannel_t * channel, msg_t * msg);
msg_t * nextMsg(unichannel_t * channel);
int32_t __OS_ipc_freeChannel(int32_t c);
int32_t isChannelBroken(int32_t c);

#endif

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

#ifndef __IPC_H__
#define __IPC_H__

#include "global.h"

/* it returns a pointer to a channel */
#define IPC_GET_CHANNEL(PLIST, ID) ((PLIST)->channels[ID])

#define IPC_SET_CHANNEL(PLIST, ID, PCHANNEL) {\
    ((PLIST)->channels)[ID] = PCHANNEL;\
  }

typedef enum {
  CHANNEL_ERR_OK,
  CHANNEL_ERR_OVERFLOW,
  CHANNEL_ERR_NOMEM,
  CHANNEL_ERR_TABLEFULL
} channel_err_t;

typedef struct {
  char * buf;
  uint32_t msgsize;
  uint32_t bufsize;
} channel_t;

typedef struct {
  channel_t ** channels;
  /* something else, e.g. a semaphore... */
} channelList_t;

/* channels table stuff */
void          __OS_ipc_initChannelList(channelList_t * list);
void          __OS_ipc_destroyChannelList(channelList_t * list);
int32_t       __OS_ipc_getFreshID(channelList_t * list);


/* channels stuff */
channel_t *   __OS_ipc_createChannel(uint32_t size);
channel_err_t __OS_ipc_writeToChannel(channel_t * c, 
				      char * buf, uint32_t size);
channel_err_t __OS_ipc_readFromChannel(channel_t * c, char * buf,
				       uint32_t maxsize);
void          __OS_ipc_destroyChannel(channel_t * c);

/* the old data will be lost */
channel_err_t __OS_ipc_resizeChannel(channel_t * c, uint32_t size);

void          __OS_ipc_zeroChannel(channel_t * c);

#endif

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

#define MAXCHANNELS 2
extern channel_t ** _channelTable;

/* channels table stuff */
void          __OS_channel_initChannelsTable();
int32_t       __OS_channel_getFreshID();


/* channels stuff */
channel_t *   __OS_channel_createChannel(uint32_t size);
channel_err_t __OS_channel_writeToChannel(channel_t * c, 
					  char * buf, uint32_t size);
channel_err_t __OS_channel_readFromChannel(channel_t * c, char * buf);
void          __OS_channel_destroyChannel(channel_t * c);

/* the old data will be lost */
channel_err_t __OS_channel_resizeChannel(channel_t * c, uint32_t size);

void          __OS_channel_zeroChannel(channel_t * c);

#endif

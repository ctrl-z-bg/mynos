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

#define MAXCHANNELS 20

void __OS_ipc_initChannelList(channelList_t * list) {
  uint32_t i;
  list->channels = (channel_t**)kmalloc(MAXCHANNELS * sizeof(channel_t*));
  for (i = 0; i < MAXCHANNELS; i++)
    (list->channels)[i] = NULL;
}

void __OS_ipc_destroyChannelList(channelList_t * list) {
  uint32_t i;

  for (i = 0; i < MAXCHANNELS; i++)
    if ((list->channels)[i] != NULL)
      __OS_ipc_destroyChannel((list->channels)[i]);
  kfree(list->channels);
}

int32_t __OS_ipc_getFreshID(channelList_t * list) {
  static int32_t id = 0;
  int32_t start;

  start = id;
  do {
    if ((list->channels)[id] == NULL)
      break;
    id = (id + 1) % MAXCHANNELS;
  } while (id != start);
  if ((list->channels)[id] == NULL)
    return id;
  else
    return -1;
}

channel_t * __OS_ipc_createChannel(uint32_t size) {
  channel_t * c;
  c = (channel_t*)kmalloc(sizeof(channel_t));
  if (c == NULL) return NULL;
  c->buf = (char*)kmalloc(size);
  if (c->buf == NULL) return NULL;
  c->bufsize = size;
  c->msgsize = 0;
  return c;
}

channel_err_t __OS_ipc_writeToChannel(channel_t * c, char * buf, uint32_t size) {
  /* TODO: checks on buffer permissions */
  if (size > c->bufsize)
    return CHANNEL_ERR_OVERFLOW;
  kmemcpy((void*)(c->buf), (void*)buf, size);
  c->msgsize = size;
  return CHANNEL_ERR_OK;
}

channel_err_t __OS_ipc_readFromChannel(channel_t * c, char * buf, 
				       uint32_t maxsize) {
  /* TODO: checks on buffer permissions */
  if (maxsize != 0)  // zero means no control
    if (maxsize < c->msgsize)
      return CHANNEL_ERR_OVERFLOW;
  kmemcpy((void*)buf, (void*)c->buf, c->msgsize);
  return CHANNEL_ERR_OK;
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

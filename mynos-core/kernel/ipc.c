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

channel_t ** _channelTable;

void __OS_channel_initChannelsTable() {
  uint32_t i;
  _channelTable = (channel_t **)kmalloc(MAXCHANNELS * sizeof(channel_t*));
  for (i = 0; i < MAXCHANNELS; i++)
    _channelTable[i] = NULL;
}

int32_t __OS_channel_getFreshID() {
  static int32_t id = 0;
  int32_t start;

  start = id;
  do {
    id = (id + 1) % MAXCHANNELS;
  } while ((_channelTable[id] != NULL) && (id != start));
  if (id != start)
    return id;
  else
    return -1;
}

channel_t * __OS_channel_createChannel(uint32_t size) {
  channel_t * c;
  c = (channel_t*)kmalloc(sizeof(channel_t));
  if (c == NULL) return NULL;
  c->buf = (char*)kmalloc(size);
  if (c->buf == NULL) return NULL;
  c->bufsize = size;
  c->msgsize = 0;
  return c;
}

channel_err_t __OS_channel_writeToChannel(channel_t * c, char * buf, uint32_t size) {
  /* TODO: checks on buffer permissions */
  if (size > c->bufsize)
    return CHANNEL_ERR_OVERFLOW;
  kmemcpy((void*)(c->buf), (void*)buf, size);
  c->msgsize = size;
  return CHANNEL_ERR_OK;
}

channel_err_t __OS_channel_readFromChannel(channel_t * c, char * buf) {
  /* TODO: checks on buffer permissions */
  kmemcpy((void*)buf, (void*)c->buf, c->msgsize);
  return CHANNEL_ERR_OK;
}

void __OS_channel_destroyChannel(channel_t * c) {
  kfree(c->buf);
  kfree(c);
}

/* the old data will be lost */
channel_err_t __OS_channel_resizeChannel(channel_t * c, uint32_t size) {
  kfree(c->buf);
  c->buf = (char*)kmalloc(size);
  if (c->buf == NULL) return CHANNEL_ERR_NOMEM;
  c->bufsize = size;
  c->msgsize = 0;
  return CHANNEL_ERR_OK;
}

void __OS_channel_zeroChannel(channel_t * c) {
  c->msgsize = 0;
}

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

#include "../include/mynos.h"
#include "syscall.h"

#include <stdlib.h>
#include <sys/mman.h>

int mynos_send(int channel, void * buf, unsigned int size,
	       unsigned int flags) {
  int ret;
  ret = __mynos_syscall(3, (int)channel, (int)buf, (int)size, (int)flags, 0);
  return ret;
}

static int  __mynos_recv(int channel, mynos_msg_t * msg,
			 void * shortmsg, unsigned int flags,
			 unsigned int timeout) {
  int ret;
  ret = __mynos_syscall(4, (int)channel, (int)msg, (int)shortmsg, (int)flags, (int)timeout);
  if (ret < 0) {
    if (shortmsg != NULL) free(shortmsg);
    if (msg != NULL) free(msg);
  } else 
    if (msg && (msg->start != shortmsg))  // if it wasn't a short message...
      if (shortmsg != NULL) free(shortmsg);
  return ret;
}

int mynos_recv(int channel, mynos_msg_t **pmsg, 
		   unsigned int flags, unsigned int timeout) {
  void * shortmsg = malloc(MYNOS_SHORT_MESSAGE_SIZE);
  int ret;
  (*pmsg) = (mynos_msg_t*)malloc(sizeof(mynos_msg_t));
  ret = __mynos_recv(channel, *pmsg, shortmsg, flags, timeout);
  /* on an error __mynos_recv freed both: no dangling pointer */
  if (ret < 0) *pmsg = NULL;
  return ret;
}

void mynos_signalSync(int channel) {
  mynos_send(channel, NULL, 0, 0);
}

void mynos_waitSync(int channel) {
  __mynos_recv(channel, NULL, NULL, 0, 0);
}

int mynos_freeChannel(int c) {
  int ret;
  ret = __mynos_syscall(5, (int)c, 0, 0, 0, 0);
  return ret;    
}

int mynos_freeMsg(mynos_msg_t ** pmsg) {
  mynos_msg_t * msg = *pmsg;
  void * start;
  unsigned int len;
  if (msg == NULL) return 0;
  *pmsg = NULL;
  if (msg->isShort)
    free(msg->start);
  else {
    start = (void *)((unsigned int)(msg->start) & 0xFFFFF000);
    len = ((unsigned int)(msg->start) & 0xFFF) + msg->size;
    munmap(start, len);
  }
  free(msg);
  return 0;
}


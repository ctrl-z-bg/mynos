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
#include "mynos.h"

void initIPC();
int32_t __OS_ipc_send(int32_t channel, void * start, uint32_t size,
		      uint32_t flags);
int32_t __OS_ipc_recv(int32_t c, mynos_msg_t * mmsg, 
		      void * shortmsg, uint32_t flags);

#endif

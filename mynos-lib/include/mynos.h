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

#ifndef __MYNOS_H__
#define __MYNOS_H__

#define MYNOS_IPC_FLAGS_NONBLOCK 0x1

int mynos_send(int dest, char * buf, unsigned int size,
	       unsigned int flags);
int mynos_recv(int sender, char * buf, unsigned int maxsize,
	       unsigned int flags);
int mynos_recvAll(int * sender, char * buf, unsigned int maxsize,
		  unsigned int flags);

#endif

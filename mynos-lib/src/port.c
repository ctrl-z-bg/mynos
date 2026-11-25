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

#include <unistd.h>

int mynos_allocPort() {
  return __mynos_syscall(20, 0, 0, 0, 0, 0);
}

/* a well-known port (below MYNOS_FIRST_FREE_PORT), privileged processes
   only */
int mynos_allocPortP(int port) {
  return __mynos_syscall(21, (long)port, 0, 0, 0, 0);
}

/* the pid at the other end of one of our channels */
int mynos_channelPeer(int channel) {
  return __mynos_syscall(26, channel, 0, 0, 0, 0);
}

int mynos_connectToPort(int port) {
  int ret;
  ret = __mynos_syscall(22, (long)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_listenPort(int port) {
  int ret;
  ret = __mynos_syscall(23, (long)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_freePort(int port) {
  int ret;
  ret = __mynos_syscall(24, (long)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_changePortOwner(int port, int newpid) {
  int ret;
  ret = __mynos_syscall(25, (long)port, (long)newpid, 0, 0, 0);
  return ret;
}


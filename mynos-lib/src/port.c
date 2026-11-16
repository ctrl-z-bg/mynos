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
  int ret;
  pid_t pid = getpid();
  ret = __mynos_syscall(20, (int)pid, 0, 0, 0, 0);
  return ret;    
}

int mynos_allocPortP(int port) {
  int ret;
  pid_t pid = getpid();
  ret = __mynos_syscall(21, (int)port, (int)pid, 0, 0, 0);
  return ret;
}

int mynos_connectToPort(int port) {
  int ret;
  ret = __mynos_syscall(22, (int)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_listenPort(int port) {
  int ret;
  ret = __mynos_syscall(23, (int)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_freePort(int port) {
  int ret;
  ret = __mynos_syscall(24, (int)port, 0, 0, 0, 0);
  return ret;    
}

int mynos_changePortOwner(int port, int newpid) {
  int ret;
  ret = __mynos_syscall(25, (int)port, (int)newpid, 0, 0, 0);
  return ret;
}


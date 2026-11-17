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

#ifndef __PORT_H__
#define __PORT_H__

#include "global.h"

#define MAXREQ   10

#define LOCK_PORT(p)   {p->locked = 1;}
#define UNLOCK_PORT(p) {p->locked = 0;}

// this is for connecting request
typedef struct {
  pid_t pid;
  int32_t sem;
  int32_t * chan;  // to communicate the allocated channel
} req_t;

typedef struct {
  int32_t id;     // slot + MAXPORTS * generation
  pid_t owner;
  int32_t locked;
  int32_t sem;    // owner sem
  uint32_t free;
  uint32_t wrP;
  uint32_t rdP;
  req_t * queue[MAXREQ];
} port_t;

void initPortTable();
int32_t getFreePort();
int32_t __OS_port_allocPort(void);
void initPort(port_t * p, pid_t pid);
int32_t __OS_port_allocPortP(int32_t port);
int32_t __OS_port_freePort(int32_t port);
int32_t __OS_port_changeOwner(int32_t port, pid_t newpid);
req_t * nextReq(port_t * port);
int32_t __OS_port_connectToPort(int32_t p);
int32_t __OS_port_listenPort(int32_t p);

#endif

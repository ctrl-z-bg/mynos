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

#ifndef __MYNOS_REGISTRY_H__
#define __MYNOS_REGISTRY_H__

/* registry/1, typed IPC (mynos_wire.h; module Registry in OCaml): a
   request is "registry/1", its case and its arguments; the reply Ok and
   the value, or Error and a message starting with not_found, exists or
   invalid. The registry answers at the well-known port MYNOS_PORT_REGISTRY,
   and is in its own table as "registry" (so that it can describe itself).
   A name belongs to the process that registered it while it runs. */
#define REGISTRY_PROTOCOL "registry/1"
#define REGISTRY_REGISTER 0   /* (name:S) -> I: a new port, now the caller's   */
#define REGISTRY_LOOKUP   1   /* (name:S) -> I: the port of a name            */
#define REGISTRY_LIST     2   /* U -> L<(name:S,port:I,owner:I)>: every name  */

#define MAXNAMELEN 20

/* a name of the registry: its port and the process that registered it */
typedef struct {
  char name[24];
  int port;
  int owner;
} mynos_reg_entry_t;

/* the port of a new name (MYNOS_ERR_INVALID if it is taken) */
int mynos_registryRegister(char * name);
/* the port of a name (MYNOS_ERR_INVALID if there is none) */
int mynos_registryLookUp(char * name);
/* the names registered by live processes, at most max: how many */
int mynos_registryList(mynos_reg_entry_t * buf, int max);

#endif

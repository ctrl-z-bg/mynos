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

// Registry commands
#define MYNOS_REGISTRY_REGISTER (1)
#define MYNOS_REGISTRY_LOOKUP   (2)
#define MYNOS_REGISTRY_DELETE   (3)

#define MAXNAMELEN 20

typedef struct {
  int cmd;
  char name[MAXNAMELEN+1];
  int arg1;
  int arg2;
  int arg3;
} mynos_reg_cmd_t;

int mynos_registryRegister(char * name);
int mynos_registryLookUp(char * name);

#endif

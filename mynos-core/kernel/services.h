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

#ifndef __SERVICES_H__
#define __SERVICES_H__

#define SERVICENAMEMAXLEN 10

#define MAXSERVICES 1000

void __OS_service_initServicesRegistry();
void __OS_service_removeFromProcList(uint32_t idx, pid_t pid);
int __OS_service_registerService(char * name);
int __OS_service_registerClient(char * name);

#endif

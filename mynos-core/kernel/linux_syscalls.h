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

#ifndef __LINU_SYSCALLS_H__
#define __LINU_SYSCALLS_H__
#include "global.h"

/* the 0x80 handler */
void _linux_syscalls_trap_TRAP();

/* for the not yet implemented syscalls */
void _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id);

/* the sys_calls... */
void _linux_syscall_exit(int status);
void _linux_syscall_write(int fd, const void *buf, size_t count);
int _linux_syscall_getpid();

struct mmap_args {
  ulong32_t * start;
  size_t length;
  int prot;
  int flags;
  int fd;
  off_t offset;
};

void * _linux_syscall_mmap(struct mmap_args * args);

#endif

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

#ifndef __LINUX_SYSCALLS_H__
#define __LINUX_SYSCALLS_H__
#include "global.h"

/* the 0x80 handler */
void _linux_syscalls_trap_TRAP();

/* for the not yet implemented syscalls */
void _linux_syscall_NOTIMPLEMENTED(uint32_t syscall_id);

/* the sys_calls... */
void _linux_syscall_exit(int status);
int _linux_syscall_write(int fd, const void *buf, size_t count);
int _linux_syscall_read(int fd, const void *buf, size_t count);
int _linux_syscall_open(char * pathname, int flags, int mode);
int _linux_syscall_close(int fd);
int _linux_syscall_getpid();
int _linux_syscall_getppid();
int _linux_syscall_llseek(uint32_t fd, ulong32_t offhi, ulong32_t offlow,
			  long long int * result, uint32_t whence);

struct mmap_args {
  ulong32_t * start;
  size_t length;
  int prot;
  int flags;
  int fd;
  off_t offset;
};

void * _linux_syscall_mmap(struct mmap_args * args);
int _linux_syscall_munmap(void *start, size_t length);

/* Linux i386 struct user_desc */
struct user_desc {
  uint32_t entry_number;
  uint32_t base_addr;
  uint32_t limit;
  uint32_t flags;  /* seg_32bit:1 contents:2 read_exec_only:1
                      limit_in_pages:1 seg_not_present:1 useable:1 */
};

int _linux_syscall_set_thread_area(struct user_desc * u_info);

/* load the TLS segment of thread t into the GDT_TLS_INDEX descriptor */
void tls_load(void * t);

#endif

/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * Descriptors that are not files (fileio.c): the sockets (socket.c) set
 * __mynos_sock_ops when a program makes its first one, and read, write,
 * close, lseek and fstat pass their descriptors to it. A program that
 * makes no socket does not link socket.c.
 */

#ifndef __MYNOS_FDHOOKS_H__
#define __MYNOS_FDHOOKS_H__

#include <sys/types.h>
#include <sys/stat.h>

/* the sockets' descriptors: after the files' (fileio.c: FD_BASE 20,
   FD_MAX 64) */
#define SOCK_FD_BASE 84
#define SOCK_FD_MAX  32

struct mynos_sock_ops {
  int (*owns)(int fd);
  ssize_t (*read)(int fd, void * buf, size_t count);
  ssize_t (*write)(int fd, const void * buf, size_t count);
  int (*close)(int fd);
  int (*fstat)(int fd, struct stat * st);
};

extern const struct mynos_sock_ops * __mynos_sock_ops;

#endif

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
 * File I/O of MyNOS programs, in user space (doc/decisions/terminal.md).
 *
 * These functions replace the C library's ones at static link time: libmynos
 * comes before the libc on the link line, and both musl and dietlibc keep
 * one function per object file. They turn I/O on MyNOS file descriptors into
 * IPC with the services, and pass everything else to the kernel.
 *
 * Today: standard input (fd 0) is read from the console service, if one is
 * registered. Files through memrofs come next (mynos-nxa).
 */

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <mynos.h>
#include <mynos_console.h>

/* raw Linux system call, independent of the C library */
static long linux_syscall3(long n, long a, long b, long c)
{
  long ret = n;
  __asm__ volatile ("int $0x80"
		    : "+a"(ret) : "b"(a), "c"(b), "d"(c) : "memory");
  return ret;
}

static long result(long r)
{
  if (r < 0 && r > -4096) { errno = -r; return -1; }
  return r;
}

/* port of the console service: looked up once; -1 if there is none */
static int console_port = -2;

static int console(void)
{
  if (console_port == -2) {
    console_port = mynos_registryLookUp(CONSOLE_SERVICE);
    if (console_port < 0) console_port = -1;
  }
  return console_port;
}

static ssize_t console_read(int port, void * buf, size_t count)
{
  struct console_req req;
  mynos_msg_t * msg;
  int channel, n;

  channel = mynos_connectToPort(port);
  if (channel < 0) { errno = EIO; return -1; }
  req.op = CONSOLE_READ;
  req.len = count;
  if (mynos_send(channel, &req, sizeof(req), 0) < 0 ||
      mynos_recv(channel, &msg, 0, 0) < 0) {
    mynos_freeChannel(channel);
    errno = EIO;
    return -1;
  }
  n = msg->size < count ? msg->size : count;
  memcpy(buf, msg->start, n);
  mynos_freeMsg(&msg);
  mynos_freeChannel(channel);
  return n;
}

ssize_t read(int fd, void * buf, size_t count)
{
  if (fd == 0 && console() >= 0)
    return console_read(console_port, buf, count);
  return result(linux_syscall3(3 /* read */, fd, (long)buf, count));
}

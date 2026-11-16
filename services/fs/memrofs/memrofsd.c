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

#include <mynos.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include "memrofs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * memrofs: read-only filesystem on the RAM disk that GRUB loads as a module
 * (".RAMDISK" image, see tool/createDisk.c). The kernel maps the image at
 * 0x40400000 in every process. Protocol: mynos-lib/include/mynos_fs.h.
 */

char * MAGIC = ".RAMDISK";

filedescriptor_t filedesc[MAXOPENFILES];
fileentry_t * filesystem;
char *ramdisk;

#define MIN(a, b) (((a)<(b))?(a):(b))

static int find_file(const char * name)
{
  int i;
  for (i = 0; i < MAXFILES && filesystem[i].filename[0]; i++)
    if (!strncmp(filesystem[i].filename, name, FILENAMEMAXLEN))
      return i;
  return -1;
}

/* the open file `fd` of `client`, or NULL with *status set */
static filedescriptor_t * owned(int fd, int client, int * status)
{
  if (fd < 3 || fd >= MAXOPENFILES) { *status = FS_INVALID; return NULL; }
  if (!filedesc[fd].pid) { *status = FS_NOT_OPEN; return NULL; }
  if (filedesc[fd].pid != client) { *status = FS_DENIED; return NULL; }
  *status = FS_OK;
  return &filedesc[fd];
}

static void reply(int channel, int status, int value)
{
  struct fs_reply r;
  r.status = status;
  r.value = value;
  mynos_send(channel, &r, sizeof(r), 0);
}

static void memrofs_open(int channel, struct fs_req * req)
{
  int idx, fd;
  req->name[FS_NAMEMAX - 1] = 0;
  if (req->arg1 & (FS_O_WRITE | FS_O_CREAT | FS_O_TRUNC | FS_O_APPEND)) {
    reply(channel, FS_READONLY, -1);
    return;
  }
  /* names are flat; accept an optional leading slash */
  idx = find_file(req->name[0] == '/' ? req->name + 1 : req->name);
  if (idx < 0) { reply(channel, FS_NOT_FOUND, -1); return; }
  for (fd = 3; fd < MAXOPENFILES && filedesc[fd].pid; fd++)
    ;
  if (fd >= MAXOPENFILES) { reply(channel, FS_TOO_MANY, -1); return; }
  filedesc[fd].pid = req->client;
  filedesc[fd].fileidx = idx;
  filedesc[fd].pos = 0;
  reply(channel, FS_OK, fd);
}

static void memrofs_close(int channel, struct fs_req * req)
{
  int status;
  filedescriptor_t * f = owned(req->fd, req->client, &status);
  if (f) f->pid = 0;
  reply(channel, status, 0);
}

static void memrofs_read(int channel, struct fs_req * req)
{
  static char buf[FS_IOMAX];
  int status, n;
  fileentry_t * fe;
  filedescriptor_t * f = owned(req->fd, req->client, &status);

  if (!f) { reply(channel, status, 0); return; }
  fe = &filesystem[f->fileidx];
  n = f->pos < fe->size ? fe->size - f->pos : 0;
  n = MIN(n, MIN(req->arg1, FS_IOMAX));
  if (n < 0) n = 0;
  reply(channel, FS_OK, n);
  if (n > 0) {
    /* copy first: sending straight from the RAM disk would map its frames
       into the client, which may free them when it unmaps the message */
    memcpy(buf, ramdisk + (uint32_t)fe->start + f->pos, n);
    mynos_send(channel, buf, n, 0);
    f->pos += n;
  }
}

static void memrofs_lseek(int channel, struct fs_req * req)
{
  int status;
  long long pos;
  filedescriptor_t * f = owned(req->fd, req->client, &status);

  if (!f) { reply(channel, status, -1); return; }
  switch (req->arg2) {
  case 0: pos = req->arg1; break;
  case 1: pos = (long long)f->pos + req->arg1; break;
  case 2: pos = (long long)filesystem[f->fileidx].size + req->arg1; break;
  default: reply(channel, FS_INVALID, -1); return;
  }
  if (pos < 0) { reply(channel, FS_INVALID, -1); return; }
  f->pos = (uint32_t)pos;
  reply(channel, FS_OK, f->pos);
}

static void memrofs_list(int channel, struct fs_req * req)
{
  fileentry_t * fe;
  if (req->arg1 < 0 || req->arg1 >= MAXFILES ||
      !filesystem[req->arg1].filename[0]) {
    reply(channel, FS_NOT_FOUND, -1);
    return;
  }
  fe = &filesystem[req->arg1];
  reply(channel, FS_OK, fe->size);
  mynos_send(channel, fe->filename, strlen(fe->filename) + 1, 0);
}

static void process_request(int channel, struct fs_req * req)
{
  switch (req->type) {
  case FS_OPEN:  memrofs_open(channel, req);  break;
  case FS_CLOSE: memrofs_close(channel, req); break;
  case FS_READ:  memrofs_read(channel, req);  break;
  case FS_LSEEK: memrofs_lseek(channel, req); break;
  case FS_LIST:  memrofs_list(channel, req);  break;
  case FS_WRITE:
  case FS_RENAME: {                /* take the data (or the new name), sent
				      before the client waits for the reply */
    mynos_msg_t * data;
    if (mynos_recv(channel, &data, 0, 1000) == 0) mynos_freeMsg(&data);
    reply(channel, FS_READONLY, -1);
    break;
  }
  case FS_UNLINK: reply(channel, FS_READONLY, -1); break;
  default:            reply(channel, FS_INVALID, -1);
  }
}

/* self test, in a child process: read a file through the file functions of
   libmynos (open/read/close), which talk to this service */
static void self_test(void)
{
  char buf[200];
  int fd, n;

  mynos_log("%s", "Opening a text file...");
  fd = open("AUTOEXEC.BAT", O_RDONLY);
  if (fd < 0) { mynos_log("%s", "Open failed"); exit(-1); }
  mynos_log("%s", "Reading the file content...");
  n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) { mynos_log("%s", n == 0 ? "EOF" : "Some error."); exit(-1); }
  buf[n] = 0;
  mynos_log("%s", "Show the content:");
  mynos_log("%s", buf);
  exit(0);
}

int main() {
  int port;

  ramdisk = (char*)0x40400000;
  filesystem = (fileentry_t *)(ramdisk + strlen(MAGIC));

  port = mynos_registryRegister(MEMROFS_SERVICE);
  mynos_log("memrofs service port: %d\n", port);
  if (port < 0) exit(-1);

  if (fork() == 0)
    self_test();

  while (1) {
    mynos_msg_t * msg;
    struct fs_req req;
    int channel = mynos_listenPort(port);

    if (channel < 0) {
      mynos_log("%s", "Error receiving request");
      exit(-1);
    }
    if (mynos_recv(channel, &msg, 0, 0) == 0) {
      if (msg->size == sizeof(req)) {
	memcpy(&req, msg->start, sizeof(req));
	process_request(channel, &req);
      } else
	reply(channel, FS_INVALID, -1);
      mynos_freeMsg(&msg);
    }
    mynos_freeChannel(channel);
  }

  return 0;
}

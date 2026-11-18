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
#include <mynos_wire.h>

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

/* ---- fs/1 (mynos_fs.h): typed IPC, its replies ---- */

static const char * const error_names[] = FS_ERROR_NAMES;

static void send_reply(int channel, wire_writer * w)
{
  if (!w->error) mynos_send(channel, w->buf, w->len, 0);
  wire_writer_free(w);
}

static void reply_error(int channel, int status)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_error(&w, error_names[status < FS_NERRORS ? status : FS_INVALID]);
  send_reply(channel, &w);
}

static void reply_int(int channel, long long v)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, v);
  send_reply(channel, &w);
}

static void reply_unit(int channel)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  send_reply(channel, &w);
}

static const wire_request_doc requests[] = {
  { 0, "open", "(path:S,flags:I)", "I",
    "Open a file: its descriptor. flags: 1 write, 2 create, 4 truncate, 8 append "
    "(0: read)." },
  { 1, "close", "fd:I", "U", "Close a descriptor." },
  { 1, "read", "(fd:I,max:I)", "S",
    "Up to max bytes (16384 at most) from the position: \"\" at the end." },
  { 0, "write", "(fd:I,data:S)", "I",
    "Write data (16384 bytes at most) at the position: how many." },
  { 1, "seek", "(fd:I,offset:I,whence:I)", "I",
    "Move the position: whence 0 from the start, 1 from here, 2 from the end. "
    "The new position." },
  { 1, "list", "path:S", "L<(name:S,size:I)>",
    "A directory's entries: names and sizes (-1: a directory)." },
  { 0, "remove", "path:S", "U", "Remove a file." },
  { 0, "mkdir", "path:S", "U", "Make a directory." },
  { 0, "rmdir", "path:S", "U", "Remove an empty directory." },
  { 0, "rename", "(from:S,to:S)", "U", "Rename a file (one of the new name is replaced)." },
};

static void describe(int channel)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, FS_PROTOCOL,
    "Files: open, read, write, list and change the files of a file service "
    "(memrofs: /, read-only; tmpfs: /tmp; fatfs: /disk). This one is memrofs, "
    "the RAM disk (C, 2002), read-only and flat.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(channel, &w);
}

static void memrofs_open(int channel, int client, const char * name, int flags)
{
  int idx, fd;
  if (flags & (FS_O_WRITE | FS_O_CREAT | FS_O_TRUNC | FS_O_APPEND)) {
    reply_error(channel, FS_READONLY);
    return;
  }
  if (!name[0]) { reply_error(channel, FS_IS_DIR); return; }
  /* names are flat; accept an optional leading slash */
  idx = find_file(name[0] == '/' ? name + 1 : name);
  if (idx < 0) { reply_error(channel, FS_NOT_FOUND); return; }
  for (fd = 3; fd < MAXOPENFILES && filedesc[fd].pid; fd++)
    ;
  if (fd >= MAXOPENFILES) { reply_error(channel, FS_TOO_MANY); return; }
  filedesc[fd].pid = client;
  filedesc[fd].fileidx = idx;
  filedesc[fd].pos = 0;
  reply_int(channel, fd);
}

static void memrofs_read(int channel, filedescriptor_t * f, int max)
{
  fileentry_t * fe = &filesystem[f->fileidx];
  int n = f->pos < fe->size ? fe->size - f->pos : 0;
  wire_writer w;
  n = MIN(n, MIN(max, FS_IOMAX));
  if (n < 0) n = 0;
  /* the bytes are copied into the reply: sending straight from the RAM disk
     would map its frames into the client, which may free them */
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_string(&w, ramdisk + (uint32_t)fe->start + f->pos, n);
  f->pos += n;
  send_reply(channel, &w);
}

static void memrofs_seek(int channel, filedescriptor_t * f, long long offset, long long whence)
{
  long long pos;
  switch (whence) {
  case 0: pos = offset; break;
  case 1: pos = (long long)f->pos + offset; break;
  case 2: pos = (long long)filesystem[f->fileidx].size + offset; break;
  default: reply_error(channel, FS_INVALID); return;
  }
  if (pos < 0) { reply_error(channel, FS_INVALID); return; }
  f->pos = (uint32_t)pos;
  reply_int(channel, f->pos);
}

static void memrofs_list(int channel, const char * name)
{
  wire_writer w;
  int i, n = 0;
  if (name[0]) { reply_error(channel, FS_NOT_FOUND); return; }   /* flat */
  while (n < MAXFILES && filesystem[n].filename[0]) n++;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, n);
  for (i = 0; i < n; i++) {
    wire_put_cstring(&w, filesystem[i].filename);
    wire_put_int(&w, filesystem[i].size);
  }
  send_reply(channel, &w);
}

/* a request: the protocol, its case, its arguments */
static void handle(int channel, int client, const char * msg, unsigned int len)
{
  wire_reader r;
  unsigned int n;
  const char * id;
  char name[FS_NAMEMAX];
  int status;
  long long kind, fd, a, b;
  filedescriptor_t * f;

  wire_reader_init(&r, msg, len);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n)) {
    describe(channel);
    return;
  }
  if (r.error || n != strlen(FS_PROTOCOL) || memcmp(id, FS_PROTOCOL, n)) {
    wire_writer w;
    wire_writer_init(&w);
    wire_reply_error(&w, "invalid: memrofs speaks " FS_PROTOCOL);
    send_reply(channel, &w);
    return;
  }
  kind = wire_get_int(&r);
  switch (kind) {
  case FS_OPEN:
    wire_get_cstring(&r, name, sizeof name);
    a = wire_get_int(&r);
    if (r.error) break;
    memrofs_open(channel, client, name, (int)a);
    return;
  case FS_CLOSE: case FS_READ: case FS_SEEK:
    fd = wire_get_int(&r);
    a = kind == FS_CLOSE ? 0 : wire_get_int(&r);
    b = kind == FS_SEEK ? wire_get_int(&r) : 0;
    if (r.error) break;
    if ((f = owned((int)fd, client, &status)) == NULL) { reply_error(channel, status); return; }
    if (kind == FS_CLOSE) { f->pid = 0; reply_unit(channel); }
    else if (kind == FS_READ) memrofs_read(channel, f, (int)a);
    else memrofs_seek(channel, f, a, b);
    return;
  case FS_LIST:
    wire_get_cstring(&r, name, sizeof name);
    if (r.error) break;
    memrofs_list(channel, name);
    return;
  case FS_WRITE: case FS_REMOVE: case FS_MKDIR: case FS_RMDIR: case FS_RENAME:
    reply_error(channel, FS_READONLY);   /* read-only */
    return;
  }
  reply_error(channel, FS_INVALID);      /* malformed */
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
    int channel = mynos_listenPort(port);

    if (channel < 0) {
      mynos_log("%s", "Error receiving request");
      exit(-1);
    }
    /* the client: the process at the other end, as the kernel says */
    if (mynos_recv(channel, &msg, 0, 1000) == 0) {
      handle(channel, mynos_channelPeer(channel), msg->start, msg->size);
      mynos_freeMsg(&msg);
    }
    mynos_freeChannel(channel);
  }

  return 0;
}

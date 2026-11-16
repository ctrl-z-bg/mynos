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
 * one function per object file. They turn I/O into IPC with the services
 * and pass the rest to the kernel:
 *   - standard input (fd 0) is read from the console service;
 *   - files live on the file services (protocol: mynos_fs.h) and get
 *     descriptors from FD_BASE up. /tmp/NAME is NAME on tmpfs (writable,
 *     in memory), /disk/PATH is PATH on fatfs (the FAT disk); any other
 *     path is on memrofs, the read-only RAM disk, whose root also lists
 *     the mount points;
 *   - everything else (stdout, stderr, and the kernel's own single file
 *     when there is no memrofs) goes to the kernel.
 * The C library's internal I/O (fopen, ...) may bypass these functions;
 * the OCaml runtime uses open/read/write/lseek/close/stat directly.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mynos.h>
#include <mynos_console.h>
#include <mynos_fs.h>

#define FD_BASE 20
#define FD_MAX  64

/* name of the bytecode file the kernel serves (GRUB module 1), used by
   ocamlrun when no other program is named */
#define KERNEL_BYTECODE "mynos_bytecode"

/* ---- raw Linux system calls, independent of the C library ---- */

static long sys3(long n, long a, long b, long c)
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

/* ---- services ---- */

/* monotonic time in milliseconds (raw clock_gettime) */
static long now_ms(void)
{
  struct { long sec, nsec; } ts;
  sys3(265 /* clock_gettime */, 1 /* CLOCK_MONOTONIC */, (long)&ts, 0);
  return ts.sec * 1000 + ts.nsec / 1000000;
}

/* a service's port, looked up once: port -2 before the first lookup, -1
   while it is not found */
struct svc { int port; long retry_at; };

/* the port of a service, or -1. Services start together at boot, so the
   first lookup gives it a second to register; a lookup that takes long
   means there is no registry at all (the library waits 2 s for it): give
   up. A service not found is looked up again, once, every 2 s: init may
   start it later. */
static int service_port(const char * name, struct svc * cache)
{
  if (cache->port == -2) {
    int tries;
    cache->port = -1;
    for (tries = 0; tries < 50; tries++) {
      long t0 = now_ms();
      int p = mynos_registryLookUp((char *)name);
      if (p >= 0) { cache->port = p; break; }
      if (p != MYNOS_ERR_INVALID || now_ms() - t0 > 1000) break;
      mynos_sleep(20000);
    }
    cache->retry_at = now_ms() + 2000;
  } else if (cache->port == -1 && now_ms() >= cache->retry_at) {
    int p = mynos_registryLookUp((char *)name);
    if (p >= 0) cache->port = p;
    cache->retry_at = now_ms() + 2000;
  }
  return cache->port;
}

static struct svc console_cache = { -2, 0 };

/* one request/reply exchange on a new connection; the channel stays open
   (in *channel_out) for a data message */
static int call(int port, const void * req, int len, mynos_msg_t ** reply,
		int * channel_out)
{
  int channel = mynos_connectToPort(port);
  if (channel < 0) return -1;
  if (mynos_send(channel, (void *)req, len, 0) < 0 ||
      mynos_recv(channel, reply, 0, 0) < 0) {
    mynos_freeChannel(channel);
    return -1;
  }
  if (channel_out) *channel_out = channel;
  else mynos_freeChannel(channel);
  return 0;
}

/* ---- console ---- */

static ssize_t console_read(int port, void * buf, size_t count)
{
  struct console_req req;
  mynos_msg_t * msg;
  int n;

  req.op = CONSOLE_READ;
  req.len = count;
  if (call(port, &req, sizeof(req), &msg, NULL) < 0) { errno = EIO; return -1; }
  n = msg->size < count ? msg->size : count;
  memcpy(buf, msg->start, n);
  mynos_freeMsg(&msg);
  return n;
}

/* ---- file services ---- */

enum { MEMROFS, TMPFS, FATFS, NSERVICES };
static const char * service_name[NSERVICES] =
  { MEMROFS_SERVICE, TMPFS_SERVICE, FATFS_SERVICE };
static const char * service_mount[NSERVICES] =
  { "", TMPFS_MOUNT, FATFS_MOUNT };
static struct svc service_cache[NSERVICES] = { { -2, 0 }, { -2, 0 }, { -2, 0 } };

static int service(int s)
{
  return service_port(service_name[s], &service_cache[s]);
}

/* the path, cleaned: no leading, trailing or doubled "/", no "." and ".."
   components (there is no current directory: a relative path starts at
   the root). -1 if it does not fit. */
static int clean_path(const char * path, char * out, int size)
{
  int len = 0;
  while (*path) {
    const char * c;
    int n;
    while (*path == '/') path++;
    c = path;
    while (*path && *path != '/') path++;
    n = path - c;
    if (n == 0 || (n == 1 && c[0] == '.')) continue;
    if (n == 2 && c[0] == '.' && c[1] == '.') {   /* drop the last one */
      while (len > 0 && out[len - 1] != '/') len--;
      if (len > 0) len--;
      continue;
    }
    if (len + (len > 0) + n >= size) return -1;
    if (len > 0) out[len++] = '/';
    memcpy(out + len, c, n);
    len += n;
  }
  out[len] = 0;
  return 0;
}

/* where a path lives: the service, and the path inside it, in name
   (FS_NAMEMAX bytes; "" for its root). -1 (errno set) if too long. */
static int resolve(const char * path, char * name)
{
  char clean[2 * FS_NAMEMAX];
  int s;

  if (clean_path(path, clean, sizeof(clean)) < 0) {
    errno = ENAMETOOLONG;
    return -1;
  }
  for (s = 1; s < NSERVICES; s++) {
    int n = strlen(service_mount[s]);
    if (!strncmp(clean, service_mount[s], n) &&
	(clean[n] == 0 || clean[n] == '/')) {
      const char * rest = clean[n] ? clean + n + 1 : clean + n;
      if (strlen(rest) >= FS_NAMEMAX) { errno = ENAMETOOLONG; return -1; }
      strcpy(name, rest);
      return s;
    }
  }
  if (strlen(clean) >= FS_NAMEMAX) { errno = ENAMETOOLONG; return -1; }
  strcpy(name, clean);
  return MEMROFS;
}

/* open files: service and its descriptor; used = 0 for a free slot */
static struct { int used, service, fd; } files[FD_MAX];

static int file_slot(int fd)
{
  if (fd < FD_BASE || fd >= FD_BASE + FD_MAX || !files[fd - FD_BASE].used)
    return -1;
  return fd - FD_BASE;
}

static int fs_call(int s, struct fs_req * req, struct fs_reply * r,
		   int * channel_out)
{
  mynos_msg_t * msg;
  int port = service(s);
  if (port < 0) return -1;
  req->client = getpid();
  if (call(port, req, sizeof(*req), &msg, channel_out) < 0) return -1;
  if (msg->size != sizeof(*r)) {
    mynos_freeMsg(&msg);
    if (channel_out) mynos_freeChannel(*channel_out);
    return -1;
  }
  memcpy(r, msg->start, sizeof(*r));
  mynos_freeMsg(&msg);
  return 0;
}

static int status_errno(int status)
{
  switch (status) {
  case FS_NOT_FOUND: return ENOENT;
  case FS_TOO_MANY:  return EMFILE;
  case FS_DENIED:    return EACCES;
  case FS_NOT_OPEN:  return EBADF;
  case FS_READONLY:  return EROFS;
  case FS_NO_SPACE:  return ENOSPC;
  case FS_IS_DIR:    return EISDIR;
  case FS_NOT_EMPTY: return ENOTEMPTY;
  case FS_EXISTS:    return EEXIST;
  case FS_NOT_DIR:   return ENOTDIR;
  default:           return EINVAL;
  }
}

/* a request on a name (UNLINK, MKDIR, RMDIR): 0 or -1 with errno */
static int name_call(const char * path, int type)
{
  struct fs_req req;
  struct fs_reply r;
  int s;

  memset(&req, 0, sizeof(req));
  if ((s = resolve(path, req.name)) < 0) return -1;
  if (service(s) < 0) { errno = ENOENT; return -1; }
  if (!req.name[0]) { errno = s == MEMROFS ? EROFS : EBUSY; return -1; }
  req.type = type;
  if (fs_call(s, &req, &r, NULL) < 0) { errno = EIO; return -1; }
  if (r.status != FS_OK) { errno = status_errno(r.status); return -1; }
  return 0;
}

/* ---- the replaced functions ---- */

int open(const char * path, int flags, ...)
{
  struct fs_req req;
  struct fs_reply r;
  int slot, mode = 0, s;

  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = va_arg(ap, int);
    va_end(ap);
  }

  memset(&req, 0, sizeof(req));
  if ((s = resolve(path, req.name)) < 0) return -1;
  if (service(s) < 0) {
    if (s == MEMROFS)    /* no filesystem: the kernel's own file */
      return result(sys3(5 /* open */, (long)path, flags, mode));
    errno = ENOENT;
    return -1;
  }
  if (!req.name[0]) { errno = EISDIR; return -1; }

  req.type = FS_OPEN;
  if ((flags & O_ACCMODE) != O_RDONLY) req.arg1 |= FS_O_WRITE;
  if (flags & O_CREAT)  req.arg1 |= FS_O_CREAT;
  if (flags & O_TRUNC)  req.arg1 |= FS_O_TRUNC;
  if (flags & O_APPEND) req.arg1 |= FS_O_APPEND;
  if (fs_call(s, &req, &r, NULL) < 0) { errno = EIO; return -1; }
  if (r.status != FS_OK) {
    if (s == MEMROFS && r.status == FS_NOT_FOUND &&
	!strcmp(req.name, KERNEL_BYTECODE))
      return result(sys3(5, (long)path, flags, 0));
    errno = status_errno(r.status);
    return -1;
  }
  for (slot = 0; slot < FD_MAX && files[slot].used; slot++)
    ;
  if (slot == FD_MAX) {
    int fd = r.value;
    memset(&req, 0, sizeof(req));
    req.type = FS_CLOSE;
    req.fd = fd;
    fs_call(s, &req, &r, NULL);
    errno = EMFILE;
    return -1;
  }
  files[slot].used = 1;
  files[slot].service = s;
  files[slot].fd = r.value;
  return FD_BASE + slot;
}

int close(int fd)
{
  struct fs_req req;
  struct fs_reply r;
  int slot = file_slot(fd);

  if (slot < 0) return result(sys3(6 /* close */, fd, 0, 0));
  files[slot].used = 0;
  memset(&req, 0, sizeof(req));
  req.type = FS_CLOSE;
  req.fd = files[slot].fd;
  if (fs_call(files[slot].service, &req, &r, NULL) < 0) { errno = EIO; return -1; }
  if (r.status != FS_OK) { errno = status_errno(r.status); return -1; }
  return 0;
}

/* one READ request: up to FS_IOMAX bytes */
static ssize_t fs_read(int slot, char * buf, size_t count)
{
  struct fs_req req;
  struct fs_reply r;
  mynos_msg_t * msg;
  int channel, n;

  memset(&req, 0, sizeof(req));
  req.type = FS_READ;
  req.fd = files[slot].fd;
  req.arg1 = count > FS_IOMAX ? FS_IOMAX : count;
  if (fs_call(files[slot].service, &req, &r, &channel) < 0) {
    errno = EIO;
    return -1;
  }
  if (r.status != FS_OK) {
    mynos_freeChannel(channel);
    errno = status_errno(r.status);
    return -1;
  }
  n = r.value;
  if (n > 0) {
    if (mynos_recv(channel, &msg, 0, 0) < 0) {
      mynos_freeChannel(channel);
      errno = EIO;
      return -1;
    }
    if ((int)msg->size < n) n = msg->size;
    memcpy(buf, msg->start, n);
    mynos_freeMsg(&msg);
  }
  mynos_freeChannel(channel);
  return n;
}

ssize_t read(int fd, void * buf, size_t count)
{
  size_t done = 0;
  int slot;

  if (fd == 0 && service_port(CONSOLE_SERVICE, &console_cache) >= 0)
    return console_read(console_cache.port, buf, count);
  slot = file_slot(fd);
  if (slot < 0) return result(sys3(3 /* read */, fd, (long)buf, count));

  /* like a Linux regular file: all that was asked, unless the file ends */
  while (done < count) {
    ssize_t n = fs_read(slot, (char *)buf + done, count - done);
    if (n < 0) return done ? (ssize_t)done : -1;
    if (n == 0) break;
    done += n;
  }
  return done;
}

/* one WRITE request: the request, then the data, then the reply */
static ssize_t fs_write(int slot, const char * buf, size_t count)
{
  struct fs_req req;
  struct fs_reply r;
  mynos_msg_t * msg;
  int port = service(files[slot].service), channel, ok;

  if (port < 0) { errno = EIO; return -1; }
  memset(&req, 0, sizeof(req));
  req.type = FS_WRITE;
  req.client = getpid();
  req.fd = files[slot].fd;
  req.arg1 = count > FS_IOMAX ? FS_IOMAX : count;
  if ((channel = mynos_connectToPort(port)) < 0) { errno = EIO; return -1; }
  ok = mynos_send(channel, &req, sizeof(req), 0) == 0 &&
       mynos_send(channel, (void *)buf, req.arg1, 0) == 0 &&
       mynos_recv(channel, &msg, 0, 0) == 0;
  mynos_freeChannel(channel);
  if (!ok) { errno = EIO; return -1; }
  if (msg->size != sizeof(r)) {
    mynos_freeMsg(&msg);
    errno = EIO;
    return -1;
  }
  memcpy(&r, msg->start, sizeof(r));
  mynos_freeMsg(&msg);
  if (r.status != FS_OK) { errno = status_errno(r.status); return -1; }
  return r.value;
}

ssize_t write(int fd, const void * buf, size_t count)
{
  size_t done = 0;
  int slot = file_slot(fd);

  if (slot < 0) return result(sys3(4 /* write */, fd, (long)buf, count));
  while (done < count) {
    ssize_t n = fs_write(slot, (const char *)buf + done, count - done);
    if (n < 0) return done ? (ssize_t)done : -1;
    if (n == 0) break;
    done += n;
  }
  return done;
}

off_t lseek(int fd, off_t offset, int whence)
{
  struct fs_req req;
  struct fs_reply r;
  int slot = file_slot(fd);

  if (slot < 0) return result(sys3(19 /* lseek */, fd, (long)offset, whence));
  memset(&req, 0, sizeof(req));
  req.type = FS_LSEEK;
  req.fd = files[slot].fd;
  req.arg1 = (int)offset;
  req.arg2 = whence;
  if (fs_call(files[slot].service, &req, &r, NULL) < 0) { errno = EIO; return -1; }
  if (r.status != FS_OK) { errno = status_errno(r.status); return -1; }
  return r.value;
}

int unlink(const char * path)
{
  return name_call(path, FS_UNLINK);
}

/* rename: within one service; the new name comes in a second message */
int rename(const char * from, const char * to)
{
  struct fs_req req;
  struct fs_reply r;
  char newname[FS_NAMEMAX];
  mynos_msg_t * msg;
  int s, s2, port, channel, ok;

  memset(&req, 0, sizeof(req));
  if ((s = resolve(from, req.name)) < 0 || (s2 = resolve(to, newname)) < 0)
    return -1;
  if (s != s2) { errno = EXDEV; return -1; }
  if ((port = service(s)) < 0) { errno = ENOENT; return -1; }
  if (!req.name[0] || !newname[0]) { errno = EBUSY; return -1; }
  req.type = FS_RENAME;
  req.client = getpid();
  if ((channel = mynos_connectToPort(port)) < 0) { errno = EIO; return -1; }
  ok = mynos_send(channel, &req, sizeof(req), 0) == 0 &&
       mynos_send(channel, newname, strlen(newname) + 1, 0) == 0 &&
       mynos_recv(channel, &msg, 0, 0) == 0;
  mynos_freeChannel(channel);
  if (!ok) { errno = EIO; return -1; }
  if (msg->size != sizeof(r)) { mynos_freeMsg(&msg); errno = EIO; return -1; }
  memcpy(&r, msg->start, sizeof(r));
  mynos_freeMsg(&msg);
  if (r.status != FS_OK) { errno = status_errno(r.status); return -1; }
  return 0;
}

int mkdir(const char * path, mode_t mode)
{
  (void)mode;
  return name_call(path, FS_MKDIR);
}

int rmdir(const char * path)
{
  return name_call(path, FS_RMDIR);
}

/* Linux i386 struct stat64, as the kernel fills it */
struct kstat64 {
  unsigned long long st_dev;
  unsigned char      pad0[4];
  unsigned long      st_ino32;
  unsigned int       st_mode;
  unsigned int       st_nlink;
  unsigned long      st_uid;
  unsigned long      st_gid;
  unsigned long long st_rdev;
  unsigned char      pad3[4];
  long long          st_size;
  unsigned long      st_blksize;
  unsigned long long st_blocks;
  unsigned long      st_atime_, st_atime_nsec;
  unsigned long      st_mtime_, st_mtime_nsec;
  unsigned long      st_ctime_, st_ctime_nsec;
  unsigned long long st_ino;
} __attribute__((packed));

int fstat(int fd, struct stat * st)
{
  int slot = file_slot(fd);
  memset(st, 0, sizeof(*st));
  if (slot < 0) {
    struct kstat64 k;
    long ret = sys3(197 /* fstat64 */, fd, (long)&k, 0);
    if (ret < 0) return result(ret);
    st->st_mode = k.st_mode;
    st->st_nlink = k.st_nlink;
    st->st_size = k.st_size;
    st->st_blksize = k.st_blksize;
    st->st_blocks = k.st_blocks;
    st->st_ino = k.st_ino;
    return 0;
  } else {
    off_t cur = lseek(fd, 0, SEEK_CUR);
    off_t size = lseek(fd, 0, SEEK_END);
    if (cur < 0 || size < 0) return -1;
    lseek(fd, cur, SEEK_SET);
    st->st_mode = S_IFREG | (files[slot].service == MEMROFS ? 0444 : 0644);
    st->st_nlink = 1;
    st->st_size = size;
    st->st_blksize = 4096;
    st->st_blocks = (size + 511) / 512;
    return 0;
  }
}

static void dir_stat(struct stat * st, int writable)
{
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFDIR | (writable ? 0755 : 0555);
  st->st_nlink = 2;
}

int stat(const char * path, struct stat * st)
{
  char name[FS_NAMEMAX];
  int fd, ret, s;

  if ((s = resolve(path, name)) < 0) return -1;
  if (!name[0] && service(s) >= 0) {   /* a service's root */
    dir_stat(st, s != MEMROFS);
    return 0;
  }
  fd = open(path, O_RDONLY);
  if (fd < 0) {
    if (errno == EISDIR) {             /* a directory inside a service */
      dir_stat(st, s != MEMROFS);
      return 0;
    }
    return -1;
  }
  ret = fstat(fd, st);
  close(fd);
  return ret;
}

int lstat(const char * path, struct stat * st)
{
  return stat(path, st);
}

/* ---- directories ---- */

struct __dirstream {
  int service;
  char name[FS_NAMEMAX];   /* the directory inside the service */
  int index;               /* next entry to list */
  int mounts_listed;       /* "/" also lists the mount points, after */
  struct dirent entry;
};

DIR * opendir(const char * path)
{
  char name[FS_NAMEMAX];
  int s;
  DIR * d;

  if ((s = resolve(path, name)) < 0) return NULL;
  if (service(s) < 0) {
    errno = s == MEMROFS ? ENOSYS : ENOENT;
    return NULL;
  }
  if (name[0]) {
    struct stat st;
    if (stat(path, &st) < 0) return NULL;
    if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return NULL; }
  }
  if ((d = calloc(1, sizeof(*d))) == NULL) { errno = ENOMEM; return NULL; }
  d->service = s;
  strcpy(d->name, name);
  return d;
}

static struct dirent * dir_entry(DIR * d, const char * name, int len,
				 int is_dir)
{
  memset(&d->entry, 0, sizeof(d->entry));
  if (len > (int)sizeof(d->entry.d_name) - 1)
    len = sizeof(d->entry.d_name) - 1;
  memcpy(d->entry.d_name, name, len);
  d->entry.d_ino = d->index + 1;
  d->entry.d_reclen = sizeof(d->entry);
#ifdef _DIRENT_HAVE_D_TYPE
  d->entry.d_type = is_dir ? DT_DIR : DT_REG;
#else
  (void)is_dir;
#endif
  return &d->entry;
}

/* the root of memrofs also shows the mount points of the other services */
static struct dirent * next_mount(DIR * d)
{
  while (d->mounts_listed < NSERVICES - 1) {
    int s = ++d->mounts_listed;
    if (service(s) >= 0)
      return dir_entry(d, service_mount[s], strlen(service_mount[s]), 1);
  }
  return NULL;
}

struct dirent * readdir(DIR * d)
{
  struct fs_req req;
  struct fs_reply r;
  mynos_msg_t * msg;
  struct dirent * e;
  int channel;

  if (d->mounts_listed) return next_mount(d);
  memset(&req, 0, sizeof(req));
  req.type = FS_LIST;
  req.arg1 = d->index;
  strcpy(req.name, d->name);
  if (fs_call(d->service, &req, &r, &channel) < 0) { errno = EIO; return NULL; }
  if (r.status != FS_OK) {               /* the end: errno unchanged */
    mynos_freeChannel(channel);
    if (d->service == MEMROFS && !d->name[0]) return next_mount(d);
    return NULL;
  }
  if (mynos_recv(channel, &msg, 0, 0) < 0) {
    mynos_freeChannel(channel);
    errno = EIO;
    return NULL;
  }
  {
    const char * name = msg->start;
    int len = 0;
    while (len < (int)msg->size && name[len]) len++;
    e = dir_entry(d, name, len, r.value == -1);
  }
  mynos_freeMsg(&msg);
  mynos_freeChannel(channel);
  d->index++;
  return e;
}

void rewinddir(DIR * d)
{
  d->index = 0;
  d->mounts_listed = 0;
}

int closedir(DIR * d)
{
  free(d);
  return 0;
}

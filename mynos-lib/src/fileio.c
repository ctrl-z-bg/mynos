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
 * comes before the libc on the link line, and musl keeps
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
#include <sys/ioctl.h>
#include <termios.h>
#include <mynos.h>
#include <mynos_console.h>
#include <mynos_fs.h>
#include <mynos_wire.h>

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
static struct svc * caches[8];
static int ncaches;

static int service_port(const char * name, struct svc * cache)
{
  int i;
  for (i = 0; i < ncaches && caches[i] != cache; i++) ;
  if (i == ncaches && ncaches < 8) caches[ncaches++] = cache;
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

/* the console: the service "console" (consoled), or the one the
   environment names (MYNOS_CONSOLE: a terminal window, doc/decisions/
   gui.md), which then gets the output of fds 1 and 2 too */
static const char * console_name(void)
{
  const char * c = getenv("MYNOS_CONSOLE");
  return c && c[0] ? c : CONSOLE_SERVICE;
}

static int console_owns_output(void)
{
  const char * c = getenv("MYNOS_CONSOLE");
  return c && c[0];
}

/* one request/reply exchange on a new connection; the channel stays open
   (in *channel_out) for a data message */
/* a service that ended (init restarts it, with a new port): every cache
   holding its port looks its name up again at the next request */
static void forget_port(int port)
{
  int i;
  for (i = 0; i < ncaches; i++)
    if (caches[i]->port == port) caches[i]->port = -2;
}

static int call(int port, const void * req, int len, mynos_msg_t ** reply,
		int * channel_out)
{
  int channel = mynos_connectToPort(port);
  if (channel < 0) { forget_port(port); return -2; }   /* not delivered */
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

/* output to a terminal's console service: a CONSOLE_WRITE request, the
   bytes after it, in pieces */
static ssize_t console_write(int port, const void * buf, size_t count)
{
  static char msg[sizeof(struct console_req) + 8192];
  struct console_req req;
  size_t done = 0;
  while (done < count) {
    size_t n = count - done > 8192 ? 8192 : count - done;
    mynos_msg_t * reply;
    memset(&req, 0, sizeof(req));
    req.op = CONSOLE_WRITE;
    req.len = n;
    req.pid = getpid();
    memcpy(msg, &req, sizeof(req));
    memcpy(msg + sizeof(req), (const char *)buf + done, n);
    if (call(port, msg, sizeof(req) + n, &reply, NULL) < 0) {
      errno = EIO;
      return done ? (ssize_t)done : -1;
    }
    mynos_freeMsg(&reply);
    done += n;
  }
  return done;
}

static ssize_t console_read(int port, void * buf, size_t count)
{
  struct console_req req;
  mynos_msg_t * msg;
  int n;

  memset(&req, 0, sizeof(req));
  req.op = CONSOLE_READ;
  req.len = count;
  req.pid = getpid();
  /* a console that has gone (its terminal closed): the end of the input,
     as a hang-up is in Unix, so that programs reading it end */
  if (call(port, &req, sizeof(req), &msg, NULL) < 0) return 0;
  n = msg->size < count ? msg->size : count;
  memcpy(buf, msg->start, n);
  mynos_freeMsg(&msg);
  return n;
}

/* the terminal settings of fds 0-2 (termios), kept here: consoled gets
   what it uses (line editing, echo, VMIN, VTIME) */
static struct termios tio;
static int tio_ready = 0;

static void tio_init(void)
{
  if (tio_ready) return;
  tio_ready = 1;
  memset(&tio, 0, sizeof(tio));
  tio.c_iflag = ICRNL;
  tio.c_oflag = OPOST | ONLCR;
  tio.c_cflag = CS8 | CREAD;
  tio.c_lflag = ICANON | ECHO | ECHOE | ISIG | IEXTEN;
  tio.c_cc[VMIN] = 1;
  tio.c_cc[VTIME] = 0;
  tio.c_cc[VEOF] = 4;
  tio.c_cc[VERASE] = 127;
  tio.c_cc[VINTR] = 3;
}

/* set the console's mode: line editing and echo, Ctrl-C an interrupt or a
   character, and for raw reads VMIN and VTIME; -1 without a console */
static int console_mode(int canon, int echo, int isig, int vmin, int vtime)
{
  struct console_req req;
  mynos_msg_t * msg;
  if (service_port(console_name(), &console_cache) < 0) return -1;
  memset(&req, 0, sizeof(req));
  req.op = CONSOLE_MODE;
  req.pid = getpid();
  req.mode = (canon ? CONSOLE_CANON : 0) | (echo ? CONSOLE_ECHO : 0)
    | (isig ? 0 : CONSOLE_NOSIG);
  req.vmin = vmin;
  req.vtime = vtime;
  if (call(console_cache.port, &req, sizeof(req), &msg, NULL) < 0) return -1;
  mynos_freeMsg(&msg);
  tio_init();
  if (canon) tio.c_lflag |= ICANON; else tio.c_lflag &= ~ICANON;
  if (echo) tio.c_lflag |= ECHO; else tio.c_lflag &= ~ECHO;
  if (isig) tio.c_lflag |= ISIG; else tio.c_lflag &= ~ISIG;
  tio.c_cc[VMIN] = vmin;
  tio.c_cc[VTIME] = vtime;
  return 0;
}

int mynos_consoleMode(int canon, int echo, int vmin, int vtime)
{
  tio_init();
  return console_mode(canon, echo, (tio.c_lflag & ISIG) != 0, vmin, vtime);
}

/* the program the caller waits for: Ctrl-C ends it (0: none) */
int mynos_consoleForeground(int pid)
{
  struct console_req req;
  mynos_msg_t * msg;
  if (service_port(console_name(), &console_cache) < 0) return -1;
  memset(&req, 0, sizeof(req));
  req.op = CONSOLE_FOREGROUND;
  req.pid = getpid();
  req.mode = pid;
  if (call(console_cache.port, &req, sizeof(req), &msg, NULL) < 0) return -1;
  mynos_freeMsg(&msg);
  return 0;
}

/* ioctl: the terminal requests on fds 0-2 (tcgetattr, tcsetattr, the
   window size), the rest to the kernel */
#define IOCTL_REQ int             /* as musl declares ioctl */

static int std_fd(int fd);

int ioctl(int fd, IOCTL_REQ req, ...)
{
  va_list ap;
  void * arg;
  va_start(ap, req);
  arg = va_arg(ap, void *);
  va_end(ap);
  if (fd >= 0 && fd <= 2 && std_fd(fd) != fd) {   /* redirected to a file */
    errno = ENOTTY;
    return -1;
  }
  if (fd >= 0 && fd <= 2 && service_port(console_name(), &console_cache) >= 0) {
    switch (req) {
    case TCGETS:
      tio_init();
      memcpy(arg, &tio, sizeof(tio));
      return 0;
    case TCSETS: case TCSETSW: case TCSETSF: {
      const struct termios * t = arg;
      if (console_mode((t->c_lflag & ICANON) != 0, (t->c_lflag & ECHO) != 0,
		       (t->c_lflag & ISIG) != 0, t->c_cc[VMIN], t->c_cc[VTIME]) < 0) {
	errno = EIO;
	return -1;
      }
      tio_init();
      tio = *t;
      return 0;
    }
    case TIOCGWINSZ: {
      struct winsize * w = arg;
      memset(w, 0, sizeof(*w));
      w->ws_row = CONSOLE_ROWS;
      w->ws_col = CONSOLE_COLS;
      return 0;
    }
    }
  }
  return result(sys3(54 /* ioctl */, fd, req, (long)arg));
}

/* ---- file services ---- */

int stat(const char * path, struct stat * st);

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

/* ---- the current directory ---- */

/* the current directory, absolute and clean ("/", "/disk/src"...). A
   process starts in the directory named by PWD in its environment, which
   mynos_spawn sets to its parent's. */
#define CWD_MAX (3 * FS_NAMEMAX)
static char cwd[CWD_MAX] = "/";
static int cwd_ready = 0;

static void cwd_init(void)
{
  const char * pwd;
  char clean[CWD_MAX];
  if (cwd_ready) return;
  cwd_ready = 1;
  pwd = getenv("PWD");
  if (pwd && pwd[0] == '/' && clean_path(pwd, clean, sizeof(clean)) == 0) {
    cwd[0] = '/';
    strcpy(cwd + 1, clean);
  }
}

const char * mynos_cwd(void)
{
  cwd_init();
  return cwd;
}

/* a path made absolute (against the current directory) and clean, without
   its leading "/"; -1 (errno set) if too long */
static int absolute(const char * path, char * out, int size)
{
  char full[2 * CWD_MAX];
  if (path[0] != '/') {
    int n, m = strlen(path);
    cwd_init();
    n = strlen(cwd);
    if (n + 1 + m >= (int)sizeof(full)) { errno = ENAMETOOLONG; return -1; }
    memcpy(full, cwd, n);
    full[n] = '/';
    memcpy(full + n + 1, path, m + 1);
    path = full;
  }
  if (clean_path(path, out, size) < 0) { errno = ENAMETOOLONG; return -1; }
  return 0;
}

char * getcwd(char * buf, size_t size)
{
  int n;
  cwd_init();
  n = strlen(cwd) + 1;
  if (!buf) {
    if (size == 0) size = n;
    if ((buf = malloc(size)) == NULL) { errno = ENOMEM; return NULL; }
  }
  if ((int)size < n) { errno = ERANGE; return NULL; }
  memcpy(buf, cwd, n);
  return buf;
}

int chdir(const char * path)
{
  char clean[CWD_MAX];
  struct stat st;
  if (absolute(path, clean, sizeof(clean)) < 0) return -1;
  if (stat(path, &st) < 0) return -1;
  if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
  cwd[0] = '/';
  strcpy(cwd + 1, clean);
  cwd_ready = 1;
  return 0;
}

/* where a path lives: the service, and the path inside it, in name
   (FS_NAMEMAX bytes; "" for its root). A relative path starts at the
   current directory. -1 (errno set) if too long. */
static int resolve(const char * path, char * name)
{
  char clean[CWD_MAX];
  int s;

  if (absolute(path, clean, sizeof(clean)) < 0) return -1;
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

/* ---- fs/1 (mynos_fs.h): requests to the file services ---- */

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

/* an Error reply's status, from the name its message starts with */
static int error_status(const char * m, unsigned int len)
{
  static const char * const names[] = FS_ERROR_NAMES;
  unsigned int n = 0;
  int i;
  while (n < len && m[n] != ':') n++;
  for (i = 0; i < FS_NERRORS; i++)
    if (strlen(names[i]) == n && !memcmp(names[i], m, n)) return i;
  return FS_INVALID;
}

/* start a request: the protocol, the case */
static void fs_start(wire_writer * w, int kind)
{
  wire_writer_init(w);
  wire_put_cstring(w, FS_PROTOCOL);
  wire_put_int(w, kind);
}

/* send a request to service s; on Ok, *msg holds the reply and r reads its
   value (the caller frees *msg). -1 with errno otherwise. A service that
   ended is looked up again (init restarts it) and the request sent to the
   new one, if it was never delivered. */
static int fs_request(int s, wire_writer * w, wire_reader * r, mynos_msg_t ** msg)
{
  int port = service(s), ret;
  if (w->error) { wire_writer_free(w); errno = ENOMEM; return -1; }
  if (port < 0) { wire_writer_free(w); errno = ENOENT; return -1; }
  ret = call(port, w->buf, w->len, msg, NULL);
  if (ret == -2) {
    int again = service(s);
    if (again >= 0 && again != port) ret = call(again, w->buf, w->len, msg, NULL);
  }
  wire_writer_free(w);
  if (ret < 0) { errno = EIO; return -1; }
  wire_reader_init(r, (*msg)->start, (*msg)->size);
  if (wire_get_int(r) != 0) {              /* Error: its message */
    unsigned int len;
    const char * m = wire_get_string(r, &len);
    errno = r->error ? EIO : status_errno(error_status(m, len));
    mynos_freeMsg(msg);
    return -1;
  }
  return 0;
}

/* a request whose reply is unit or an int: the int (0 for unit), or -1 */
static long long fs_simple(int s, wire_writer * w, int has_value)
{
  wire_reader r;
  mynos_msg_t * msg;
  long long v = 0;
  if (fs_request(s, w, &r, &msg) < 0) return -1;
  if (has_value) v = wire_get_int(&r);
  if (r.error) { mynos_freeMsg(&msg); errno = EIO; return -1; }
  mynos_freeMsg(&msg);
  return v;
}

/* a request on a name (REMOVE, MKDIR, RMDIR): 0 or -1 with errno */
static int name_call(const char * path, int type)
{
  char name[FS_NAMEMAX];
  wire_writer w;
  int s;

  if ((s = resolve(path, name)) < 0) return -1;
  if (service(s) < 0) { errno = ENOENT; return -1; }
  if (!name[0]) { errno = s == MEMROFS ? EROFS : EBUSY; return -1; }
  fs_start(&w, type);
  wire_put_cstring(&w, name);
  return fs_simple(s, &w, 0) < 0 ? -1 : 0;
}

/* ---- redirections of fds 0-2 ----
   A shell redirects a program's standard input or output through its
   environment: MYNOS_STDIN=path, MYNOS_STDOUT=path (">>path" appends),
   MYNOS_STDERR=path. The first use of fd 0, 1 or 2 opens the file, and the
   fd stands for it from then on. The variable is then rewritten to append,
   so that the program's own children add to the file. (C programs' stdio
   writes with direct system calls and is not redirected.) */

static int redirected[3] = { -1, -1, -1 };
static int redir_ready = 0;

int open(const char * path, int flags, ...);

int close(int fd);

static void redir_close(void)
{
  int i;
  for (i = 0; i < 3; i++)
    if (redirected[i] >= 0) { close(redirected[i]); redirected[i] = -1; }
}

static void redir_init(void)
{
  static const char * vars[3] = { "MYNOS_STDIN", "MYNOS_STDOUT", "MYNOS_STDERR" };
  int i, any = 0;
  if (redir_ready) return;
  redir_ready = 1;
  for (i = 0; i < 3; i++) {
    const char * v = getenv(vars[i]);
    int append;
    if (!v || !v[0]) continue;
    append = v[0] == '>' && v[1] == '>';
    if (append) v += 2;
    if (i == 0)
      redirected[0] = open(v, O_RDONLY);
    else
      redirected[i] = open(v, O_WRONLY | O_CREAT |
			   (append ? O_APPEND : O_TRUNC), 0644);
    if (i > 0 && redirected[i] >= 0 && !append) {
      char * a = malloc(strlen(v) + 3);
      if (a) {
	strcpy(a, ">>");
	strcat(a, v);
	setenv(vars[i], a, 1);       /* our children add to it */
	free(a);
      }
    }
    if (redirected[i] >= 0) any = 1;
  }
  if (any) atexit(redir_close);
}

/* fd, or the file standing for it when it is a redirected 0, 1 or 2 */
static int std_fd(int fd)
{
  if (fd < 0 || fd > 2) return fd;
  redir_init();
  return redirected[fd] >= 0 ? redirected[fd] : fd;
}

/* ---- the replaced functions ---- */

int open(const char * path, int flags, ...)
{
  char name[FS_NAMEMAX];
  wire_writer w;
  long long fd;
  int slot, mode = 0, s, f = 0;

  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = va_arg(ap, int);
    va_end(ap);
  }

  if ((s = resolve(path, name)) < 0) return -1;
  if (service(s) < 0) {
    if (s == MEMROFS)    /* no filesystem: the kernel's own file */
      return result(sys3(5 /* open */, (long)path, flags, mode));
    errno = ENOENT;
    return -1;
  }
  if (!name[0]) { errno = EISDIR; return -1; }

  if ((flags & O_ACCMODE) != O_RDONLY) f |= FS_O_WRITE;
  if (flags & O_CREAT)  f |= FS_O_CREAT;
  if (flags & O_TRUNC)  f |= FS_O_TRUNC;
  if (flags & O_APPEND) f |= FS_O_APPEND;
  fs_start(&w, FS_OPEN);
  wire_put_cstring(&w, name);
  wire_put_int(&w, f);
  if ((fd = fs_simple(s, &w, 1)) < 0) {
    if (s == MEMROFS && errno == ENOENT && !strcmp(name, KERNEL_BYTECODE))
      return result(sys3(5, (long)path, flags, 0));
    return -1;
  }
  for (slot = 0; slot < FD_MAX && files[slot].used; slot++)
    ;
  if (slot == FD_MAX) {
    fs_start(&w, FS_CLOSE);
    wire_put_int(&w, fd);
    fs_simple(s, &w, 0);
    errno = EMFILE;
    return -1;
  }
  files[slot].used = 1;
  files[slot].service = s;
  files[slot].fd = (int)fd;
  return FD_BASE + slot;
}

int close(int fd)
{
  int slot;

  if (fd >= 0 && fd <= 2 && std_fd(fd) != fd) {
    int f = redirected[fd];
    redirected[fd] = -1;
    return close(f);
  }
  slot = file_slot(fd);

  if (slot < 0) return result(sys3(6 /* close */, fd, 0, 0));
  files[slot].used = 0;
  {
    wire_writer w;
    fs_start(&w, FS_CLOSE);
    wire_put_int(&w, files[slot].fd);
    return fs_simple(files[slot].service, &w, 0) < 0 ? -1 : 0;
  }
}

/* one Read request: up to FS_IOMAX bytes */
static ssize_t fs_read(int slot, char * buf, size_t count)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  const char * data;
  unsigned int n;

  fs_start(&w, FS_READ);
  wire_put_int(&w, files[slot].fd);
  wire_put_int(&w, count > FS_IOMAX ? FS_IOMAX : count);
  if (fs_request(files[slot].service, &w, &r, &msg) < 0) return -1;
  data = wire_get_string(&r, &n);
  if (r.error) { mynos_freeMsg(&msg); errno = EIO; return -1; }
  if (n > count) n = count;
  memcpy(buf, data, n);
  mynos_freeMsg(&msg);
  return n;
}

ssize_t read(int fd, void * buf, size_t count)
{
  size_t done = 0;
  int slot;

  fd = std_fd(fd);
  if (fd == 0 && service_port(console_name(), &console_cache) >= 0)
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

/* one Write request: the data in the request */
static ssize_t fs_write(int slot, const char * buf, size_t count)
{
  wire_writer w;
  fs_start(&w, FS_WRITE);
  wire_put_int(&w, files[slot].fd);
  wire_put_string(&w, buf, count > FS_IOMAX ? FS_IOMAX : count);
  return fs_simple(files[slot].service, &w, 1);
}

ssize_t write(int fd, const void * buf, size_t count)
{
  size_t done = 0;
  int slot;

  fd = std_fd(fd);
  slot = file_slot(fd);

  if (slot < 0 && (fd == 1 || fd == 2) && console_owns_output() &&
      service_port(console_name(), &console_cache) >= 0)
    return console_write(console_cache.port, buf, count);
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
  wire_writer w;
  int slot;

  fd = std_fd(fd);
  slot = file_slot(fd);

  if (slot < 0) return result(sys3(19 /* lseek */, fd, (long)offset, whence));
  fs_start(&w, FS_SEEK);
  wire_put_int(&w, files[slot].fd);
  wire_put_int(&w, offset);
  wire_put_int(&w, whence);
  return fs_simple(files[slot].service, &w, 1);
}

int unlink(const char * path)
{
  return name_call(path, FS_REMOVE);
}

/* rename: within one service */
int rename(const char * from, const char * to)
{
  char name[FS_NAMEMAX], newname[FS_NAMEMAX];
  wire_writer w;
  int s, s2;

  if ((s = resolve(from, name)) < 0 || (s2 = resolve(to, newname)) < 0)
    return -1;
  if (s != s2) { errno = EXDEV; return -1; }
  if (service(s) < 0) { errno = ENOENT; return -1; }
  if (!name[0] || !newname[0]) { errno = EBUSY; return -1; }
  fs_start(&w, FS_RENAME);
  wire_put_cstring(&w, name);
  wire_put_cstring(&w, newname);
  return fs_simple(s, &w, 0) < 0 ? -1 : 0;
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
  int slot;
  fd = std_fd(fd);
  slot = file_slot(fd);
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
  int loaded;              /* the entries came (one List request) */
  int count;
  char * names;            /* count names, each with its final 0 */
  char * dirs;             /* count flags: a directory */
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

/* the directory's entries, with one List request: 0 or -1 */
static int dir_load(DIR * d)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  long long n, i;
  size_t used = 0;

  d->loaded = 1;
  fs_start(&w, FS_LIST);
  wire_put_cstring(&w, d->name);
  if (fs_request(d->service, &w, &r, &msg) < 0) return -1;
  n = wire_get_int(&r);
  if (r.error || n < 0 || n > (long long)msg->size) { mynos_freeMsg(&msg); errno = EIO; return -1; }
  d->names = malloc(msg->size + 1);
  d->dirs = malloc(n + 1);
  if (!d->names || !d->dirs) { mynos_freeMsg(&msg); errno = ENOMEM; return -1; }
  for (i = 0; i < n; i++) {
    unsigned int len;
    const char * name = wire_get_string(&r, &len);
    long long size = wire_get_int(&r);
    if (r.error) break;
    memcpy(d->names + used, name, len);
    d->names[used + len] = 0;
    used += len + 1;
    d->dirs[i] = size == -1;
  }
  d->count = r.error ? (int)i : (int)n;
  mynos_freeMsg(&msg);
  return 0;
}

struct dirent * readdir(DIR * d)
{
  const char * name;
  int i;

  if (d->mounts_listed) return next_mount(d);
  if (!d->loaded && dir_load(d) < 0) return NULL;
  if (d->index >= d->count) {             /* the end: errno unchanged */
    if (d->service == MEMROFS && !d->name[0]) return next_mount(d);
    return NULL;
  }
  name = d->names;
  for (i = 0; i < d->index; i++) name += strlen(name) + 1;
  d->index++;
  return dir_entry(d, name, strlen(name), d->dirs[d->index - 1]);
}

void rewinddir(DIR * d)
{
  d->index = 0;
  d->mounts_listed = 0;
  d->loaded = 0;                          /* listed again */
  free(d->names); d->names = NULL;
  free(d->dirs); d->dirs = NULL;
}

int closedir(DIR * d)
{
  free(d->names);
  free(d->dirs);
  free(d);
  return 0;
}

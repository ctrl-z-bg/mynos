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
 * stdio over libmynos (mynos-d6k). musl's FILE functions do their I/O
 * through five internal functions that make Linux system calls directly
 * (readv, writev, close, lseek, ioctl), and fopen opens with the raw open
 * call: that bypassed libmynos, where files and consoles are services. So
 * fopen opened the kernel's one built-in file, fgets(stdin) failed (no
 * readv), and printf in a terminal window went to the text screen.
 *
 * These are those five functions and fopen, on libmynos's open, read,
 * write, lseek, close and ioctl. They replace musl's at link time: mynos.mk
 * names them with -u, so the linker takes them from libmynos, which comes
 * before the C library. musl itself is unchanged.
 *
 * struct mynos_file is musl 1.2.5's struct _IO_FILE
 * (src/internal/stdio_impl.h, MIT licence), field for field: it must
 * follow the musl the container builds with (tests/stdio checks it).
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define F_EOF 16
#define F_ERR 32
#define F_SVB 64

struct mynos_file {
  unsigned flags;
  unsigned char *rpos, *rend;
  int (*close)(FILE *);
  unsigned char *wend, *wpos;
  unsigned char *mustbezero_1;
  unsigned char *wbase;
  size_t (*read)(FILE *, unsigned char *, size_t);
  size_t (*write)(FILE *, const unsigned char *, size_t);
  off_t (*seek)(FILE *, off_t, int);
  unsigned char *buf;
  size_t buf_size;
  FILE *prev, *next;
  int fd;
  int pipe_pid;
  long lockcount;
  int mode;
  volatile int lock;
  int lbf;
  void *cookie;
  off_t off;
  char *getln_buf;
  void *mustbezero_2;
  unsigned char *shend;
  off_t shlim, shcnt;
  FILE *prev_locked, *next_locked;
  struct __locale_struct *locale;
};

#define F(f) ((struct mynos_file *)(f))

size_t __stdio_write(FILE *, const unsigned char *, size_t);

/* read: as musl's, which fills the caller's buffer and the FILE's in one
   readv; here one read, into the caller's buffer when it wants more than
   a byte (a second read could wait for a line that is not coming), else
   into the FILE's buffer */
size_t __stdio_read(FILE * ff, unsigned char * buf, size_t len)
{
  struct mynos_file * f = F(ff);
  size_t first = len - !!f->buf_size;
  ssize_t cnt;

  if (first) {
    cnt = read(f->fd, buf, first);
    if (cnt <= 0) {
      f->flags |= cnt ? F_ERR : F_EOF;
      return 0;
    }
    return cnt;
  }
  cnt = read(f->fd, f->buf, f->buf_size);
  if (cnt <= 0) {
    f->flags |= cnt ? F_ERR : F_EOF;
    return 0;
  }
  f->rpos = f->buf;
  f->rend = f->buf + cnt;
  buf[len - 1] = *f->rpos++;
  return len;
}

static int write_all(int fd, const unsigned char * p, size_t n)
{
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w <= 0) return -1;
    p += w;
    n -= w;
  }
  return 0;
}

/* write: what is buffered, then the caller's bytes */
size_t __stdio_write(FILE * ff, const unsigned char * buf, size_t len)
{
  struct mynos_file * f = F(ff);
  size_t buffered = f->wpos - f->wbase;
  int bad = (buffered && write_all(f->fd, f->wbase, buffered) < 0);
  if (!bad && len) bad = write_all(f->fd, buf, len) < 0;
  if (bad) {
    f->wpos = f->wbase = f->wend = 0;
    f->flags |= F_ERR;
    return 0;
  }
  f->wend = f->buf + f->buf_size;
  f->wpos = f->wbase = f->buf;
  return len;
}

/* stdout: line-buffered on a terminal, fully buffered when redirected */
size_t __stdout_write(FILE * ff, const unsigned char * buf, size_t len)
{
  struct mynos_file * f = F(ff);
  struct winsize wsz;
  f->write = __stdio_write;
  if (!(f->flags & F_SVB) && ioctl(f->fd, TIOCGWINSZ, &wsz))
    f->lbf = -1;
  return __stdio_write(ff, buf, len);
}

off_t __stdio_seek(FILE * f, off_t off, int whence)
{
  return lseek(F(f)->fd, off, whence);
}

int __stdio_close(FILE * f)
{
  return close(F(f)->fd);
}

/* fopen: libmynos's open, then musl's fdopen */
FILE * fopen(const char * restrict name, const char * restrict mode)
{
  int flags, fd;
  FILE * f;
  if (!strchr("rwa", *mode)) {
    errno = EINVAL;
    return 0;
  }
  flags = strchr(mode, '+') ? O_RDWR : *mode == 'r' ? O_RDONLY : O_WRONLY;
  if (*mode != 'r') flags |= O_CREAT;
  if (*mode == 'w') flags |= O_TRUNC;
  if (*mode == 'a') flags |= O_APPEND;
  if (strchr(mode, 'x')) flags |= O_EXCL;
  if ((fd = open(name, flags, 0666)) < 0) return 0;
  if ((f = fdopen(fd, mode)) == NULL) close(fd);
  return f;
}

FILE * fopen64(const char * restrict name, const char * restrict mode)
{
  return fopen(name, mode);
}

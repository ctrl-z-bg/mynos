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
 * Protocol of the file services: memrofs, the read-only RAM disk
 * (services/fs/memrofs); tmpfs, a writable filesystem in memory written in
 * OCaml (services/tmpfs), mounted at /tmp; fatfs, the FAT filesystem of
 * the disk, in OCaml (services/fatfs), mounted at /disk. Programs use them
 * through the file functions of libmynos (mynos-lib/src/fileio.c).
 *
 * One connection per request: the client sends a struct fs_req and
 * receives a struct fs_reply. Some requests carry a second message:
 *   - READ: a reply with value > 0 is followed by the data;
 *   - WRITE: the client sends the data right after the request, then
 *     receives the reply;
 *   - LIST: a reply with status OK is followed by the name.
 * Names are paths inside the service ("dir/file", no leading slash; "" is
 * its root). memrofs and tmpfs are flat: only their root exists.
 *
 * Only fixed-size types, so that the layout is the same with every libc
 * (and in OCaml: 84 bytes, little endian).
 */

#ifndef __MYNOS_FS_H__
#define __MYNOS_FS_H__

#define MEMROFS_SERVICE  "memrofs"
#define TMPFS_SERVICE    "tmpfs"
#define TMPFS_MOUNT      "tmp"      /* /tmp/NAME is NAME on tmpfs */
#define FATFS_SERVICE    "fatfs"
#define FATFS_MOUNT      "disk"     /* /disk/PATH is PATH on fatfs */

#define FS_NAMEMAX  64       /* file names, including the final 0 */
#define FS_IOMAX    16384    /* largest READ or WRITE */

/* request types */
#define FS_OPEN   0   /* name, arg1: FS_O_* flags -> value: descriptor     */
#define FS_CLOSE  1   /* fd                       -> value: 0              */
#define FS_READ   2   /* fd, arg1: max            -> value: n, then data   */
#define FS_LSEEK  3   /* fd, arg1: offset, arg2: whence (0/1/2)
                                                  -> value: new position   */
#define FS_LIST   4   /* name: directory, arg1: index -> value: size of the
                         index-th entry (-1: a directory), then its name
                         (NOT_FOUND past the end) */
#define FS_WRITE  5   /* fd, arg1: n, then the data -> value: n written     */
#define FS_UNLINK 6   /* name (a file)            -> value: 0              */
#define FS_MKDIR  7   /* name                     -> value: 0              */
#define FS_RMDIR  8   /* name (an empty directory) -> value: 0             */

/* FS_OPEN flags */
#define FS_O_WRITE   1   /* open for writing (and reading) */
#define FS_O_CREAT   2   /* create it if missing */
#define FS_O_TRUNC   4   /* empty it */
#define FS_O_APPEND  8   /* every write at the end */

/* reply status */
#define FS_OK         0
#define FS_NOT_FOUND  1
#define FS_TOO_MANY   2
#define FS_DENIED     3   /* the descriptor belongs to another client */
#define FS_NOT_OPEN   4
#define FS_INVALID    5
#define FS_READONLY   6   /* writing on a read-only file or service */
#define FS_NO_SPACE   7
#define FS_IS_DIR     8   /* opening or unlinking a directory */
#define FS_NOT_EMPTY  9
#define FS_EXISTS    10
#define FS_NOT_DIR   11

struct fs_req {
  int type;
  int client;                  /* pid of the client: owner of descriptors */
  int fd;
  int arg1;
  int arg2;
  char name[FS_NAMEMAX];
};

struct fs_reply {
  int status;
  int value;
};

#endif

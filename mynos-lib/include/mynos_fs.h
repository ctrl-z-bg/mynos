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
 * fs/1, the protocol of the file services: memrofs, the read-only RAM disk
 * (services/fs/memrofs, C); tmpfs, files in memory (services/tmpfs, OCaml),
 * mounted at /tmp; fatfs, the FAT file system of the disk (services/fatfs,
 * OCaml), mounted at /disk. Programs use them through the file functions of
 * libmynos (mynos-lib/src/fileio.c); OCaml programs can also speak it typed
 * (module Fs, mynos-lib/ocaml/fs.mli, which defines it).
 *
 * Typed IPC (doc/decisions/typed-ipc.md, mynos_wire.h): a request is the
 * protocol id "fs/1", the request's case number and its arguments; the
 * reply is Ok and the value, or Error and a message that starts with one
 * of the error names below ("not_found: ..."). A service describes the
 * protocol itself (a request "describe"). The client is the process at
 * the other end of the channel (the kernel says who: channelPeer); its
 * descriptors are its own.
 *
 * Names are paths inside the service ("dir/file", no leading slash; "" is
 * its root). memrofs and tmpfs are flat: only their root exists.
 */

#ifndef __MYNOS_FS_H__
#define __MYNOS_FS_H__

#define FS_PROTOCOL      "fs/1"

#define MEMROFS_SERVICE  "memrofs"
#define TMPFS_SERVICE    "tmpfs"
#define TMPFS_MOUNT      "tmp"      /* /tmp/NAME is NAME on tmpfs */
#define FATFS_SERVICE    "fatfs"
#define FATFS_MOUNT      "disk"     /* /disk/PATH is PATH on fatfs */

#define FS_NAMEMAX  64       /* a path, including the final 0 */
#define FS_IOMAX    16384    /* the largest Read or Write */

/* the requests (case numbers), their arguments and replies (shapes in the
   notation of mynos_wire.h) */
#define FS_OPEN    0   /* (path:S,flags:I)          -> I: a descriptor  */
#define FS_CLOSE   1   /* (fd:I)                    -> U                */
#define FS_READ    2   /* (fd:I,max:I)              -> S: the bytes     */
#define FS_WRITE   3   /* (fd:I,data:S)             -> I: written       */
#define FS_SEEK    4   /* (fd:I,offset:I,whence:I)  -> I: the position  */
#define FS_LIST    5   /* (path:S) -> L<(name:S,size:I)>: a directory's
                          entries; size -1 for a directory              */
#define FS_REMOVE  6   /* (path:S): a file          -> U                */
#define FS_MKDIR   7   /* (path:S)                  -> U                */
#define FS_RMDIR   8   /* (path:S): an empty directory -> U             */
#define FS_RENAME  9   /* (from:S,to:S): an existing file of the new
                          name is replaced          -> U                */

/* Open flags */
#define FS_O_WRITE   1   /* open for writing (and reading) */
#define FS_O_CREAT   2   /* create it if missing */
#define FS_O_TRUNC   4   /* empty it */
#define FS_O_APPEND  8   /* every write at the end */

/* errors: an Error reply's message starts with the name */
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

#define FS_ERROR_NAMES { "ok", "not_found", "too_many", "denied", "not_open", \
                         "invalid", "read_only", "no_space", "is_dir",        \
                         "not_empty", "exists", "not_dir" }
#define FS_NERRORS 12

#endif

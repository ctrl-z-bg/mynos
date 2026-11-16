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
 * Protocol of memrofs, the read-only RAM disk filesystem service
 * (services/fs/memrofs), used by the file functions of libmynos
 * (mynos-lib/src/fileio.c). One connection per request: the client sends a
 * struct memrofs_req and receives a struct memrofs_reply; a READ reply with
 * value > 0 is followed by a second message with the data, a LIST reply
 * with status OK by a message with the name. The namespace is flat.
 *
 * Only fixed-size types, so that the layout is the same with every libc.
 */

#ifndef __MYNOS_MEMROFS_H__
#define __MYNOS_MEMROFS_H__

#define MEMROFS_SERVICE  "memrofs"
#define MEMROFS_NAMEMAX  64       /* file names, including the final 0 */
#define MEMROFS_READMAX  16384    /* largest READ */

/* request types */
#define MEMROFS_OPEN   0   /* name          -> value: file descriptor   */
#define MEMROFS_CLOSE  1   /* fd            -> value: 0                 */
#define MEMROFS_READ   2   /* fd, arg1: max -> value: n, then the data  */
#define MEMROFS_LSEEK  3   /* fd, arg1: offset, arg2: whence (0/1/2)
                                            -> value: new position      */
#define MEMROFS_LIST   4   /* arg1: index   -> value: size of the index-th
                              file, then its name (NOT_FOUND past the end) */

/* reply status */
#define MEMROFS_OK         0
#define MEMROFS_NOT_FOUND  1
#define MEMROFS_TOO_MANY   2
#define MEMROFS_DENIED     3   /* the descriptor belongs to another client */
#define MEMROFS_NOT_OPEN   4
#define MEMROFS_INVALID    5

struct memrofs_req {
  int type;
  int client;                  /* pid of the client: owner of descriptors */
  int fd;
  int arg1;
  int arg2;
  char name[MEMROFS_NAMEMAX];
};

struct memrofs_reply {
  int status;
  int value;
};

#endif

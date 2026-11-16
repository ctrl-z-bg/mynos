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
 * Protocol of the block services: disk drivers, such as the ATA driver
 * written in OCaml (services/ata). One connection per request: the client
 * sends a struct block_req and receives a struct block_reply.
 *   - READ: a reply with status OK is followed by the data
 *     (count * BLOCK_SECTOR bytes);
 *   - WRITE: the client sends the data right after the request, then
 *     receives the reply.
 * Only fixed-size types, little endian: 12-byte requests, 8-byte replies.
 */

#ifndef __MYNOS_BLOCK_H__
#define __MYNOS_BLOCK_H__

#define BLOCK_SERVICE    "ata0"     /* the first disk */
#define BLOCK_SECTOR     512
#define BLOCK_MAXCOUNT   32         /* sectors per request: 16 KB */

/* request types */
#define BLOCK_INFO   0   /*                     -> value: number of sectors */
#define BLOCK_READ   1   /* lba, count          -> value: count, then data  */
#define BLOCK_WRITE  2   /* lba, count, then data -> value: count           */

/* reply status */
#define BLOCK_OK        0
#define BLOCK_INVALID   1   /* bad request, or beyond the end of the disk */
#define BLOCK_IO_ERROR  2   /* the device reported an error */

struct block_req {
  int type;
  int lba;
  int count;
};

struct block_reply {
  int status;
  int value;
};

#endif

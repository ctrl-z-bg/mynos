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

#define FILENAMEMAXLEN 20
#define MAXOPENFILES   1000
#define MAXFILES       1000
#define RAMDISKMAXSIZE (1024*1024)

typedef enum {OPEN, CLOSE, READ, LSEEK} request_type_t;

typedef enum {STATUS_OK, STATUS_NOT_FOUND, STATUS_TOO_MANY,
	      STATUS_PERMISSION_DENIED, STATUS_NOT_OPEN} status_t;

typedef struct {
  int fd;
  size_t to_read;
} read_request_data_t;

typedef struct {
  int fd;
  off_t offset;
  int whence;
} lseek_request_data_t;

typedef struct {
  request_type_t type;
  union {
    int fd;
    char fname[FILENAMEMAXLEN];
    read_request_data_t read_data;
    lseek_request_data_t lseek_data;
  } data;
} request_t;

#ifndef _MEMROFS_H_
#define _MEMROFS_H_

typedef struct {
  pid_t pid;
  int   fileidx;
  char * currpos;
} filedescriptor_t;

typedef struct {
  char filename[FILENAMEMAXLEN];
  char * start;
  uint32_t size;
} fileentry_t;

typedef struct {
  int fd;
  status_t status;
} open_response_t;

typedef struct {
  size_t rd;
  status_t status;
} read_response_t;

extern filedescriptor_t filedesc[MAXOPENFILES];
extern fileentry_t * filesystem;
extern char *ramdisk;

#endif /* _MEMROFS_H_ */

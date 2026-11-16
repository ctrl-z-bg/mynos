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
#include <mynos_fs.h>
#include <stdint.h>
#include <sys/types.h>

#define FILENAMEMAXLEN FS_NAMEMAX
#define MAXOPENFILES   1000
#define MAXFILES       1000
#define RAMDISKMAXSIZE (1024*1024)

#ifndef _MEMROFS_H_
#define _MEMROFS_H_

/* RAM disk image (tool/createDisk.c): ".RAMDISK", then MAXFILES entries,
   then the file contents; start is the offset of a file from the image
   beginning */
typedef struct {
  char filename[FILENAMEMAXLEN];
  char * start;
  uint32_t size;
} fileentry_t;

/* an open file: owner (client pid, 0 = free), file, position */
typedef struct {
  int      pid;
  int      fileidx;
  uint32_t pos;
} filedescriptor_t;

#endif /* _MEMROFS_H_ */

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

//#include <memrofs.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include "../memrofs.h"

int main(int argc, char ** argv) {
  int i;
  int size;
  int fd;
  FILE * diskFILE;
  char * disk;
  fileentry_t * header;
  int headerlen;
  char * index;
  int sumlen = 0;
  char * MAGIC = ".RAMDISK";
  int MAGIC_len;
  int disksize;

  MAGIC_len = strlen(MAGIC);

  headerlen = MAXFILES * sizeof(fileentry_t);
  header = (fileentry_t*)malloc(headerlen);

  for (i = 1; i < argc; i++) {
    if ((fd = open(argv[i], O_RDONLY)) == -1) {
      fprintf(stderr, "Unable to open file %s\n", argv[i]);
      exit(-1);
    }
    size = lseek(fd, 0, SEEK_END);
    strcpy(header[i-1].filename, argv[i]);
    header[i-1].start = 0;
    header[i-1].size = size;
    sumlen += size;
    close(fd);
  }

  disksize = MAGIC_len + headerlen + sumlen;
  disk = (char*)malloc(disksize);

  index = disk + MAGIC_len + headerlen;

  /* copy the files */
  for (i = 1; i < argc; i++) {
    fd = open(argv[i], O_RDONLY);
    read(fd, index, header[i-1].size);
    header[i-1].start = (char*)((int)index - (int)disk);
    index += header[i-1].size;
    close(fd);
  }

  /* copy the MAGIC */
  memcpy(disk, MAGIC, MAGIC_len);
  /* copy the header */
  memcpy(disk + MAGIC_len, header, headerlen);

  if ((diskFILE = fopen("RAMDISK.dsk", "w")) == NULL) {
    fprintf(stderr, "Unable to create the disk file\n");
    exit(-1);
  }
  //printf("scritti %d bytes\n",
  write(fileno(diskFILE), disk, disksize);
  fclose(diskFILE);

  free(header);
  printf("header size: %d\n", headerlen);
  header = (fileentry_t*)disk;
  for (i = 0; i < argc-1; i++) {
    printf("file %s:\t size %d start from offset %d\n", header[i].filename, 
	   header[i].size,
	   (int)(header[i].start));
  }

  free(disk);

  return 0;
}

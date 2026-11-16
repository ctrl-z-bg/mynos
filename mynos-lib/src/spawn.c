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
 * Starting programs: mynos_spawn reads an ELF program from a file (through
 * the file functions of fileio.c, so from memrofs) and asks the kernel to
 * start it as a child process (native call 30). The parent collects its
 * exit status with the usual waitpid.
 */

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mynos.h>
#include "syscall.h"

int mynos_spawnImage(void * elf, unsigned int len, char ** argv, char ** envp)
{
  return __mynos_syscall(30, (int)elf, (int)len, (int)argv, (int)envp, 0);
}

int mynos_spawn(const char * path, char ** argv, char ** envp)
{
  struct stat st;
  char * image;
  int fd, pid;
  unsigned int done = 0;

  if ((fd = open(path, O_RDONLY)) < 0) return MYNOS_ERR_INVALID;
  if (fstat(fd, &st) < 0 || st.st_size <= 0 ||
      (image = malloc(st.st_size)) == NULL) {
    close(fd);
    return MYNOS_ERR_FULL;
  }
  while (done < (unsigned int)st.st_size) {
    int n = read(fd, image + done, st.st_size - done);
    if (n <= 0) break;
    done += n;
  }
  close(fd);
  if (done != (unsigned int)st.st_size) {
    free(image);
    return MYNOS_ERR_INVALID;
  }
  pid = mynos_spawnImage(image, done, argv, envp);
  free(image);
  return pid;
}

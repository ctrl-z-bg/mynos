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
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mynos.h>
#include "syscall.h"

int mynos_spawnImage(void * elf, unsigned int len, char ** argv, char ** envp)
{
  return __mynos_syscall(30, (long)elf, (long)len, (long)argv, (long)envp, 0);
}

/* mapPhysical (28): the address, or an error (a small negative number) */
void * mynos_mapPhysical(unsigned long phys, int npages) {
  unsigned long r = (unsigned long)__mynos_syscall(28, phys, npages, 0, 0, 0);
  return r >= (unsigned long)-4096 ? NULL : (void *)r;
}

/* piScreen (104): mynos.h */
int mynos_piScreen(int op, int w, int h, unsigned long * out) {
  return (int)__mynos_syscall(104, op, w, h, (long)out, 0);
}

/* piFirmware (105): mynos.h */
int mynos_piFirmware(unsigned int * buf, int len) {
  return (int)__mynos_syscall(105, (long)buf, len, 0, 0, 0);
}

/* dmaArea (29): the DMA area mapped here, its physical address in *phys;
   NULL without one (or without the io privilege) */
void * mynos_dmaArea(unsigned long * phys) {
  long p = __mynos_syscall(29, 1, 0, 0, 0, 0);
  unsigned long r;
  if (p < 0 && p > -4096) return NULL;
  r = (unsigned long)__mynos_syscall(29, 0, 0, 0, 0, 0);
  if (r >= (unsigned long)-4096) return NULL;
  if (phys) *phys = (unsigned long)p;
  return (void *)r;
}

/* dmaAlloc (39): npages of RAM in one physical piece, mapped here, its
   physical address in *phys; NULL if there is none (or without the io
   privilege). Freed when the process ends. */
void * mynos_dmaAlloc(int npages, unsigned long * phys) {
  unsigned long p = 0;
  unsigned long r = (unsigned long)__mynos_syscall(39, npages, (long)&p, 0, 0, 0);
  if (r >= (unsigned long)-4096) return NULL;
  if (phys) *phys = p;
  return (void *)r;
}

/* processInfo (27): MYNOS_PROC_ALIVE | privileges, or an error */
int mynos_processInfo(int pid)
{
  return __mynos_syscall(27, pid, 0, 0, 0, 0);
}

const char * mynos_cwd(void);   /* fileio.c */
extern char ** environ;

/* the environment of a child: the caller's, with PWD set to our current
   directory (the child starts there) */
static char ** child_env(char ** envp, char * pwd_var)
{
  int n = 0, i, k = 0;
  char ** env;
  for (i = 0; envp && envp[i]; i++) n++;
  if ((env = malloc((n + 2) * sizeof(char *))) == NULL) return NULL;
  for (i = 0; envp && envp[i]; i++)
    if (strncmp(envp[i], "PWD=", 4)) env[k++] = envp[i];
  strcpy(pwd_var, "PWD=");
  strncat(pwd_var, mynos_cwd(), 250);
  env[k++] = pwd_var;
  env[k] = NULL;
  return env;
}

static int spawn_file(const char * path, char ** argv, char ** envp,
		      int privileges);

int mynos_spawn(const char * path, char ** argv, char ** envp)
{
  return spawn_file(path, argv, envp, 0);
}

int mynos_spawnPriv(const char * path, char ** argv, char ** envp,
		    int privileges)
{
  return spawn_file(path, argv, envp, privileges);
}

static int spawn_file(const char * path, char ** argv, char ** envp,
		      int privileges)
{
  struct stat st;
  char * image;
  char ** env;
  char pwd_var[256];
  int fd, pid;
  unsigned int done = 0;

  /* a bare name is a system program, at the root of the RAM disk, else a
     file of the current directory */
  fd = -1;
  if (!strchr(path, '/')) {
    char sys[256] = "/";
    strncat(sys, path, sizeof(sys) - 2);
    fd = open(sys, O_RDONLY);
  }
  if (fd < 0 && (fd = open(path, O_RDONLY)) < 0) return MYNOS_ERR_INVALID;
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
  if (!envp) envp = environ;      /* by default, our own environment */
  env = child_env(envp, pwd_var);
  pid = __mynos_syscall(30, (long)image, (long)done, (long)argv,
                        (long)(env ? env : envp), privileges);
  free(env);
  free(image);
  return pid;
}

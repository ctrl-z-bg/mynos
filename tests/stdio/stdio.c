/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* C's stdio on MyNOS (mynos-d6k): fopen and friends reach the file
   services through libmynos, and stdin gives lines typed at the console
   or a file a shell redirected. Run from sh (tools/run-tests.sh, seventh
   boot): /disk/stdio-test, then a typed line; and with a pipe. */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static int failures = 0;

static void check(const char * what, int ok)
{
  printf("stdio: %-44s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main(void)
{
  char line[256], raw[256], a[32] = "", b[32] = "", c[32] = "";
  FILE * f;
  int fd, n, ok;

  /* a file of the RAM disk, through fopen and through open: the same */
  f = fopen("/init.rc", "r");
  fd = open("/init.rc", O_RDONLY);
  n = fd >= 0 ? read(fd, raw, sizeof raw - 1) : -1;
  if (fd >= 0) close(fd);
  check("fopen reads a file of the RAM disk",
        f && n > 0 && fgets(line, sizeof line, f) &&
        strncmp(line, raw, strlen(line)) == 0);
  if (f) fclose(f);

  /* written, appended, read back, sought, on /tmp (tmpfs) */
  f = fopen("/tmp/stdio.txt", "w");
  check("fopen creates a file", f != NULL);
  if (f) { fprintf(f, "one %d\n", 1); fputs("two\n", f); fclose(f); }
  if ((f = fopen("/tmp/stdio.txt", "a")) != NULL) { fputs("three\n", f); fclose(f); }
  f = fopen("/tmp/stdio.txt", "r");
  ok = f && fgets(a, sizeof a, f) && fgets(b, sizeof b, f) && fgets(c, sizeof c, f)
    && !strcmp(a, "one 1\n") && !strcmp(b, "two\n") && !strcmp(c, "three\n")
    && fgets(a, sizeof a, f) == NULL && feof(f);
  check("fprintf, fputs, append, fgets, end of file", ok);
  if (f) {
    check("fseek and ftell", fseek(f, 4, SEEK_SET) == 0 && ftell(f) == 4 && fgetc(f) == '1');
    fclose(f);
  }
  errno = 0;
  check("a missing file: NULL and ENOENT",
        fopen("/tmp/no-such-file", "r") == NULL && errno == ENOENT);

  /* isatty follows the shell's redirections: 1 on the console, 0 in a
     file */
  printf("stdio: isatty(1) %d\n", isatty(1));

  /* standard input: the console, or what the shell redirected */
  printf("stdio: type a line\n");
  if (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    printf("stdio: read [%s]\n", line);
  } else
    printf("stdio: read nothing\n");
  printf(failures ? "stdio: SOME CHECKS FAILED\n" : "stdio: all checks passed\n");
  return failures != 0;
}

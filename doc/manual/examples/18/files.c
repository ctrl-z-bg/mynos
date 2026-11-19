/* files.c: files from C, with stdio and with the calls beneath it */
#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

int main(void)
{
  FILE * f;
  char line[100], dir[100];
  struct stat st;
  DIR * d;
  struct dirent * e;
  int fd;

  /* write a file on /tmp (tmpfs), read it back */
  if ((f = fopen("/tmp/notes.txt", "w")) == NULL) {
    perror("/tmp/notes.txt");
    return 1;
  }
  fprintf(f, "first line\nsecond line\n");
  fclose(f);
  f = fopen("/tmp/notes.txt", "r");
  while (fgets(line, sizeof line, f))
    printf("read: %s", line);
  fclose(f);

  /* the same file with open, write, stat */
  fd = open("/tmp/notes.txt", O_WRONLY | O_APPEND);
  write(fd, "third line\n", 11);
  close(fd);
  if (stat("/tmp/notes.txt", &st) == 0)
    printf("size: %ld bytes\n", (long)st.st_size);

  /* a relative name, from the current directory */
  chdir("/tmp");
  rename("notes.txt", "old.txt");
  printf("in %s:", getcwd(dir, sizeof dir));
  d = opendir(".");
  while ((e = readdir(d)) != NULL)
    printf(" %s", e->d_name);
  printf("\n");
  closedir(d);
  unlink("old.txt");

  /* errors are errno values */
  if (open("old.txt", O_RDONLY) < 0)
    printf("old.txt: %s\n", strerror(errno));
  if (fopen("/hello.txt", "w") == NULL)
    printf("/hello.txt: %s\n", strerror(errno));
  return 0;
}

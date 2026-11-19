/* keys.c: keys one by one, with termios, until q */
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

int main(void)
{
  struct termios saved, raw;
  unsigned char c;

  tcgetattr(0, &saved);
  raw = saved;
  raw.c_lflag &= ~(ICANON | ECHO);      /* no line editing, no echo */
  raw.c_cc[VMIN] = 1;                   /* each read: at least one byte */
  raw.c_cc[VTIME] = 0;
  tcsetattr(0, TCSANOW, &raw);
  printf("press keys, q to quit\n");
  fflush(stdout);
  while (read(0, &c, 1) == 1 && c != 'q')
    printf("key %3d %c\n", c, c >= ' ' && c < 127 ? c : '.');
  tcsetattr(0, TCSANOW, &saved);        /* back to line mode */
  return 0;
}

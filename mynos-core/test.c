#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

int main() {
  char a[20];
  char * b = "zxc";
  double radice = sqrt(9);

  a[0] = (char)0;

  strcat(a, "AAasd");

  while(1) {
    //putc('X', 0);
    puts(a);
    write(0, b, strlen(b));
  }
  return 1;
}

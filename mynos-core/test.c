#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

//extern int printf(const char *format, ...);
#define ZERO 48
#define MAX_INT_LEN 20
typedef unsigned long ulong32_t;
void print_ulong_hex(ulong32_t n);
void print_ulong(unsigned long n);
char asd[200];

int main() {
  char a[240];
  char * b = "zxc";
  double radice = sqrt(9);
  int i;

  strcat(a, "AAasd   asdasdasdsadsadsadasdsadsa");
  while(1) {
    printf("--VIA! %d", 4);

    //putc('X', stdout);
    puts(a);
    write(0, b, strlen(b));

    //print_ulong_hex((ulong32_t)&(asd[105]));
    //asd[105] = 'a';

  }
  return 1;
}

void print_ulong(unsigned long n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  tmp = n;
  do {
    q = tmp / 10;
    r = tmp % 10;
    *curr_char = r + ZERO;
    curr_char--;
    tmp = q;
  } while (q);

  write(0, curr_char + 1, strlen(curr_char+1));
}

void print_ulong_hex(ulong32_t n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  //  printk("0x");
  tmp = n;
  do {
    q = tmp / 16;
    r = tmp % 16;
    if (r < 10)
      *curr_char = r + ZERO;
    else
      *curr_char = (r - 10) + 65;

    curr_char--;
    tmp = q;
  } while (q);

  write(0, curr_char + 1, strlen(curr_char+1));
}

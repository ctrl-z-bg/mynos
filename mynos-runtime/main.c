/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
*/

/*
 * main() of the MyNOS OCaml runtime. The rest is the upstream OCaml
 * bytecode runtime, unchanged (libcamlrun.a, built with musl in the dev
 * container).
 *
 * The program to run: the first argument if there is one; otherwise
 * init.byte from the RAM disk (memrofs, through the file functions of
 * libmynos); otherwise the bytecode the kernel serves as "mynos_bytecode"
 * (GRUB module 1), as in the original MyNOS.
 */

#include <sys/stat.h>

extern void caml_main(char **argv);
extern void caml_do_exit(int retcode);

int main(int argc, char **argv)
{
  struct stat st;
  char *prog = argc > 1 ? argv[1]
    : stat("init.byte", &st) == 0 ? "init.byte" : "mynos_bytecode";
  char *args[] = { "ocamlrun", prog, 0 };
  caml_main(args);
  caml_do_exit(0);
  return 0;
}

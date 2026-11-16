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
 * The kernel has no filesystem behind open() yet (mynos-nxa): any file opens
 * the bytecode passed as GRUB module 1. So, as mynos-byterun/src/main.c did
 * for OCaml 3.06, give the runtime a bytecode file name to open.
 */

extern void caml_main(char **argv);
extern void caml_do_exit(int retcode);

int main(int argc, char **argv)
{
  char *args[] = { "ocamlrun", "mynos_bytecode", 0 };
  caml_main(args);
  caml_do_exit(0);
  return 0;
}

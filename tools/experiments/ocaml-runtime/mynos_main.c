/* Same trick as mynos-byterun/src/main.c: the kernel serves GRUB module 1
   for any file, so give ocamlrun a bytecode name to open. */
extern void caml_main(char **argv);
extern void caml_do_exit(int retcode);
int main(int argc, char **argv) {
  char *args[] = { "ocamlrun", "mynos_bytecode", 0 };
  caml_main(args);
  caml_do_exit(0);
  return 0;
}

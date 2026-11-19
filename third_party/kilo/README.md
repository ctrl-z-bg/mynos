# kilo

[kilo](https://github.com/antirez/kilo) is a small text editor in C by
Salvatore Sanfilippo, BSD 2-clause license (see `LICENSE`), taken from its
repository on 2026-11-16 (version 0.0.1). In MyNOS it tests the terminal:
the VT100 sequences of the kernel's screen, the raw input mode of the
console service, `tcsetattr` and the window size through `libmynos`.

Changes for MyNOS (marked `MyNOS:` in `kilo.c`):
- `editorOpen` reads the file with `open`/`read` instead of
  `fopen`/`getline`: musl's stdio reads through direct system calls, which
  do not reach MyNOS's file services;
- `editorSave` opens with `O_TRUNC` instead of calling `ftruncate`.
- `editorAtExit` clears the screen, so that the shell's prompt does not
  appear over the file.

Usage in MyNOS: `kilo /disk/notes.txt` from `sh` (or `run "kilo"
["/disk/notes.txt"]` from the OCaml toplevel); Ctrl-S saves, Ctrl-Q
quits, Ctrl-F searches.

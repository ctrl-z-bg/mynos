# OCS in MyNOS

OCS 1.0.3, Ville-Pertti Keinonen's Scheme in OCaml (R5RS, 2003-2004;
BSD licence, `COPYING`), from https://github.com/freehck/ocs (commit
b68e286). The package `scheme` (`packages/scheme`) builds `ocs_main.ml`
as the program `scheme`.

Changes, for OCaml 5 and for MyNOS:

- Scheme's strings are `bytes` (`Sstring of bytes`): OCaml's strings are
  immutable since 4.06, and Scheme's are not (`string-set!`,
  `string-fill!`). `ocs_string.ml` uses `Bytes`; where a Scheme string
  meets an OCaml one (printing, file names, symbols, numbers), it is
  converted.
- `ocs_port.ml` is written again on OCaml's channels instead of Unix
  file descriptors (`Unix.read`, `Unix.select`): MyNOS's programs have
  no descriptors of their own for the console. A port reading the
  console flushes the standard output first (the prompt).
- `String.lowercase` and the like: their `_ascii` versions.
- `(exit)` and `(exit CODE)`, as R7RS has them (`ocs_prim.ml`).
- Its Makefiles are not used.
- The changes, as a patch against that commit: `mynos.patch`.

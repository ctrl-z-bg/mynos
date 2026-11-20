# Num

[Num](https://github.com/ocaml/num) 1.6 (INRIA), arbitrary-precision
integers and rationals (`Num`, `Big_int`, `Ratio`, `Nat`), once part of
OCaml's distribution. LGPL 2.1 with the OCaml linking exception
(`LICENSE`). Taken from the release archive `v1.6.tar.gz` on 2026-11-20
(sha256 `b5cce325449aac746d5ca963d84688a627cca5b38d41e636cf71c68b60495b3e`):
`src/`'s OCaml modules and C stubs, unchanged, without the assembly
versions of `bng` and the toplevel printers.

The C stubs (`nat_stubs.c`, `bng.c` with the portable `bng_digit.c`) are
compiled into MyNOS's `ocamlrun` by `mynos-runtime/Makefile`; this
Makefile builds `nums.cma` against that runtime's primitives. Programs
link it with `-I +num` on MyNOS (it is on the RAM disk as
`num/nums.cma`) or `-I third_party/num` in the dev container.

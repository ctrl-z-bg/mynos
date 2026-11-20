# 2048-ml

[2048-ml](https://github.com/pyx/2048-ml) is a clone of the game 2048 in
OCaml by Philip Xu, written in 2014 for OCaml's `Graphics` library. BSD
3-clause license (see `LICENSE`). Taken from its repository on 2026-11-20
(commit `72411b1`, 2014-03-28; archive sha256
`a4b80f601c55c092ef3b7f2761f4ed1c32320e8043ff04e5255d793b031e32ec`):
`src/`, `LICENSE` and `README.rst`, unchanged; its `Makefile` (ocamlbuild)
and Gentoo ebuild are left out.

In MyNOS it is a demo of `graphics.cma` (`graphics/`): a program written
for X11's `Graphics` that compiles without changes. This Makefile builds
`2048.byte` against MyNOS's primitives, in the dev container
(`tools/build-all.sh`); it goes on the RAM disk.

Usage in MyNOS, in a terminal of the graphical session: `/2048.byte`.
The keys are h, j, k, l (left, down, up, right), r starts again, q quits;
the arrows are not reported by `Graphics` on MyNOS. The game also prints
the board as text in the terminal (its `Tui` module).

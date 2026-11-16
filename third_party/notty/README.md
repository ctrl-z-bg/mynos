# Notty and uutf

[Notty](https://github.com/pqwy/notty) 0.2.3 (David Kaloper Meršinjak) and
its dependency [uutf](https://github.com/dbuenzli/uutf) 1.0.3 (Daniel
Bünzli), ISC licenses (`LICENSE.md` here and in `../uutf`), taken from
their release archives on 2026-11-16: Notty's core (`src/notty.ml*`, and
the `no-uucp` modules it uses) and uutf's `src/uutf.ml*`.

Change for MyNOS, marked `MyNOS:` in `notty.ml`: the `out_width` field
that OCaml 5.2 added to `Format.formatter_out_functions`.

`notty_mynos.ml` is not part of Notty: it is MyNOS's backend, in place of
`Notty_unix` (which needs the Unix library), for full-screen programs on
the MyNOS console. The Makefile builds `notty.cma` with uutf, Notty and
this backend.

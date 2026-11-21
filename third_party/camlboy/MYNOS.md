# CAMLBOY in MyNOS

CAMLBOY, a Game Boy emulator in OCaml by linoscope (MIT licence,
`LICENSE`), from https://github.com/linoscope/CAMLBOY (commit 11ae10a):
its library, `lib/`, flattened into `src/`, unchanged, and a module
`Bigstringaf` of six lines in place of that library (only `create`,
`unsafe_get`, `unsafe_set` are used). Its front ends (SDL, the web) are
not here: MyNOS's is `packages/camlboy/camlboy_main.ml`.

Speed, measured with CAMLBOY's own benchmark (the first 300 frames of
Tobu Tobu Girl, no drawing): 360 frames a second as bytecode on the host;
inside MyNOS, 357 under QEMU with KVM, 18 under QEMU without it (the
Game Boy needs 60).

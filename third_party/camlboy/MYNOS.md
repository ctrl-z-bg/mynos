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

## Sound: `src/apu.ml`, MyNOS's (2026-11-22)

CAMLBOY has no sound ("TODO: Fill sound related IO registers"). MyNOS
adds `apu.ml`/`apu.mli`, its own code (MIT, as CAMLBOY): the DMG's two
square channels (one with the sweep), the wave channel, the noise
channel, the frame sequencer at 512 Hz, NR50-NR52, advanced by whole
samples at 22050 Hz, with the Game Boy's output capacitor (a high-pass
filter). Three small changes to CAMLBOY's files make room for it:
`bus.ml`/`bus.mli` route 0xFF10-0xFF3F to it, `camlboy.ml` creates it
and runs it with the CPU's cycles, `camlboy_intf.ml` adds
`audio_samples` and `set_audio`. Off by default: then it costs nothing.

Its cost, measured as above on the host: 329 frames a second without
it, 273 with it.


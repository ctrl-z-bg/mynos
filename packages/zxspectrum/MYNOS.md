# zxspectrum: speed

Frames a second, GLAZX's title screen (animated): each frame run and its
picture made, as for the window (`zxspectrum --bench N`; on the host
`tests/z80/bench.ml`, the same modules without MyNOS). The Spectrum needs
50. Measured on 2026-11-27, MyNOS 1.0 (i386), with other QEMUs running on
the same machine: figures to a tenth.

| where | frames a second |
|---|---|
| the host, bytecode (`ocamlrun`, the dev container) | about 300 (295-312) |
| MyNOS, QEMU with KVM | about 330 (324-346) |
| MyNOS, QEMU without KVM | 10 |

In a window under KVM: 50 (the Spectrum's own rate). Without KVM the
window shows a fifth of it, and the sound turns itself off.

The service (emu/1) idle costs nothing measurable: under KVM 327 frames
a second with it, 324-346 without (`--bench N --no-service`).

The Z80 alone, in bytecode on the host: zexdoc and zexall, 46.7 billion
T-states each, about 24 minutes, 32 MHz of Z80: nine Spectrums.

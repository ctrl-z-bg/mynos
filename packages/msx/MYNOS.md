# msx: speed

Frames a second, Westen House running (its introduction: Graphics II,
sprites), each frame run and its picture made, as for the window (`msx
--bench N westen`; on the host `tests/msx/msxtest.ml`, the same modules
without MyNOS). The MSX needs 60. Measured on 2026-11-27, MyNOS 1.0
(i386), with other QEMUs running on the same machine.

| where | frames a second |
|---|---|
| the host, bytecode (`ocamlrun`, the dev container; no picture) | about 600 |
| MyNOS, QEMU with KVM | about 210 (205 without the service, 217 with) |
| MyNOS, QEMU without KVM | 7 |

The MSX's Z80 runs 3,584,160 T-states a second (59,736 a frame), about
the Spectrum's 3,494,400; the frames a second are fewer than the
Spectrum's (330 under KVM) because the TMS9918A's picture is drawn whole
at each frame, its sprites twice (their status, then their colours),
where the Spectrum's ULA redraws only the rows that changed. Without KVM
the window shows an eighth of the MSX's speed, and the sound turns itself
off.

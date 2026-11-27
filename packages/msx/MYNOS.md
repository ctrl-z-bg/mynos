# msx: speed

Frames a second, each frame run and its picture made, as for the window
(`msx --bench N GAME`; on the host `tests/msx/msxtest.ml`, the same
modules without MyNOS). The MSX needs 60. MyNOS 1.0 (i386), measured on
2026-11-27; the MSX1 with Westen House (its introduction: Graphics II,
sprites), the MSX2 with Robotron (SCREEN 4, sprites of mode 2).

| where | MSX1 | MSX2 |
|---|---|---|
| the host, bytecode (`ocamlrun`, the dev container) | 209 | 157 |
| MyNOS, QEMU with KVM (`--no-service`) | 212 | 164 |
| MyNOS, QEMU without KVM | 7 | |

The VDP draws each line as the beam reaches it (262 a frame, 192 or 212
drawn); the MSX2's are 512 columns wide. Without a window
(`--headless`) the lines are not drawn: only their sprites' status is
found, and a screenshot draws the picture when asked. The MSX's Z80
runs 3,584,160 T-states a second (59,736 a frame), about the
Spectrum's 3,494,400; the frames a second are fewer than the
Spectrum's (330 under KVM) because the picture is drawn whole each
frame, where the Spectrum's ULA redraws only the rows that changed.
Without KVM the window shows an eighth of the MSX1's speed, and the
sound turns itself off.

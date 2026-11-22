# Decision: sound

- **Issue:** mynos-7jn
- **Date:** 2026-11-22
- **Status:** accepted (2026-11-22: "level 2", sampled sound, chosen over
  the PC speaker alone); implemented the same day.

## What it is for

Sound in MyNOS the way the rest is done: a driver that is an ordinary
process, a server that programs talk to over typed IPC, and as little in
the kernel as possible. WAV files and tones from the command line
(`play`); streams that any program can open (module `Sound`), mixed.

## Choices

### 1. The card: a Sound Blaster 16

QEMU emulates several cards (PC speaker, SB16, AdLib, AC97, ES1370, HDA);
v86, which runs MyNOS in the browser, emulates the PC speaker and the
SB16. The SB16 is the one both have, and the simplest that plays samples:
ports at `0x220`, IRQ 5, ISA DMA. The PC speaker plays only square waves;
AC97 and HDA are PCI bus masters, with buffer descriptor lists, for no
gain here.

### 2. The kernel's part: a DMA area

ISA DMA reads RAM by itself, below 16 MB, without crossing 64 KB: a
driver needs memory whose physical address it knows. MyNOS's drivers
could map device memory (`mapPhysical`, call 28) but not RAM. The
smallest addition: at boot the kernel keeps 64 KB on a 64 KB boundary
below 16 MB, and call 29 (`dmaArea`) maps it for a driver, or gives its
physical address.

Where: the bootloaders load the modules right after the kernel, and the
RAM disk (26 MB) covers 4 to 31 MB; GRUB puts the small modules between
1 and 2 MB. The kernel keeps the first 4 MB but uses, between its page
directory (1 MB) and its image (2 MB), nothing: the area is chosen at
boot in that gap, avoiding the modules and the bootloader's structures,
else above 4 MB in pages still free. Fixed addresses were measured and
rejected: they differ between QEMU's own multiboot loader and GRUB.

The pages are counted as shared pages are: the area keeps one reference,
each mapping one more, which the process's end drops. No change to the
memory manager.

### 3. The driver and the server: one process, soundd

`soundd` (C, `services/sound/`, a `driver`) programs the 8237 (channel 5,
16-bit, auto-init) and the card (22050 Hz, 16-bit stereo, auto-init),
gets IRQ 5 as `netd` gets IRQ 9, and fills the half of the buffer that
has just played (two halves of 4 KB: 46 ms) with the mix. Driver and
mixer in one process: the mix must be ready at the interrupt, and an IPC
hop there would add latency for nothing. After half a second of silence
the card pauses (DSP 0xD5), and resumes (0xD6) with the next sound, which
goes into the half to be played next.

### 4. The protocol: sound/1

`info`, `open` a stream, `write` samples (the request waits while the
stream holds more than a second: the card sets the pace, as `displayd`'s
`next_event` waits), `close` (waits until played), `stop`, `tone`,
`volume`. One format, the card's: programs convert (module `Sound` reads
WAV, PCM 8/16-bit, mono/stereo, any rate, by linear interpolation, a
second at a time). Samples travel in the request, copied: 88 KB a second
is little; a shared buffer, as for the windows' pixels, can come later.

### 5. The host's side

`run-qemu.sh` adds the card with `SOUND=BACKEND` (or `SOUND=wav:FILE`,
which records it: the tests check the recording's frequencies);
`run-demo.sh` and the release's `run-mynos.sh` choose the host's backend
that the installed QEMU has (PipeWire, PulseAudio, ALSA, Core Audio), and
run silent if none. On the web, the page wakes the browser's audio at the
first click or key (browsers keep it suspended until then).

## Not now

The Game Boy's sound in camlboy (CAMLBOY does not emulate it); a shared
buffer instead of copied samples; recording (the SB16 can).

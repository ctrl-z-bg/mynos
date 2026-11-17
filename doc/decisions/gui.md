# Decision: MyNOS's graphical interface

- **Issue:** mynos-9lr
- **Date:** 2026-11-17
- **Status:** accepted (2026-11-17, all the choices below as proposed);
  phases 1 to 3 implemented the same day, 4 to come.

## What it is for

Not a generic desktop first, but what shows MyNOS's ideas, on the least of
a desktop it needs (windows, a terminal):

- a **service explorer**: every typed service describes its protocol
  (`doc/decisions/llm.md`, section 8), so a window can list the services,
  their requests, and make a form for any request from its shape; calling
  it shows the reply;
- a **trace viewer**: the event recorder's calls on a time line, nested;
- an **agent window**: the agent's conversation, its tool calls, the
  confirmations as buttons.

## Choices

### 1. A display server, windows in shared memory

`displayd` (C, `services/display/`) owns the screen. Each window's pixels
are a buffer of its program, shared with `displayd` through IPC's shared
pages (`MYNOS_IPC_SHARED`): the program draws in it, says which part
changed, and `displayd` composes the windows (with their title bars), the
pointer and the desktop into the screen. As in Wayland, and unlike X, no
drawing commands travel. Programs are separate processes, isolated as
the rest of MyNOS. The protocol is typed, `"display/1"`, and describes
itself.

### 2. Pixels in C, everything else in OCaml

OCaml runs as bytecode: a loop over pixels in OCaml is far too slow. So:

- `displayd` is in C (composition, the pointer, input);
- programs draw with a few primitives in C, in the OCaml runtime (module
  `Gfx`: fill a rectangle, draw text, a line, copy pixels, on a buffer of
  32-bit pixels);
- windows, widgets and applications are in OCaml (module `Gui`, a small
  immediate-mode toolkit: a program redraws its window from its state and
  gets events).

### 3. The screen

QEMU's standard VGA card has the Bochs extension (BGA): a linear frame
buffer, set by I/O ports `0x1CE`/`0x1CF`; its address is the card's first
PCI memory region (vendor 0x1234, device 0x1111). 1024 x 768, 32 bits a
pixel. `displayd`, a driver (`io` privilege), sets it and maps the frame
buffer with a new native call, `mapPhysical` (28, `io` only): physical
pages that are not RAM, mapped into the caller. Leaving the graphical mode
turns the extension off, and the VGA text console is back as it was.

### 4. Input

- **Pointer:** the PS/2 mouse (IRQ 12), read by `displayd`; when QEMU's
  `vmmouse` is there (I/O port 0x5658), absolute coordinates, so the
  pointer moves in and out of QEMU's window without being captured.
- **Keyboard:** `consoled` keeps it, with its layouts. While the graphical
  mode is on, `displayd` reads the console in raw mode, as any program
  can, and gives the keys (UTF-8, and VT100 sequences for the others) to
  the window that has the focus.

### 5. Text programs in windows

A terminal window must be the console of the programs it runs. Today
their output goes to the kernel's text screen. Each terminal window will
be a console service of its own (the console protocol, plus writing), and
`libmynos` will send a program's standard input and output there when its
environment names one (`MYNOS_CONSOLE`), as it does for files with
`MYNOS_STDOUT`. The terminal draws a VT100 screen (as the kernel's
terminal, in OCaml).

### 6. Starting it

The text console stays the system's console. `displayd` starts at boot
(a `driver` line in `init.rc`) and waits; the `gui` command starts the
graphical session and its first windows, and returns to the text console
when the session ends (the menu's "Exit", or Ctrl+Alt+Backspace).

### 7. Characters

A bitmap font with a Unicode table: Terminus 8x16 (`Uni2-Terminus16`, in
PSF form, from Debian's console-setup; SIL Open Font License), in
`third_party/fonts/`: Latin, Greek, Cyrillic, box drawing. Characters
without a glyph show as a box. Larger fonts or TrueType can come later.

### 8. Tests

The drawing primitives are tested in MyNOS (pixels read back). The
graphical session is tested from screen dumps of QEMU's monitor: given
pixels have given colours, and the windows' titles are where they should
be.

## Phases

1. `mapPhysical`; `displayd`: the mode, the desktop, the pointer, windows
   and their composition; `display/1`; `Gfx` and `Gui`; the `gui` command;
   first windows (a welcome window, a clock).
2. The service explorer (forms from descriptions).
3. Terminal windows (consoles per window).
4. The agent window (with streamed answers) and the trace viewer.

## As built (phases 1 and 2)

- **The text console is kept.** In QEMU's VGA, the Bochs frame buffer
  and VGA's text-mode memory (the screen and the font, in plane 2) are
  the same video memory. The picture starts 256 KB in (BGA's Y offset),
  and the card is enabled without clearing its memory; VGA's registers
  are saved before and put back after (turning BGA off leaves them in
  graphics mode, where a BIOS would set the text mode again). The text
  console comes back as it was, font included.
- **Composition** is in a back buffer, one rectangle at a time (the
  damage, the pointer's old and new places), then copied to the frame
  buffer. Moves of the pointer over the focused window are sent to it,
  only the last one queued.
- **The mouse in tests.** QEMU's monitor moves the mouse relatively, which
  vmmouse (absolute) ignores: the tests turn vmport off and use the PS/2
  mouse. PS/2 acknowledgements (0xFA) look like a packet's first byte and
  are skipped.
- **Programs:** `gui` (the session; `gui check` compares displayd's
  description with `display.ml`'s), `welcome`, `clock`, `services` (the
  explorer: `display`, `net`, `llm`, `ata0`, asked by name).

## As built (phase 3)

- `libmynos`: when `MYNOS_CONSOLE` names a service, a program's reads,
  terminal modes and window size go to it, and so does the output of
  fds 1 and 2 (`CONSOLE_WRITE`, a new request of the console protocol,
  with the bytes after it). OCaml programs (and C programs using `write`)
  follow; musl's stdio writes with direct system calls and still goes to
  the kernel's screen (kilo).
- `terminal` (OCaml): registers `term<pid>`, starts `sh` with
  `MYNOS_CONSOLE` naming it. The service domain never waits for input (a
  read with nothing to give stays pending, served when keys come or its
  VTIME passes); the window domain gets the keys, edits lines in line
  mode, passes them on in raw mode. A VT100 emulator (cursor, erasing,
  insert and delete, scrolling, SGR colours, the alternate screen, UTF-8)
  draws an 80 x 25 grid in runs of cells of the same attributes, only the
  rows that changed. `edit` (Notty) runs in it.

## Not now

- Several screens, other resolutions chosen by the user, other cards
  (virtio-gpu, real hardware).
- Transparency, animations, window decorations drawn by programs.
- Copy and paste between windows (the host's: `SERIAL=1`, see
  `doc/decisions/console.md`).

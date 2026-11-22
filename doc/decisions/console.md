# Decision: the console's scrollback, accented letters, and the host's terminal

- **Issues:** mynos-59g (this note), with mynos-vdj done alongside
- **Date:** 2026-11-17
- **Status:** accepted (2026-11-17), implemented the same day.

## What was asked

1. A buffer of the lines scrolled off the top of the screen, to look back.
2. Accented letters (Unicode).
3. Copy and paste between MyNOS and the host.

## The console today

The screen is VGA text mode, 80 x 25 cells of one byte and one colour,
drawn by the kernel's terminal (`mynos-core/kernel/video.c`, VT100-like)
from what programs write. `consoled` owns the keyboard (US layout, bytes
0x20-0x7E only) and edits lines. Every byte written to the screen also goes
to the second serial port (COM2), which the tests log.

## Choices

### 1. Scrollback, in the kernel's terminal

The kernel keeps the last 500 lines scrolled off the top of the main
screen (not the alternate screen of full-screen programs): 80 KB. Shift +
Page Up and Shift + Page Down, taken by `consoled` in every mode as the
Linux console does, page through them; the kernel saves the live screen
while one looks back, and any output, or any other key, brings it back.
`consoled` asks with private escape sequences (`CSI ? 1 v` back, `CSI ? 2
v` forward, `CSI ? 0 v` live), which the terminal takes and nothing else
uses.

### 2. Unicode: UTF-8 in, code page 437 on screen

Programs write **UTF-8**, as everywhere else (OCaml strings, the network,
the models' answers). The kernel's terminal decodes it and shows each
character with the glyph of VGA's built-in font (code page 437) that
draws it: à è é ì ò ù ç ä ö ü ñ, É, « », °, £, box drawing, Greek
letters used in maths. The capitals À È Ì Ò Ù and € are not in it: the
kernel redraws six glyphs of the font that MyNOS has no use for (₧ ƒ ⌐ ⌠
⌡ ∙) with them, at boot. Other characters show as `?`. What goes to the
serial port is the UTF-8 itself.

Typing: `consoled` gets **keyboard layouts**, `us` (the default) and
`it` (Italian, with AltGr: è é à ò ù ì ç ° § £ €, and `[ ] { } @ # ~ \``
on AltGr as on Linux). `keymap it` in `sh` switches, and is remembered in
`/disk/.keymap`. Typed characters reach programs as UTF-8. Line editing
(`consoled`'s, and `sh`'s own) moves and erases whole characters, not
bytes.

### 3. Copy and paste: the host's terminal as MyNOS's console

QEMU's window cannot paste into the guest (that needs an agent such as
spice-vdagent, and a clipboard protocol). But a terminal emulator on the
host does all three things asked here (copy, paste, scrollback) and
renders UTF-8. So the console works on the serial port too: `consoled`
reads COM2 (IRQ 3) as a second keyboard. Its bytes are what a terminal
sends: UTF-8 characters, Enter as `\r`, Backspace as DEL, arrows as
`ESC [ A`... decoded for line editing, passed as they are in raw mode.
The kernel already writes everything to COM2, escape sequences included,
so a VT100 terminal shows it as the screen does.

`SERIAL=1 tools/run-demo.sh` connects COM2 to the terminal it runs in
(QEMU's window stays, showing the same). Programs still think the screen
is 80 x 25: full-screen ones (`edit`, `kilo`) want a terminal of that
size.

### 4. Ctrl-C (2026-11-18)

MyNOS has no signals; Ctrl-C ends a program by `kill`, as Unix's terminal
driver sends SIGINT to the foreground program:

- `sh` tells its console which program it waits for
  (`CONSOLE_FOREGROUND`, `Mynos.console_foreground`), and that it waits
  for none when the program ends. The console accepts only a child of
  the caller.
- On Ctrl-C, if interrupts are on, the console (consoled, or a Terminal
  window) kills that program, shows `^C` and drops what was typed for
  it. `sh` sees signal 9 (`$?` is 137) and undoes what the program may
  have left on the screen (colours, a hidden cursor, the alternate
  screen).
- A program that wants Ctrl-C as a key turns interrupts off, as with
  termios: `ISIG` cleared (`CONSOLE_NOSIG`). Editors do; displayd does,
  since it takes every key for the windows (without it, the first Ctrl-C
  in a Terminal window ended `gui`, the program the text console's sh
  waited for).
- At sh's own prompt, Ctrl-C clears the line.
- Key releases (2026-11-21, mynos-ap3): in raw mode with
  `CONSOLE_RELEASES`, consoled follows each key with its release, as
  kitty's keyboard protocol reports one (`ESC [ code ; 1:3 u`, or the
  key's own final for the arrows and the editing keys). consoled keeps
  what each scan code's press sent, so the release names the same text;
  a terminal on the serial port sends no releases, so its keys are
  released at once. displayd asks for them and turns them into `key_up`
  events: games know which keys are held, several at once.
- Shift with the arrows, Home and End (2026-11-22, selecting in text
  boxes): xterm's sequences, `ESC [ 1 ; 2 A`..., and their releases with
  the modifier, `ESC [ 1 ; 2:3 A`.

## Not now

- A graphical console (bitmap fonts, any Unicode character): with the GUI
  (mynos-9lr).
- Copy and paste in QEMU's window, and a mouse on the console.
- Characters wider than one cell (CJK, emoji): one cell, `?`.

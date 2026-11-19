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
when the session ends (the menu's "Exit"; there is no key for it: every
key goes to the focused window).

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
4. The agent window (with streamed answers) and the trace viewer. The
   agent window and the recordings window are built (below); streaming
   is not.

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

## Scrolling (2026-11-18)

Windows must scroll: a terminal above all. Two things go by that name.

- **A terminal's scrollback** is no toolkit's business: the VT100
  emulator keeps the lines that leave the top of its main screen (1000;
  not those of the alternate screen of full-screen programs) and shows
  them on demand. `terminal` has a scrollbar beside its grid; the wheel
  and the bar move the view, a key brings it back to the bottom, and
  output while one looks back keeps the same lines in view.
- **Content taller than its box** (a list of requests, a long reply, a
  conversation) is the toolkit's: `Gui.scroll`, a box whose content is
  drawn shifted and clipped, its height measured as it is drawn and used
  at the next frame (immediate mode knows a content's size only after
  drawing it), with a bar and the wheel.

Both need **clipping** (`Gfx.with_clip`: every primitive draws inside a
rectangle, nested clips intersected) and **the wheel** (`displayd`:
vmmouse's z, and the PS/2 mouse switched to IntelliMouse mode, packets of
four bytes; a `wheel` event, positive downwards, for the window under the
pointer; QEMU's monitor turns a negative `dz` into "down").

**Our toolkit, or microui?** microui (about 1100 lines of C, immediate
mode) has scrollable containers, layout rows and text boxes. But it would
put the widgets' logic in C, against choice 2 above; OCaml would be a
client of bindings (about forty functions, callbacks from C for text
sizes, mutable C state); it manages windows of its own, which displayd
already does; and clipping and the wheel were needed with it too.
Nuklear is the same, larger. So `Gui` stays OCaml, and borrows microui's
design: containers that clip and remember their content's size.

## The agent window (phase 4, 2026-11-18)

`agent_window` (`gui/agent_window.ml`; the menu's Agent, the welcome
window's button) is the agent's conversation in a window, on the same
loop as the `agent` command (the module `Agent`, `doc/decisions/llm.md`
section 9):

- the task is typed at the bottom (Enter or Send); above, in a scroll
  box that follows the end, the task, the model's words, each action
  and the first lines of its result, the stops and the recording's file.
  The header shows the model (the first profile) and the tokens so far;
- the agent runs in a domain of its own, as a model call takes seconds.
  It adds entries to the log under a mutex; the window draws four times a
  second, and at every event;
- a confirmation is a box in the conversation (the action, as the
  command would print it) and, **where the task's field was**, three
  buttons: Allow, Deny, Allow all (for the rest of the window's life).
  The agent's domain waits on a condition for the answer. Replacing the
  field means no task can be typed meanwhile, the buttons are always in
  the same place (the test clicks Allow there), and a click meant for the
  field cannot allow anything;
- a follow-up continues the conversation (the session keeps the
  messages of the tasks the model finished).

Not yet: answers streamed as they come (llmd answers whole messages),
stopping a task midway.

## The recordings window (phase 4, 2026-11-18)

`recordings [FILE]` (`gui/recordings.ml`; the menu's Recordings, the
agent window's Recording button) shows a recording of the event recorder
(`doc/decisions/tracer.md`), from `Tracer.calls`:

- **Timeline**: a lane per process; each call is a light box on its
  client's lane (waiting) and a dark one, coloured by program, on its
  server's (serving); the selected call is outlined, with a line from
  client to server. The marks are a band of labels above and lines
  across; clicking a label shows that step, to the next mark (an agent's
  task is mostly waiting: for the model, for the user's Allow). The wheel
  zooms where the pointer is, a drag moves along, Whole shows it all.
- **Calls**: the list of `trace calls`, nested, the marks between;
  choosing one centres the timeline on it.
- **The detail**, under either: client and server, the request and the
  reply in words, when, how long, how long it waited for the server and
  how long the server worked (and on which thread), the first bytes of
  both messages in hex.
- The field opens a file (Open), or runs a command under `trace -o`, in
  a domain, and opens its recording (Record). The display's own traffic
  (every window's frames) is hidden by default: "GUI: shown" brings it
  back.

## The System window (2026-11-18, the owner's idea)

`system [FILE]` (`gui/system.ml`; the menu's System) draws MyNOS's
architecture as it is now, not as a document says it is:

- from the bottom: **the hardware** (CPU, memory, timer, keyboard,
  mouse, serial ports, disk, network card, video); **the microkernel**,
  with its parts (processes, IPC, memory, timer and scheduler, the
  recorder) and a lane through which messages pass; **the drivers**
  (processes with the io privilege, wired to their devices, beside the
  kernel: they reach the hardware themselves); **the services**
  (processes that registered a name, the boot modules, what init
  started); **the programs** (the rest);
- the boxes are the live processes (`Mynos.processes`,
  `Mynos.registered`), polled every second: a new one appears outlined
  in orange for six seconds, one that ends fades, then goes. When an
  agent starts a service (sh's `&`), its box appears, and moves to the
  services when it registers its name;
- a **recording** (the field: a file to Open, or a command to Record) is
  replayed on it, step by step (Prev, Next, Play, Next mark, or a click
  on the progress bar, where the marks are): a call is a red arrow from
  its client down into the kernel's lane, along it, and up into its
  server, with its reply in green; IPC lights up; an interrupt is a
  purple arrow from its device to its driver; a mark outlines the
  process that made it, with its label. The processes of the recording
  that have ended are grey ghosts. The display's traffic (and the
  mouse's interrupts) are left out;
- the panel at the bottom explains the step, or what was clicked: a box
  (its layer, who started it, its threads, its registered names and
  ports, its children, its calls in the recording), the kernel, a
  device.

Each live box says what its program is written in: **OCaml** (bytecode,
run by `ocamlrun`) or **C** (native code): the kernel remembers, when it
starts a process, whether its program was `ocamlrun`
(`MYNOS_PROC_BYTECODE` in the list of processes, `Mynos.process.bytecode`).
The interpreter itself is never a box: the kernel names a process after
the bytecode it runs (`ocamlrun /sh.byte` is `sh`); init, which the
kernel starts as a bare `ocamlrun`, is shown as `init`.

A process of a recording is drawn as the live box only if the pid **and**
the program are the same: a recording of an earlier boot has the same
pids for other processes (pids start again at each boot), and its
processes are ghosts then, in the layer the recording shows (a known
driver; a service, if it served calls; else a program).

The layers are read from what the kernel and the registry say, with two
rules of thumb: a driver is a process with the io privilege that a
process started (the boot modules have it too, being started by the
kernel: they are services); init's children other than sh are services
even when they register no name (httpd). The terminal registers a
console for its sh, and is drawn as the service it is.

Not live: arrows for the traffic as it happens. The window would record
itself drawing (each frame a message to displayd), so a live view needs
a filter in the recorder first.

## The top bar's tabs; closing (2026-11-18)

- Every window has a tab in the top bar, between the MyNOS menu and the
  clock, in the order the windows were made (a tab does not move when its
  window is raised); the focused one is lit. A click on a tab brings its
  window to the front and focuses it: a window under the others is found
  without moving them.
- The close box acts on release, not on press: pressed, it darkens; it
  closes only if the button is released on it. A slip is not a close.

## Choosing files; Files (2026-11-18)

- **`Gui.file_picker`**: a panel over the window, opened by
  `Gui.open_file_picker id ~filter ~dir`, drawn last in the frame,
  answering `Picked path` or `Cancelled`. Places (`/`, `/tmp`, `/disk`),
  the path in parts (each a link), Up, the entries (directories first,
  sizes; the filter hides other files unless "All files"). A click
  enters a directory or chooses a file, a second click (or Open, or
  Enter) picks it, Escape cancels, Backspace goes up. While it is open
  the window's other widgets get no pointer and no keys (`Gui.hovered`
  and `text_field` know), so an immediate-mode panel behaves as a modal
  one. Recordings and System have a Files button for their recordings.
- **Files** (`gui/files.ml`, the menu's Files): the places on the left,
  with **the service that serves the one shown** (memrofs, tmpfs, fatfs
  and the ata driver under it: pid, OCaml or C), the entries in the
  middle, and New folder, Rename, Delete (asked first), Copy or Cut then
  Paste (between services a copy and a removal, as `mv` does), Open: a
  directory is entered, a `.byte` started, a recording shown in
  Recordings, a text or a PGM image viewed in the window. Folders are not
  copied yet.

## A window outside the session (2026-11-18)

displayd refuses to make a window when the graphical session is not on
("no graphical session: start it with gui"), and `Gui.run` says where a
graphical program runs (a Terminal window, Files, or `&` in the session)
and ends with status 2. Before, a window made from the text console was
never shown, and its program waited for events forever.

## The tour (2026-11-18)

MyNOS as a teaching system (mynos-5zp): **Tour** (`gui/tour.ml`; the
menu's Tour, the welcome window's button) lists lessons on how an
operating system works, each with MyNOS as the specimen: a file from the
RAM disk, a directory from the disk (and its cache, the second time), a
program born, the network, a language model.

- A lesson (`gui/lesson.ml`; the lessons in `/tour.txt` on the RAM disk,
  more in `/disk/tour.txt`) is a title, a command, the programs to show,
  notes, and a text. Notes are `PATTERN | words`: the words are said at
  the first step whose description contains the pattern (`fs/1 Open
  ("init.rc"`, `spawn of hello`, `IRQ 9`), once.
- "Run and watch" records the command (`trace -o`, in a domain) and opens
  the System window on the recording with `--lesson`: only the lesson's
  programs, the others faint, the lesson's text before the first step,
  its words at the steps it explains, "Next note" to go from one to the
  next, a tick on the progress bar at each.
- The System window now also shows a process born (a green arrow from
  its parent, through the kernel, to it) and one ending: lessons are
  about programs starting as much as about messages.

A note says what a step *is*: the first try said "the newborn process
reads its program" at a step where sh, not the newborn, opened the file
(to see whether it is bytecode). The test caught the wrong step; the
lessons are checked against the recordings they make.

## The logo (2026-11-18)

The 2003 website's drawing (`doc/website/img/mynos-logo.jpg`, a Minotaur:
Minos's) is the session's logo: in the welcome window's banner, light on
blue, and faint in the desktop's corner. MyNOS reads no JPEG and the
build container has no image tools, so `gui/make-logo.sh` (ImageMagick,
on the host) turns it into two grey PGM files kept in the repository,
its levels cleaned so that the paper is white. A grey image is drawn as
a *mask*: black is ink of a chosen colour, white is left as it was
(`Gfx.load_mask`, `Gfx.draw_mask` with an opacity; displayd blends the
large one into its gradient). One drawing serves on light and dark.

## Not now

- Several screens, other resolutions chosen by the user, other cards
  (virtio-gpu, real hardware).
- Transparency, animations, window decorations drawn by programs.
- Copy and paste between windows (the host's: `SERIAL=1`, see
  `doc/decisions/console.md`).

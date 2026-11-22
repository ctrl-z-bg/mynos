# Decision: MyNOS Studio, and a text editor for the graphical session

- **Issue:** mynos-y87 (epic)
- **Date:** 2026-11-22
- **Status:** accepted (2026-11-22: the whole plan; Studio as an
  installable package, `studio`; the text editor in the system, `text`,
  in the MyNOS menu).

## What it is for

An IDE with MyNOS's factor: not a smaller VS Code, but an editor that is
a citizen of the system it programs. Its parts lean on what MyNOS has
and others do not: protocols that describe themselves, an event recorder
open to every process, `ocamlc` inside the system, services that are
ordinary processes, restartable by name.

## The parts

### 0. A text area in the toolkit (mynos.cma)

`Textarea` (`mynos-lib/ocaml/textarea.ml`): a multi-line text box for
`Gui` windows. Lines, a cursor, a selection (the mouse, Shift with the
arrows), the keys of an editor (arrows, Home, End, Page Up and Down,
Backspace, Delete, Enter keeping the indentation, Tab), undo and redo,
copy, cut and paste (a clipboard within the program), search, scroll
bars, line numbers, colours from a function (OCaml's: keywords, strings,
comments, numbers), marks on ranges (errors, underlined, with a
message), and an API to read and replace ranges (Studio's protocol).
Both programs below use it; so may anyone's.

### 1. Text, the system's text editor

`text` (`gui/text.ml`, on the RAM disk, "Text" in the MyNOS menu): one
file, Open (the file picker), Save, Save as, find; a resizable window.
Files opens text files with it.

### 2. Studio, the package (`pkg install studio`)

- **The editor.** Tabs of files (Textarea), OCaml colours, a file
  panel; resizable.
- **Build and run.** Build compiles the file with the `ocamlc` inside
  MyNOS (the libraries named, as `pkg -s` does); its errors become marks
  in the text, and a list. Run starts the program with its console in a
  pane of Studio (Studio is a console service for it, as a terminal
  window is: output, and a line to type); a window program opens its
  window.
- **ide/1: Studio is a service.** It registers `studio<pid>` with a
  typed protocol that describes itself: files, read, replace, open,
  save, build, errors, goto, find. Its agent pane is MyNOS's agent
  (module `Agent`) given that service: the requests become its tools,
  with no code of their own. A replace waits for Allow or Deny, shown as
  a change in the text. sh, a script, the Services window can drive
  Studio too.
- **Completion from the running system.** After `Sound.` or
  `Display.` (or any module of a service's protocol), the suggestions
  come from the service's own description (`Ipc.describe`): its
  requests, their typed arguments and replies, their documentation. A
  service that is not running says so.
- **Run and watch.** Run under the event recorder: next to the output,
  whom the program talked to (services, requests, how many, how long),
  its slowest calls; the recording opens in the System window, which
  replays it. The agent can read it too.
- **A service of your own.** "New service" writes a protocol module, a
  server and a client to try it; "Run as service" starts it, the
  Services window shows it with a form for each request; "Restart"
  replaces it after a change, and its clients find it again by name.

## Order

0 and 1 first (the text area, proved by Text), then Studio's editor,
build and run; then ide/1 and the agent; then completion; then run and
watch; then the service template. Each part tested in the graphical
session's test, and in the manual by a few lines (chapter 10 for Text,
Studio's documentation in its package).

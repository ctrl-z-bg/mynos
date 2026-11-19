# Appendix G. The Event Recorder

In MyNOS the parts of the system talk to each other in one way only: by
messages that the kernel carries. A recorder placed in the kernel can
therefore see every interaction between them without changing any of
them. This appendix describes that recorder: what the kernel writes down
(G.2–G.5), how module `Tracer` turns raw events into requests, replies
and nested calls (G.6–G.9), the recording file and its export to Perfetto
(G.10–G.11), the `trace` command (G.12), a real recording (G.13), and the
programs that use recordings (G.14). The design is in
`doc/decisions/tracer.md` (mynos-cub).

## G.1 Why a recorder

The recorder was added in November 2026 to answer the question a newcomer
asks first, "what does the system actually do when I type this?", and
the question a developer asks second, "where did the time go?". The order
is deliberate: it is a tool for learning how MyNOS works before it is a
debugger.

A monolithic kernel answers these questions with many instruments
(system call tracers, kernel probes, a profiler), because the work is
done in many places. A microkernel needs one: a file read, a disk
access, a DNS lookup and a window's redraw are all messages, and all
messages pass through `send` and `recv` in `kernel/ipc/ipc.c`. A few
hooks there, and at the birth and death of processes, record everything.

> **THE MyNOS FACTOR — The whole system, from one vantage point.**
> `trace cat /disk/hello.txt` shows `sh` asking `fatfs` for the file, and,
> nested inside that request, `fatfs` asking the disk driver `ata` for
> four sectors, with the time each took. No service was changed, rebuilt
> or told: the kernel saw the messages go by. The same recording shows
> `memrofsd`, written in C in 2002, and `fatfs`, written in OCaml in 2026,
> side by side, because both speak through the same kernel.

## G.2 What the kernel records

An event is written at each of the points below. The kinds are numbered
as in `kernel/trace.h`:

| No. | Kind | Written by | pid | peer | Other fields |
|---|---|---|---|---|---|
| 1 | `Process` | `trace` start (G.5) | each live process | its parent | name |
| 2 | `Spawn` | `process.c` (spawn), `linux_syscalls.c` (fork) | the parent | the child | the child's name |
| 3 | `Exit` | `process.c`, when a process ends | the process | — | `arg`: its status |
| 4 | `Connect` | `ipc/port.c`, a connection accepted | the client | the server | `channel`, `arg`: the port |
| 5 | `Send` | `ipc/ipc.c`, a message sent | the sender | the receiver | `channel`, `size`, data: the first bytes |
| 6 | `Recv` | `ipc/ipc.c`, a message received | the receiver | the sender | `channel`, `size` |
| 7 | `Free` | `ipc/channel.c`, a channel end freed | the process | the other end | `channel` |
| 8 | `Irq` | `irq.c`, an interrupt dispatched | the driver | the process interrupted | `arg`: the IRQ line |
| 9 | `Mark` | `trace` operation 5 (G.9) | the process | — | data: a label |

Every event also carries a sequence number, the processor's time-stamp
counter (`rdtsc`) and the id of the running thread.

Two details matter when reading recordings. A **channel** has two ends,
with two ids that differ in their lowest bit; the recorder clears that
bit (`TRACE_CHANNEL`, `ipc/channel.h`), so both ends of a conversation
carry the same number. And a **name** is the kernel's name for the
process (`trace_setName`, `trace.c`): the base name of `argv[0]` up to the
first dot, at most 15 characters, except that for `ocamlrun X.byte` it is
`X`. An OCaml program is named after its bytecode, not after the runtime
that executes it.

Not recorded: semaphores, futexes, the Linux system calls (a `write` to
the screen, an `mmap`), the scheduler's decisions. These are candidate
event classes for later (mynos-6yr).

## G.3 The event

Events are 96 bytes, little endian (`event_t`, `trace.c`):

```
  offset
     0  seq          4  tsc (low)    8  tsc (high)   12 kind (2)  14 pid (2)
    16  tid         20  peer        24  channel      28 size
    32  arg         36  ndata (2)   38  pad (2)
    40  data ─────────────────────── 56 bytes ───────────────────────── 95
        (fields of 4 bytes, except those marked (2): 2 bytes)
```

`data` holds 56 bytes at most (`TRACE_DATA`): for a `Send`, the first 56
bytes of the message (none for a message of size 0, a pure
synchronization); for `Process` and `Spawn`, the name; for `Mark`, the
label. 56 bytes are not much, and they are enough: G.7 explains why.

## G.4 The ring buffer

The kernel keeps events in one buffer of **8,192 events**
(`TRACE_EVENTS`), 768 KB, allocated from the kernel heap the first time a
recording starts. Programs read from the front while the kernel writes at
the back.

```
            first                        first + count
              │                                │
   ┌──────────▼────────────────────────────────▼──────────┐
   │ (read)   │ e17 e18 e19 ... events waiting │  (free)  │   8192 slots
   └──────────┴────────────────────────────────┴──────────┘
              └── TRACE_READ copies from here, then moves first
```

When the buffer is full, **new events are dropped and counted**; old
ones are never overwritten. A recording therefore always keeps its
beginning, which is what one wants when tracing a command from its
start. (Linux's ftrace overwrites the oldest instead, which suits "what
happened just before the crash"; the decision notes it as a possible
option.) A reader that drains the buffer often never loses anything:
`trace` reads every 50 ms.

When no recording is on, the cost is one test of a global flag
(`trace_on`) at each hook: the `TRACE` macro in `trace.h`.

**Time.** Events are stamped with the time-stamp counter, which counts
processor cycles. Its rate is unknown to the kernel, so it also notes the
timer's tick count when the recording starts; the reader compares both at
the end (G.5, operation 3) and computes the counter's rate in kHz from
the elapsed ticks at 100 Hz. Times in recordings are milliseconds since
the first event.

## G.5 The system calls

The recorder is native call **32**, `trace(op, arg1, arg2)`; libmynos
wraps it as `mynos_trace`, with the operations as `MYNOS_TRACE_*` in
`mynos.h`.

| Op | Name | What it does |
|---|---|---|
| 0 | start | allocate the buffer if needed, empty it, note the counter and the ticks, turn recording on, and write one `Process` event per live process: who was there |
| 1 | stop | turn recording off; the events stay in the buffer |
| 2 | read | copy at most `arg2` events into the caller's buffer `arg1` (checked to be the caller's memory), remove them from the buffer; returns how many |
| 3 | info | 9 words into `arg1`: on or off, events waiting, events dropped, the counter (2 words) and the ticks at start, the counter (2) and the ticks now |
| 4 | free | stop, and give the buffer back to the kernel heap |
| 5 | mark | an event `Mark` of the caller with the label `arg1`, of length `arg2` (at most 56 bytes kept), if a recording is on |

Native call **33**, `processes(buf, max)`, is the recorder's companion:
the live processes, 32 bytes each (pid, parent, privileges, threads,
name in 16 bytes), with the privilege bit `MYNOS_PROC_BYTECODE` (`0x200`)
set for processes started as `ocamlrun`. `ps` and the System window use
it, through `Mynos.processes` in OCaml.

**One recording at a time.** A recording belongs to the process that
started it: another process's start gets `MYNOS_ERR_BUSY` (in OCaml,
`Tracer.Busy`), its stop, read or free `MYNOS_ERR_DENY`; info and mark
are anyone's. When the owner frees the buffer, or ends, the recorder is
free again. `trace` says "another program is recording" and stops; the
agent works without recording and says so; the Tour shows `trace`'s
message. (Until November 2026 a start emptied any recording in progress,
and anyone could stop it: the agent, `trace` and the Tour erased each
other's events, mynos-kwe.)

## G.6 Module `Tracer`

The OCaml side is module `Tracer` (`mynos-lib/ocaml/tracer.mli`, part of
`mynos.cma`). It is not called `Trace` because the compiler libraries that
the toplevel links already have a module of that name.

```ocaml
Tracer.start ();
ignore (Sys.readdir "/disk");
let r = Tracer.stop_and_get () in
Tracer.print_calls stdout r
```

| Function | Purpose |
|---|---|
| `start`, `stop`, `mark s` | operations 0, 1 and 5 (`mark` does nothing if no recording is on) |
| `read ()`, `info ()` | the raw events waiting, 512 at a time; operation 3, with the counter's rate (`khz`) |
| `save`, `load`, `of_raw` | the recording file (G.10); raw events into a `recording` |
| `stop_and_get ()` | stop, read the rest, free the kernel's buffer |
| `name r pid`, `program r pid` | `"fatfs(8)"`, `"fatfs"`; pid 0 is `kernel` |
| `describe`, `calls`, `to_json` | a message in words (G.7); the calls (G.8); Perfetto (G.11) |
| `print_events`, `print_calls` | the two text views (G.13) |

A `recording` holds the events, the number dropped, and a table from pid
to names: every `Process` and `Spawn` event names a pid, and the table
keeps each name with the sequence number from which it applied, so that
`name r ~seq pid` gives the name the process had at that moment.

## G.7 What a message means

The player sees only a message's first 56 bytes. That is enough because
of the way MyNOS's protocols are built.

**Typed IPC** messages (appendix E) are values in the `Wire` encoding,
and a request begins with its protocol's id and the number of its case.
`Tracer` recognises such a request by its first byte, the encoded length
of a string of 3 to 24 characters, followed by an id that contains a `/`
and only lower-case letters, digits, `/`, `_` and `-`. It then reads the
case number, and, for the protocols it knows, the request's name and
arguments:

| Protocol | Requests the player names |
|---|---|
| `block/1` | `Info`, `Read`, `Write` |
| `net/1` | `Config`, `Ping`, `Resolve`, `Connect`, `Listen`, `Accept`, `Send`, `Recv`, `Close`, `Set_timeout`, `Connect_tls`, `Udp_bind`, `Send_to`, `Recv_from` |
| `llm/1` | `Profiles`, `Chat` (its profile only) |
| `fs/1` | `Open`, `Close`, `Read`, `Write`, `Seek`, `List`, `Remove`, `Mkdir`, `Rmdir`, `Rename` |
| `registry/1` | `Register`, `Lookup`, `List` |
| `console/1` | `Read`, `Mode`, `Keymap`, `Write`, `Foreground` |

For each case the table also gives the types of the reply. A request
sent on a channel is remembered for that channel, and the next message
from the server on it is decoded as its reply: tag 0 is `Ok` followed by
the values, tag 1 is `Error` followed by a string. A protocol not in the
table is shown as `greeter/1 #0`: its id and the case number.

Strings are shown whole and quoted if they are printable and fit in
32 bytes; a longer printable string as its first 20 characters and its
size, `"# MyNOS init configu"… (577 bytes)`; anything else by its size,
`(2048 bytes)`. The decoder is lenient: where the 56 bytes run out, an
argument is shown as `…`.

**The C protocols** from before typed IPC have no ids, but have fixed
sizes and known servers. Older recordings, made before `fs/1`,
`registry/1` and `console/1` replaced them, are decoded by size and by
the receiver's name: 84-byte requests to `memrofsd`, `tmpfs` or `fatfs`
as `fs OPEN "…"`, `fs READ fd n`…, their 8-byte replies as `OK n` or a
status name; 40-byte requests to `registry` and its 4-byte answers
(`port N`); 24-byte requests to `consoled`. A message of size 0 is
`(sync)`; anything else is shown as bytes.

## G.8 Calls, rebuilt from channels

The view a reader wants is not a list of messages but of **calls**: who
asked whom for what, what came back, and how long it took. The kernel
knows nothing of calls. The player rebuilds them from the channels, the
way distributed tracing (OpenTelemetry's spans) rebuilds them from
request ids. In MyNOS a client makes a new connection for each call, so
a channel's life is one call:

```
  client (sh)                 kernel                   server (fatfs)
      │ Connect ───────────────► channel c ◄───────────────── │
      │ Send "fs/1 Read" ─────── c ───────────► Recv          │  server_start
      │                                         ...           │
      │                     Recv ◄──────── c ─── Send "Ok …"  │  server_finish
      │  finish                                               │
      │ Free c                                         Free c │
  start = the client's first Send; finish = its Recv of the reply
```

In `Tracer.calls`:

- `Connect` records the channel's two ends: the client and the server.
  For a channel opened before the recording started, the first process
  to send on it is taken as the client.
- The client's first `Send` on a channel opens a call (further sends
  before the reply are more of the same request). The server's first
  `Send` back is the reply.
- The server's `Recv` of the request is when it started serving; the
  client's `Recv` of the reply ends the call. If it is not in the
  recording, the call's duration is unknown, shown as `?`.
- **Nesting**: a call is placed inside another if its client is that
  call's server, and it started while the server was serving it. A
  `block/1 Read` made by `fatfs` while it serves `sh`'s `fs/1 Read` is
  one level deeper.

Each call keeps both threads, the server's times as well as the
client's, and the first bytes and sizes of the request and of the reply:
the Recordings window shows them in hexadecimal.

## G.9 Marks

A program can label a moment of a recording: `Tracer.mark "model call 2"`
writes a `Mark` event with its pid and the label (operation 5; nothing
happens if no recording is on). `print_calls` prints marks between the
calls, at their time:

```
       ms      took  call
    1.234            # agent(23): model call 1
```

(The layout is `print_calls`'s; the time and the pid are made up.)
Marks turn a recording of a program's whole run into chapters. The agent
(G.14) marks each model call and each tool it runs, so its recording
shows what each of its decisions made the system do.

## G.10 The recording file

`Tracer.save` writes, and `Tracer.load` reads, a simple binary file:

```
   0  "MYNOSTR1"                 8 bytes: the magic
   8  the counter's rate, kHz    an IEEE double (8 bytes, little endian)
  16  events dropped             32 bits
  20  events                     96 bytes each, exactly as the kernel gave them
```

The events are stored raw, so that a better player can be written later
and still read old recordings: `tests/greeter/old-boot.trc` is a
recording of 2,036 bytes (21 events) made at an earlier boot, which the
graphical test (H.7) loads into the System window. `load` refuses a file
shorter than 20 bytes or without the magic ("not a MyNOS recording").

The programs use two extensions: `.trc` (the agent, the windows, the
tour), and `.trace` (`trace`'s default file, `/tmp/last.trace`). The
Files window and the file pickers of Recordings and System accept both.

## G.11 Perfetto

`Tracer.to_json`, and `trace json FILE OUT`, write the recording in the
**Chrome trace event format**, which Perfetto (`ui.perfetto.dev`) and
`chrome://tracing` display as a timeline:

| Phase | What |
|---|---|
| `M` | a name for each process seen: one track per process |
| `i` | instants: spawns (on the parent), exits, interrupts, marks (marks span the whole view) |
| `X`, category `call` | a box on the client's track while it waits |
| `X`, category `serve` | a box on the server's track while it serves |
| `s`, `f` | a flow arrow from the request to its handling |

Times are in microseconds; a call whose end is not in the recording is
drawn to the last event. `httpd` serves `/disk`, so a JSON file written
there can be downloaded by the host's browser through the forwarded
port (H.6) and opened in Perfetto.

## G.12 The `trace` command

`trace` (`trace/trace_main.ml`, on the RAM disk as `trace.byte`) is the
recorder's command line:

| Usage | What it does |
|---|---|
| `trace COMMAND...` | run the command under `sh -c`, record everything meanwhile, save to `/tmp/last.trace`, print the calls |
| `trace -o FILE COMMAND...` | the same, saved in `FILE` |
| `trace -s SECONDS [-o FILE]` | record the whole system for that long; nothing printed but the summary |
| `trace show FILE` | the events, one per line |
| `trace calls FILE` | the calls, nested, with their durations and the marks |
| `trace json FILE OUT` | the Perfetto file (G.11) |

`trace COMMAND` starts the recording, spawns `ocamlrun /sh.byte -c
COMMAND` (the words joined by spaces) with `trace`'s environment, and
waits for it in a second OCaml domain while the first one drains the
kernel's buffer every 50 ms. When
the command ends it stops, reads the rest, and only then writes the file:
the recorder's own writes to the disk are not in the recording. The last
line names the file, the number of events and those lost. The options
must come in the order shown: `-s` first, then `-o`.

A recording made this way begins with `trace` reading `ocamlrun` from
the RAM disk in 16 KB requests in order to spawn `sh`: starting a program
is part of what the command costs, and the recording does not hide it.

## G.13 A recording

`trace -o /tmp/h.trc cat /disk/hello.txt`, the first command after a
boot (so `fatfs`'s cache is cold), then `trace calls /tmp/h.trc`. This
is the real output of the build of 2026-11-18, cut where marked:

```
117 calls
       ms      took  call
    0.686     0.251  trace(14) -> memrofsd(3)  fs/1 Open ("ocamlrun", 0)  =>  Ok 3
    1.106     0.067  trace(14) -> memrofsd(3)  fs/1 Seek (3, 0, 1)  =>  Ok 0
  ...                (2 seeks, 40 reads: the 649,072 bytes of ocamlrun, to start sh)
   13.585     0.058  trace(14) -> memrofsd(3)  fs/1 Close 3  =>  Ok
   31.751     0.211  sh(15) -> registry(2)  registry/1 Lookup "fatfs"  =>  Ok 21
   32.568     0.567  sh(15) -> fatfs(8)  fs/1 Open ("bin/ocamlrun", 0)  =>  Error "not_found"
   34.782     0.100  sh(15) -> registry(2)  registry/1 Lookup "memrofs"  =>  Ok 16
   34.957     0.081  sh(15) -> memrofsd(3)  fs/1 Open ("ocamlrun", 0)  =>  Ok 3
  ...                (sh, starting, reads its own bytecode)
   77.137     0.521  sh(15) -> fatfs(8)  fs/1 Open ("hello.txt", 0)  =>  Ok 4
   77.825     0.124  sh(15) -> fatfs(8)  fs/1 Seek (4, 0, 1)  =>  Ok 0
   78.290     0.123  sh(15) -> fatfs(8)  fs/1 Seek (4, 0, 2)  =>  Ok 23
   78.504     0.132  sh(15) -> fatfs(8)  fs/1 Seek (4, 0, 0)  =>  Ok 0
   78.844     1.586  sh(15) -> fatfs(8)  fs/1 Read (4, 16384)  =>  Ok "Hello from a FAT disk! "
   79.108     1.059    fatfs(8) -> ata(7)  block/1 Read (308, 4)  =>  Ok (2048 bytes)
   80.522     0.178  sh(15) -> fatfs(8)  fs/1 Read (4, 16384)  =>  Ok ""
   80.928     0.125  sh(15) -> fatfs(8)  fs/1 Read (4, 16384)  =>  Ok ""
   81.265     0.137  sh(15) -> fatfs(8)  fs/1 Close 4  =>  Ok
```

`cat` is a command of `sh` itself, so `sh` opens the file. The read of
1.6 ms contains, one level deeper, `fatfs` asking `ata` for 4 sectors
from sector 308; the second and third reads find the end of the file.
The same moment in `trace show`, event by event:

```
       ms  who                  with             what
   78.807  sh(15)           =>  fatfs(8)         connect, channel 1368984
   78.844  sh(15)           ->  fatfs(8)         fs/1 Read (4, 16384)
   78.864  fatfs(8)         <-  sh(15)           received 10 bytes
   79.033  fatfs(8)         =>  ata(7)           connect, channel 922
   79.108  fatfs(8)         ->  ata(7)           block/1 Read (308, 4)
   79.148  ata(7)           <-  fatfs(8)         received 12 bytes
   80.121  ata(7)           ->  fatfs(8)         Ok (2048 bytes)
   80.153  ata(7)                                free channel 922
   80.167  fatfs(8)         <-  ata(7)           received 2051 bytes
   80.202  fatfs(8)                              free channel 922
   80.390  fatfs(8)         ->  sh(15)           Ok "Hello from a FAT disk! "
   80.416  fatfs(8)                              free channel 1368984
   80.429  sh(15)           <-  fatfs(8)         received 25 bytes
   80.442  sh(15)                                free channel 1368984
```

The arrows: `=>` a connection, `->` a message sent, `<-` received, `+` a
spawn, `x` an exit, `!` an interrupt, `#` a mark. The file begins with a
`running:` line for each process alive at the start.

## G.14 Where recordings are used

**The Recordings window** (`gui/recordings.ml`; `recordings [FILE]`, the
MyNOS menu) opens a recording (by default `/tmp/agent.trc`, else
`/tmp/last.trace`) or records a command typed in its field, running
`trace -o /tmp/rec-PID-N.trc` in a domain of its own while it keeps
drawing. Two views: a **timeline**, a lane per process, each call a light
box on its client's lane (waiting) and a dark one on its server's
(serving), marks as orange lines across, the wheel to zoom and a drag to
move along; and the **calls**, the list of `print_calls` with the marks
between. Under either, the selected call: who, what, the reply, the
times, and the first 24 bytes of both messages in hexadecimal. The
display server's own traffic (calls to or from `displayd`) is hidden by
default; one button shows it.

**The System window** (`gui/system.ml`; `system [FILE]`) draws the
system as it is, in layers (hardware, kernel, drivers, services,
programs), from `Mynos.processes` and the registry's list, polled every
second. A recording is **replayed** on that picture step by step (Prev,
Next, Play at a step every 0.6 s, Next mark): a call is an arrow from its
client down into the kernel and up into its server, an interrupt an
arrow from a device to its driver; processes of the recording that no
longer exist are drawn as ghosts. Calls to and from `displayd`, its
spawns and exits, and IRQ 12 (the mouse) are left out of the steps.

**The tour** (`gui/tour.ml`, `gui/lesson.ml`) runs lessons from
`/tour.txt` (`gui/tour.txt` in the source) and `/disk/tour.txt` if
there is one. A lesson is a block of `key: value` lines, then its text;
lessons are separated by `---` lines:

```
title: A directory from the disk
command: ls /disk
show: sh, fatfs, ata, registry
note: Lookup "fatfs" | sh needs the file service of the disk: ...
note: block/1 Read | fatfs does not touch the disk: it asks the driver...
```

The tour records `command` with `trace` (into `/tmp/tour-PID-N.trc`),
then opens the System window with `--lesson`, which shows only the
processes named in `show` and attaches each `note` to the **first step
whose description contains the pattern** before the `|`. The description
is the step in words, as `Tracer` decodes it:
`sh(15) -> fatfs(8)  fs/1 Open ("hello.txt", 0)`, `IRQ 9 -> netd(9)`,
`spawn of hello(16), by sh(15)`, `exit of sh(15): exit, status 0`. A
pattern is therefore written against the decoder's own output: `fs/1
Open ("init.rc"` matches the opening of that file, `IRQ 9` the network
card's interrupts. "Next note" jumps to the next explained step.

**The agent** (`mynos-lib/ocaml/agent.ml`) records its whole run: it
starts the recorder before its first model call, marks `model call N`
before each one and `TOOL: ARGUMENT` before each tool it runs (the
argument is the tool input's first field, if it is a string, with
control characters replaced by spaces), drains the buffer after each
step, and saves the recording to
`/tmp/agent.trc` (`agent -t FILE` for another). The agent window's
Recording button opens it in the Recordings window.

**The tests** (H.7) check the recorder end to end, by reading the
output of `trace calls` and `trace json` from the disk image: nested
`fatfs -> ata` calls, a Perfetto box and arrow, the agent's marks, and,
by counting `block/1 Read` calls, that `fatfs` reads in runs and then
from its cache.

## G.15 Known limits

- **Who may record.** Any process may, and the recording holds the
  first 56 bytes of every message in the system, whatever they carry
  (file contents, the start of network data). A decision, not an
  oversight: MyNOS has one user, and the recorder is there to see
  everything (`doc/decisions/identity-and-permissions.md`, section 9).
- One recording at a time: two programs cannot record at once.
- The `pid` field of an event is 16 bits, while pids grow by 1,000 with
  every reuse of a slot (appendix A): after some 65,000 processes, pids
  no longer fit and are recorded truncated. `peer` is 32 bits.
- `ocamlrun` at boot, the process that runs `init`, is named `ocamlrun`
  (it has no bytecode argument); the System window calls pid 1 `init`
  (mynos-6yr).
- Only interactions are recorded, not semaphores, futexes or Linux system
  calls; no filters; no deterministic replay (mynos-6yr). The System
  window cannot show traffic live, because the window's own drawing is
  traffic; a recorder filter is mynos-49l.
- The decoder knows the protocols listed in G.7; others show their id
  and case number. The tour's notes are matched against its output, so a
  change in the decoder's wording can silently stop a note from showing.

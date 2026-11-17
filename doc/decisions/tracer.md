# Decision: the event recorder and the trace player

- **Issue:** mynos-cub (the owner's idea, 2026-11-17)
- **Date:** 2026-11-17
- **Status:** accepted (2026-11-17) and implemented: `mynos-core/kernel/trace.c`,
  module `Tracer` (`mynos-lib/ocaml/tracer.mli`; `Trace` is taken by the
  toplevel's compiler libraries), the `trace` program (`trace/`). Messages
  keep their first 56 bytes (events are 96 bytes). Next: mynos-6yr.

## Goal

Record every interaction between the parts of the system while something
runs (the kernel, the services, the programs), then look at it: what
called what, with which request, how long it took. For learning how
MyNOS works first, for debugging second. A microkernel suits this:
the parts interact only through the kernel, which can see all of it
without changing any service.

```
mynos:/$ trace cat /disk/hello.txt
hello
   ms  from            to             what
0.000  sh(14)        → fatfs(7)     fs OPEN "hello.txt"
0.390  fatfs(7)      → ata0(6)      block/1 Read (2061, 1)
1.104  ata0(6)       → fatfs(7)     Ok (512 bytes)                0.71 ms
1.250  fatfs(7)      → sh(14)       OK 3                          1.04 ms
...
```

## Choices

### What is recorded, where

In the kernel, at the points every interaction passes through:

| Event | When | Fields |
|---|---|---|
| `Process` | at the start of a recording, one per live process | pid, name |
| `Spawn` | `spawn`/`fork` | parent, child, child's name |
| `Exit` | a process ends | pid, status |
| `Connect` | a client's connection is accepted | client, server, port, channel |
| `Send` | a message is sent | sender, receiver, channel, size, its first 64 bytes |
| `Recv` | a message is received | receiver, sender, channel, size |
| `Free` | a channel end is freed | pid, channel |

Each event has a sequence number, the time (the processor's time-stamp
counter, calibrated against the 100 Hz timer), the pid and the thread.
Events are 96 bytes; they go to a ring buffer in the kernel (8192 events,
768 KB, allocated when a recording starts). When it is full, new events
are dropped and counted, not old ones overwritten: a recording keeps its
beginning. When nothing is recorded, the cost is one test of a flag.

Processes get a **name** (the program's base name; for `ocamlrun X.byte`,
`X`), which the kernel did not keep so far.

Not in this first version: semaphores, futexes, interrupts and the Linux
system calls (`write` to the screen...). They can be added as event
classes later.

### Meaning: the first bytes are enough

Typed IPC messages start with the protocol id and the request's case
number, in the `Wire` format: 64 bytes are enough for the player to show
`block/1 Read (2061, 1)` or `net/1 Connect ("10.0.2.2", 80)`, and a reply
as `Ok …` or `Error "…"`. The C protocols are decoded too: the file
services' requests (`mynos_fs.h`) start with their type and descriptor,
the registry's with its command and name. Other messages are shown as
bytes.

A **call** is reconstructed from the channel, as in distributed tracing
(OpenTelemetry's spans): with one connection per call, the client's
`Send` and the `Recv` of the reply on the same channel are its start and
end; calls made by the server meanwhile are nested in it.

### Control, recording, playing

- A native system call (`trace`, 32): start, stop, read the events (into
  the caller's memory, checked), status. Module `Trace` in OCaml.
- The program `trace`:
  - `trace COMMAND...` runs the command under `sh -c`, records everything
    meanwhile, saves the recording to `/tmp/last.trace` and prints it;
  - `trace -o FILE COMMAND...` saves it there;
  - `trace -s SECONDS` records the whole system for a while;
  - `trace show FILE` and `trace calls FILE` print a recording (the events;
    the calls with their durations, nested);
  - `trace json FILE OUT.json` exports it in the Chrome trace event format,
    which [Perfetto](https://ui.perfetto.dev) shows graphically: one track
    per process, calls as boxes, arrows between them. `httpd` serves
    `/disk`, so the file can be opened from the host's browser at once.
- The recorder keeps the events in memory while the command runs and
  writes the file at the end, so that its own writes to the disk are not
  in the recording.

Alternatives: recording in each service (an `Ipc` wrapper) would need no
kernel work but would miss the C services and the non-typed traffic, and
could not be trusted to be complete; overwriting the oldest events
(Linux's ftrace default) suits "what happened just before the crash",
which can be an option later.

## Later

Filters (a program and what it talks to), more event classes, a graphical
player in MyNOS when there is a GUI (mynos-9lr), deterministic replay of a
service from its recorded inputs.

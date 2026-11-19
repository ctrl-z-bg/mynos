# 22. The event recorder

The kernel can record every interaction between processes: who started
whom, every connection, every message with its first 56 bytes, every
interrupt. The `trace` command uses this from the shell; this chapter
shows how a program uses it, through module `Tracer`
(`mynos-lib/ocaml/tracer.mli`): to record (22.1–22.3), with a complete
example (22.4), to keep a recording (22.5), and to read one (22.6).
What the kernel records, and how the player rebuilds calls from
messages, is explained in appendix G; this chapter does not repeat it.

## 22.1 Recording

```ocaml
val start : unit -> unit          (* raises Tracer.Busy *)
val stop : unit -> unit
val free : unit -> unit
val mark : string -> unit
val stop_and_get : unit -> recording
```

`Tracer.start ()` empties the kernel's buffer (8,192 events), notes the
time, writes one `Process` event for each live process, and turns
recording on. From then on the kernel writes an event at every spawn,
exit, connection, message sent or received, channel freed and interrupt,
in the whole system, until `stop`. `stop_and_get ()` stops, reads the
events, frees the kernel's buffer and returns the recording, ready to
be shown:

```ocaml
Tracer.start ();
ignore (Sys.readdir "/disk");
let r = Tracer.stop_and_get () in
Tracer.print_calls stdout r
```

**One recording at a time.** A recording belongs to the process that
started it. While it is on, or stopped but not yet freed, another
process's `start` raises `Tracer.Busy`, and its `stop`, `read` or
`free` raises `Mynos.Error ("trace", code)` with `Mynos.error_name code
= "deny"`; `mark` and `info` are anyone's. The recorder is free again
when its owner calls `free` (or `stop_and_get`), or ends. A program
should be ready for `Busy`, as `trace`, the agent and the tour are:

```ocaml
match Tracer.start () with
| () -> (* recording *)
| exception Tracer.Busy -> prerr_endline "another program is recording"
```

**The buffer fills.** At 8,192 events new ones are dropped, and counted;
old ones are kept. A short action (a command, one request) fits easily:
reading a file from the disk is some 80 events. Anything longer must be
**drained** while it runs: `Tracer.read ()` takes the events waiting and
removes them from the kernel's buffer (22.5).

## 22.2 What it costs

When no recording is on, the kernel tests one flag at each hook. While
one is on, each event costs filling one 96-byte slot of the buffer (the
time-stamp counter, the fields, up to 56 bytes of data), so the times in
a recording are those of a system that is recording, a little slower
than one that is not. The recorder's own reads and the program's
writing of the file are traffic too; save after `stop`, as `trace` does,
so that they are not in the recording.

## 22.3 Marks

```ocaml
Tracer.mark "model call 2"
```

writes an event `Mark` with the caller's pid and the label (its first 56
bytes), if a recording is on, and does nothing otherwise, so a program
can mark its phases without knowing whether anyone records. Any process
may mark, not only the recording's owner: a child marks the parent's
recording. `print_calls` prints the marks between the calls, at their
time; the Recordings window draws them as lines across the timeline. The
agent marks each model call and each tool it runs (G.14).

## 22.4 A complete example: what a read costs

`tracecall FILE` reads a file under the recorder, with a mark before and
after, and prints the calls the read made:

```ocaml
(* tracecall: read a file under the event recorder, then print the
   calls it made.  tracecall FILE *)

let () =
  if Array.length Sys.argv <> 2 then (prerr_endline "usage: tracecall FILE"; exit 2);
  let file = Sys.argv.(1) in
  (match Tracer.start () with
   | () -> ()
   | exception Tracer.Busy ->
     prerr_endline "tracecall: another program is recording"; exit 1);
  Tracer.mark ("open " ^ file);
  let text =
    try In_channel.with_open_bin file In_channel.input_all
    with Sys_error e -> Tracer.free (); prerr_endline e; exit 1 in
  Tracer.mark "read";
  let r = Tracer.stop_and_get () in
  Printf.printf "%s: %d bytes, %d events recorded\n"
    file (String.length text) (Array.length r.Tracer.events);
  Tracer.print_calls stdout r
```

The file is read with the standard library: `In_channel` calls `open`
and `read`, which libmynos turns into `fs/1` requests to the service of
`/disk` (appendix E.10). If the read fails, the program frees the
recorder before it ends (ending would free it too). A run, on a freshly
booted system whose `fatfs` has an empty cache:

```
$ tracecall.byte /disk/hello.txt
/disk/hello.txt: 23 bytes, 83 events recorded
10 calls
       ms      took  call
    0.390            # tracecall(17): open /disk/hello.txt
    0.874     0.527  tracecall(17) -> registry(2)  registry/1 Lookup "fatfs"  =>  Ok 20
    1.701     1.803  tracecall(17) -> fatfs(8)  fs/1 Open ("hello.txt", 0)  =>  Ok 3
    3.744     0.251  tracecall(17) -> fatfs(8)  fs/1 Seek (3, 0, 1)  =>  Ok 0
    4.530     0.208  tracecall(17) -> fatfs(8)  fs/1 Seek (3, 0, 2)  =>  Ok 23
    4.873     0.168  tracecall(17) -> fatfs(8)  fs/1 Seek (3, 0, 0)  =>  Ok 0
    5.395     2.107  tracecall(17) -> fatfs(8)  fs/1 Read (3, 16384)  =>  Ok "Hello from a FAT disk! "
    5.793     1.351    fatfs(8) -> ata(7)  block/1 Read (308, 4)  =>  Ok (2048 bytes)
    7.629     0.186  tracecall(17) -> fatfs(8)  fs/1 Read (3, 16384)  =>  Ok ""
    8.135     0.189  tracecall(17) -> fatfs(8)  fs/1 Read (3, 16384)  =>  Ok ""
    8.634     0.188  tracecall(17) -> fatfs(8)  fs/1 Close 3  =>  Ok
    8.903            # tracecall(17): read
```

Read from the top. Between the two marks the program made ten calls.
The first asks the registry where `fatfs` is: libmynos does it once, at
the first file of `/disk`, and keeps the port. `In_channel.input_all`
then opens the file, asks its size with three seeks (where am I, where
is the end, back to the start: whence 1, 2, 0), and reads. The first
read took 2.1 ms because, indented one level under it, `fatfs` asked the
disk driver for four sectors from sector 308: the file's cluster. The
second and third reads find the end of the file. Everything else on the
machine, the kernel's work, the driver's port I/O, is inside the
`took` column of the call that caused it.

> **THE MyNOS FACTOR — A profiler that crosses processes.**
> `tracecall` changed no service and asked no one's permission, yet its
> output shows the work of three processes on its behalf, nested as it
> happened, with each one's time. In a monolithic kernel the disk
> request would be invisible inside a `read` system call; here it is a
> message, and the kernel saw it go by. Any program can wrap any action
> in `start` and `stop_and_get` and learn what it really cost.

## 22.5 Keeping a recording

`Tracer.stop_and_save "/disk/r.trc"` stops, frees the recorder, saves
the recording in the file and returns it decoded: the simplest way to
keep one. (`stop_and_get` returns a decoded `recording` only, and a
`recording` alone cannot be saved: `save` takes raw events.) To keep
the events while a long recording goes on, take them raw:

```ocaml
Tracer.stop ();
let raw = Tracer.read () in          (* the events, 96 bytes each *)
let info = Tracer.info () in         (* the clock's rate, the dropped count *)
Tracer.free ();
Tracer.save "/tmp/t.trc" ~raw info;
let r = Tracer.of_raw ~raw info in   (* or, later: Tracer.load "/tmp/t.trc" *)
...
```

`Tracer.info ()` returns `{ recording; pending; dropped_now; khz }`: on
or off, events waiting, events lost so far, and the processor's clock
rate in kHz, measured since `start`, which turns the events' time stamps
into milliseconds. `save` writes the recording file of appendix G.10
(`.trc` by convention), which `trace calls`, `trace json`, the
Recordings window and the System window all read; `load` reads one back
(`Failure "...: not a MyNOS recording"` otherwise).

**A long recording** is drained as it runs. `read` returns at most what
is waiting and empties it, so a program appends what it reads to a
buffer and saves the whole at the end. The agent reads after each step;
`trace` waits for its command in a second domain while the first reads
every 50 ms, which is the shape of this sketch:

```ocaml
let raw = Buffer.create 65536 in
Tracer.start ();
let worker = Domain.spawn (fun () -> do_the_work ()) in
let rec drain () =
  Buffer.add_string raw (Tracer.read ());
  if not (finished ()) then (Mynos.sleep 0.05; drain ()) in
drain ();
Domain.join worker;
Tracer.stop ();
Buffer.add_string raw (Tracer.read ());
let info = Tracer.info () in
Tracer.free ();
Tracer.save "/tmp/long.trc" ~raw:(Buffer.contents raw) info
```

(`do_the_work` and `finished` are the program's: an `Atomic` flag set at
the end of the work will do.)

## 22.6 Reading a recording

A `recording` is `{ events; dropped; names }`. Each `event` has a
sequence number, a `time` in ms since the first event, its `kind`
(`Process`, `Spawn`, `Exit`, `Connect`, `Send`, `Recv`, `Free`, `Irq`,
`Mark`), the `pid` and thread (`tid`) that caused it, the `peer`, the
`channel`, a `size`, an `arg`, and `data`: the first bytes of a message,
or a name, or a mark's label. Three views are ready-made:

| Function | Gives |
|---|---|
| `print_events oc r` | one line per event: `trace show` |
| `print_calls oc r` | the calls, nested, with the marks: `trace calls` |
| `to_json r` | the Chrome trace event format, for Perfetto: `trace json` |

and the pieces to build others:

| Function | Gives |
|---|---|
| `calls r` | the calls, in order of their start |
| `name r ?seq pid` | `"fatfs(8)"`: the program the pid ran at event `seq` |
| `program r ?seq pid` | `"fatfs"` |
| `describe r e` | a message in words: `"block/1 Read (308, 4)"`, `"Ok (2048 bytes)"` |

A `call` holds its `client` and `server` (pids), its `start` and
`finish` on the client's side (`finish` is `nan` if the reply is not in
the recording), `server_start` and `server_finish` on the server's, the
`request` and `reply` in words, their first bytes and sizes, both
threads, and its `depth`: 0 for a call the client made of its own
accord, 1 for one a server made while serving it, and so on. A view of
one's own, with the time each call took:

```ocaml
List.iter (fun (c : Tracer.call) ->
    Printf.printf "%s%s -> %s  %s => %s  (%s)\n" (String.make (2 * c.depth) ' ')
      (Tracer.name r c.client) (Tracer.name r c.server) c.request c.reply
      (if Float.is_nan c.finish then "?"
       else Printf.sprintf "%.3f ms" (c.finish -. c.start)))
  (Tracer.calls r)
```

which prints, for a `Net.Config` request:

```
tracetour(18) -> netd(5)  net/1 Config => Ok ("52:54:00:12:34:56", "10.0.2.15",
  "255.255.255.0", "10.0.2.2", "10."… (8 bytes))  (0.290 ms)
```

The reply is cut where the 56 bytes the kernel kept run out (G.7). The
marks are events of kind `Mark`:

```ocaml
Array.iter (fun (e : Tracer.event) ->
    if e.kind = Tracer.Mark then
      Printf.printf "%.3f ms, %s: %s\n" e.time (Tracer.name r e.pid) e.data)
  r.events
```

**Perfetto.** `Tracer.to_json r` is a string of JSON; written to a file
under `/disk`, it can be fetched from the host through `httpd` and
opened in `ui.perfetto.dev`, where each process is a track and each
call a box on its client's and its server's (G.11).

## 22.7 What a recording also contains

- **Starting a program reads it.** `Mynos.spawn` reads the program's
  file in the parent before the kernel starts it: a recording that spans
  a spawn of an OCaml program holds some forty `fs/1 Read` calls of
  the parent to `memrofs`, which is `ocamlrun` being read (649,072
  bytes on the system's RAM disk). `trace`'s recordings begin this way
  (G.12).
- **Everything else that happened.** The recording is of the whole
  system: the display server, `netd`'s timers, a terminal's output.
  Filter by pid, or by `program r pid`, to see one process's part.
- **The first 56 bytes of every message**, whatever they carry: file
  contents, the start of network data, a model's prompt. Any process may
  record; MyNOS has one user (G.15).

## 22.8 Known limits

The limits of appendix G.15 apply: one recording at a time, 8,192 events
before the buffer must be drained, no filters in the kernel, pids
recorded in 16 bits. A `recording` from `stop_and_get` or `load` cannot be
saved again (`save` takes raw events; `stop_and_save` saves as it stops).

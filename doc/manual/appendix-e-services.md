# Appendix E. Services and their protocols

Appendix A ends where the kernel hands the machine over to its first
programs. This appendix is about what those programs build: the
services. It explains the idea, the common language the services speak
(typed IPC), how `init` starts and supervises them, then each service,
with its requests as the code defines them; it ends with what is left of
2002, and the known limits.

## E.1 A service is a process

The file systems, the disk driver, the console, the network and the
display are ordinary processes. Each registers a **name** with the
registry; a client looks the name up, gets a **port**, connects to it,
sends a request and waits for the reply on the **channel** the
connection opened (appendix C). Nothing else ties a client to a service:
a service that ends and comes back, or another program that answers
under the same name with the same protocol, is the same service to its
clients. Three rules follow:

- **The kernel says who calls.** A service learns the pid at the other
  end of a channel from the kernel (`channelPeer`, call 26), never from
  the request. Descriptors, sockets, windows and names belong to the
  process that made them; a request naming someone else's is refused.
- **A service must survive any client.** A malformed message or a
  request of another protocol gets an error reply, and the service goes
  on.
- **One connection per call.** Connect, send one request, receive one
  reply, free the channel; there are no sessions. A request that has to
  wait (a key, a packet, a window event) keeps its channel open until
  the service can answer.

## E.2 The common language: typed IPC

Until November 2026 each service had its own protocol: C structs of
32-bit fields, a status code, the data in a second message. Typed IPC
(`doc/decisions/typed-ipc.md`) replaced them all. A protocol is an OCaml
module: a GADT of requests indexed by the type of their reply, the
codecs, an identifier with a version (`"fs/1"`), a summary and the list
of its requests. `Ipc.Make (P)` (`mynos-lib/ocaml/ipc.ml`) turns it into
a client (`connect`, `call`) and a server loop (`serve`), and the type
checker ties each request to its reply on both sides:

```ocaml
let c = Fs.connect "fatfs" in
let entries : (string * int) list = Fs.call c (Fs.List "docs")
```

**The wire format** (`Wire`, `mynos-lib/ocaml/wire.mli`) is written by
hand rather than taken from `Marshal`, whose reader trusts its input:

| Value | Bytes |
|---|---|
| `int` | zigzag, then LEB128: 7 bits a byte, low bits first, the high bit set on all bytes but the last. A value beyond the reader's `int` (31 bits in OCaml on i386) is an error. |
| `bool` / `unit` | one byte, 0 or 1 / nothing |
| `string` | its length as an `int`, then its bytes |
| `float` | IEEE 754 double, 8 bytes, little endian |
| `option` | a `bool`, then the value if present |
| `list`, `array` | the count as an `int`, then the elements |
| tuples, records | the components in order |
| variants | the case number as an `int`, then the case's value |

A count or a length is never accepted beyond the bytes left in the
message, so a malformed message cannot make a service allocate much.

**A request** is the protocol's identifier (a `string`), the request's
case number and its arguments. **A reply** is a `result`: case 0 and the
value, or case 1 and an error message. `Fs.Read (3, 16384)` and two
possible replies:

```
  request   08 66 73 2F 31   04       06      80 80 02
            └── "fs/1" ───┘  case 2   fd 3    max 16384
            (length 4 → zigzag 8)             (zigzag 32768: three bytes)

  reply     00   04 68 69                 Ok "hi"
  reply     02   12 6E 6F 74 5F ...       Error "not_found..."
            (case 1 → zigzag 2; length 9 → zigzag 18)
```

**Errors** travel as text that starts with a name and a colon
(`not_found: ...`, `exists: ...`). On the OCaml side an exception raised
by a handler becomes the error reply, and the client raises
`Ipc.Remote_error (service, message)`.

**Every service describes itself.** A message whose identifier is
`"describe"`, with nothing after it, is answered with the protocol's
description: identifier, summary, and for each request its case, name,
documentation, the **shapes** of its arguments and reply (their
structure, as data), and whether it is **safe** (it only reads).
`Ipc.describe "net"` returns it. The service explorer window builds a
form for any request from it; module `Tools` turns it into tools a
language model can call. The tests compare the descriptions the C
services send with the OCaml modules', so a protocol written twice
cannot drift.

**The C side** is `mynos-lib/include/mynos_wire.h`: a writer, a reader
that sets `r->error` on a malformed message instead of failing, and
`wire_reply_description`, which takes shapes in the notation used in the
tables below: `U B I F S` for the basic types, `O<x>`, `L<x>`, `(x,y)`
for tuples, `name:x` for a named argument, `V(0:a=x,1:b=y)` for variants.

**The server loop** of `Ipc.Make` takes one request at a time: it waits
at most a second for it (a client that sends nothing must not stop the
service), asks the kernel for the caller's pid and `io` privilege,
answers and frees the channel. A service that keeps requests waiting
uses `decode` and `reply` instead. **The client** looks the name up
once; if connecting fails, it looks it up again for up to three seconds
while `init` restarts the service. A request is never sent twice.

> **THE MyNOS FACTOR — A service is a value you can call.**
> In the OCaml toplevel (`ocaml`, from `sh`),
> `Block.call (Block.connect ()) (Block.Read (0, 1))` returns the disk's
> first sector as a `string`, checked by the type checker. A program
> that has never seen a protocol can ask any service for its description
> and call it from JSON. Unix offers a byte stream and an `ioctl`
> number; MyNOS offers a typed function.

## E.3 How the system starts its services

The kernel starts three boot modules (A.2): the **registry**,
**memrofs**, and **`ocamlrun`**, which runs `init.byte` from the RAM
disk. `init` (`init/init.ml`) reads `system/init.rc` and starts its
lines in order:

```
driver consoled          start tmpfs.byte         start clipboard.byte
driver ata.byte          start fatfs.byte         driver pagerd.byte
driver netd              driver displayd          driver soundd
start llmd.byte          start httpd.byte         start pkg.byte boot
respawn sh.byte
```

| Keyword | Meaning |
|---|---|
| `start PROGRAM ARGS` | start it and leave it running: a service |
| `driver PROGRAM ARGS` | the same, with the `io` privilege (port I/O, IRQs, physical memory: A.7) |
| `respawn PROGRAM ARGS` | start it, and again whenever it ends: the login shell |

A program whose name ends in `.byte` runs as `ocamlrun PROGRAM ...`.
`#` starts a comment; a line `init` cannot read is logged and skipped.

**Supervision.** `init` then waits for its children:

- a `respawn` program is started again whenever it ends, after a second
  if it lived less than a second, so that one failing at once cannot take
  the processor;
- a `start` or `driver` service that ends with exit code 0 decided to
  (httpd without a network, netd without a card, ata and fatfs without a
  disk, displayd without the Bochs VGA) and is left alone;
- one that ends otherwise (crashed, killed, a non-zero code) is started
  again after 0.3 s, unless it was already restarted five times in the
  last sixty seconds; then `init` logs that it gives up, for good.

The registry and memrofs are not `init`'s children: nobody restarts
them.

**Clients find a restarted service again.** When a service ends, the
kernel frees its ports and wakes clients waiting to connect with
`MYNOS_ERR_BROKEN` (appendix C); the new instance registers the same
name and gets a new port. `Ipc` clients look the name up again (E.2),
and so does libmynos: when a connection fails it forgets that port in
all its caches and sends the undelivered request to the port the
registry now gives (`fs_request`, `mynos-lib/src/fileio.c`). `init` is
a service too: one of its domains serves **power/1** (E.17).

## E.4 The running system

| Name | Program | Lang. | Priv. | Started by | Protocol |
|---|---|---|---|---|---|
| `registry` | `services/registry/registry.c` | C | io | boot module | registry/1 |
| `memrofs` | `services/fs/memrofs/memrofsd.c` | C | io | boot module | fs/1 |
| `power` | `init/init.ml` | OCaml | io | boot module (`ocamlrun`) | power/1 |
| `console` | `services/console/consoled.c` | C | io | `driver` | console/1 |
| `tmpfs` | `services/tmpfs/tmpfs.ml` | OCaml | — | `start` | fs/1 |
| `clipboard` | `services/clipboard/clipboard_service.ml` | OCaml | — | `start` | clipboard/1: `get`, `set` (the text copied last, for every program) |
| `ata0` | `services/ata/ata.ml` | OCaml | io | `driver` | block/1 |
| `fatfs` | `services/fatfs/fatfs.ml` | OCaml | — | `start` | fs/1 |
| `pager` | `services/pager/pagerd.ml` | OCaml | io | `driver` | pager/1: files mapped into memory, the external pager (E.16) |
| `net` | `services/net/netd.c` | C | io | `driver` | net/1 |
| `display` | `services/display/displayd.c` | C | io | `driver` | display/1 |
| `sound` | `services/sound/soundd.c` | C | io | `driver` | sound/1 |
| `llm` | `services/llm/llmd.ml` | OCaml | — | `start` | llm/1 |
| — | `httpd/httpd.ml` | OCaml | — | `start` | a client of net/1 |
| — | `sh/sh.ml` | OCaml | — | `respawn` | a client |
| `term<pid>` | `gui/terminal.ml` | OCaml | — | the GUI | console/1 |
| `mynos` | `gui/agent_window.ml` (as `ask.byte`) | OCaml | — | the GUI | mynos/1: `ask` (MyNOS's voice, 21.7) |

The first column is the name in the registry. Who talks to whom:

```
  every process ──registry/1──► registry  (well-known port 0)

  sh ──console/1──► consoled ──► keyboard (IRQ 1), COM2 (IRQ 3)
   │                   └──fs/1──► fatfs          (/disk/.history, /disk/.keymap)
   ├──fs/1──► memrofs ──► the RAM disk, mapped read-only
   ├──fs/1──► tmpfs   ──► its own memory
   └──fs/1──► fatfs ──block/1──► ata ("ata0") ──► the disk (ports 0x1F0-0x1F7)

  httpd ──net/1──► netd ──► NE2000 (port 0x300, IRQ 9) ──► the network
    └──fs/1──► fatfs   └──fs/1──► memrofs, fatfs  (/cacert.pem, /disk/ca.pem)
  llmd ──net/1──► netd                            (HTTPS to the model's API)
    └──fs/1──► fatfs                              (/disk/llm.env)

  gui programs ──display/1──► displayd ──► frame buffer, mouse (IRQ 12)
                                 ├──console/1──► consoled  (keys, raw mode)
                                 └──fs/1──► memrofs        (fonts, logo)
  sh in a window ──console/1──► its terminal ("term<pid>") ──display/1──► displayd

  init ──spawn, wait──► every service above; serves power/1
```

Services are clients of each other through the same library as any
program: netd opens `/cacert.pem` with `open`, consoled appends to
`/disk/.history` with `write`.

## E.5 registry: names

The name server (`services/registry/registry.c`, C, from 2002), a boot
module: it has the `io` privilege it needs to take the **well-known port
0** (ports below 16 are taken by number, by privileged processes only,
with `allocPortP`). Protocol **registry/1**
(`mynos-lib/ocaml/registry.mli`, `mynos-lib/include/mynos_registry.h`):

| Case | Request | Arguments | Reply | Safe |
|---|---|---|---|---|
| 0 | `register` | `name:S` | `I`: a new port, now the caller's | |
| 1 | `lookup` | `name:S` | `I`: the name's port | yes |
| 2 | `list` | `U` | `L<(name:S,port:I,owner:I)>` | yes |

Errors start with `not_found`, `exists` or `invalid`; names are at most
20 bytes (`MAXNAMELEN`, unchanged since 2002).

- *The registry makes the port.* On `register` it allocates a port,
  gives it to the caller (`changePortOwner`) and records the caller, as
  the kernel names it, as the owner.
- *A name lives as long as its owner.* Every `lookup`, `register` and
  `list` drops the entries whose owner has ended (`processInfo`), so a
  restarted service can register its name again.
- *One request at a time*, with a one-second timeout for the request.
  The 2004 version started a thread per request, whose stacks leaked.
- *It is in its own table*, as `registry`, to be described like any
  service.

Programs use it through libmynos (`mynos_registryRegister`,
`mynos_registryLookUp`, `mynos_registryList`; in OCaml `Mynos.register`,
`Mynos.lookup`, `Mynos.registered`), which waits up to two seconds for
the registry to start.

## E.6 memrofs: the RAM disk

The read-only file system of the RAM disk, at `/`
(`services/fs/memrofs/memrofsd.c`, C, from 2002), a boot module.
Protocol **fs/1** (E.7). The RAM disk is a GRUB module made on the host
by `services/fs/memrofs/tool/createDisk`: the magic `.RAMDISK`, a table
of 1,000 entries (a name of up to 63 characters, the offset of the
contents, the size), then the contents. The kernel maps it read-only
into every process at `0x40400000`, up to 64 MB (`RAMDISK_MAXPTS`,
`kernel/process.c`), and memrofs reads the table and the files there.

The namespace is flat: `list` works on the root only, and every request
that would change something (`write`, `remove`, `mkdir`, `rmdir`,
`rename`, an `open` with any flag) answers `read_only`. Descriptors run
from 3 to 999. A `read` copies the bytes into the reply: sending them
straight from the RAM disk's pages would map those frames into the
client, which could free them. At start memrofs forks a child that reads
`AUTOEXEC.BAT` through libmynos and logs it, a self-test kept from 2002.

## E.7 fs/1, and tmpfs

**fs/1** (`mynos-lib/ocaml/fs.ml`, `mynos-lib/include/mynos_fs.h`) is
spoken by memrofs, tmpfs and fatfs. Paths are inside the service,
without a leading slash; `""` is its root.

| Case | Request | Arguments | Reply | Safe |
|---|---|---|---|---|
| 0 | `open` | `(path:S,flags:I)` | `I`: a descriptor | |
| 1 | `close` | `fd:I` | `U` | yes |
| 2 | `read` | `(fd:I,max:I)` | `S`: up to 16,384 bytes; `""` at the end | yes |
| 3 | `write` | `(fd:I,data:S)` | `I`: bytes written | |
| 4 | `seek` | `(fd:I,offset:I,whence:I)` | `I`: the new position | yes |
| 5 | `list` | `path:S` | `L<(name:S,size:I)>`, size −1: a directory | yes |
| 6 | `remove` | `path:S` | `U` | |
| 7 | `mkdir` | `path:S` | `U` | |
| 8 | `rmdir` | `path:S` (empty) | `U` | |
| 9 | `rename` | `(from:S,to:S)`; a file of the new name is replaced | `U` | |
| 10 | `space` | `U` | `(size_kb:I,free_kb:I)`: what `df` shows | yes |

Open flags: 1 write, 2 create, 4 truncate, 8 append (0: read). `whence`:
0 from the start, 1 from the position, 2 from the end. A descriptor of
another process gets `denied`. The error names, and the `errno`
libmynos makes of them (`status_errno`, `mynos-lib/src/fileio.c`):

| Name | errno | | Name | errno |
|---|---|---|---|---|
| `not_found` | `ENOENT` | | `no_space` | `ENOSPC` |
| `too_many` | `EMFILE` | | `is_dir` | `EISDIR` |
| `denied` | `EACCES` | | `not_empty` | `ENOTEMPTY` |
| `not_open` | `EBADF` | | `exists` | `EEXIST` |
| `invalid` | `EINVAL` | | `not_dir` | `ENOTDIR` |
| `read_only` | `EROFS` | | anything else | `EINVAL` |

**tmpfs** (`services/tmpfs/tmpfs.ml`, OCaml, no privilege) serves `/tmp`:
one flat directory of files in memory, lost when the machine stops. The
first service written in OCaml, 125 lines: a hash table of
files, each a growing `Bytes` buffer, a table of descriptors (3 to 1,000,
reused in turn), and one polymorphic handler given to `Fs.serve`. A
removed file stays readable through the descriptors still open on it;
`mkdir` and `rmdir` answer `invalid`.

## E.8 ata: the disk driver

The driver of the first ATA disk (`services/ata/ata.ml`, OCaml, a
`driver`), registered as `ata0`. Protocol **block/1**
(`mynos-lib/ocaml/block.ml`; no C program speaks it):

| Case | Request | Arguments | Reply | Safe |
|---|---|---|---|---|
| 0 | `info` | `U` | `I`: the number of 512-byte sectors | yes |
| 1 | `read` | `(lba:I,count:I)`, 1 to 32 sectors | `S`: their bytes | yes |
| 2 | `write` | `(lba:I,bytes:S)`, whole sectors, up to 32 | `U` | |
| 3 | `flush` | `U`: the drive's cache to the disk | `U` | |

The disk is the master of the primary channel (ports `0x1F0`–`0x1F7`,
`0x3F6`), addressed with 28-bit LBA, in PIO mode. The driver turns the
controller's interrupts off and polls the status register: in PIO it
copies every word itself anyway. The size comes from `IDENTIFY` (words
60–61); writes go 16 sectors to a data block (`WRITE MULTIPLE`) when the
disk can. The drive's cache is flushed (`0xE7`) half a second after the
last write, by a domain of the driver, and when `flush` asks: `init`
does before the power goes. Requests
outside the disk or of a wrong size are refused before any port is
touched; a controller error becomes `I/O error: ...` and a line in the
log. Without a disk, `ata` logs it and ends with code 0. Module `Block`
also offers `read` and `write` of any length, split into requests of 32
sectors.

## E.9 fatfs: the disk's file system

The FAT file system of the disk (`services/fatfs/fatfs.ml`, OCaml, no
privilege), mounted at `/disk`. Protocol **fs/1**; it reads and writes
sectors through `ata0`, which it waits for at start (100 attempts, 0.1 s
apart). If none comes there is no disk: fatfs logs it and ends with
code 0, and there is no `/disk`.

- *FAT16 and FAT32* as `mkfs.fat` makes them, 512-byte sectors only;
  directories, 8.3 names with Windows NT's lower-case flags, VFAT long
  names; names compared without regard to case.
- *The whole FAT is in memory*; after each change its changed sectors
  are written to every copy. On FAT32 the FSInfo free-cluster hints are
  set to "unknown" at start, since fatfs does not keep them.
- *A sector cache* of 4,096 sectors (2 MB), oldest out first,
  write-through; missing sectors are read in runs of up to 64.
- *Open files are protected*: removing or renaming one answers `denied`.
  `rename` moves between directories, and rewrites a moved directory's
  `..`. Descriptors start at 3 and only grow.

> **THE MyNOS FACTOR — The disk stack is two OCaml programs.**
> A `cat /disk/notes.txt` is three processes and two protocols: libmynos
> in `cat` sends fs/1 to fatfs, which sends block/1 to ata, which talks
> to the controller's ports. Both are ordinary bytecode programs: a bug
> in either ends a process, which `init` starts again, not the system.
> Replace either with another program that speaks the same protocol, and
> nothing above it changes.

## E.10 How a program reaches files

C programs and the OCaml runtime call `open`, `read`, `lseek`, `stat`,
`opendir`... as on Linux. libmynos (`mynos-lib/src/fileio.c`) replaces
these functions at link time and turns them into fs/1 requests:

```
  open("/disk/src/a.ml", O_RDONLY)
      │  made absolute against the current directory (PWD) and cleaned
      ▼  ("." and ".." resolved, "//" removed)
  "disk/src/a.ml"
      │  the first component chooses the service:
      ▼     "tmp/..." → tmpfs, "disk/..." → fatfs, anything else → memrofs
  fatfs: Open ("src/a.ml", 0)  ──►  a descriptor of fatfs
      │
      ▼
  fd 20 in the program (libmynos's descriptors run from 20 to 83)
```

- A path inside a service is at most 63 characters (`FS_NAMEMAX`).
- `read` and `write` go by requests of at most 16,384 bytes; `read`
  loops until it has all it asked for or the file ends, as on Linux.
- An Error reply becomes −1 and the `errno` of its name (E.7); `rename`
  across two services fails with `EXDEV`.
- Listing `/` gives memrofs's files, then `tmp` and `disk` if their
  services are registered.
- fd 0 is read from the console service (consoled, or the one
  `MYNOS_CONSOLE` names); fds 1 and 2 go to the kernel's screen, or to
  the console `MYNOS_CONSOLE` names (E.11).

## E.11 consoled and the terminal windows

`consoled` (`services/console/consoled.c`, C, 2026, a `driver`),
registered as `console`, owns the keyboard and is the standard input of
programs. A terminal window (`gui/terminal.ml`, OCaml) is a console of
its own. Both serve **console/1** (`mynos-lib/ocaml/console.ml`,
`mynos-lib/include/mynos_console.h`):

| Case | Request | Arguments | Reply |
|---|---|---|---|
| 0 | `read` | `max:I` | `S`: a line (line mode) or keys (raw); `""` at the end of input or when VTIME passes |
| 1 | `mode` | `(mode:I,vmin:I,vtime:I)`; bits: 1 line editing, 2 echo, 4 Ctrl-C is a key, 8 key releases (raw mode) | `U` |
| 2 | `keymap` | `layout:I`: 0 us, 1 it, −1 unchanged | `I`: the layout in use |
| 3 | `write` | `data:S` | `U` |
| 4 | `foreground` | `pid:I`: the program the caller waits for, 0 none | `U` |
| 5 | `size` (safe) | `U` | `(cols:I,rows:I)`: 80 × 25, or a terminal window's as it is now |

libmynos translates termios: `ICANON` and `ECHO` are bits 1 and 2, the
absence of `ISIG` sets bit 4, VMIN and VTIME pass through.

- *Three threads.* The keyboard thread (IRQ 1) and, when there is a
  COM2, a serial thread (IRQ 3, so that the host's terminal is a whole
  console) translate keys and edit the line; the main thread serves
  requests, one at a time. The input threads are native threads, which
  share their creator's TLS (A.4): they call no C library function.
- *Line editing in the service*: UTF-8, Backspace, Ctrl-D for end of
  file, the last 64 lines recalled with Up and Down (kept in
  `/disk/.history`), the layout kept in `/disk/.keymap`. In raw mode the
  arrows are VT100 sequences.
- *A raw mode belongs to its caller.* When another process reads while
  the console is raw, consoled returns to line mode: the program that
  set it has ended, or did not restore it.
- *Ctrl-C without signals.* `sh` names the program it waits for with
  `foreground` (consoled accepts only a child of the caller, or 0);
  Ctrl-C kills it (`kill`, call 34) and drops what was typed for it.
- *Output does not go through consoled*: programs write to the kernel's
  screen directly, and consoled answers a `write` by writing there too.

**Terminal windows.** Each registers `term<pid>` and starts `sh` with
`MYNOS_CONSOLE=term<pid>`; libmynos then sends that shell's reads, modes
and output, and those of every program it starts, to the window. The
output goes through a VT100 emulator onto an 80 × 25 grid. Two domains:
one serves requests and never waits for input (a `read` with nothing to
give is kept, with its channel, until a key comes: `decode` and `reply`
of E.2), the other handles the display's events. `keymap` answers 0 and
changes nothing: the keys reach displayd already translated by consoled.
Closing the window kills `sh` and what it started.

## E.12 netd: the network

`netd` (`services/net/netd.c`, C, 2026, a `driver`), registered as
`net`: the lwIP 2.2.1 TCP/IP stack, an NE2000 driver (`ne2k.c`, port
`0x300`, IRQ 9) and mbedTLS 3.6, in one process, so that a frame is a
function call rather than a message. Protocol **net/1**
(`mynos-lib/ocaml/net.ml`), whose case numbers netd follows:

| Case | Request | Arguments | Reply | Safe |
|---|---|---|---|---|
| 0 | `config` | `U` | `(mac:S,address:S,(netmask:S,gateway:S,dns:S))` | yes |
| 1 | `ping` | `(address:S,timeout_ms:I)` | `I`: round trip, ms | yes |
| 2 | `resolve` | `name:S` | `S`: an IPv4 address | yes |
| 3 | `connect` | `(address:S,port:I)` | `I`: a TCP socket | |
| 4 | `listen` | `port:I` | `I`: a listening socket | |
| 5 | `accept` | `socket:I` | `(socket:I,address:S,port:I)` | |
| 6 | `send` | `(socket:I,data:S)` | `I`: bytes sent | |
| 7 | `recv` | `(socket:I,max:I)`, up to 16,384 | `S`; `""` at the end | |
| 8 | `close` | `socket:I` | `U` | |
| 9 | `set_timeout` | `(socket:I,ms:I)` | `U` | |
| 10 | `connect_tls` | `(host:S,port:I)` | `I`: a TLS socket | |
| 11 | `udp_bind` | `port:I`, 0 any | `I`: a UDP socket | |
| 12 | `send_to` | `((socket:I,address:S),(port:I,data:S))` | `I`: its size | |
| 13 | `recv_from` | `(socket:I,max:I)` | `(address:S,port:I,data:S)` | |

- *One thread runs lwIP* (its raw API, `NO_SYS`): the main loop, which
  wakes on a request, an interrupt or every 100 ms. A listener thread
  queues the requests with their channels; a third waits for the card's
  interrupt (both are pthreads).
- *Requests that wait keep their channel*: `recv`, `accept`, `connect`,
  `ping`, `resolve`, `recv_from` are answered by the lwIP callback that
  ends the wait, or fail with `timeout` after `set_timeout`; `connect`
  and `connect_tls` (its handshake included) after 20 s.
- *An address first.* DHCP; after 5 s without an answer, QEMU's user
  network (10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3). Requests wait
  in the queue until there is an address.
- *Sockets have owners*: at most 64; another process's gets `not your
  socket`. Once a second the sockets of processes that have ended are
  closed, so a restarted server can listen on its port again.
- *TLS for clients*: the server's certificate is checked against
  Mozilla's authorities (`/cacert.pem`, on the RAM disk) and the user's
  (`/disk/ca.pem`), read at the first `connect_tls`; `send` and `recv`
  then carry the clear bytes.
- Without an NE2000 card netd logs it and ends with code 0.

**httpd** (`httpd/httpd.ml`, OCaml, no privilege) registers no name: it
is a client of net/1 and of the file services. `httpd [DIR [PORT]]`
serves `/disk` on port 80 by default, HTTP/1.0, `GET` only (a path with
`..` gets `403`). Its main domain `accept`s; 8 worker domains serve the
connections, each with a 10 s `set_timeout`, so that an idle browser
connection does not hold the others. Without a network service it ends
with code 0. When `netd` ends and `init` starts it again, the listening
socket is gone: after three failed `accept`s in a row `httpd` listens
again, on the new `netd`.

## E.13 llmd: language models

`llmd` (`services/llm/llmd.ml`, OCaml, no privilege), registered as
`llm`. Protocol **llm/1** (`mynos-lib/ocaml/llm.ml`):

| Case | Request | Arguments | Reply | Safe |
|---|---|---|---|---|
| 0 | `profiles` | `U` | `L<(name:S,api:S,model:S)>`, the default first | yes |
| 1 | `chat` | profile, system prompt, `max_tokens`, messages, tools | content, stop reason, model, input and output tokens | |

A message is a role and a list of blocks: `text`, `tool_call`,
`tool_result`, or `opaque`, a provider's own block (Claude's thinking)
carried back unchanged. The stop reason is `end`, `tool_use`,
`max_tokens`, `refusal` or `other`. The configuration, `/disk/llm.env`, is a `.env` file of profiles
(`LLM_<NAME>_API`, `_MODEL`, `_KEY`, `_URL`, `_MAX_TOKENS`, `_EFFORT`,
`_FALLBACKS`, and `LLM_DEFAULT`), read again at every request, so it can
be edited while the system runs; without it, `chat` fails with `no model
configured`. A profile speaks one of two HTTP APIs: `anthropic` (the
Messages API) or `openai` (Chat Completions, also spoken by vLLM, Ollama,
llama.cpp). Requests go out through module `Http`, over net/1, with TLS
for `https://`; keys stay in llmd. An answer takes seconds, so llmd does
not use `Ipc.Make`'s loop: its main domain accepts connections, and 4
worker domains answer them with `Llm.answer`.

## E.14 displayd: the display

`displayd` (`services/display/displayd.c`, C, 2026, a `driver`),
registered as `display`. It waits in text mode until a client starts the
graphical session, then sets QEMU's VGA to 1024 × 768 × 32 through the
Bochs extension (BGA), maps its frame buffer (`mapPhysical`, call 28),
and composes the desktop, the windows and the pointer. A machine
without the Bochs extension has no graphical session: displayd logs it at
boot and ends with code 0. Protocol **display/1**
(`mynos-lib/ocaml/display.ml`):

| Case | Request | Arguments | Reply |
|---|---|---|---|
| 0 | `info` (safe) | `U` | `(width:I,height:I)` |
| 1 | `create` | `(title:S,width:I,height:I)` | `I`: a window |
| 2 | `attach` | `window:I`, then a shared message of pixels | `U` |
| 3 | `damage` | `((window:I,x:I,y:I),(width:I,height:I))` | `U` |
| 4 | `next_event` | `(window:I,timeout_ms:I)` | `V(0:key=S,1:mouse=(x:I,y:I,buttons:I),2:close=U,3:tick=U,4:focus=B,5:wheel=I,6:key_up=S,7:resize=(width:I,height:I))` |
| 5 | `destroy` | `window:I` | `U` |
| 6 | `set_title` | `(window:I,title:S)` | `U` |
| 7 | `start` | `U` | `U`: the session begins |
| 8 | `wait_session` | `U` | `U`, when the session ends |
| 9 | `stop` | `U` | `U`: windows get `close`, text mode is back |
| 10 | `move` | `(window:I,x:I,y:I)` | `U` |
| 11 | `resize` | `(window:I,width:I,height:I)`, then a shared message of pixels | `U` |
| 12 | `resizable` | `(window:I,min_width:I,min_height:I)`; 0: not | `U` |

- *Pixels are shared, not sent.* After `attach` the same connection
  carries one more message, sent with `MYNOS_IPC_SHARED`: the window's
  32-bit pixels, mapped in both processes. The program draws and sends
  `damage`; displayd copies the rectangle to the screen.
- *Events wait in a queue* per window (64 at most); `next_event` on an
  empty queue keeps its channel until an event comes, or answers `tick`
  after `timeout_ms`; with a negative `timeout_ms`, at once.
- *Input*: the PS/2 mouse (IRQ 12), with QEMU's vmmouse when present;
  keys from the console service, read in raw mode during the session.
- *The text console survives*: the picture starts 256 KB into the card's
  memory, after VGA's text-mode memory, and the VGA registers are put
  back after the session.
- At most 32 windows, each its creator's (`not your window`); a timer
  thread removes those of programs that have ended.
- *Resizing*: a window made `resizable` gets a grip; displayd draws an
  outline while it is dragged, and on release sends the program `resize`
  with the size asked (a double click on the title asks for the whole
  screen, or the size before). The program answers with the request
  `resize` and new pixels; until then the old ones show.

## E.15 soundd: sound

`soundd` (`services/sound/soundd.c`, C, 2026, a `driver`), registered as
`sound`. It drives a Sound Blaster 16 at `0x220` (QEMU's `-device sb16`,
which `run-demo.sh` adds; v86 has one), IRQ 5, 16-bit DMA on channel 5;
without the card it logs it at boot and ends with code 0. The card reads
its samples from the kernel's **DMA area**: 64 KB of RAM below 16 MB on a
64 KB boundary, as ISA DMA requires, chosen at boot where the bootloader
put nothing and mapped for a driver by call 29 (appendices A and B).
Two halves of 4 KB (46 ms) play in turn; at the card's interrupt for one,
`soundd` fills it again with the mix of what programs play. The output is
22050 Hz, 16-bit, stereo; after half a second of silence the card pauses.
Protocol **sound/1** (`mynos-lib/ocaml/sound.ml`):

| Case | Request | Arguments | Reply |
|---|---|---|---|
| 0 | `info` (safe) | `U` | `(rate:I,channels:I)` |
| 1 | `open` | `U` | `I`: a stream |
| 2 | `write` | `(stream:I,samples:S)` | `U`; waits while the stream holds more than a second |
| 3 | `close` | `stream:I` | `U`, once what it holds has played |
| 4 | `stop` | `stream:I` | `U`: it ends at once |
| 5 | `tone` | `(hz:I,ms:I)` | `U`: a square wave, mixed in |
| 6 | `volume` | `level:I` (0–100, -1 asks) | `I` |

A stream is its creator's, and goes when that process ends. The pace of
the music is the card's: a program writes a second at a time and waits.
`play` (chapter 13) plays WAV files and tones; module `Sound` converts a
WAV file's rate and format on the way.

## E.16 pagerd: files mapped by the pager

`pagerd` (`services/pager/pagerd.ml`, OCaml) is the external pager of
appendix B.14: `init` starts it as a driver, since becoming the pager
needs the `io` privilege, and it registers as `pager`, protocol
**pager/1** (`mynos-lib/ocaml/pager.ml`):

| Case | Name | Request | Reply | Safe |
|---|---|---|---|---|
| 0 | `map` | `(path:S,offset:I,length:I)` | `(page:I,length:I)` | no |
| 1 | `unmap` | `page:I` | `U` | no |
| 2 | `stats` | `U` | `(regions:I,given:I,refused:I)` | yes |

`map` opens the file, takes a range of tokens, and asks the kernel for
a read-only region of that many pages in the caller's memory (a page
number: OCaml's integers have 31 bits, an address 32). Two threads: one
serves pager/1, the other waits for faults (`Pager.wait`), reads the
page from the file, and gives it (`Pager.supply`), or refuses it if the
file cannot be read. A mapping lasts until its owner unmaps it or ends.

```
  a program touches m.{i} ──fault──► kernel ──V──► pagerd (its pages thread)
                                                       │ reads the page:
                                                       └──fs/1──► memrofs, tmpfs, fatfs
  the program goes on ◄──the page, moved── kernel ◄──supply── pagerd
```

`mapcat FILE` writes files out through it, `mapcat -c` compares each
mapping with the file read as usual, `mapcat -s` asks `stats`.

## E.17 power: init as a service

**power/1** (`mynos-lib/ocaml/power.ml`) is served by `init` itself, as
`power`: case 0 `shutdown` and case 1 `reboot`, both `U` → `U`. `init`
replies first, then acts from another domain 0.2 s later: it stops the
graphical session (display/1 `stop`), then writes ACPI's sleep state 5
to the power-management ports of QEMU, Bochs and VirtualBox, or pulses
the keyboard controller's reset line. Any process may ask: MyNOS has one
user.

> **THE MyNOS FACTOR — Turning the machine off is a request.**
> `shutdown` is not a system call but a typed message to a service that
> happens to be `init`. The service explorer or a language model's tool
> can send it the same way, and it describes itself like any other.

## E.18 2002 and 2026

The last commit of the original project (tag `legacy-2008`) had four
services, all in C, each with its own struct protocol: the
**registry**, **memrofs**, and two drivers, **keyboardd** and
**seriald**.

- **The registry** kept its C, its linked list and its 20-byte names. It
  lost its thread per request (2026-11-16), gained owners (2026-11-17)
  and a list of its names (2026-11-18), and the same day its struct
  protocol (`REGISTER`, `LOOKUP`, `DELETE` in 2002, the client's pid
  inside the request) became registry/1.
- **memrofs** kept its 2002 structures and RAM disk format. Its protocol
  was replaced twice: by a new C protocol (2026-11-16; the old one tied
  open files to the client's channel number and had an empty `LSEEK`),
  then by fs/1 (2026-11-18).
- **keyboardd** and **seriald** are still built and booted by one of the
  tests (`tools/run-tests.sh`), but the system does not start them:
  consoled took the keyboard, with keyboardd's scan code tables
  (`services/keyboard/keymap.h`), and reads the second serial port
  itself.

Everything else is from 2026: consoled, tmpfs, ata and fatfs
(2026-11-16); netd, httpd, llmd and displayd (2026-11-17); power/1 in
init (2026-11-18). Typed IPC arrived on 2026-11-17 with block/1, then
net/1; fs/1, registry/1 and console/1 replaced the last C struct
protocols on 2026-11-18. The drivers are mixed: consoled, netd and
displayd are C, living with C libraries (lwIP, mbedTLS) and interrupt
threads; ata shows that a driver can be an ordinary OCaml bytecode
program with the `io` privilege.

## E.19 Known limits

- fatfs and ata answer one request at a time: two programs reading
  `/disk` wait for each other (mynos-cui). So does consoled, whose main
  loop is held by a `read` until a line comes; it also waits without a
  timeout for the request of a client that has connected (mynos-f2d).
- C programs have no sockets; only OCaml programs reach the network
  (mynos-t9l). TLS is for clients only, without revocation checks.
- The `io` privilege is all or nothing (mynos-37p): every driver can
  touch every port.
- Services know who calls but rarely decide on it: `ata0` accepts writes
  from any process, beneath fatfs, and `power` serves anyone.
  `Ipc.caller` carries the caller's `io` flag; no service uses it yet
  (mynos-dow).
- The file services do not close the descriptors of a client that has
  ended, unlike netd's sockets and displayd's windows (mynos-f2d).
- memrofs and tmpfs are flat; paths inside a service are at most 63
  characters; `rename` works within one service.
- The registry and memrofs are boot modules: if either ends, nobody
  starts it again.
- No request is sent twice: a service that dies while handling one
  leaves its client with an error, not a retry.

# Appendix C. IPC in the Kernel

Everything in MyNOS that is not the kernel is a process, and processes
talk only through the kernel's IPC: a file read, a line typed at the
console, a TCP packet, a window's pixels. The code is in
`mynos-core/kernel/ipc/`: under 700 lines of C (license headers included)
in four files. `port.c` keeps the ports, `channel.c` the channels, `ipc.c`
sends and receives, `msg.h` describes a message in transit. The pages of
long messages are moved by `mem/externalmem.c` (appendix B.11).

## C.1 Three objects, and what is not there

```
                     port 20023
                   ┌──────────────┐
   client ── connect ──► queue of │   the client waits in the queue
                   │  connectors  │
   server ── listen ───► owner    │   the server takes one: a channel
                   └──────────────┘
                          │
                          ▼
   client  end 24591 ───── messages to the server ─────►  end 24590  server
   (odd)             ◄──── messages to the client ──────             (even)
```

- A **port** is a place to connect to. It has one owner, the process that
  listens on it, and a queue of processes waiting to connect.
- A **channel** is a connection between two processes, made when the
  owner of a port accepts a connector. It has two ends, each with its own
  id and its own queue of incoming messages.
- A **message** is a buffer sent on an end, received on the other.

What the kernel does not have is **names**. A port is a number. Finding
that "fatfs" listens on port 20023 is the job of a process, the registry
(`services/registry/registry.c`), which owns the well-known port 0 and
speaks the protocol registry/1 (appendix E). A client connects to port 0,
asks for a name, gets a port number, and connects to that. The kernel
still holds a name table from 2002 (calls 11 and 12, appendix A.8), which
nothing uses.

> **THE MyNOS FACTOR — The kernel does not know names.**
> In MyNOS the name service is an ordinary program, started at boot like
> the others, with no special rights except the well-known port it owns.
> It can be read, replaced, traced like any service; and the kernel's IPC
> stays three objects small.

## C.2 Ports

A port is a `port_t` (`port.h`): its id, its owner's pid, a semaphore on
which the owner waits for connectors, and a ring of up to 10 connection
requests (`MAXREQ`). The table holds 10,000 (`MAXPORTS`).

**Ids.** A port's id is `slot + 10000 × generation`, and a slot's
generation grows when its port is freed, so an id never names a later
port (`doc/decisions/identity-and-permissions.md`). Generations wrap so
that ids stay below 2^30, OCaml's `max_int` on i386.

**Well-known ports.** Slots 0–15 (below `MYNOS_FIRST_FREE_PORT`) are never
handed out by `allocPort`. A process with the `io` privilege takes one by
number with `allocPortP(n)`; their generation is always 0, so the
registry's port is 0 across restarts. This reservation came from a hang:
`allocPort` once searched from 0, and a program that started before the
registry took port 0; the registry, finding it busy, ended, and every
client then waited for ever (JOURNAL, "The stress test that hung").

| Call | No. | What it does |
|---|---|---|
| `allocPort()` | 20 | a new port, owned by the caller |
| `allocPortP(n)` | 21 | well-known port `n` (0–15), `io` only; `MYNOS_ERR_BUSY` if taken |
| `connectToPort(p)` | 22 | queue a request on `p`, wait until it is accepted: the caller's end of the new channel |
| `listenPort(p)` | 23 | owner only: wait for a request, accept it: the owner's end |
| `freePort(p)` | 24 | owner only; `MYNOS_ERR_BUSY` while someone listens on it |
| `changePortOwner(p, pid)` | 25 | owner only: give the port to a live process |

**Connect and listen.** `connectToPort` puts a request (the caller's pid,
its thread's private semaphore, where to write the answer) in the port's
ring, `V`s the port's semaphore, and sleeps; with 10 requests already
waiting it returns `MYNOS_ERR_BUSY` at once. `listenPort` locks the port
(one listener at a time: a second gets `MYNOS_ERR_BUSY`), `P`s the
semaphore, takes the oldest request, makes a channel between the two
processes, writes the connector's end into its thread, and wakes it.
There is no timeout on either side.

`changePortOwner` lets one process make a port for another. The registry
does exactly that: when a service registers a name, the registry
allocates a port, gives it to the service (`channelPeer` tells it who that
is), and records the name.

## C.3 Channels

A channel is a `channel_t` (`channel.h`): its id and two one-way queues,
`unichannel_t`s, each with the pid of the process that reads from it, a
lock (one receiver at a time), the semaphore of a receiver waiting on it,
and a ring of up to 10 messages (`MAXMSGS`). The table holds 4,096
(`MAXCNLS`).

**Ids.** A channel is `2 × (slot + 4096 × generation)`; the end of the
process that listened is that even number, the end of the one that
connected is the next, odd one. An operation on id `c` takes its own
queue from `c & 1`, and the kernel checks that the caller's process is the
one reading that queue. Ids are below 2^30, as for ports.

Until 2026-11-17 the id named the channel, and the kernel inferred the
end from the caller's pid. With threads and OCaml domains a process can be
both client and server of itself, and then both threads matched the same
queue: the call never returned (mynos-9e1; JOURNAL, "A channel's ends,
told apart by id"). An id that names the end fixed it.

**Freeing** (`freeChannel`, call 5) is done by each side for its own end.
The first side to free marks its queue's reader as gone (-1); from then
on the other side's `send` returns `MYNOS_ERR_BROKEN`, and its `recv`
returns the messages already queued, then `MYNOS_ERR_BROKEN`. When the
second side frees, the channel, its queues and any undelivered messages
go, and the slot's generation grows.

**`channelPeer(c)`** (call 26) returns the pid at the other end of one of
the caller's ends, or `MYNOS_ERR_BROKEN` if that side freed it. It is how
a service knows who calls: from the kernel, not from the request, so a
program cannot claim to be another. Typed IPC hands it to every handler
(appendix E).

## C.4 Messages

**send** (`send(c, buffer, size, flags)`, call 3) checks that `c` is the
caller's end, that the buffer is the caller's memory (`__mem_userArea`,
appendix B.10) and that the other side has not freed the channel. Then the
message travels one of two ways:

| Message | How it travels |
|---|---|
| at most 8 bytes (`MYNOS_SHORT_MESSAGE_SIZE`), not shared | copied into the kernel's `msg_t`, and from there into the receiver's buffer |
| longer than 8 bytes | its pages are mapped into the receiver (`__OS_mapPagesTo`), copy-on-write in both processes |
| any size, with `MYNOS_IPC_SHARED` | its pages are mapped into the receiver shared: each sees the other's writes from then on |
| `buffer` NULL | no data: a pure synchronization (`mynos_signalSync`) |

A long message is not copied: the receiver gets the same frames, at an
address of its own, read-only until one of the two writes (appendix
B.7). The 2002 design made copying the exception: a long message costs
page table edits, one per page, and a copy later only of a page that one
side writes. Since whole pages are mapped, the receiver also sees whatever
else the sender kept in the first and last of them.

> **THE MyNOS FACTOR — Long messages move as pages.**
> A 64 KB message, or the pixels of a window (3 MB at 1024 × 768) sent
> to `displayd` with `MYNOS_IPC_SHARED`, crosses from one process to the
> other by editing page tables. The pixels are then one buffer in two
> address spaces: the program draws, and the display server sees it.

If the receiver has no free linear area large enough for the pages, the
send fails with `MYNOS_ERR_FULL` (until November 2026 the pages were
mapped at page 1, over the kernel's own page table, and the machine
reset: mynos-py9). Then the message is queued on the receiver's end
(`MYNOS_ERR_FULL` if 10 are waiting). If a thread of the receiver is waiting in `recv`, the kernel
wakes it and `send` returns. If not, the sender sleeps until the message
is taken, unless it passed `MYNOS_IPC_NONBLOCK`. So a `send` returns when
the message is in the receiver's hands, or in its queue for a non-blocking
one.

**recv** (`recv(c, msg, shortbuf, flags, timeout)`, call 4) checks that
the description `msg` and the short buffer are the caller's memory, locks
its end (`MYNOS_ERR_BUSY` if another thread is receiving on it), and
takes the oldest message. If there is none and the other side has freed
the channel, it returns `MYNOS_ERR_BROKEN`; otherwise it sleeps, for at
most `timeout` milliseconds if `timeout` is not 0 (counted in 10 ms timer
ticks), and returns `MYNOS_ERR_EXPIRED` if nothing came. It wakes a
sender waiting for this message, then writes the description:

```c
typedef struct {          /* mynos-lib/include/mynos.h */
  void * start;           /* the data: in shortbuf, or in pages mapped */
  unsigned int size;      /*   into the receiver for it                */
  int isShort;
} mynos_msg_t;
```

It writes with `copy_to_user`: the call may have slept, and another
thread may have unmapped that memory meanwhile; the call then fails
instead of ending the process (appendix B.10). The `flags` argument of
`recv` is not used.

**Who frees what.** `mynos_recv` in libmynos allocates the description
and an 8-byte short buffer with `malloc`, frees the short buffer if the
message was long, and gives the description to the caller. The caller
frees the message with `mynos_freeMsg`: `free` for a short one, `munmap`
of its pages for a long one, which drops the receiver's references on
those frames.

## C.5 One exchange, step by step

A client (pid 1031) asks a service (pid 2012), already registered on port
20023, for something; the request is 120 bytes, the reply 6. libmynos
does the same for every file operation (some add a second message, the
data, on the same channel).

```
  client, pid 1031              kernel                     server, pid 2012
  ────────────────              ──────                     ────────────────
                                                           listenPort(20023)
                                port locked; P(port sem):  ··· sleeps
                                the server sleeps
  connectToPort(20023)
    ··· sleeps                  request queued; V(port sem)
                                server wakes: allocChannel
                                  slot 7, generation 3:
                                  ends 24590 and 24591
    ◄── 24591                   V(client's semaphore)  ──► returns 24590
  send(24591, req, 120, 0)
    ··· sleeps                  map req's page into 2012,
                                copy-on-write; queue it on
                                24590; no one receiving
                                                           recv(24590, &m, ...)
                                take the message;          channelPeer(24590)
    ◄── 0                       V(client's semaphore)        ──► 1031
  recv(24591, &m, ...)                                     m = {0x4801A0A8, 120, 0}
    ··· sleeps                  24591 empty: the client
                                waits on its end
                                                           send(24590, rep, 6, 0)
                                6 ≤ 8: copied into the
                                kernel; the client waits:
                                V, and send returns     ──► 0
    ◄── m = {shortbuf, 6, 1}
  mynos_freeMsg(&m)                                        mynos_freeMsg(&m)
  freeChannel(24591)            first side: 24591's                (munmap)
                                reader gone                freeChannel(24590)
                                second side: channel freed,
                                slot 7 → generation 4
```

(The address in the server's `m.start` is illustrative: it is wherever
the server's free list had room, plus the request's offset in its page.)

The registry lookup that found port 20023 was the same exchange on port
0. In this shape (connect, one request, one reply, free) a channel is a
call; but nothing in the kernel ties a channel to one call: it lasts
until both sides free it.

## C.6 When a process ends

`endProcess` (`process.c`, appendix A.9) releases the IPC objects of a
process that exits, faults or is killed. It runs as the dying process
while it does so (`currProcess` set to it), because every check in
`port.c` and `channel.c` compares the owner with the current process:
when `kill` (call 34) ended a service, the caller was the killer, the
checks said "denied", and the service's ports stayed open (JOURNAL, "A
killed service left a port that swallowed its clients").

- **Its ports** go through `__OS_port_freeDead`, which, unlike `freePort`,
  frees a port even if its owner died listening on it, and wakes every
  process queued to connect with `MYNOS_ERR_BROKEN`. A client of
  libmynos or of `Ipc.Make` then asks the registry again, and finds the
  service init has restarted on a new port.
- **Its channels** are freed end by end, as with `freeChannel`: the other
  side's `send` gets `MYNOS_ERR_BROKEN`, its `recv` the messages already
  queued and then `MYNOS_ERR_BROKEN`.

The kernel sends no message when a process ends. A service that keeps
something for its clients (netd's sockets, the registry's names) asks
`processInfo` (call 27) from time to time whether their owners are still
alive; with generational pids, "no such pid" is final.

## C.7 The calls

| No. | Call (libmynos) | Kernel function |
|---|---|---|
| 3 | `mynos_send(c, buf, size, flags)` | `__OS_ipc_send` |
| 4 | `mynos_recv(c, &msg, flags, timeout)` | `__OS_ipc_recv` |
| 5 | `mynos_freeChannel(c)` | `__OS_ipc_freeChannel` |
| 20 | `mynos_allocPort()` | `__OS_port_allocPort` |
| 21 | `mynos_allocPortP(n)` | `__OS_port_allocPortP` |
| 22 | `mynos_connectToPort(p)` | `__OS_port_connectToPort` |
| 23 | `mynos_listenPort(p)` | `__OS_port_listenPort` |
| 24 | `mynos_freePort(p)` | `__OS_port_freePort` |
| 25 | `mynos_changePortOwner(p, pid)` | `__OS_port_changeOwner` |
| 26 | `mynos_channelPeer(c)` | `_mynos_syscall_channelPeer` (`syscalls.c`) |

Errors (`mynos.h`): `MYNOS_ERR_FULL` (-1) a table or a queue is full;
`MYNOS_ERR_BUSY` (-2) taken, or someone else is listening or receiving;
`MYNOS_ERR_INVALID` (-3) no such object, or a bad pointer;
`MYNOS_ERR_DENY` (-4) not the caller's; `MYNOS_ERR_BROKEN` (-5) the other
side is gone; `MYNOS_ERR_EXPIRED` (-6) the timeout passed. While a
recording is on, every connection, message sent or received and channel
freed is also an event for the recorder (appendix G).

## C.8 Table sizes

| What | How many | Where |
|---|---|---|
| ports | 10,000 (0–15 well known) | `MAXPORTS`, `port.c`; `MYNOS_FIRST_FREE_PORT`, `mynos.h` |
| requests waiting on a port | 10 | `MAXREQ`, `port.h` |
| channels | 4,096 | `MAXCNLS`, `channel.h` |
| messages waiting on an end | 10 | `MAXMSGS`, `channel.h` |
| bytes copied rather than mapped | 8 | `MYNOS_SHORT_MESSAGE_SIZE`, `mynos.h` |

A full table is said once on the log ("kernel: the channel table is
full"), and the call returns `MYNOS_ERR_FULL`.

## C.9 Known limits

- **A thread blocked on a channel is not woken when the other side frees
  it.** Freeing an end only marks it; a `recv` without a timeout already
  waiting, or a `send` waiting for its message to be taken, keeps
  waiting. libmynos's clients receive without a timeout (mynos-3bb).
- `freePort` does not wake the processes queued to connect (only
  `__OS_port_freeDead` does), and a request queued by a process that then
  ends stays in the port's queue (mynos-blv).
- A long message's pages are mapped into the receiver when it is sent: a
  message never received (a queue full, a channel freed) leaves them in
  the receiver's address space until it ends. The receiver also sees the
  rest of the sender's first and last pages.
- `connectToPort` and `listenPort` have no timeout; `recv` has one,
  `send` has `MYNOS_IPC_NONBLOCK`.
- One processor (mynos-awn): the kernel's IPC relies on system calls
  running with interrupts off, and has no locks of its own beyond the
  per-port and per-end flags.

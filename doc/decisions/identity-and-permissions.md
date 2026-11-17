# Decision: who is calling, what it may do

- **Issues:** mynos-nn7 (permissions, safe copies from user memory),
  mynos-c9h (sockets owned by their process; UDP)
- **Date:** 2026-11-17
- **Status:** accepted (2026-11-17), with generational ids instead of a
  serial (the owner's choice); implemented the same day (steps 1-4).
  Follow-ups: mynos-37p (per-port I/O bitmap), mynos-9e1 (IPC between
  threads of one process: done, each end of a channel has its own id).

## The problem

MyNOS trusts every process with everything:

- **Hardware.** Every process runs with IOPL 3 (`process.c`,
  `INITIAL_EFLAGS`): any program, even one typed in the toplevel, can
  reprogram the interrupt controller, the disk or the network card with
  `Mynos.outb`. Any process can take a free IRQ.
- **Kernel objects.** Any process can `P`, `V` or free any semaphore,
  including a thread's private one (on which it waits for its messages) or
  a port's.
- **Services do not know their callers.** A channel connects two
  processes, but a service cannot ask which one is at the other end. So
  netd cannot tell whose socket is whose: any process can read or close
  any socket number, and the sockets of a process that ended stay open (its
  listening port too: a restarted `httpd` cannot listen on 80 again). The
  registry cannot tell who registered a name, nor notice that it ended.
- **Pids are reused** (1-999, round robin), so "process 42" is not a
  stable name for long.
- **A user pointer** is checked at the entry of a system call, but a call
  that blocks (a `recv` waiting) writes into user memory later, when
  another thread of the process may have unmapped it: the kernel faults
  halfway, and ends the process with its state half updated.

## Choices

### 1. Ids that are never reused soon: generations

A first draft gave each process a second number, a serial never reused,
next to its pid. Two numbers for one identity: the pid would have stayed
ambiguous everywhere else (`waitpid`, the recorder, logs). Instead, the
kernel's ids carry a **generation**, as semaphore ids already did
(`id % MAXSEM` is the slot):

```
pid     = slot + 1000 * generation      (processTable has 1000 slots)
channel = 2 * (slot + 4096 * generation) + end   (end 0: listener, 1: connector)
port    = slot + 10000 * generation     (well-known ports: generation 0)
```

A slot's generation grows each time its object is freed, so an id names
one object for its whole life: the next process in the same slot has
another pid, and a stale channel id no longer reaches someone else's new
channel. Looking an id up is the slot, then a comparison with the id kept
in the object (`proc(pid)` in the kernel). Generations wrap so that pids
stay below 10^9; thread ids live between 10^9 and 2^30 (the C library
keeps a mutex's owner as `tid & 0x3fffffff`, the bits above are flags).
This is the "generational index" (slot map) pattern.

Two native calls:

- `channelPeer(channel)` (26): the pid at the other end of one of the
  caller's channels. A service calls it on the channel of a request;
- `processInfo(pid)` (27): its privileges, with `MYNOS_PROC_ALIVE` while it
  runs; an error once it is gone.

No message from the kernel when a process ends: a service that keeps
something for its clients (netd's sockets, the registry's names) checks
its owners with `processInfo` from time to time (netd: every second, in
its loop; the registry: when a name is looked up or registered again). It
is simple, it cannot lose a notification, and the cost is one system call
per owner per second. A notification (a semaphore the kernel `V`s when a
process ends) can come later if a service needs to react at once.

**Table sizes.** They were set in 2002-2004 and never reached then: 1000
processes (a pointer each: the real limit is memory, tens of KB per
process), 2000 semaphores (a static array), 100 channels for the whole
system (one per call in progress, one per request waiting in netd: the
tightest). Channels go to 4096 and semaphores to 4096.

### 2. Privileges: one, for drivers

One privilege for now, **`io`**: port I/O (IOPL 3) and IRQs
(`driverRegister`, enabling and disabling one's own lines). A process
without it runs with IOPL 0: `inb`/`outb` end it with a protection fault,
as any bad instruction does; `driverRegister` returns "denied".

Who has it:

- the processes the kernel starts at boot (the modules: the registry,
  memrofs, `ocamlrun` with init, the old drivers), as today;
- the children a privileged process spawns *asking for it*: `spawn` gets a
  flags argument (the native call has a free one), and a child gets at
  most its parent's privileges;
- init gives it to the lines marked so in `init.rc`: `driver consoled`,
  `driver ata.byte`, `driver netd`; `start` and `respawn` give nothing. So
  `sh`, and everything started from it, has none.

Finer grants (the I/O bitmap of the TSS: `ata` gets ports 0x1F0-0x1F7 and
0x3F6, nothing else) are the natural next step, and fit the same flag.

### 3. Kernel objects belong to their process

- **Semaphores** made by `initSem` can be used and freed by their process
  only (all MyNOS programs use their semaphores among their own threads
  only). The kernel's own semaphores (threads' private ones, ports') are
  not reachable from user space at all. An IRQ's semaphore belongs to the
  driver that registered the line.
- **IRQ lines**: enabled and disabled by their driver only.
- **Ports**: already checked (`listenPort`, `freePort`, `changeOwner`
  require the owner); `allocPort` took the owner's pid from the caller,
  now it is the caller. Well-known ports (0-15; the registry's is 0) are
  taken by number only, by privileged processes (`allocPortP`).

### 4. Typed IPC: the handler knows its caller

`Ipc.serve`'s handler gets the caller:

```ocaml
type caller = { pid : int; io : bool }
type handler = { handle : 'a. caller -> 'a request -> 'a }
```

(explicit, rather than a hidden "current caller": `httpd` serves from
several domains). The C side gets `mynos_channelPeer(ch, &info)`. The
existing services (`ata`, the tests) take the new argument and ignore it.

### 5. netd: sockets have an owner; UDP

- A socket belongs to the process that made it (`Connect`, `Connect_tls`,
  `Listen`, and `Accept`'s new socket to the caller of `Accept`). A
  request on someone else's socket: `"not your socket"`. Once a second,
  netd checks its owners with `processInfo` and closes the sockets of those that
  ended (listening ones too).
- **UDP** in "net/1" (cases 11-13): `Udp_bind port` (0: any) → a socket;
  `Send_to (s, address, port, data)`; `Recv_from (s, max)` → `(address,
  port, data)`, waiting like `Recv` (and `Set_timeout` applies). Up to 32
  datagrams are kept per socket, then new ones are dropped.
- The registry binds a name to its owner: another process cannot register
  it while the owner lives; it is freed when the owner ends.

### 6. Safe copies from and to user memory

`copy_from_user` and `copy_to_user` in the kernel, with an **exception
table** (as Linux's): the addresses of the instructions that touch user
memory; a page fault at one of them jumps to its fix-up, which returns
`-EFAULT` (Linux calls) or `MYNOS_ERR_INVALID` (native ones) instead of
ending the process. Used first where a call can block before touching user
memory (`recv`, `read` from the console, futexes), then everywhere the
system calls copy. The checks at entry stay: they refuse kernel addresses
early.

### 7. Limits

Running out of pids, semaphores, channels or ports returns
`MYNOS_ERR_FULL` (most calls do already) and logs it once per kind, so
that "the system hangs" becomes "the semaphore table is full".

## Not now

- **Users and files.** MyNOS is single-user; file services do not check
  who reads what. Identity (1) is what they will need.
- **The recorder** stays open to every process: it shows all messages,
  but MyNOS is single-user and it is there to learn from. To revisit with
  users.
- **Capabilities** (handing a socket or a channel to another process) fit
  this model later: the owner becomes transferable.

## Order

1. Kernel: generational pids, channels and ports, larger tables;
   `channelPeer` and `processInfo`; the `io` privilege (IOPL, IRQs,
   `spawn` flags) and `driver` in `init.rc`; semaphores and IRQ lines
   owned. Tests in `tests/stress`: an unprivileged child is ended by `inb`
   and refused an IRQ and someone else's semaphore.
2. Typed IPC and `mynos_wire`: the caller; the registry's names owned.
3. netd: sockets owned and closed with their process; UDP; tests.
4. Safe copies; limits.

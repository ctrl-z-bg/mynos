# Appendix I. Glossary

Terms as this manual uses them. *Italics* point to other entries.

**block/1** — The protocol of the disk driver `ata`: sectors read and
written (appendix E).

**bytecode** — What `ocamlc` makes: the instructions of the OCaml
virtual machine, run by *ocamlrun*. Every MyNOS program in OCaml is
bytecode, and runs unchanged on any machine that has `ocamlrun`.

**channel** — A connection between two processes, made by connecting to
a *port*. It has two ends, each with its own id, and carries *messages*
both ways (appendix C).

**channelPeer** — The system call that tells a service which process is
at the other end of a *channel*: the kernel, not the client, says who is
calling.

**console/1** — The protocol of the consoles: consoled, and each
terminal window (appendix E).

**copy-on-write** — Pages shared between two processes until one of them
writes; then the writer gets its own copy (appendix B).

**describe** — A request every typed service answers: the description
of its protocol, with the name, arguments and reply of each request. The
Services window and the agent's tools are made from it.

**domain** — In OCaml 5, a unit of parallelism with its own heap and
thread; on MyNOS, a Linux *thread* (chapter 15).

**driver** — A process that owns a device: it has the *io privilege*,
registers an IRQ line, and talks to the device's ports (appendix A,
chapter 23). In `init.rc`, the keyword that starts a program with that
privilege.

**fs/1** — The protocol of the file services: memrofs, tmpfs, fatfs
(appendix E).

**generation** — The part of a pid, port or channel id that changes
each time its slot in a kernel table is reused, so that an id names one
object for its whole life.

**init** — The first program (`init/init.ml`): it reads `init.rc`,
starts the services and the login shell, and restarts them when they
end.

**io privilege** — The one privilege of MyNOS: port I/O, IRQ lines,
physical memory. A child gets at most its parent's (appendix A).

**IPC** — Inter-process communication: in MyNOS, *ports*, *channels* and
*messages*, the only way processes talk to services.

**libmynos** — The C library of MyNOS (`mynos-lib/`): the native system
calls, and the functions of the C library that MyNOS implements over IPC
(files, the console), on top of musl.

**message** — The bytes sent on a *channel* with one `send`, and received
whole with one `recv`.

**microkernel** — A kernel that keeps only what must be in the kernel
(memory, threads, IPC, interrupts) and leaves everything else to
processes.

**module** — A file GRUB loads with the kernel: a program to start, or
the RAM disk.

**ocamlrun** — The OCaml bytecode interpreter, the upstream runtime
unchanged, built for MyNOS (appendix F).

**port** — A number a service listens on; clients connect to it to open
a *channel*. Port 0 is the *registry*'s.

**protocol** — The requests a service understands and the replies it
gives. A typed protocol is defined once in OCaml, as a type, and named
with a version: `fs/1`, `net/1`.

**RAM disk** — The read-only file system loaded with the kernel
(`system/ramdisk.dsk`), served by memrofs at `/`.

**recording** — A file of the *event recorder* (`.trc`): every spawn,
exit, connection and message of a stretch of time (appendix G).

**registry** — The service that maps names to *ports*, at the well-known
port 0. Its protocol is `registry/1`.

**semaphore** — The kernel's synchronization primitive: `P` waits, `V`
signals (appendix A).

**service** — A process that answers requests over IPC, under a name in
the *registry*.

**spawn** — The system call that starts a program from its bytes; the
parent has read them, since the kernel cannot open files.

**thread** — A flow of execution inside a process. MyNOS has native
threads and Linux threads; OCaml's `Thread` module and its *domains* use
the latter.

**typed IPC** — Messages that carry OCaml values, encoded by `Wire`, with
a type for each request and its reply (chapter 17).

**Wire** — The encoding of typed IPC: integers, strings, lists, records
and variants as bytes (chapter 17, appendix E).

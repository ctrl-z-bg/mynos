# Decision: how OCaml programs reach the console and the files

- **Epic:** mynos-a2j (a small demonstrable OS with a terminal)
- **Date:** 2026-11-16
- **Status:** accepted (2026-11-16): option B

## Goal

A terminal: the user types, OCaml programs answer, and the shell is the
OCaml toplevel itself. For that, OCaml programs need:

1. the MyNOS API (IPC, ports, semaphores, sleep, registry) — mynos-a2j.1;
2. keyboard input and screen output as standard input and output;
3. files (the toplevel needs the `.cmi` files of the standard library, and
   programs need to be loaded from somewhere) — mynos-nxa;
4. a way to start a program from another program — mynos-a2j.2.

Point 1 does not depend on the others and is being done first. Points 2–4
share one question.

## The question

The OCaml runtime, the toplevel and every OCaml library do I/O through the
C library: `open`, `read`, `write`, `lseek`, `close` on file descriptors.
Today these are Linux system calls answered by the kernel, which serves one
fake file (GRUB module 1) and prints `write` on screen.

In a microkernel, consoles and filesystems are services reached by IPC.
Where do we turn `read(fd, …)` into IPC to the right service?

### Option A — in the kernel

The kernel keeps a file descriptor table per process and, inside the system
call, talks IPC to the console or filesystem service on the process's
behalf, then returns the result.

- \+ Every static Linux binary works unchanged, whatever its libc.
- − The kernel must act as an IPC client from inside a system call, copying
  data between the process and kernel buffers: new, delicate kernel code.
- − It moves policy (which service serves which path) into the kernel.

### Option B — in user space, in a small C library linked before musl

`mynos-lib` provides its own `open`, `read`, `write`, `lseek`, `close`,
`fstat`, … . Linked statically before musl, they replace musl's versions
(musl has one function per object file, so this is clean). They keep the
file descriptor table in the process and talk IPC directly: descriptors
0/1/2 to the console service, paths to the filesystem services found through
the registry. The kernel loses its fake bytecode file.

- \+ The microkernel stays small: the kernel only does IPC, as intended.
- \+ It is plain C in user space: easy to debug, can evolve fast.
- \+ It is how Plan 9 and the Hurd structure it, and what MyNOS's IPC was
  designed for.
- − Only programs linked with `libmynos` get files and the console. All
  MyNOS programs are (services, `ocamlrun`), so in practice none is
  excluded.
- − `ocamlrun` must find its bytecode through the filesystem service at
  startup, so the service must be up first (the registry retry handles
  ordering).

## Proposal

**Option B.** Then, in order:

1. **mynos-a2j.1** — OCaml bindings (in progress, independent of this).
2. **Console service** (mynos-a2j.3): owns the screen and receives keys
   from `keyboardd`; offers line input and text output over IPC. Kernel
   `printk` stays for kernel messages.
3. **File client in `mynos-lib`** (mynos-nxa): fd table, `open/read/...`
   over IPC to memrofs (read-only for now, real storage later: mynos-rf4).
   `ocamlrun` loads its bytecode by name from memrofs.
4. **Spawn** (mynos-a2j.2, done): a native call to start a process from an
   ELF image read from a file, with arguments; a shell can then run
   `ocamlrun prog.byte`. The image is read in user space (`mynos_spawn`,
   `mynos-lib/src/spawn.c`) and passed to the kernel, which only builds the
   process.
5. **The shell** (mynos-a2j.4, done): the OCaml toplevel, its `.cmi` files
   on the RAM disk, reading the console (`shell/`).

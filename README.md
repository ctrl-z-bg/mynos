# MyNOS

> The MyNOS project aims at developing a new and different operating
> system, based on high-level languages. MyNOS will be based on the
> OCaml bytecode interpreter. We'd like to explore microkernel
> architecture and new language definition too.

MyNOS is an experimental operating system for 32-bit x86, written between 2002
and 2004. It consists of a small microkernel in C and assembly, with drivers and
services running as user processes, and the OCaml bytecode interpreter ported to
run on top of it. The long-term goal was an OS whose programs are written in a
high-level language rather than in C.

## What's inside

| Directory | Contents |
|---|---|
| [`mynos-core/`](mynos-core/) | The microkernel: multiboot boot, paging, processes and threads, copy-on-write fork, scheduler, semaphores, port/channel IPC, user-space IRQ delivery, native (`int 0x90`) and Linux-compatible (`int 0x80`) syscalls |
| [`mynos-lib/`](mynos-lib/) | User-space library for the native syscalls (`include/mynos.h`) |
| [`services/`](services/) | User-space servers: name registry, keyboard and serial drivers, `memrofs` read-only RAM filesystem |
| [`mynos-runtime/`](mynos-runtime/) | The OCaml 5.5 bytecode runtime for MyNOS: the upstream runtime, unchanged, plus a MyNOS `main()` |
| [`mynos-byterun/`](mynos-byterun/) | The original OCaml 3.06 bytecode runtime (`ocamlrun`), patched to run on MyNOS (legacy toolchain) |
| [`doc/STATUS.md`](doc/STATUS.md) | Architecture overview and current state of the project |
| [`doc/JOURNAL.md`](doc/JOURNAL.md) | Engineering journal: what was found while reviving the code, bug by bug |
| [`doc/decisions/`](doc/decisions/) | Design decisions, with the evidence behind them |

Low-level design notes from 2002 (memory layout, interrupts, startup) are in
[`mynos-core/doc/MyNOS-note.txt`](mynos-core/doc/MyNOS-note.txt).

## How it works, in short

GRUB loads the kernel together with a set of modules. The kernel starts every
ELF module as a user process: the services and `ocamlrun`. User programs are
built for Linux with [dietlibc](https://www.fefe.de/dietlibc/) and statically
linked. The kernel implements just enough of the Linux syscall interface for
them to run unmodified, while MyNOS-specific features (IPC, ports, semaphores,
IRQs, threads) go through `libmynos`. `ocamlrun` then executes the OCaml
bytecode passed to it as a GRUB module.

See [`doc/STATUS.md`](doc/STATUS.md) for details.

## Building

The system is 32-bit: user programs are static Linux i386 binaries (musl)
and the OCaml runtime is 5.5, built for that target. Current distributions
don't provide this for an x86_64 host. Builds run in containers
with [podman](https://podman.io/); QEMU runs on the host.

```sh
tools/containers/build-image.sh dev      # once: build the image
tools/build-all.sh                       # build everything in the container
tools/run-demo.sh                        # boot the whole system in QEMU
```

There are two build environments: `dev` (default) with a modern toolchain
(gcc 14, musl, OCaml 5.5, Debian trixie i386), and `legacy` with the
toolchain of the original project (gcc 4.3, dietlibc, OCaml 3.06, Debian
lenny i386), kept to compare behaviour with the original. Pass the name to the scripts, e.g. `tools/build-all.sh legacy`;
run `tools/clean-all.sh` first when switching between them.

`tools/run-tests.sh` boots the system headless and checks its output.
`tools/in-container.sh dev` opens a shell in the build environment, or runs
the command given after it. `tools/run-qemu.sh` boots the kernel with any
list of modules (module 1 is the OCaml bytecode); see the scripts for
details.

## Status

Development stopped at the end of 2004, after the IPC, threads, copy-on-write
and the bytecode interpreter port were in place. In 2026 the original system
was rebuilt, ported to a modern toolchain and moved to OCaml 5.5; it runs
again in QEMU. No OCaml services exist yet, and the way the bytecode is
loaded is a shortcut. The current state, known issues and a
work log are kept in [`doc/STATUS.md`](doc/STATUS.md).

## Authors

[Cesare Zavattari](https://github.com/bradstallion),
[Alessandro Tommasi](https://github.com/aaaaale) and
[Tommaso Schiavinotto](https://github.com/Teudimundo). Originally hosted on
SourceForge (`sourceforge.net/projects/mynos`).

Some code in `mynos-core/kernel/idt.[hc]` and `pic.[hc]` is derived from
gazos-0.2 by Gareth Owen (see [`mynos-core/CREDITS`](mynos-core/CREDITS)).
`mynos-core/kernel/3parts/` contains code taken from other projects, such as
the delay loop calibration by Ramon van Handel. The OCaml runtime in
`mynos-byterun/` is by Xavier Leroy and others, © INRIA.

## License

MyNOS code is released under the GNU General Public License, version 2 or
(at your option) any later version. The OCaml runtime in `mynos-byterun/` keeps
its own license, the GNU Library General Public License with the OCaml linking
exception. See the header of each source file.

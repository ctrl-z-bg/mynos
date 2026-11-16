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
| [`mynos-byterun/`](mynos-byterun/) | The OCaml 3.06 bytecode runtime (`ocamlrun`), patched to run on MyNOS |
| [`doc/STATUS.md`](doc/STATUS.md) | Architecture overview and current state of the project |

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

> **Not yet verified on a modern toolchain.** The code was last built with
> gcc 3 and GRUB legacy. Getting it to build and boot in QEMU again is the
> current goal; see `doc/STATUS.md`.

Requirements: `gcc` with 32-bit support, `ld`, `nasm`, `dietlibc` (the
`diet` wrapper), GNU `make`.

The Makefiles expect this order:

```sh
make -C mynos-core            # -> mynos-core/kernel/kernel.elf
mkdir -p mynos-lib/lib        # not in the repository; ar needs it
make -C mynos-lib             # -> mynos-lib/lib/libmynos.a
make -C services              # -> registry, keyboardd, seriald, memrofsd
make -C mynos-byterun/src     # -> ocamlrun
```

## Status

Development stopped at the end of 2004, after the IPC, threads, copy-on-write
and the bytecode interpreter port were in place. No OCaml programs or services
were written yet, and the way the bytecode is loaded is a shortcut. The current state, known issues and a
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

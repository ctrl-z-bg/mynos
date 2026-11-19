# 1. Welcome to MyNOS

MyNOS is an operating system for the PC. It has a **microkernel** written
in C and assembly, and above it everything else (the file systems, the
disk and network drivers, the shells, the windows) runs as ordinary
**processes**, most of them written in **OCaml**. The processes talk to
each other only through the kernel's messages; since 2026 those messages
carry typed OCaml values, and every service can describe its own
protocol.

It was begun in 2002 by three ~~nerds~~ young computer scientists on SourceForge, set aside in
2004, and taken up again in November 2026, when it reached what it had
been designed for. Its name is an exclamation: **My! Not another
Operating System**. Its authors' first page asked "why embark in the
writing of yet another OS (therefore the name)?" (chapter 2).

## 1.1 What MyNOS is, in one page

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  programs     sh, the OCaml toplevel, edit, the windows, agent   │
  │               (OCaml bytecode on ocamlrun; C programs on musl)   │
  ├──────────────────────────────────────────────────────────────────┤
  │  services     registry · memrofs · tmpfs · fatfs · ata · netd     │
  │               consoled · displayd · llmd · init        (processes)│
  ├──────────────────────────────────────────────────────────────────┤
  │  microkernel  memory · processes and threads · IPC · interrupts  │
  │               (C and assembly, 32-bit x86)                        │
  └──────────────────────────────────────────────────────────────────┘
```

- **A microkernel.** The kernel keeps memory, processes and threads,
  messages, and interrupts; nothing else (appendix A). It does not know
  what a file is.
- **OCaml as the system's language.** The unmodified OCaml 5 runtime
  runs as a process (appendix F), and on it run the shell, the disk
  driver, the FAT file system, the web server, the graphical session,
  `init` itself.
- **Typed IPC.** A request to a service is an OCaml value, checked by
  the type checker on both sides; a service answers `describe` with its
  protocol, so that a window, a program or a language model can call any
  service without knowing it in advance (chapter 17).
- **Linux compatibility, underneath.** The kernel answers the Linux
  system calls that a static C library needs, so musl and the OCaml
  runtime run unchanged (appendix D).
- **A system that shows itself.** An event recorder in the kernel
  records every message; the System window replays them as arrows
  between processes, and the Tour explains what they mean (chapter 11).

## 1.2 Who this manual is for

For anyone curious about how an operating system works, and willing to
look inside one small enough to be read. Part II is for using MyNOS:
it assumes only some familiarity with a command line. Part III is for
writing programs for it, in OCaml or in C. The appendices explain the
inside, for readers who know what a page table is or want to learn.

MyNOS is an experimental system, not a product: it runs in
an emulator, on one processor, for one user.

## 1.3 What you need to try it

- A PC or a Mac with **QEMU** (`qemu-system-i386`): MyNOS runs in it.
- To build it from its sources, **podman**: the build runs in a
  container that holds the whole toolchain (chapter 5).
- 256 MB of memory for the emulator (what `tools/run-demo.sh` gives it), and a few hundred MB of disk.
- Optionally, a key for a language model service (Anthropic's or any
  OpenAI-compatible one) for the agent (chapter 12).

Chapter 5 tells how to build and start it; chapter 6 is the first
session at the console.

## 1.4 How this manual is organized

| Part | For | Chapters |
|---|---|---|
| I. Introduction | everyone | why MyNOS exists, its time, its history |
| II. User's Guide | using it | installation, the console, files, programming inside, the network, the graphical session, watching the system, language models, the commands |
| III. Programmer's Guide | writing programs | C and OCaml programs, processes, IPC, typed IPC, files and console, network, graphics, models, the recorder, drivers, reference pages |
| Appendices | the inside | kernel, memory, IPC, Linux compatibility, services, the OCaml runtime, the recorder, building and testing, glossary, bibliography |

The boxes marked **THE MyNOS FACTOR** point to what is characteristic of
MyNOS: ideas it takes further than most systems, or does in its own way.
Other systems share some of them; chapter 3 names several.

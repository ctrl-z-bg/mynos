# The MyNOS Manual (working text)

This folder is the working text of the MyNOS manual: Markdown, in the
repository, written against the code and checked by it. The typeset
edition, in the style of the manuals of 1975–1990 (A5, LaTeX), will be
made from it later (mynos-278). The table of contents follows the draft
agreed for that edition.

Conventions:

- `code` is something you type, or a name in the source tree;
  `file.c:123` points to a line.
- Diagrams are drawn with characters, as they will be in print.
- **THE MyNOS FACTOR** boxes (quoted blocks) point to what is
  characteristic of MyNOS: ideas it takes further than most systems, or
  does in its own way. Other systems, past and present, share some of
  them (chapter 3).
- The complete programs of Part III are in `examples/`, one directory per
  chapter; `tools/build-examples.sh` (run by `tools/build-all.sh`)
  compiles them all, so that a library change that breaks one breaks the
  build.

## Contents

**Part I — Introduction**

1. [Welcome to MyNOS](01-welcome.md)
2. [Why MyNOS](02-why.md)
3. [The historical context (2000–2004)](03-context.md)
4. [Timeline](04-timeline.md)

**Part II — User's Guide**

5. [Installation](05-installation.md)
6. [First steps at the console](06-first-steps.md)
7. [Files and disks](07-files.md)
8. [Programming inside MyNOS](08-programming-inside.md)
9. [Networking](09-networking.md)
10. [The graphical session](10-graphical-session.md)
11. [Watching the system at work](11-watching.md)
12. [Language models and agents](12-language-models.md)
13. [Command reference](13-command-reference.md)

**Part III — Programmer's Guide**

14. [C programs and OCaml programs](14-c-and-ocaml.md)
15. [Processes, threads and domains](15-processes.md)
16. [IPC: ports, channels, the name registry](16-ipc.md)
17. [Typed IPC](17-typed-ipc.md)
18. [Files and console](18-files-console.md)
19. [Networking](19-networking.md)
20. [Graphics](20-graphics.md)
21. [Language models](21-language-models.md)
22. [The event recorder](22-recorder.md)
23. [Writing a driver](23-writing-a-driver.md)
24. [Reference pages](24-reference.md)

**Appendices — Architecture**

- [A. The microkernel](appendix-a-microkernel.md): boot, descriptors,
  processes and threads, the scheduler, semaphores, interrupts, system
  calls
- [B. Memory](appendix-b-memory.md): paging, the address space,
  physical pages, the kernel heap, copy-on-write, pointers from processes
- [C. IPC in the kernel](appendix-c-ipc.md): ports, channels, messages,
  one exchange step by step
- [D. Linux compatibility](appendix-d-linux.md): `int 0x80`, the calls
  MyNOS answers, musl, the initial stack, threads
- [E. Services and their protocols](appendix-e-services.md): typed IPC,
  init and supervision, every service and its requests
- [F. The OCaml runtime on MyNOS](appendix-f-ocaml-runtime.md): the
  upstream runtime, the primitives, threads and domains, the libraries
- [G. The event recorder](appendix-g-recorder.md): what the kernel
  records, `Tracer`, `trace`, the windows and the Tour
- [H. Building and testing MyNOS](appendix-h-building.md): the toolchain,
  the build, QEMU, the test suite, debugging
- [I. Glossary](appendix-i-glossary.md)
- [J. Bibliography](appendix-j-bibliography.md)

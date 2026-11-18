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
- **THE MyNOS FACTOR** boxes (quoted blocks) mark what MyNOS does that
  other systems do not.
- What is not written yet is marked *(to be written)*.

## Contents

**Part I — Introduction** *(to be written)*

1. Welcome to MyNOS
2. Why MyNOS
3. The historical context (2000–2004)
4. Timeline

**Part II — User's Guide** *(to be written)*

5. Installation
6. First steps at the console
7. Files and disks
8. Programming inside MyNOS
9. Networking
10. The graphical session
11. Watching the system at work
12. Language models and agents
13. Command reference

**Part III — Programmer's Guide** *(to be written)*

14. C programs and OCaml programs
15. Processes, threads and domains
16. IPC: ports, channels, the name registry
17. Typed IPC
18. Files and console
19. Networking
20. Graphics
21. Language models
22. The event recorder
23. Writing a driver
24. Reference pages

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

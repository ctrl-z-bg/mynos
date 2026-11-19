# 4. Timeline

The dates come from the project's history: the CVS repository of
2002–2008, imported into git with its authors and dates; the project's
SourceForge page and the news the authors posted there (kept in
`doc/website/news.html`); and,
for 2026, `doc/STATUS.md` and `doc/JOURNAL.md`.

## 4.1 The people

MyNOS was written by **Cesare Zavattari**, **Alessandro Tommasi** and
**Tommaso Schiavinotto**, three ~~nerds~~ young computer scientists, as a free
software project hosted on SourceForge (`sourceforge.net/projects/mynos`).
On SourceForge they signed as *zavatt*, *alley* and *nardo*. The logo,
the Minotaur that the graphical session still shows, was drawn by Luigi
Ferrini.

## 4.2 2001–2004: the first MyNOS

| Date | Event |
|---|---|
| 2001-09-05 | The project is registered on SourceForge, after a long planning (the date on its SourceForge page). |
| 2002-01-08 | The first news on SourceForge: the kernel's memory management is under development, paging already works, the code will soon be on CVS. |
| 2002-02-02 | The first commit, by Cesare Zavattari: a floppy boot loader in assembly and the first files of the kernel. |
| 2002-03 | Tommaso Schiavinotto adds a target to build a boot floppy. |
| 2002-10-03 | Allocation on first use: pages are given to a process when it first touches them. |
| 2002-10-08 | The web site opens (its visitor counter starts that day), with the page *Why MyNOS?* (chapter 2). |
| 2002-10-11 | `fork`, in a simple form, without copy-on-write. |
| 2002-10-22 | "ocaml virtual machine ran on mynos kernel!": OCaml's virtual machine, compiled against dietlibc, runs as a process on MyNOS's kernel, executing a simple bytecode program. |
| 2002-11-04 | "Static ELF format supported!": the kernel loads static ELF modules, and the OCaml virtual machine has been tested on it. |
| 2002-11-09 | "IPC implemented: MyNOS reaches Alpha state!", after a long night's work: send and receive, synchronous or not. |
| 2002-11-20 | IPC buffers are checked. |
| 2002-11-26 | "MyNOS! has Semaphores!", and a first management of process queues. |
| 2003-04-07 | The serial driver, a process like the keyboard's; services register with the kernel; a message received from the serial port. |
| 2003 | A private test: messages sent over a serial cable between a PC running MyNOS and a Sinclair ZX Spectrum (4.3). |
| 2003-07-30 | The task switch moves from the processor's hardware mechanism to software; `fork` reworked, and `sched()`. |
| 2003-08-18 | Threads: every thread belongs to its process, with the same pid. |
| 2003-11-07 | Copy-on-write. |
| 2004-09-01 | The kernel's IPC redesigned from scratch: ports and channels, long messages moved by copy-on-write, the IPC of today (appendix C). |
| 2004-12 | The last commits of the period. |
| 2005, 2008 | A few more, in February 2005 and November 2008 (tagged `legacy-2008`). |

Then the project stopped, for the most common of reasons: real life.

## 4.3 A chat with a ZX Spectrum

The progress report of April 2003 ends with one line: "We have conducted
a private test sending messages via the serial port from/to a sinclair
spectrum old computer." Cesare and Alessandro connected a PC running
MyNOS and a ZX Spectrum, a home computer of 1982, with a serial cable:
the Spectrum spoke serial through its **Interface 1** expansion, the PC
through MyNOS's new serial driver, a process like any other. On the
Spectrum, most likely, a small program read from the serial port and
wrote to it.

The serial port is still how MyNOS talks to the outside, in a way: since
2026 the second serial port is a second terminal on the same shell
(chapter 6), and the log that the test suite reads.

## 4.4 2026: the restart

On 16 November 2026 the CVS history was imported into git, the original
system was built and run again as it was (tagged `revival-baseline`),
and the work began again, with
Claude Code, Anthropic's AI coding agent, writing the code under its
authors' direction. The first days, in outline (each line is detailed in
`doc/STATUS.md`'s work log):

| Date | What was done |
|---|---|
| 2026-11-16 | The 2008 system built again and running in QEMU, first with a period toolchain, then with a modern one (gcc 14, musl). The OCaml runtime replaced by OCaml 5.5's, unmodified. The console, files over the RAM disk, `spawn`, the OCaml toplevel as a shell, `init` in OCaml, `tmpfs`, Linux threads and OCaml domains, the ATA disk driver and the FAT file system in OCaml, `ocamlc` inside MyNOS, the editor `edit`, the shell `sh`. |
| 2026-11-17 | Typed IPC, and protocols that describe themselves. The network (lwIP, an NE2000 driver, TLS) and a web server. The event recorder. Identities with generations, and the `io` privilege. Language models: `llm`, `ask`, the agent. The graphical session, with terminal windows. |
| 2026-11-18 | The agent and recordings windows, the System window, `kill`, the Tour, services restarted by `init`, files, registry and console over typed IPC (every service typed), OCaml threads. The period toolchain retired. The manual's appendices, and the kernel bugs they found: the FPU state, write protection, unchecked pointers. |
| 2026-11-19 | C's stdio over the file services, one recording at a time, the manual's user's and programmer's guides, and the bugs they found. |

The work followed the plan of 2002 (chapter 2.2) and kept its code
where it worked: the kernel of 2002–2004 is still the kernel. What was
added was decided step by step, by the authors, in the notes of
`doc/decisions/`; what went wrong, and what it taught, is in
`doc/JOURNAL.md`, a diary of every non-trivial bug.

> **THE MyNOS FACTOR — A system finished twenty-four years later.**
> The design of 2002 needed no correction to be finished in 2026: a
> microkernel, services as processes, OCaml's virtual machine as one of
> them, and a higher level of abstraction through the language. What
> changed is the cost of doing it: four days of work, directed by the
> people who had the ideas, and done with an AI agent that read their
> code of 2002 as carefully as its own.

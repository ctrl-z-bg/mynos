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
| 2002-07-05 | Tommaso Schiavinotto gives the kernel GRUB's boot information (multiboot): the memory, and the modules loaded with the kernel. It is how the kernel finds its first programs and the RAM disk today. |
| 2002-10-03 | Allocation on first use: pages are given to a process when it first touches them. |
| 2002-10-08 | The web site opens (its visitor counter starts that day), with the page *Why MyNOS?* (chapter 2). |
| 2002-10-11 | `fork`, by Alessandro Tommasi: the child gets its own copy of its parent's pages, page directory and page tables, not yet copy-on-write. |
| 2002-10-22 | "ocaml virtual machine ran on mynos kernel!": OCaml's virtual machine, compiled against dietlibc, runs as a process on MyNOS's kernel, executing a simple bytecode program. |
| 2002-11-04 | "Static ELF format supported!": Tommaso Schiavinotto's ELF loader. The kernel loads static ELF programs, and the OCaml virtual machine has been tested on it. Every program of today, services and `ocamlrun` alike, still starts through it. |
| 2002-11-06 | "About to go alpha: roadmap": IPC first, even simple-minded, then the services (file system, memory, POSIX compatibility, an OCaml server). The order the project followed, then and in 2026. |
| 2002-11-09 | "IPC implemented: MyNOS reaches Alpha state!", after a long night's work: send and receive, synchronous or not. |
| 2002-11-20 | IPC buffers are checked. |
| 2002-11-26 | "MyNOS! has Semaphores!": Tommaso Schiavinotto's semaphores, and a first management of process queues, with their system calls in the library. |
| 2003-04-07 | The serial driver, a process like the keyboard's; services register with the kernel; a message received from the serial port. |
| 2003 | A private test: messages sent over a serial cable between a PC running MyNOS and a Sinclair ZX Spectrum (4.3). |
| 2003-07-30 | The task switch moves from the processor's hardware mechanism to software; `fork` reworked, and `sched()`. |
| 2003-08-18 | Threads: every thread belongs to its process, with the same pid. |
| 2003-11-07 | Copy-on-write. |
| 2004-07-29 | Alessandro Tommasi extends the record of each process's free address space (`lmemtrack`, appendix B): its copy for `fork`, and the areas taken at a given place (the program, the stacks, the RAM disk). The new IPC finds room there for the long messages it maps. |
| 2004-09-01 | The kernel's IPC redesigned from scratch by Cesare Zavattari: ports and channels, long messages moved by copy-on-write, the IPC of today (appendix C). |
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
| 2026-11-19 | C's stdio over the file services, one recording at a time, the log inside MyNOS, UTF-8 in the editor. A bootable ISO, the first release, and MyNOS in the browser. The manual's user's and programmer's guides, and the bugs they found. |
| 2026-11-20 | What of OCaml's distribution runs, measured: Str and Num added to the runtime, `Sys.time`, `getuid` and `O_EXCL` fixed. OCaml's `Graphics`, written again on the toolkit. Packages: `pkg`, its repository on GitHub, and the Packages window; 2048 and the agent's tree in the wind as the first packages. |
| 2026-11-21 | Small fixes before the printed manual: connections bounded in time, `httpd` after a restart of the network, services that end cleanly without their hardware. Twenty-one packages more: commands (`utils`, `calc`, `scheme`, the manual itself), windows (Wikipedia, feeds, images, painting), games, a Z-machine with Zork I to III, a Game Boy. `httpd` receives files, the menu's Applications, KVM in the start scripts. Key releases for the windows, and disk writes six times faster. |
| 2026-11-22 | Sound: a DMA area from the kernel, `soundd` for a Sound Blaster 16, `play`, a volume in the top bar. Resizable windows, and a terminal that grows with its window; bigger screens (`gui 1920x1080`). A clipboard shared by every program, text selected with the mouse in every window, a question before closing unsaved work. Text, a text editor, and MyNOS Studio, for writing OCaml programs inside MyNOS. Ask MyNOS: the system answers questions about itself, in the first person. Packages: the Game Boy with its sound, GavML (GAV, Arcade Volleyball, in OCaml, two against two and over the network), a web browser with pictures and forms. |
| 2026-11-23 | The documentation brought up to date: the start scripts' variables, this timeline, the README, the printed book. Page faults three times faster, and the external pager: a service in OCaml, `pagerd`, gives pages of files mapped into memory (read-only, shared, private) and memory that goes to a swap; C's `mmap` of a file over it. 2 GB of memory by default. A monitor of the system, and CSS in the browser. C's `malloc` eighteen times faster, and the timer at 1000 Hz. |
| 2026-11-24 | A kernel bug of the direction flag, found with a hardware watchpoint. Before this book's freeze: `fork` copies only its caller, BSD sockets for C programs, with `poll` and `select`. The old website's news and notes of 2002–2004 kept in `doc/`. |

The work followed the plan of 2002 (chapter 2.2) and kept its code
where it worked: the kernel of 2002–2004 is still the kernel. What was
added was decided step by step, by the authors, in the notes of
`doc/decisions/`; what went wrong, and what it taught, is in
`doc/JOURNAL.md`, a diary of every non-trivial bug.

> **THE MyNOS FACTOR — A system finished twenty-four years later.**
> The design of 2002 needed no correction to be finished in 2026: a
> microkernel, services as processes, OCaml's virtual machine as one of
> them, and a higher level of abstraction through the language. What
> changed is the cost of doing it: a few days of work, directed by the
> people who had the ideas, and done with an AI agent that read their
> code of 2002 as carefully as its own.

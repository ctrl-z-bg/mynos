# 2. Why MyNOS

## 2.1 The answer of 2002

In 2002 the project's web site opened with a page called *Why MyNOS?*.
It is reproduced here as it was written (from `doc/website/why.html`),
because it says better than any summary what three ~~nerds~~ young computer scientists wanted from
an operating system of their own.

> **Why MyNOS?**
>
> In this time and age, when so many advanced OSes compete for a market
> that changes at a furious pace, why embark in the writing of yet
> another OS (therefore the name)?
>
> Before an answer is attempted, please notice just how many similar
> projects are there. There are countless "alternative" operating
> systems that people have been writing in their spare time. Very few of
> them ever reached any useful, or even usable state, and yet new ones
> start on a regular basis. One reason for this lies within the fact
> that an operating system is a very complex and challenging system,
> which undoubtably attracts people with a technically inclined mind. A
> second, more "psychological" reason is that by writing your own OS,
> you get your system to execute, even at the lowest level, only things
> you told it to execute. That makes you feel more independent, more in
> control. To some of us, this is a sheer personal satisfaction that is
> right on the money. To most people, this is the definition of a
> lifeless geek.
>
> At last, but not least, present OSes are far from perfect. They often
> trade elegance for speed, effectiveness for backward compatibility,
> experimentation for widespread distribution. To give an example, the
> most common programming language used to write operating system is C
> (this is perhaps changing to move to more structured languages,
> however). The reason for this is that C is very close to the
> underlying hardware, and therefore allows great control over it. A
> common drawback is that the interaction with the OS is usually
> constrained to a low C API level (case in point, POSIX). Building
> higher-level intermediate layers makes the system run slower, and is
> usually avoided, at the cost of keeping a 30 years old interface.
>
> With MyNOS, we wanted to explore how OS staples (memory allocation,
> filesystem, macrokernel, etc.) could be "removed". The operating system
> could be written in a high-level language, and provide higher level
> abstractions. The language of choice is OCAML, because it is a very
> nice, elegant language, because it is functional, because it is
> object-oriented, and simply because it is so far from the the usual
> low-level view over the OS.
>
> As it happened with LISP, that in the old days required a LISP-machine
> to run effectively, to write an operating system in OCAML we would
> definitely need some kind of special hardware support. While modifying
> hardware is not really our bag, we know that to abstract from the
> hardware layer is the job of an OS. The idea is therefore to build an
> underlying OS to provide "standard" OS functionalities, in order to
> have an "abstract machine" on top of which which to run the OCAML
> virtual machine. This is not a chinese box. At first we wanted to get
> the underlying OS done as soon as possible, in order to switch to the
> OCAML layer. However, why not experiment with that as well.
>
> Our current more complete vision features:
>
> - a complete microkernel architecture written in C+asm to provide
>   basic microkernel functionalities (process management and IPC)
> - peripheral services running as processes
> - "virtual machine" services to run as processes.
>
> Virtual machine processes include a POSIX server which should
> implement the POSIX standard, allowing us to run, for instance, Unix
> programs. One of the virtual machines will be the OCAML virtual machine
> which should be able to run OCAML bytecode natively, and provide a
> higher level abstraction to the OS.
>
> The project started after a very long planning activity. Its goals
> have somehow shifted, and we are now more involved and concerned with
> the development of the lower leve OS than with the higher level, OCAML
> one. Our objective is to reach a stable and versatile platform on which
> we would be able to run code originally developed for different
> platforms (like Linux), and on which to experiment with our OCAML
> "kernel". Thanks to the elegant and robust microkernel architecture
> (another feature not commonly exploited by today's OSes), we will be
> able to access and modify views over very low-level facilities like
> memory and disk without rewriting critical kernel parts, and always
> acting at user-level.
>
> Ideally, we would like to get to a point where a different, new,
> higher level and yet strong abstraction to the machine is achieved
> through OCAML, similar to what Unix achieved in the 70ies.

The name answers the page's first question: MyNOS stands for **My! Not
another Operating System**.

## 2.2 What became of it

Twenty-four years later, the plan of 2002 reads as a specification. Here
is what each of its points became.

| 2002 | 2026 |
|---|---|
| "A complete microkernel architecture written in C+asm", for process management and IPC | The same kernel, grown: generation-tagged ids, Linux threads, an event recorder, write protection and a saved FPU state for every thread (appendix A). Much of the 2002 code is still there. |
| "Peripheral services running as processes" | Every driver and file system is a process: the keyboard and console, the disk (`ata`), the network card with its TCP/IP stack (`netd`), the display (`displayd`). |
| "The OCAML virtual machine … run OCAML bytecode natively" | `ocamlrun`, the upstream OCaml 5 runtime, unchanged, runs as an ordinary process; `init`, the shell, the FAT file system and the disk driver are OCaml programs on it (appendix F). |
| "A POSIX server … allowing us to run Unix programs" | Done another way: the kernel answers Linux's own system calls, so programs built with a standard C library (musl) run unchanged, and their files reach the services through `libmynos` (appendix D). |
| "Access and modify views over very low-level facilities like memory and disk … always acting at user-level" | The disk driver and the FAT file system are OCaml programs; a request for a sector is a message, and so is a file's directory (chapter 23, appendix E). |
| "A different, new, higher level and yet strong abstraction to the machine … through OCAML" | Typed IPC: a service's protocol is an OCaml type; a request is a value, checked on both sides; every service describes itself, and can be called from a window, a program or a language model without being known in advance (chapter 17). |

What the 2002 page did not foresee is just as telling: the system now
records its own messages and replays them as arrows, and explains itself
in a Tour (chapter 11); and the "higher level abstraction" turned out to
be useful to a reader its authors could not have imagined, a language
model, which calls the system's services through their descriptions,
and whose programs the OCaml type checker vets before they run
(chapter 12).

> **THE MyNOS FACTOR — OCaml as the system language, back in 2002.**
> In 2002 functional languages were rarely used for systems, and the
> idea of a system whose services are written in one, run by its
> bytecode interpreter as an ordinary process, was unusual. MyNOS kept
> the idea and let the machinery around it grow up: the bytecode
> interpreter of 2002 was a port of OCaml 3.06; today's is OCaml 5's,
> with domains and effects, unmodified. The language that the 2002 page
> chose "because it is so far from the usual low-level view over the OS"
> now carries every request between the system's parts.

## 2.3 Why it was finished

The project stopped in 2004 for the usual reason: real life. Its authors
took it up again in November 2026, seizing the opportunity offered by
modern development environments built on AI, in this case Claude Code,
to see their old project through to the end. It was conceived many
years ago, and they still find it interesting, and fun.

*Finished*, in this manual, means just that: MyNOS is now a small,
working demonstration of the architectural path its authors chose in
2002, not a general-purpose operating system.

The work of 2026 followed the 2002 design, not a new one: the decisions
taken along the way are in `doc/decisions/`, and the day-by-day account,
with every bug and what it taught, is in `doc/JOURNAL.md`. Chapter 4
gives the dates.

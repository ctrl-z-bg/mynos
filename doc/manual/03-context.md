# 3. The historical context (2000–2004)

MyNOS was planned at length ("after a very long planning activity", its
authors wrote) and written between 2002 and 2004. Its ideas
were not isolated: in those same years the industry and the research
laboratories were asking the questions it asked, with far more people
and money. This chapter places it among them. The works cited are in
appendix J.

## 3.1 Managed code reaches the mainstream

In the late 1990s Java (1995) had made a virtual machine, a garbage
collector and a safe language the ordinary way to write applications.
In February 2002, the month MyNOS's first line was committed, Microsoft
released the .NET Framework and its new language, C#: a second managed
runtime, from the largest software company, for the whole of Windows'
application programming.

Functional programming was starting to leave the universities too. At
Microsoft Research in Cambridge, Don Syme began in 2002 the language that
became F#: a member of the ML family, like OCaml, and deliberately close
to it, running on .NET. OCaml itself (then Objective Caml, version 3)
was used for compilers, theorem provers and analysis tools, and rarely
for systems.

## 3.2 Operating systems in safe languages

The idea of an operating system built on a safe language was older than
MyNOS, and came back while MyNOS was being written.

- **Oberon** (Niklaus Wirth and Jürg Gutknecht, ETH Zürich, from 1987):
  a whole workstation, compiler and system, in one strongly typed
  language, small enough to be explained in one book.
- **Inferno** (Bell Labs, 1996): the people of Unix and Plan 9 built a
  system whose programs, written in the safe language Limbo, run on a
  virtual machine, Dis, on any hardware or as an application.
- **Singularity** (Microsoft Research, from 2003): a research system
  written in a safe dialect of C#, whose processes are isolated by the
  language rather than by the processor's memory protection, and talk
  over **typed channels** whose protocols are declared as contracts and
  checked by the compiler. It is the nearest relative of what MyNOS's IPC
  became in 2026.
- **JNode** (from 2003): an operating system written in Java, run by its
  own Java virtual machine.
- **House** (Portland State University, 2005): an operating system in
  Haskell, with drivers and a network stack written in a purely
  functional language.

MyNOS chose a middle road: a small kernel in C, as in most systems, and
the safe language above it, in the services and programs, run by the
language's own bytecode interpreter as an ordinary process.

## 3.3 The microkernel revival

The microkernels of the 1980s, Mach above all, had a reputation for
being slow: every request to a service a message, every message a trip
through a large kernel. In the 1990s Jochen Liedtke showed with **L4**
that the fault was in the implementations, not in the idea: a kernel
designed only for fast IPC made messages cheap enough for drivers and
file systems to live outside it. By the early 2000s L4's descendants
were being developed at Karlsruhe, Dresden and Sydney; one of them,
seL4, was later proved correct by formal verification (2009), and L4
kernels went on to run inside very large numbers of mobile devices.

**MINIX**, Andrew Tanenbaum's teaching system of 1987, already put its
drivers and file system in processes, and its book showed every line;
MINIX 3 (2005) took the design further, towards reliability: drivers
that crash are restarted. MyNOS's `init` does the same since 2026
(chapter 11).

## 3.4 Where MyNOS fits

MyNOS asked the same questions, at the same time, from three young
computer scientists working in their spare time on SourceForge, the
public home of free software projects then. Its answers were modest
beside Singularity's or L4's, and its authors knew it: their page of
2002 begins by admitting how many such projects never reach a usable
state (chapter 2). What it had was a particular combination: a
microkernel in C, OCaml's own bytecode interpreter as an ordinary
process on it, services as processes, and the ambition to give programs
"a different, new, higher level and yet strong abstraction to the
machine" through OCaml.

Two decades later the pieces have become ordinary. OCaml 5 (2022) has
parallel domains and effect handlers; MirageOS (2013) builds whole
network appliances in OCaml; Rust has brought a safe language into
Linux's own kernel. MyNOS, finished in 2026, is a small, complete
example of the road its authors chose in 2002, and of where it leads.

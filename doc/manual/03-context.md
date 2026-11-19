# 3. The historical context (2000–2004)

MyNOS was planned at length ("after a very long planning activity", its
authors wrote) and written between 2002 and 2004. Its ideas
were not isolated: in those same years the industry and the research
laboratories were asking the questions it asked, with far more people
and money. This chapter places it among them. The works cited are in
appendix J.

## 3.1 Managed code reaches the mainstream

In the late 1990s Java (announced in 1995) had made a virtual machine, a garbage
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

Before them all came the **Lisp machines**: workstations developed at
MIT's Artificial Intelligence Laboratory from the mid-1970s, and sold in
the 1980s by Symbolics, Lisp Machines Inc. and Texas Instruments. Much
of their operating system, the editor and the window system included,
was written in Lisp, on processors designed for it: tagged data,
hardware help for type checking and garbage collection, and Lisp-oriented
instructions in microcode or in dedicated hardware, depending on the
generation. Lisp itself checked its types at run time and managed memory
automatically; what these machines did not have was the
hardware-enforced isolation between processes that MyNOS uses: system
and user programs lived in one shared Lisp environment, and user
programs could redefine system functions. But they were a whole
operating system whose master was a functional language, and that idea
inspired MyNOS's authors deeply. Their page of 2002 draws the analogy
(chapter 2.1): as LISP "in the old days required a LISP-machine to run
effectively", a system in OCaml would need "some kind of special
hardware support". (Lisp ran on ordinary computers too, the PDP-10
among them; its machines were built for speed, memory and
interactivity.) MyNOS took a different route: not an OCaml processor,
but an "abstract machine" made in software, a microkernel in C with
OCaml's bytecode virtual machine running on it as an ordinary process.

The idea of an operating system built on a safe language was older than
MyNOS, and came back while MyNOS was being written.

- **Oberon** (Niklaus Wirth and Jürg Gutknecht, ETH Zürich, 1986–1989):
  a whole workstation, compiler and system, in one strongly typed
  language, small enough to be explained in one book.
- **SPIN** (University of Washington, 1995): an extensible operating
  system written in Modula-3, a type-safe language. Extensions are linked
  into the kernel, and the language's safety, with controlled dynamic
  linking, protects the kernel's interfaces without a hardware protection
  boundary around each extension.
- **Inferno** (Bell Labs, 1996): the people of Unix and Plan 9 built a
  system whose programs, written in the safe language Limbo, run on the
  portable Dis virtual machine, across the hardware it was ported to or
  hosted on an existing operating system.
- **Singularity** (Microsoft Research, from 2003): a research system
  written in a safe dialect of C#, whose processes are isolated by the
  language rather than by the processor's memory protection, and talk
  over **typed channels** whose protocols are declared as contracts and
  checked by the compiler. It is a particularly interesting point of
  comparison for the typed IPC MyNOS gained in 2026, although
  Singularity's contracts also describe the state of a conversation, and
  so give stronger guarantees than MyNOS's typed requests and replies,
  one call per connection (chapter 17).
- **JNode** (from 2003): an operating system written in Java, run by its
  own Java virtual machine.
- **House** (Portland State University, 2005): an operating system in
  Haskell, with drivers and a network stack written in a purely
  functional language.

MyNOS chose a middle road: a small kernel in C, as in most systems, and
the safe language above it, in the services and programs, run by the
language's own bytecode interpreter as an ordinary process.

## 3.3 The microkernel revival

Earlier microkernels, Mach above all, had acquired a reputation for
expensive interprocess communication. In the 1990s Jochen Liedtke showed
with L3 and then **L4** that much of that cost came from implementation
choices rather than from the microkernel architecture itself: a kernel
whose IPC path was designed with care made messages cheap enough for
drivers and file systems to live outside it. By the early 2000s L4's descendants
were being developed at Karlsruhe, Dresden and Sydney; one of them,
seL4, was in 2009 the first general-purpose kernel with a
machine-checked proof of functional correctness, from its specification
to its C implementation, and L4
kernels went on to run inside very large numbers of mobile devices.

**MINIX**, Andrew Tanenbaum's teaching system of 1987, already organized
its file system, memory manager and device drivers as communicating
processes, and its book showed every line, although the original
drivers ran as privileged tasks compiled into the kernel. MINIX 3 (2005)
moved the drivers into user space and took the design further, towards
fault isolation and recovery: drivers that crash are restarted. MyNOS's `init` does the same since 2026
(chapter 11).

## 3.4 Where MyNOS fits

MyNOS asked the same questions, at the same time, from three ~~nerds~~ young
computer scientists on SourceForge, a public home of free software
projects then. Its answers were modest beside Singularity's or L4's, and
its page of 2002 begins by admitting how many such projects never reach
a usable state (chapter 2). What it had was a particular combination: a
microkernel in C, OCaml's own bytecode interpreter as an ordinary
process on it, services as processes, and the ambition to give programs
"a different, new, higher level and yet strong abstraction to the
machine" through OCaml.

Two decades later the pieces have become ordinary. OCaml 5 (2022) has
parallel domains and effect handlers; MirageOS (2013) builds whole
network appliances in OCaml; Rust has brought a safe language into
Linux's own kernel. MyNOS, finished in 2026 (in the sense of 2.3), is a
small, working demonstration of the road its authors chose in 2002, and
of where it leads.

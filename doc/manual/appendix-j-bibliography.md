# Appendix J. Bibliography

Works that shaped MyNOS, or this manual, or that a reader who wants to go
further will enjoy. Grouped by subject; within each group, by year.

## J.1 The manuals this one imitates

The typeset edition of this manual borrows its form from the manuals of
1965–1992. Scans of most of them circulate in the archives of
bitsavers.org, the Unix Heritage Society, multicians.org,
vintageapple.org and os2museum.com.

- *Multics System Programmers' Manual*. MIT Project MAC, General
  Electric, Bell Laboratories, 1965–1969. The design notes: why each
  choice was made, written while it was being made.
- *UNIX Programmer's Manual, Seventh Edition*. Bell Laboratories, 1979.
  Volume 1, the reference pages in their now classic form (NAME,
  SYNOPSIS, DESCRIPTION, SEE ALSO); Volume 2, the essays.
- *CP/M Operating System Manual*. Digital Research, 1982. One volume for
  the user, the programmer and the implementer; the CCP, BDOS and BIOS,
  which in MyNOS become programs, services and kernel.
- *AmigaDOS User's Manual* and *AmigaDOS Technical Reference Manual*.
  Commodore-Amiga, 1985.
- *Microsoft MS-DOS User's Guide and User's Reference*, version 3.3.
  Microsoft Corporation, 1987. The User's Reference: the command
  reference, one command at a time.
- *Apollo Domain/OS Design Principles*. Apollo Computer, 1989 (order
  no. 014962-A00). An operating system's architecture told as an essay.
- *Macintosh System Software User's Guide, Version 6.0.4*. Apple
  Computer, 1989. Teaching a graphical session one figure at a time.
- *OS/2 2.0 Technical Library*. IBM, 1992.

## J.2 The processor, the boot, and the first steps

- *Intel 80386 Programmer's Reference Manual*. Intel, 1986. The source
  of the 2002 notes in `mynos-core/doc/MyNOS-note.txt`: segments, paging,
  task state segments, interrupts.
- R. A. Burgess. *Developing Your Own 32-bit Operating System*. Sams
  Publishing, 1995 (ISBN 978-0-672-30655-6). A whole protected-mode
  operating system for the 386, explained and listed; in 2002 the book
  that showed MyNOS's authors how to begin the real implementation.
  Republished by its author as *MMURTL V1.0* (Sensory Publishing).
- *Intel 64 and IA-32 Architectures Software Developer's Manual*. Intel,
  current edition.
- *Multiboot Specification*, version 0.6.96. Free Software Foundation.
  How GRUB hands MyNOS its kernel, its modules and their command lines.

## J.3 Microkernels

- M. Accetta, R. Baron, W. Bolosky, D. Golub, R. Rashid, A. Tevanian,
  M. Young. "Mach: A New Kernel Foundation for UNIX Development".
  *USENIX Summer Conference*, 1986. Ports and messages as the kernel's
  interface.
- A. S. Tanenbaum. *Operating Systems: Design and Implementation*.
  Prentice Hall, 1987. MINIX: a microkernel, its drivers and file system
  as processes, explained line by line.
- J. Liedtke. "Improving IPC by Kernel Design". *14th ACM Symposium on
  Operating Systems Principles (SOSP)*, 1993. L3: how much of IPC's cost
  is in its implementation.
- J. Liedtke. "On µ-Kernel Construction". *15th ACM Symposium on
  Operating Systems Principles (SOSP)*, 1995. Why a microkernel must be
  small and its IPC fast; the principles behind the L4 family.
- J. N. Herder, H. Bos, B. Gras, P. Homburg, A. S. Tanenbaum. "MINIX 3:
  A Highly Reliable, Self-Repairing Operating System". *ACM SIGOPS
  Operating Systems Review* 40(3), 2006. Drivers as processes that are
  restarted when they fail, as MyNOS's `init` does (11.7).
- G. Klein et al. "seL4: Formal Verification of an OS Kernel". *22nd ACM
  SOSP*, 2009.

## J.4 Systems in safe languages

- A. Bawden, R. Greenblatt, J. Holloway, T. Knight, D. Moon, D. Weinreb.
  "LISP Machine Progress Report". MIT AI Memo 444, 1977. The machine
  whose operating system was its language.
- D. Weinreb, D. Moon. *Lisp Machine Manual*, fourth edition. MIT
  Artificial Intelligence Laboratory, 1981.
- D. H. H. Ingalls. "Design Principles Behind Smalltalk". *Byte* 6(8),
  August 1981. "An operating system is a collection of things that
  don't fit into a language. There shouldn't be one."
- A. Goldberg, D. Robson. *Smalltalk-80: The Language and its
  Implementation*. Addison-Wesley, 1983. A system of objects and
  messages, its tools written in itself, examined and changed while it
  runs.
- N. Wirth, J. Gutknecht. *Project Oberon: The Design of an Operating
  System and Compiler*. Addison-Wesley, 1992.
- A. C. Kay. "The Early History of Smalltalk". *ACM SIGPLAN Notices*
  28(3), 1993 (HOPL-II). Objects as computers that exchange messages.
- B. N. Bershad, S. Savage, P. Pardyak, E. G. Sirer, M. E. Fiuczynski,
  D. Becker, C. Chambers, S. Eggers. "Extensibility, Safety and
  Performance in the SPIN Operating System". *15th ACM SOSP*, 1995.
  Kernel extensions in Modula-3, protected by the language.
- S. Dorward, R. Pike, D. L. Presotto, D. M. Ritchie, H. Trickey,
  P. Winterbottom. "The Inferno Operating System". *Bell Labs Technical
  Journal* 2(1), 1997. Limbo, a safe language, on a virtual machine.
- JNode, an operating system in Java, from 2003:
  sourceforge.net/projects/jnode.
- T. Hallgren, M. P. Jones, R. Leslie, A. Tolmach. "A Principled
  Approach to Operating System Construction in Haskell". *ICFP*, 2005.
  House.
- G. C. Hunt, J. R. Larus. "Singularity: Rethinking the Software Stack".
  *ACM SIGOPS Operating Systems Review* 41(2), 2007. Processes isolated
  by the language, and typed channels with contracts: a point of
  comparison for MyNOS's typed IPC, whose request and reply give weaker
  guarantees (chapter 3.2).
- A. Madhavapeddy et al. "Unikernels: Library Operating Systems for the
  Cloud". *ASPLOS*, 2013. MirageOS, an operating system in OCaml.

## J.5 OCaml

- X. Leroy. "The ZINC Experiment: An Economical Implementation of the ML
  Language". INRIA technical report 117, 1990. The ancestor of the
  bytecode machine that runs every MyNOS program.
- D. Syme. "The Early History of F#". *Proceedings of the ACM on
  Programming Languages* 4 (HOPL), 2020. An ML for .NET, begun in 2002.
- K. C. Sivaramakrishnan, S. Dolan, L. White, S. Jaffer, T. Kelly,
  A. Sahoo, S. Parimala, A. Dhiman, A. Madhavapeddy. "Retrofitting
  Parallelism onto OCaml". *ICFP*, 2020. The domains.
- K. C. Sivaramakrishnan, S. Dolan, L. White, T. Kelly, S. Jaffer,
  A. Madhavapeddy. "Retrofitting Effect Handlers onto OCaml". *PLDI*,
  2021.
- X. Leroy et al. *The OCaml System: Documentation and User's Manual*.
  INRIA, current edition (5.5). The language, the bytecode compiler, the
  runtime, and the libraries MyNOS links.

## J.6 The software inside MyNOS

Each comes with its licence, or a README that names it, in
`third_party/` (musl with the container that builds MyNOS).

- musl, the C library: musl.libc.org.
- lwIP, the TCP/IP stack: A. Dunkels, "Design and Implementation of the
  lwIP TCP/IP Stack", Swedish Institute of Computer Science, 2001.
- Mbed TLS, the TLS library.
- Notty (David Kaloper Meršinjak) and uutf (Daniel Bünzli), the OCaml
  terminal libraries under the editor `edit`.
- kilo, the small C editor, by Salvatore Sanfilippo.
- Terminus, the bitmap font of the graphical session, by Dimitar Zhekov.
- Num, OCaml's numbers of any size (INRIA): github.com/ocaml/num.
- 2048-ml, the game, by Philip Xu: github.com/pyx/2048-ml.
- In the packages: CAMLBOY, a Game Boy emulator, by linoscope; Tobu Tobu
  Girl, by Tangram Games; GavML, a rewrite in OCaml of GAV (GPL Arcade
  Volleyball), with GAV's pictures; Ocs, a Scheme, by Ville-Pertti
  Keinonen; Infocom's Zork I–III, story files released by Microsoft under
  the MIT licence in 2025.
- Mozilla's list of certificate authorities.

# Appendix J. Bibliography

Works that shaped MyNOS, or this manual, or that a reader who wants to go
further will enjoy. Grouped by subject; within each group, by year.

## J.1 The manuals this one imitates

The typeset edition of this manual borrows its form from the manuals of
1965–1991. Scans of all of them circulate in the archives of
bitsavers.org, the Unix Heritage Society and multicians.org.

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
- *MS-DOS 3.3 User's Guide*. 1987. The command reference, one command per
  page.
- *Apollo Domain/OS Design Principles*. Apollo Computer, 1989. An
  operating system's architecture told as an essay.
- *Macintosh System 6.0.4 User's Guide*. Apple Computer, 1989. Teaching a graphical session one figure at a time.
- *OS/2 2.0 Technical Library*. IBM, 1991–1992.

## J.2 The processor, the boot, and the first steps

- R. A. Burgess. *Developing Your Own 32-bit Operating System*. Sams
  Publishing, 1995 (ISBN 978-0-672-30655-6). A whole protected-mode
  operating system for the 386, explained and listed; in 2002 the book
  that showed MyNOS's authors how to begin the real implementation.

- *Intel 80386 Programmer's Reference Manual*. Intel, 1986. The source
  of the 2002 notes in `mynos-core/doc/MyNOS-note.txt`: segments, paging,
  task state segments, interrupts.
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
- J. Liedtke. "On µ-Kernel Construction". *15th ACM Symposium on
  Operating Systems Principles (SOSP)*, 1995. Why a microkernel must be
  small and its IPC fast; the origin of the L4 family.
- G. Klein et al. "seL4: Formal Verification of an OS Kernel". *22nd ACM
  SOSP*, 2009.

## J.4 Systems in safe languages

- N. Wirth, J. Gutknecht. *Project Oberon: The Design of an Operating
  System and Compiler*. Addison-Wesley, 1992.
- S. Dorward, R. Pike, D. L. Presotto, D. M. Ritchie, H. Trickey,
  P. Winterbottom. "The Inferno Operating System". *Bell Labs Technical
  Journal* 2(1), 1997. Limbo, a safe language, on a virtual machine.
- T. Hallgren, M. P. Jones, R. Leslie, A. Tolmach. "A Principled
  Approach to Operating System Construction in Haskell". *ICFP*, 2005.
  House.
- G. C. Hunt, J. R. Larus. "Singularity: Rethinking the Software Stack".
  *ACM SIGOPS Operating Systems Review* 41(2), 2007. Processes isolated
  by the language, and typed channels with contracts: the closest
  relative of MyNOS's typed IPC.
- A. Madhavapeddy et al. "Unikernels: Library Operating Systems for the
  Cloud". *ASPLOS*, 2013. MirageOS, an operating system in OCaml.

## J.5 OCaml

- X. Leroy et al. *The OCaml System: Documentation and User's Manual*.
  INRIA, current edition (5.5). The language, the bytecode compiler, the
  runtime, and the libraries MyNOS links.
- X. Leroy. "The ZINC Experiment: An Economical Implementation of the ML
  Language". INRIA technical report 117, 1990. The ancestor of the
  bytecode machine that runs every MyNOS program.
- K. C. Sivaramakrishnan, S. Dolan, L. White, S. Jaffer, T. Kelly,
  A. Sahoo, S. Parimala, A. Dhiman, A. Madhavapeddy. "Retrofitting
  Parallelism onto OCaml". *ICFP*, 2020. The domains.
- K. C. Sivaramakrishnan, S. Dolan, L. White, T. Kelly, S. Jaffer,
  A. Madhavapeddy. "Retrofitting Effect Handlers onto OCaml". *PLDI*,
  2021.

## J.6 The software inside MyNOS

Each comes with its licence in `third_party/`.

- musl, the C library: musl.libc.org.
- lwIP, the TCP/IP stack: A. Dunkels, "Design and Implementation of the
  lwIP TCP/IP Stack", Swedish Institute of Computer Science, 2001.
- Mbed TLS, the TLS library.
- Notty and uutf, the OCaml terminal libraries under the editor `edit`.
- kilo, the small C editor.
- Terminus, the bitmap font of the graphical session.

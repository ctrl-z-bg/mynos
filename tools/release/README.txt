MyNOS @VERSION@
===============

MyNOS ("My! Not another Operating System") is an experimental operating
system for 32-bit PCs: a microkernel in C, and above it everything else,
the file systems, the drivers, the shells, the windows, as processes,
most of them written in OCaml. Written in 2002-2004 by Cesare Zavattari,
Alessandro Tommasi and Tommaso Schiavinotto; taken up again in 2026 with
the help of AI. Logo by Luigi Ferrini.

This archive runs it in QEMU. Nothing else is needed.


Running it
----------

1. Install QEMU:
     Debian, Ubuntu:  sudo apt install qemu-system-x86
     Fedora:          sudo dnf install qemu-system-x86
     macOS:           brew install qemu

2. In this directory:
     ./run-mynos.sh

   A window opens; MyNOS boots in a few seconds to its shell, sh.

Options (./run-mynos.sh --help):
  --serial       this terminal is a console of MyNOS too
  --no-net       no network
  --http PORT    the host port for MyNOS's web server (default 8080;
                 if QEMU stops at once because the port is taken, use
                 another, or --http 0 for none)
  --mem MB       memory (default 2048; MyNOS uses at most 3072)
  --no-kvm       emulate the processor even if KVM is there
  --no-sound     no sound card (by default one, through the host's audio)
  --udp PORT     this machine's UDP port forwarded to MyNOS's (GavML's
                 network game: --udp 7145)
  --display UI   QEMU's window: sdl by default with sound (QEMU's gtk
                 window could freeze while the card played), or gtk...
  --reset-disk   start /disk again, empty
  -- OPTIONS     passed to QEMU (e.g. -- -display none, with --serial)


What to try
-----------

  help                 the shell's commands
  ls /disk; edit /disk/notes.txt     a file of your own (Ctrl-S, Ctrl-Q)
  ocaml                the OCaml toplevel (#quit;; to leave)
  trace ls /disk       what the processes said to each other
  ps; log              the processes; the kernel's messages
  version              this version
  gui                  the graphical session: the Tour explains how an
                       operating system works, with MyNOS as the specimen
  shutdown             turns the machine off

/disk is the file disk.img here: what you save there is kept between
runs. / is the system, read-only; /tmp is in memory.


Language models (optional)
--------------------------

The agent, llm and ask need a model: copy llm.env.example to llm.env
here, put in your key, and run again (run-mynos.sh copies it into the
disk if mtools' mcopy is installed); or write /disk/llm.env with edit,
inside MyNOS. Without it, everything else works.


Source, manual and licence
--------------------------

Source: @URL@ (this build: commit @COMMIT@).
The manual: doc/manual/ in the source.

MyNOS is free software, under the GNU General Public License, version 2
or (at your option) any later version. It contains software of others,
under their own licences, in licenses/: the OCaml runtime (LGPL with the
OCaml linking exception), lwIP (BSD), Mbed TLS (Apache 2.0 or GPL 2.0+),
Notty and uutf (ISC), kilo (BSD), the Terminus font (SIL OFL 1.1), and
Mozilla's certificate authorities (MPL 2.0).

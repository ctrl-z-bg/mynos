# Appendix H. Building and Testing MyNOS

MyNOS is built on a Linux host, inside a container, and run in QEMU. This
appendix describes the toolchain (H.1–H.3), the build (H.4), the two
disks a running system uses (H.5), the scripts that boot it (H.6), the
test suite (H.7), the screenshots (H.8), the packages (H.9), debugging
(H.10), and the rules the project follows when it changes (H.11). Every script named here is in
`tools/`, and every one starts with a comment that says how to use it.

## H.1 One toolchain: the `dev` container

All the code that runs inside MyNOS, the kernel included, is compiled in
one container image, `mynos-dev`, defined by
`tools/containers/dev/Containerfile`. The host's compilers are never
used: the result does not depend on the distribution of the machine that
builds it.

| Component | Version | What it builds |
|---|---|---|
| Debian 13 "trixie", i386 | 13.7 | the base: a 32-bit userland, like the target |
| gcc | 14.2 | the kernel, the C services, libmynos |
| binutils | 2.44 | |
| nasm | 2.16 | `kernel/arch/i386/start.asm` |
| musl (`musl-gcc`) | 1.2.5 | the C library of every user-space C program |
| OCaml | 5.5.2, bytecode only | the OCaml programs, and the runtime (below) |
| dosfstools, mtools | | FAT images, and files copied in and out of them |

(The versions are those the image reports today: `gcc --version`, `ld
--version`, `nasm -v`, `ocamlc -version`, `dpkg -l musl`.)

The image is built in three stages. The first downloads OCaml's sources
and checks their SHA-256. The second builds OCaml twice from them: once
for the build host, as the compiler (`/opt/ocaml-5.5.2`), and once with
`musl-gcc`, static, keeping only the bytecode runtime's library
(`libcamlrun.a`), its primitive table, its headers, and the C sources of
the `unix` and `threads` libraries (`/opt/ocaml-runtime-musl`). The third
is the toolchain itself, with the compiler on the `PATH` and three
variables that the Makefiles read: `MYNOS_CC`, `MYNOS_LDFLAGS` and
`OCAML_RUNTIME_LIB`. `mynos-runtime/Makefile` then links MyNOS's own
`ocamlrun` from that library, MyNOS's `main()`, and the primitives of the
`Mynos` library (appendix F).

```
  tools/containers/build-image.sh dev       build the image (once)
  tools/in-container.sh dev COMMAND...      run a command in it
  tools/in-container.sh dev                 an interactive shell
```

`in-container.sh` runs `podman run --rm --platform linux/386` with the
repository mounted at `/mynos` (the working directory). Podman runs
rootless: the container's root is the user, so the files the build
writes belong to the user.

## H.2 The toolchain that was retired

Until 2026-11-18 a second container rebuilt the same C code with the
original project's tools: Debian 5.0 "lenny", gcc 4.3.2, dietlibc 0.31,
and OCaml 3.06 (`mynos-byterun/`), so that the two builds of the same
code could be compared while the system was ported. It was retired
(mynos-g8l) when it no longer found anything the `dev` toolchain did
not, and cost half an hour for each change to the kernel or the library.
(The serious bugs of the port were old ones that the 2008 compiler had
hidden: `doc/JOURNAL.md`, 2026-11-16.) The last commit it
builds is tagged **`legacy-last`**; there, the legacy container's
definition is still in `tools/containers/legacy`, and the scripts take
the toolchain as an argument:

```
  git checkout legacy-last
  tools/containers/build-image.sh legacy
  tools/build-all.sh legacy
```

Two older tags mark the history: `legacy-2008`, the last original commit
(2008-11-25), and `revival-baseline`, the original system running again
with its period toolchain (2026-11-16).

## H.3 `mynos.mk`

Programs that run on MyNOS are static Linux i386 executables, which the
kernel loads at `0x40000000` (appendix B). The user-space C Makefiles
(libmynos, the C services, `mynos-runtime`, kilo, the stress and ABI
tests) include `mynos.mk`, which defines how to link them:

```
MYNOS_CC      ?= musl-gcc
MYNOS_LDFLAGS ?= -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code \
                 -Wl,--build-id=none
```

- `-Ttext-segment` moves the whole image to `0x40000000`. `-Ttext` is not
  enough: musl's `crti` has an `.init` section that it would leave at
  the default address.
- `-z noseparate-code` and `--build-id=none` keep the image simple: no
  padding to separate the code from the other segments, no build-id
  note. The kernel loads the segments as one contiguous image from
  `0x40000000` and jumps to the ELF entry point.

The `?=` lets the container's environment, which sets the same values,
take precedence. The kernel does not use `mynos.mk`:
`mynos-core/CommonHeader` compiles it with the container's own `gcc`,
`-nostdinc -fno-stack-protector -fno-pie -g` and no optimization flag, and
`kernel/Makefile` links it at `0x200000` (`-Ttext 0x200000`).

OCaml programs are compiled with `ocamlc`; those that use the `Mynos`
library add `-use-prims mynos-runtime/primitives -I mynos-lib/ocaml
mynos.cma`, so that the linker knows the primitives of MyNOS's runtime.

## H.4 Building

```
  tools/build-all.sh          build everything, in the container
  tools/clean-all.sh          remove every build output
```

`build-all.sh` runs one shell in the container, with `-e`: the first
error stops it. In order, it builds:

1. the kernel (`mynos-core/kernel`: `kernel.elf`);
2. libmynos (`mynos-lib`);
3. the C services of `services/`: memrofs and its `createDisk` tool,
   keyboardd, seriald, the registry, consoled;
4. the OCaml runtime (`mynos-runtime`: `ocamlrun` and `primitives`),
   and Num (`third_party/num`);
5. the C tests (`tests/abi`, `tests/stress`, `tests/bench`, `tests/fpu`,
   `tests/stdio`);
6. the OCaml library (`mynos-lib/ocaml`: `mynos.cma`, with `Tracer`,
   `Gui` and the protocol modules);
7. the OCaml tests and their RAM disks (`tests/mynos-ocaml`, `console`,
   `files`, `spawn`, `hello`, `greeter`, `effects`, `domains`, `threads`,
   `keys`, `ramdisk`);
8. the programs: kilo and Notty (`third_party`), `edit`, `sh`, `init`;
9. the OCaml services and their tests: `tmpfs`, `clipboard`, `ata`,
   `fatfs`, `pagerd` and `mapcat`, `tests/storage`, `tests/libs`,
   `tests/fat` (with its FAT16 and FAT32 images);
10. the network: `netd`, `httpd`, `trace`, `log`, `play`, `fetch`,
    `llmd`, `llm`, `agent`;
11. the graphics and sound: `displayd`, `soundd`, `gui` (the session and its windows),
    `graphics` (OCaml's `Graphics`);
12. `tests/net`, `shell` (the OCaml toplevel), `pkg`, and `system`: the
    system RAM disk and the disk image (H.5); last the manual's examples
    and the packages (H.9).

Most steps are `make`, and so incremental; the small OCaml tests are
compiled again every time. `clean-all.sh` calls `make clean` in the same directories, and removes
the test programs and RAM disks; `tools/clean-all.sh` then
`tools/build-all.sh` is a build from scratch. It keeps `system/disk.img`
on purpose (H.5).

**Other architectures** (the version 2 line, branch `next`) build apart,
each in its own copy of the sources, so that objects never mix:

```
  tools/build-x86_64.sh       x86-64, in build/x86_64/tree (dev-x86_64)
  tools/build-aarch64.sh      AArch64, in build/aarch64/tree (dev-aarch64:
                              a cross toolchain and QEMU's AArch64 emulator)
```

Each runs `build-all.sh`'s list in its container, with its own kernel
build (`tools/build-kernel-x86_64.sh`, `tools/build-kernel-aarch64.sh`).
AArch64's kernel build makes two kernels: `build/aarch64/kernel.elf` for
QEMU's `virt`, and `build/aarch64/kernel8.img` for a Raspberry Pi 3 or
Zero 2 W (the same sources, `MYNOS_RASPI`); the programs are the same.

## H.5 The two disks

**The RAM disk** is a GRUB module (a QEMU `-initrd` module) whose first
bytes are `.RAMDISK`. The kernel finds it among the modules; the
service `memrofsd` serves it as `/`, read-only. Its format is made by
`services/fs/memrofs/tool/createDisk` (2002), a host program:

```
   0  ".RAMDISK"                          8 bytes
   8  1,000 entries: name (64 bytes), start, size
      the files, one after the other      start: offset from the image's start
```

The disk is flat: a file is named by its base name, which must be
shorter than 64 bytes, and there can be at most 1,000. `createDisk FILE...`
writes `ramdisk.dsk` in the current directory. The entry holds a C
pointer for `start`, so the tool must be built for 32 bits, as it is in
the i386 container, with the container's plain `gcc`. (Its Makefile was
once copied from the services', and it was built as a MyNOS program:
journal, "Bug 3".)

`system/Makefile` makes the system RAM disk, `system/ramdisk.dsk`, from
about 170 files today: `init.byte` and `init.rc`; `ocamlrun`,
`consoled`, `netd`, `displayd`, `soundd` and `kilo`, stripped of their debugging
information; the OCaml programs and services; fonts, logo and
certificates; and what is needed to compile OCaml inside MyNOS: the
bytecode compiler `ocamlc.byte`, the standard library's `.cmi` files and
`stdlib.cma`, `unix.cma`, `threads.cma`, `str.cma`, `nums.cma`,
`graphics.cma`, `mynos.cma` and the interfaces of
its modules, and the `primitives` list.

**The disk image** `system/disk.img` is the demo's hard disk, mounted at
`/disk` by `fatfs`:

```
  mkfs.fat -C -F 32 -n MYNOS disk.img 65536      a 64 MB FAT32 image
```

with a `README.TXT`. It is made once, when missing, and then kept: it
holds what is saved in MyNOS (the shell's history, programs, the keyboard
layout). Neither `make clean` nor `clean-all.sh` removes it; to start
again with an empty disk, delete it and build. It is not in git (`*.img`).

## H.6 Running

**Other architectures.** `ARCH=x86_64 tools/run-demo.sh` runs the
x86-64 build, with four processors (`SMP=N` for another number);
`ARCH=aarch64 tools/run-demo.sh` the AArch64 one, four processors too,
on QEMU's `virt`
machine, with virtio's disk, network card, keyboard, tablet and GPU.
AArch64 has no text screen: its console is the terminal, on the
machine's one UART (which plays COM2: the log and a terminal's keys);
`Ctrl-A X` stops it. QEMU's window shows the graphical session, which
`gui` starts. QEMU's AArch64 emulator is the host's if it has one
(Debian and Ubuntu: the package `qemu-system-arm`), else the
`dev-aarch64` container's (without a window).

**A Raspberry Pi.** `ARCH=aarch64 MACHINE=raspi3b tools/run-demo.sh`
runs `kernel8.img` on QEMU's Raspberry Pi 3: its four processors, its
1 GB, the console on the screen (the framebuffer) and the terminal (the
UART), the disk on its SD card. It has no network, keyboard or mouse
yet: the terminal is the keyboard. `tools/make-sd-raspi.sh` makes an SD
card image for a real Pi 3 or Zero 2 W (`tmp/mynos-raspi.img`): the
Pi's firmware (downloaded once, at a fixed version, checked), its
`config.txt`, the kernel and the modules, on one FAT32 partition that is
also `/disk`. Written to a card (`dd`), it boots on the Pi; its terminal
is the UART on GPIO 14 (TX) and 15 (RX), 115200 baud, 3.3 V.

**A release.** `tools/make-release.sh` makes
`tmp/release/mynos-VERSION.tar.gz` and its `.sha256`, for people who
have only QEMU: the ISO, a clean disk (`disk-clean.img`), `run-mynos.sh`
and `README.txt` (from `tools/release/`), `llm.env.example`, and the
licences (MyNOS's GPL 2 and the third parties'). It refuses a `VERSION`
that is not the current commit's (build again), and warns about
uncommitted changes. Chapter 5.2 is the user's side.

**MyNOS in the browser.** `tools/make-web.sh RELEASE_DIR` makes
`tmp/web`, a static site that runs a release's ISO and clean disk on
v86, without network: `tools/web/index.html`, v86 and SeaBIOS
(downloaded at fixed versions, checked by sha256), and the two images cut
in chunks of 1 MB compressed with zstd (`mynos-0-1048576.iso.zst`...),
which v86 fetches only when the guest reads them: about 10 MB in all,
of which the empty disk is a few kilobytes.

**Publishing.** `tools/publish-release.sh`, on a built, committed and
pushed tree, runs both, creates the GitHub release `vVERSION` with the
archive, its checksum and the notes of `tools/release/release-notes.md`, and
pushes `tmp/web`, alone, to the `gh-pages` branch, which GitHub Pages
serves. It needs `gh`, GitHub's command line, logged in.

**A bootable ISO.** `tools/make-iso.sh [OUT]` (default `tmp/mynos.iso`,
not kept by git) puts GRUB for PC BIOS, the kernel and the four modules of
`run-demo.sh` on a CD image, with `grub-mkrescue` in the container
(`grub-pc-bin`, `xorriso`). Beside it, `tmp/mynos-disk.img`: a clean disk,
made anew every time with `system/Makefile`'s recipe (an empty FAT32 and a
`README.TXT`), never a copy of the developer's `system/disk.img`, which
holds `llm.env` and their files. They boot as a real PC would:
`qemu-system-i386 -boot d -cdrom tmp/mynos.iso -m 256`, with
`-drive file=tmp/mynos-disk.img,format=raw,if=ide,index=0` for `/disk` and
`-netdev user,id=n0 -device ne2k_isa,netdev=n0,iobase=0x300,irq=9` for
the network (`-boot d`: a FAT disk is not bootable, and the BIOS would
stop on it). GRUB passes a module's arguments after its file name, so
`grub.cfg` names each program again (`module /boot/ocamlrun ocamlrun`).

```
  tools/run-demo.sh [-- QEMU OPTIONS...]          the standard system
  tools/run-qemu.sh MODULE... [-- QEMU OPTIONS]   any set of modules
```

**`run-qemu.sh`** boots `kernel.elf` with QEMU's multiboot loader
(`-kernel`): no GRUB image is needed. Each argument before `--` is a
module, in order, with its arguments in the same word (`"tests/abi/abi one
two"`); what follows `--` goes to QEMU. With no module it runs
`run-demo.sh` instead. Without `KVM` the processor is emulated, as in the
tests. Its environment:

| Variable | Default | Effect |
|---|---|---|
| `MEM` | 32 | RAM in MB |
| `CPU` | `qemu32,+rdrand,+rdseed` | the processor; RDRAND and RDSEED seed the kernel's random numbers |
| `DISK` | none | a raw image as the first IDE disk |
| `NET` | none | an NE2000 card at I/O `0x300`, IRQ 9, on QEMU's user network (MyNOS is 10.0.2.15 by DHCP, the host 10.0.2.2) |
| `HTTP` | none | with `NET`, this host port (on 127.0.0.1) forwarded to MyNOS's port 80 |
| `UDP` | none | with `NET`, a UDP port of the host forwarded to the same port of MyNOS |
| `VERBOSE` | none | `verbose` on the kernel's command line: its messages stay on screen |
| `KVM` | none | `-accel kvm`: the host's processor runs MyNOS's |
| `VIRTIO` | none | the disk and the network card as virtio devices (`virtio-blk-pci`, `virtio-net-pci`) instead of IDE and NE2000 |
| `SOUND` | none | a Sound Blaster 16 (`-device sb16`) heard through this QEMU audio backend, or recorded with `wav:FILE` |
| `KERNEL` | `mynos-core/kernel/kernel.elf` | another kernel |
| `KERNEL_ONLY` | none | with no module, boot the bare kernel |
| `SHOT` | none | run headless, wait `WAIT` seconds (3), save the screen as an image (with ImageMagick's `convert`), stop |

**`run-demo.sh`** boots the system: the kernel, `ocamlrun` (from
`mynos-runtime/`, not stripped), the registry, `memrofsd`, and
`system/ramdisk.dsk`. `ocamlrun` finds `init.byte` on the RAM disk, and
`init` starts what `init.rc` lists (E.3): `consoled`, `tmpfs`,
`clipboard`, `ata`, `fatfs`, `pagerd`, `netd`, `displayd`, `soundd`,
`llmd`, `httpd`, `pkg boot`, and `sh`, started again whenever it ends. The script sets:

- `MEM=2048` (2 GB; MyNOS uses at most 3583 MB, B.15), and `DISK=system/disk.img` if the image exists;
- `NET=1` unless `NET` is set (`NET=` boots without a network card);
- `KVM=1` if `/dev/kvm` can be used, unless `KVM` is set (`KVM=`
  emulates the processor);
- `SOUND` to the host's audio backend that QEMU has (PipeWire,
  PulseAudio, ALSA, Core Audio), unless `SOUND` is set (`SOUND=`: none);
- QEMU's window to SDL's when there is sound, unless `QEMU_DISPLAY` is
  set or a `-display` follows `--` (GTK's froze while the card played);
- `UDP=PORT`, if given, forwards that UDP port of the host to MyNOS's;
- `HTTP=8080` if that host port is free, so that `http://localhost:8080/`
  is MyNOS's `httpd`; `HTTP=PORT` chooses another;
- with `SERIAL=1`, the host's terminal becomes MyNOS's second serial
  port, which is a console of MyNOS too (`doc/decisions/console.md`):
  copy and paste, scrollback and fonts are the terminal's. Ctrl-C goes to
  MyNOS; Ctrl-A then X stops QEMU.

**`llm.env`** is a file on the host, in the repository's root, with the
configuration of the language model providers (`llm.env.example`
describes it). If it exists and there is a disk, `run-demo.sh` copies it
into the disk image as `/disk/llm.env`, where `llmd` reads it. It is
listed in `.gitignore`: it holds keys, and never enters the repository.

**The log.** Once user space starts, the kernel writes its messages, and
the services theirs (`mynos_log`, native call 31), to the second serial
port (COM2, `0x2F8`) only; it also copies there every character written
to the text screen. QEMU's first `-serial` option is COM1 and the second
COM2, so the log is kept with

```
  tools/run-demo.sh -- -serial null -serial file:mynos.log
```

which is what the tests do.

## H.7 The test suite

```
  tools/run-tests-all.sh                  every architecture's suite at once
  tools/run-tests.sh                      everything; exit status 0 if all passed
  ARCH=x86_64 tools/run-tests.sh          the same, in build/x86_64/tree
                                          (four processors; SMP=1 for one)
  tools/run-tests-all.sh aarch64          AArch64's, in build/aarch64/tree
  LANES="d" tools/run-tests.sh            only lane d
  KEEP=1 tools/run-tests.sh               keep the logs and screens, say where
  SHOTS=DIR tools/run-tests.sh            copy the graphical session's screens to DIR
```

The tests start QEMU, headless, twenty-three times (one of these runs
restarts MyNOS three times), with different sets of modules and RAM
disks, and check what each boot did.
The boots run in nine **lanes** at once, each lane a subshell running its
boots one after the other; lanes share nothing (each has its own files,
monitor sockets and host ports). The whole run lasts as long as its
longest lane: lane d, under 4 minutes without KVM (measured on
2026-11-25: a 125 s, b 67 s, c 55 s, d 229 s, e 151 s, f 136 s, g 118
s, h 85 s, i 176 s). At the end the script prints each section's time,
and each lane's.

Where it can, a lane waits for what it is about to check rather than for
a fixed time: the toplevel's next prompt, a mark that `sh` echoes after a
command (`echo mark-$M:`, so that the typed line does not match), the
pixels of a window that has opened. `tools/run-tests-all.sh` runs the
suite of every architecture at once, each in a container
(`tools/containers/test`) with a network of its own, so that their host
ports do not meet: the i386's and the x86-64's in about 4 minutes.

| Lane | Boots |
|---|---|
| a | `hello.byte` with the first services and `tests/abi` (system call checks); effect handlers; `ata` on a 2,048-sector disk; `fatfs` on FAT16 and FAT32 images; domains; threads; each thread's FPU state |
| b | the `Mynos` library; files read through the standard library; Str and Num; the kernel stress test; `init` spawning about twenty-five programs; the console, typed on the keyboard and on COM2 |
| c | the system without COM2 (as QEMU's window starts it), then `shutdown -r`; four boots in a row through `shutdown -r` |
| d | the graphical session: windows, the mouse, the terminal, the agent window, Recordings, System, Files, the tour, `shutdown` |
| e | the network, against servers on the host; then the "seventh boot", the system RAM disk driven through the keyboard, in four parts that boot at once: here the toplevel, `sh`, the editors, `trace` |
| f | the seventh boot's second part: the agent, `kill`, threads compiled inside MyNOS, `httpd`, C's stdio |
| g | its third: packages installed from the host, the tools they bring |
| h | its fourth: Ctrl-C, a killed service restarted, `fatfs`'s cache, the serial terminal |
| i | the graphical session again, its own boot: OCaml's Graphics, key releases, a resized window, Packages, Text, Studio (its windows opened in the same order as in lane d's session, so that they are where the clicks expect them) |

**How a boot is observed.** MyNOS has no test harness inside it; the
script watches it from outside, in several ways:

- **The log port.** Every boot sends COM2 to a file (`-serial null
  -serial file:...`). Test programs print lines such as `stress: all
  checks passed`. After all lanes end, the parts are joined into one log
  and checked by `expect TEXT` (a fixed string that must appear) and
  `reject TEXT` (one that must not: `PANIC`, `page fault (?)`, `Problems
  releasing pages`, `kernel heap:`, `FAIL`).
- **The keyboard.** QEMU's monitor, on a Unix socket, takes `sendkey`
  commands: `tools/type-keys.py SOCKET TEXT...` types text on a US
  layout, `\n` as Enter, `^D` as Ctrl-D, `{name}` as any QEMU key
  (`{up}`, `{ctrl-s}`, `{alt_r-semicolon}`). The mouse is moved by
  `mouse_move` in steps of at most 40 pixels.
- **The screen.** In text mode, the monitor's `xp /2000hx 0xb8000` reads
  VGA's memory, so a test can find a string on the screen, or check
  how a UTF-8 character was drawn in code page 437. In graphics mode,
  `screendump` saves a PPM image, and Python checks pixels: an exact
  colour at a point (`0x111820` for the top bar), or how many pixels of a
  colour a region holds (a window's boxes, a red arrow in the System
  window, the orange marks of a recording). Lane d takes 22 screens.
- **The disk.** After a boot the script reads the disk image with mtools
  (`mtype`, `mdir`, in the container) and checks it with `fsck.fat -n`:
  what MyNOS wrote must be there, and the file system consistent. The
  recorder's outputs (`calls.txt`, `t.json`, `r1.txt`…) come back this
  way and are checked as in appendix G.14.
- **The host's side.** `tools/net-peer.py` plays the servers MyNOS talks
  to; `tools/serial-peer.py SOCKET LOG INPUT` is a terminal on COM2,
  logging what MyNOS writes and sending what is appended to `INPUT`.
- **The machine itself.** `shutdown` must make QEMU end by itself (ACPI
  power off); `shutdown -r` under `-no-reboot`, the same.

| Port (host) | `net-peer.py` mode | For |
|---|---|---|
| 47001 | `echo` | TCP: a line back in capitals |
| 47053 | `udpecho` | UDP: a datagram back in capitals |
| 47080 | `fetch` | the host fetches a page from MyNOS's `httpd` (`HTTP=47080`) |
| 47443–47445 | `https` | HTTPS with a good, an untrusted and a wrongly named certificate (`tests/net/tls`) |
| 47101, 47102 | `files` | `tmp/packages`, for `pkg` (seventh boot, lane d) |
| 47090, 47091 | `llm` | a fake language model provider, speaking both Claude's Messages API and Chat Completions, checking the requests' headers and shapes; 47091 for lane d |

The disks of the graphical session and of the seventh boot are copies
of `tests/fat/fat16.img`, made in `tests/fat/` and deleted after the
boot, with files put in by mtools first: the fake provider's `llm.env`,
`tests/greeter/greeter.byte`, and, for the graphical session, the old
recording of appendix G.10.

**Variables.**

| Variable | Effect |
|---|---|
| `LANES` | the lanes to run (default `a b c d e f g h i`); the checks of the others then fail, so read only those of the lanes run |
| `KEEP` | keep the temporary directory (logs, screens, monitor sockets) and print its name |
| `SHOTS` | a directory where lane d's screens are copied (PPM) |
| `WAIT` | how long, in seconds, the boots that run unattended are left running before QEMU is stopped; the default is 10, 15 or 20 depending on the boot |
| `WAIT_STRESS`, `WAIT_NET` | the same for the stress test (120) and the network (40); both end earlier when their result line appears |

The boots driven through the keyboard wait for the shell on the log
(its prompt `mynos:/`, or its banner) or for a fixed time, then pace
themselves with fixed `sleep`s. When a check fails the script prints the
whole log after the results, and exits with status 1; otherwise its last
line is `all tests passed`. The full run is the check before a commit.

The host needs, besides podman: `qemu-system-i386`, `socat`, `python3`,
`timeout`, `curl`, and `fsck.fat` (dosfstools).

## H.8 Screenshots

`tools/screenshots.sh [DIR]` (default `doc/screenshots`) boots the system
headless on a clean disk made there (never `system/disk.img`), drives
it as the tests do, and saves the manual's figures as PNG images:
thirteen, and the agent's two more in a second boot if `llm.env`
exists. `tools/ppm2png.py` converts QEMU's PPM screens.

## H.9 Packages

The packages `pkg` installs (chapter 9, 9.8) are described in the main
repository and published in another, `ctrl-z-bg/mynos-packages`, which
holds only what `pkg` downloads:

```
  index.json                      the packages: name, version, description,
                                  licence, archive, size, BLAKE2b-256 hash,
                                  the MyNOS they were built on
  packages/NAME-VERSION-HASH.tar  one archive per package and build (HASH:
                                  the start of its BLAKE2b-256)
```

Each package is a directory of `packages/` in the main repository with a
file `spec`, shell assignments read by `tools/pkg-build.sh`:

```
NAME=windtree
VERSION=1.0
DESCRIPTION='A tree in the wind: ...'
LICENSE=GPL-2.0-or-later
LIBRARIES=graphics                    unix, threads, str, num, graphics
SRC=doc/manual/examples/20            where the sources are
SOURCES=tree.ml                       in the order to compile them
EXTRA=                                more files: a licence, a README
```

Other fields, when a package needs them: `COMMANDS` (several commands
of one program, installed as scripts that run it), `DEPENDS` (packages
installed first), `RUN` (the window the Packages window starts), `DOC`
(its documentation). A package without `SOURCES` is data (a story, a
game's ROM), played by the package it depends on. The comment at the top
of `tools/pkg-build.sh` describes them all.

`tools/pkg-build.sh OUTDIR`, in the container, compiles each package
against the tree's runtime and libraries, as `pkg -s` would inside
MyNOS (in the sources' directory, with `-noautolink mynos.cma` and the
libraries named), and writes `OUTDIR/index.json` and the archives. An
archive holds `package.json` (the spec's fields, the program's name and
the MyNOS version), the bytecode, `src/` and the extra files; it is made
the same way each time (names sorted, owner and date 0), so an unchanged
package keeps its hash. `tools/build-all.sh` builds them into
`tmp/packages`, which the test suite serves to MyNOS from the host
(`tools/net-peer.py files`).

To publish: build, then `tools/pkg-publish.sh CLONE` (a clone of
`mynos-packages`) copies the new index, its archives and the packages'
documentation, keeps the archives of the index it replaces and removes
older ones; commit and push the clone. GitHub serves raw files from a
cache for five minutes: a cached index must still find the archives it
names, and a new archive, having its hash in its name, was never cached. A package whose sources changed gets
a new `VERSION`, so that `pkg list` shows the installed one as older.

**Trying packages before publishing them.** `PKG=local tools/run-demo.sh`
serves `tmp/packages` (what `tools/build-all.sh` just built) to MyNOS
from the host, on port 47120 (`PKG_PORT` another), and writes on the
disk `/disk/pkg/url`, which names it, and `/disk/pkg/autoupgrade`. At
boot `init` runs `pkg boot`, which then does a `pkg upgrade`: every
installed package whose archive is not the index's (a new version, or
the same version built again: `installed` keeps the archive's hash) is
installed again. So: change a package, `tools/build-all.sh`, `PKG=local
tools/run-demo.sh`, and the installed one is the new one; new packages
with `pkg install`. Without `PKG=local`, `run-demo.sh` takes those two
files away, and `pkg` reads GitHub again.
What `pkg boot` installs goes to the system's log (the Log window,
`log`), not to the console. A package built again the same, on a newer
MyNOS, keeps its archive (`pkg-build.sh` compares it with the previous
one but for its `"mynos"` field): only the packages that changed are
installed again.

A package's documentation may have pictures: `packages/NAME/images/`,
named in its README as `images/FILE.png`. Its page in `mynos-packages`
is then a folder, `docs/NAME/` (the README and the pictures); the archive
keeps the text only, which MyNOS's Markdown viewer shows without them.
The pictures are made by a script, not by hand: `tools/pkg-shots.sh
NAME` starts MyNOS headless on a clean disk (with the files of
`packages/NAME/shots/` in `/disk/NAME/`), installs the package from
`tmp/packages`, opens the graphical session and follows
`packages/NAME/shots.sh`, which types, clicks and takes the screen with
the functions the tool's comment lists. A script that sets `AGENT=1`
gets a copy of `llm.env` on that disk for the agent's pictures; the disk
is removed at the end. Look at the pictures before committing them.

## H.10 Debugging

The kernel is built with `-g` and without optimization, so a debugger
sees its source as written:

```
  tools/run-demo.sh -- -s -S          QEMU waits, with a gdb server on port 1234
  gdb mynos-core/kernel/kernel.elf
  (gdb) target remote :1234
```

The `ocamlrun` given as a boot module is `mynos-runtime/ocamlrun`, with
its symbols; the copy on the RAM disk is stripped.

Three QEMU facilities come back again and again in the diagnoses of
`doc/JOURNAL.md`:

- **`-d int`** logs every interrupt and exception, with the address
  where it happened (and CR2 for a page fault); `nm` or `addr2line -e
  kernel.elf` then names the function. Add `-D FILE` to send the log to a
  file, and `-no-reboot` to stop at a triple fault instead of rebooting.
- **gdb attached to a hung system**: where every thread is, and, with a
  gdb script, the kernel's queues and semaphores.
- **The monitor**: `info registers`, repeated, samples where the
  processor spends its time. That is how the shell's 32-second start was
  traced to the idle thread (journal, "Thirty-two seconds to a prompt").

**The stress test** (`tests/stress/stress.c`, lane b) runs as a boot
module with a RAM disk holding itself, and starts copies of itself as
clients. It checks: 120 clients sending messages from 1 byte to 64 KB,
four at a time; 20 rounds of 16 threads whose timers expire together;
5,000 semaphore ping-pongs between threads; invalid arguments, unknown
system calls and bad pointers refused while the kernel lives; privileges
and owners; a page unmapped while `recv` waits; that programs still
start afterwards; and that the memory comes back (within 4 pages).
`stress N` repeats its rounds N times: a long run for a kernel change.

Above the kernel, the event recorder (appendix G) is the first tool:
`trace COMMAND` shows which process asked which for what, and how long
each step took.

## H.11 How the project works

- **`doc/STATUS.md`** describes the architecture and the current state.
  A change that alters the state (something builds, runs or breaks, a
  shortcut is removed, a decision is taken) updates it in the same
  commit: "Current state", a dated line in "Work log", "Last updated".
- **`doc/JOURNAL.md`** is the engineering diary: every non-trivial
  finding (a bug, a surprising cause, a design decision) gets an entry
  with symptom, diagnosis, cause, fix and lesson, in the same commit as
  the change.
- **`doc/decisions/`** holds the design decisions: one file per subject
  (the console, the GUI, typed IPC, the recorder…), with the choices and
  the alternatives rejected.
- **Issues** are kept with `bd` (beads): `bd ready` for work that can
  start, `bd show ID`, `bd close ID`. Documents cite issue ids
  (`mynos-6yr`) instead of keeping lists of things to do.
- **Before a commit**: `tools/build-all.sh`, then `tools/run-tests.sh`.

## H.12 Known limits

- `mynos-core/boot/`, the floppy boot loader of 2002, does not assemble
  with today's nasm (mynos-s96); nothing needs it, QEMU and GRUB load
  the kernel directly.
- The tests that type on the keyboard pace themselves with fixed sleeps:
  on a much slower or busier host they can type before MyNOS is ready.
- The test script runs some tools on the host (QEMU, socat, Python,
  `fsck.fat`), outside the container, so their versions are the host's.

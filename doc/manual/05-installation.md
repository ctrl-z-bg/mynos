# 5. Installation

This chapter takes you from nothing to the MyNOS prompt. You will learn
what your computer needs, how to build MyNOS from its sources, how to
start it for the first time, and what the two files that hold your own
data are: the disk image and, if you want language models, `llm.env`.

MyNOS does not install itself on your computer's disk. It runs inside
**QEMU**, a program that emulates a whole PC: a 32-bit processor, memory,
a screen, a keyboard, a hard disk and a network card. Everything MyNOS
writes goes into one file on your computer, the disk image.

## 5.1 What you need

To **try a release** (5.2), QEMU is all: the other programs below are
for building MyNOS from its sources and for its tests.

| Program | What for | To try a release | To build |
|---|---|---|---|
| `qemu-system-i386` | runs MyNOS | **needed** | **needed** |
| `mtools` (`mcopy`) | copies `llm.env` into the disk image | optional: without it, write `/disk/llm.env` inside MyNOS | optional: the build container's is used |
| `python3` | checks that port 8080 is free (`run-mynos.sh`, `run-demo.sh`); the tests | optional: without it, `run-mynos.sh` forwards 8080 without checking, and if the port is taken QEMU stops at once (then `--http 0`, or another port) | needed for the tests |
| `podman` | builds MyNOS, in a container | — | **needed** |
| `socat` | the test suite talks to QEMU's monitor | — | for the tests |

To build, the host is a Linux PC (x86_64). (A release has been tried on
Linux; `run-mynos.sh` is a plain shell script, and should run wherever
QEMU does, macOS included, but that has not been tested.) MyNOS is a
32-bit system: its programs
are static Linux i386 programs, and its OCaml is 5.5 built for that
target. Today's distributions do not ship such a toolchain for a 64-bit
host, so the build runs in a container image, `mynos-dev` (Debian
trixie i386, gcc 14, musl, OCaml 5.5.2; appendix H). QEMU runs on the
host itself. On Linux with KVM (`/dev/kvm`, if your user may use it) the
host's processor runs MyNOS's, and the scripts use it; without KVM the
processor is emulated, slower but with no special permission.

## 5.2 A ready-made image

The quickest look needs nothing at all: **https://ctrl-z-bg.github.io/mynos/**
runs the latest release in the browser, on v86, a PC emulated in
JavaScript and WebAssembly. The shell, the files, the OCaml toplevel, the
graphical session and its Tour work there; the network does not, and so
neither do the language models, the agent and the Tour's lessons on the
network and on models; what is saved on `/disk` is lost when the page is
closed. The whole system needs QEMU, as follows.

The quickest way to run all of MyNOS needs only QEMU. Each release on the
project's GitHub page (Releases) has an archive,
`mynos-VERSION.tar.gz`, with a `.sha256` beside it to check the
download (`sha256sum -c mynos-VERSION.tar.gz.sha256`).

```
  $ tar xzf mynos-2026.11-xxxxxxx.tar.gz
  $ cd mynos-2026.11-xxxxxxx
  $ ./run-mynos.sh
```

The archive holds:

| File | What it is |
|---|---|
| `mynos.iso` | the system: GRUB, the kernel, the first programs and the RAM disk |
| `disk-clean.img` | an empty FAT32 disk |
| `run-mynos.sh` | starts QEMU with the right machine |
| `README.txt` | these instructions, in short |
| `llm.env.example` | the model configuration's template (5.7) |
| `licenses/` | MyNOS's licence (GPL 2) and those of the software it contains |

The first run copies `disk-clean.img` to `disk.img`, which is `/disk`
from then on: what you save there stays between runs. `run-mynos.sh`
takes the options of `run-demo.sh` (5.5), spelled as options:

| Option | Effect |
|---|---|
| `--serial` | this terminal is a console of MyNOS too, as `SERIAL=1` |
| `--no-net` | no network card |
| `--http PORT` | the host port forwarded to the web server (default 8080, if free; 0: none) |
| `--mem MB` | the memory (default 2048; MyNOS uses at most 3583: see `MEM` in 5.5) |
| `--reset-disk` | `/disk` empty again (`disk.img` replaced) |
| `--no-kvm` | the processor emulated, even with KVM |
| `--no-sound` | no sound card (by default a Sound Blaster 16, through the host's audio) |
| `--udp PORT` | this machine's UDP port forwarded to MyNOS's (GavML's network game: `--udp 7145`; `tools/run-demo.sh`: `UDP=7145`) |
| `--display UI` | QEMU's window: `sdl` by default when there is sound (QEMU's GTK window froze while the card played), `gtk`... (`tools/run-demo.sh`: `QEMU_DISPLAY=gtk`) |
| `-- OPTIONS` | passed to QEMU, e.g. `-- -display none` with `--serial` |

A `llm.env` beside the script is copied into the disk at every start
when `mcopy` (mtools) is installed; without it, write `/disk/llm.env`
inside MyNOS with `edit`. If QEMU is missing, the script says how to
install it.

Releases are made with `tools/make-release.sh` (H.6). To build the same
system from its sources instead, read on.

## 5.3 Building from source

Open a terminal in the directory of the MyNOS sources. All the commands
of this section are typed there, on your computer (the host), not in
MyNOS.

**Step 1. Build the container image, once.**

```
tools/containers/build-image.sh dev
```

This downloads Debian and the sources of OCaml 5.5.2, builds the
compiler and the OCaml runtime for musl, and keeps the result as the
image `mynos-dev`. It takes a while, and is needed only once: later
builds reuse the image.

**Step 2. Build MyNOS.**

```
tools/build-all.sh
```

This runs the whole build inside the container (the sources are mounted
there; the files it makes stay owned by you). It stops at the first
error. When it ends, the files that matter for running MyNOS are:

| File | What it is |
|---|---|
| `mynos-core/kernel/kernel.elf` | the microkernel |
| `mynos-runtime/ocamlrun` | the OCaml bytecode interpreter, a MyNOS program |
| `services/registry/registry` | the name registry |
| `services/fs/memrofs/memrofsd` | the service that serves the RAM disk |
| `system/ramdisk.dsk` | the system RAM disk: `init`, the services, the shells, the programs, the OCaml compiler and libraries |
| `system/disk.img` | the hard disk, made the first time only (5.6) |

Most of the build is incremental: run `tools/build-all.sh` again after
changing a source, and only what depends on it is made again.
`tools/clean-all.sh` removes everything the build made, except the disk
image; `tools/clean-all.sh` followed by `tools/build-all.sh` is a build
from scratch.

`tools/in-container.sh dev` opens a shell in the build environment, if
you want to look around in it.

## 5.4 The first boot

```
tools/run-demo.sh
```

A QEMU window opens. For a few seconds it shows the kernel's greeting,
with the version of the system (the build's date and commit, as
`version` prints it later), then its messages:

```
  Welcome to MyNOS - v2026.11-c647b16

  ...
  Initializing the 8259 Programmable Interrupt Controller... done.
  Loading Interrupt Descriptor Table... done.
  Calibrating delay loop... [427622]
  Physical Memory : 2047 MB
  ...
  RAMDISK found (module 3)

  -----------------------
```

then the greeting of the command shell, and its prompt:

```
  MyNOS sh. help lists the commands, ocaml starts the OCaml toplevel;
  Tab completes, Up and Down recall; exit or Ctrl-D leaves.
  mynos:/$ _
```

MyNOS is ready. Type `help` and press Enter: chapter 6 starts here.

If there is no `system/ramdisk.dsk`, the script says
`run-demo.sh: no system/ramdisk.dsk: build first (tools/build-all.sh)`
and stops.

**What happened.** `run-demo.sh` asked QEMU to load the kernel together
with four **modules**, as a boot loader would (GRUB loads the same four
from the release's ISO):

| Module | What it is |
|---|---|
| 0 `ocamlrun` | OCaml's bytecode interpreter, which will run `init` |
| 1 `registry` | the name registry: names → ports |
| 2 `memrofsd` | the service that serves the RAM disk as `/` |
| 3 `ramdisk.dsk` | the RAM disk's image: not a program, the data `memrofsd` serves (the boot's `RAMDISK found (module 3)`) |

The kernel starts the three programs, and `ocamlrun` finds `init` on
the RAM disk; `init` reads its list, `init.rc`, and starts the rest:

```
  QEMU ──► kernel.elf
             ├── registry         names → ports
             ├── memrofsd         the RAM disk, served as /
             └── ocamlrun ──► init  (reads init.rc)
                                ├── consoled    keyboard, screen, second serial port
                                ├── tmpfs       /tmp
                                ├── clipboard   copy and paste, for the windows
                                ├── ata         the hard disk ──► fatfs  /disk
                                ├── pagerd      files mapped into memory, swap
                                ├── netd        the network card
                                ├── displayd    the screen, for the windows
                                ├── soundd      the sound card
                                ├── llmd        language models
                                ├── httpd       a web server on /disk
                                └── sh          the command shell
```

Each box is a separate process (appendix E). The shell, `sh`, is
started again by `init` whenever it ends.

On the host, `run-demo.sh` may print a few lines of its own:

```
  run-demo.sh: llm.env copied to /disk/llm.env
  run-demo.sh: http://localhost:8080/ is MyNOS's httpd
```

The second means that a browser on your computer can open
`http://localhost:8080/` and see the files of MyNOS's disk, served by
MyNOS's web server (chapter 9). If port 8080 is taken, the script says
so and boots without it.

Without `llm.env` (5.7), the log (not the screen) says `llmd: no model
configured: write /disk/llm.env (see llm.env.example in MyNOS's
sources)`. It is a remark, not an error: everything else works.

**Stopping.** Type `shutdown`: MyNOS turns the machine off, and QEMU
ends. `shutdown -r` restarts it instead. Closing QEMU's window also
stops it at once, like pulling the plug: what was on `/tmp` is lost,
and what was being written at that instant may be lost too.

## 5.5 The options of `run-demo.sh`

The script is controlled by environment variables, written before it
on the same line, and by QEMU options, written after `--`:

```
tools/run-demo.sh                             the usual way
SERIAL=1 tools/run-demo.sh                    the window, and this terminal as a console
SERIAL=1 tools/run-demo.sh -- -display none   this terminal only, no window
NET= tools/run-demo.sh                        no network card
HTTP=8000 tools/run-demo.sh                   the web server on host port 8000
UDP=7145 tools/run-demo.sh                    GavML's network game reachable from outside
QEMU_DISPLAY=gtk tools/run-demo.sh            QEMU's GTK window, even with sound
VERBOSE=1 tools/run-demo.sh                   kernel messages stay on the screen
```

| Variable | Default | Effect |
|---|---|---|
| `SERIAL` | not set | `SERIAL=1`: the terminal you started it from becomes a second console of MyNOS, with your terminal's copy and paste and scrollback (6.11). Ctrl-C then goes to MyNOS; Ctrl-A then X stops QEMU. |
| `NET` | `1` | the network card (NE2000) on QEMU's user network: MyNOS is 10.0.2.15, the host 10.0.2.2. `NET=` (empty) boots without it. |
| `HTTP` | `8080`, if free | the host port (on 127.0.0.1 only) forwarded to MyNOS's web server |
| `MEM` | `2048` | memory, in MB. QEMU takes from the host only what MyNOS uses. MyNOS is 32-bit without PAE: it addresses 4 GB, RAM and devices together, and counts the RAM in one piece above the first MB (appendix B.15). With QEMU that is at most 3583 MB; from 3584 on, QEMU moves what is above 3 GB past 4 GB, and MyNOS sees 3 GB |
| `KVM` | `1`, with `/dev/kvm` | the host's processor runs MyNOS's; `KVM=` emulates it |
| `SOUND` | the host's audio (`pipewire`, `pa`, `alsa`, `coreaudio`) | a Sound Blaster 16 heard through this QEMU audio backend; `wav:FILE` records it; `SOUND=` none |
| `QEMU_DISPLAY` | `sdl` with sound (if QEMU has it), QEMU's own otherwise | QEMU's window (`gtk`, `sdl`, ... as `qemu-system-i386 -display help` lists them). With a sound card QEMU's GTK window froze while the card played, hence SDL. A `-display` after `--` wins. |
| `PKG` | not set | `PKG=local`: the packages just built (`tmp/packages`) from this machine instead of GitHub, the installed ones upgraded at boot (appendix H.9) |
| `UDP` | not set | with `NET`, this UDP port of the host forwarded to the same port of MyNOS, from any address: `UDP=7145` for GavML's network game |
| `DISK` | `system/disk.img`, if it exists | the disk image |
| `VERBOSE` | not set | `verbose` on the kernel's command line |
| `CPU` | `qemu32,+rdrand,+rdseed` | QEMU's processor model |

Whatever follows `--` is passed to QEMU unchanged. For example, to keep
the log of a session in a file (the kernel and the services write it on
the second serial port; appendix H):

```
tools/run-demo.sh -- -serial null -serial file:mynos.log
```

`tools/run-qemu.sh` is the lower-level script that `run-demo.sh` calls;
without modules it boots the same system. Appendix H describes it.

## 5.6 The disk image

`system/disk.img` is MyNOS's hard disk: a file of 64 MB on your
computer, holding a FAT32 file system with the label `MYNOS`. Inside
MyNOS it is `/disk` (chapter 7).

- **It is made once.** The first `tools/build-all.sh` creates it, empty
  but for a `README.TXT`. Later builds leave it alone, and so does
  `tools/clean-all.sh`.
- **It is kept between runs.** What you save under `/disk` is still
  there at the next `tools/run-demo.sh`. MyNOS also keeps there the
  shell's history (`.sh_history`), the history of the lines typed to
  other programs (`.history`) and the keyboard layout (`.keymap`).
- **It is yours.** It is not part of the sources: git ignores it (`*.img`).
- **To start again** with an empty disk, delete `system/disk.img` and run
  `tools/build-all.sh`: it makes a new one.

Because the image is an ordinary FAT file system, the host can read it
with mtools while MyNOS is stopped:

```
mdir -i system/disk.img ::/
mcopy -i system/disk.img ::/notes.txt .
```

Change it from the host only while MyNOS is not running: MyNOS's file
system service keeps the disk's allocation table in memory, and would
not see the change.

## 5.7 `llm.env`: the language models

MyNOS can talk to language models (chapter 12): Claude, or any server
that speaks OpenAI's Chat Completions API (OpenAI, vLLM, Ollama on the
host...). This is optional. What MyNOS needs to reach a model, its
address, its name and the key, is written in a file on the host,
`llm.env`, in the directory of the sources.

**Step 1.** Copy the example:

```
cp llm.env.example llm.env
```

**Step 2.** Edit `llm.env` with a text editor on your computer, and put
your own keys where the example has placeholders.

**Step 3.** Run `tools/run-demo.sh` as usual. Before starting QEMU it
copies `llm.env` into the disk image as `/disk/llm.env`, and says so.
Inside MyNOS, `llmd` reads that file again at every request.

`llm.env.example` explains the format, a `.env` file of **profiles**.
Each profile is a group of lines named `LLM_<NAME>_...`; programs choose a
profile by its name in lower case, or get the one `LLM_DEFAULT` names:

| Line | Meaning |
|---|---|
| `LLM_<NAME>_API` | `anthropic` (Claude's Messages API) or `openai` (Chat Completions) |
| `LLM_<NAME>_MODEL` | the model's name for that API |
| `LLM_<NAME>_KEY` | the API key; empty for servers that need none |
| `LLM_<NAME>_URL` | the API's base address, with `/v1`; the default is Anthropic's or OpenAI's |
| `LLM_<NAME>_MAX_TOKENS` | the longest answer, in tokens (default 16000) |
| `LLM_<NAME>_EFFORT` | for `anthropic`: how much the model thinks |
| `LLM_<NAME>_FALLBACKS` | for `anthropic`: `default` lets the API answer with another model |

`NAME=value` lines, `#` comments, values in quotes or not, and `${NAME}`
for a value set above, as in any `.env` file. The example has profiles
for Claude, for OpenAI, and for Ollama and vLLM running on the host
(seen from MyNOS at 10.0.2.2).

Three things to know about this file:

- **It is never part of the sources.** `.gitignore` lists `llm.env`; only
  `llm.env.example`, which holds no key, is in the repository.
- **The copy is made at every start.** `/disk/llm.env` is overwritten by
  the host's `llm.env` each time `run-demo.sh` runs. Edit the host's
  file, not the copy.
- **MyNOS has no users yet.** Any program inside MyNOS can read
  `/disk/llm.env`, and the web server `httpd` serves every file of
  `/disk` (forwarded to the host's 127.0.0.1:8080 by `run-demo.sh`). To
  keep a key out of MyNOS altogether, `llm.env.example` suggests pointing
  `LLM_<NAME>_URL` at a proxy on the host that adds the key
  (`http://10.0.2.2:PORT/v1`), and leaving `LLM_<NAME>_KEY` empty.

Without `llm.env`, MyNOS works the same, with no model: `llm` and `ask`
say that no model is configured.

> **THE MyNOS FACTOR — The system is not installed: it is loaded.**
> On most systems, installing means copying the system onto a disk.
> MyNOS's system is five files, the kernel and four modules, which QEMU
> loads into memory at every start; the RAM disk among them holds
> every program and library, read-only. The hard disk holds only what
> you made. Rebuild MyNOS and the next boot runs the new system, with
> your files untouched; delete the disk image and the system is as new.

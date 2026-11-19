MyNOS ("My! Not another Operating System") is an experimental operating system for 32-bit PCs: a microkernel in C, and above it the file systems, the drivers, the shells and the windows as processes, most of them in OCaml. Written in 2002–2004, taken up again and finished in 2026 with the help of AI.

## Try it in your browser

**https://ctrl-z-bg.github.io/mynos/**: the commands, the graphical session and its Tour, on v86. There is no network there, and so no language models or agent; nothing is kept.

## Run it with QEMU

The full system, network included. Only QEMU is needed (`apt install qemu-system-x86`, `brew install qemu`):

```
tar xzf mynos-@VERSION@.tar.gz
cd mynos-@VERSION@
./run-mynos.sh
```

Then `help`, `gui` (and its Tour), `ocaml`, `edit`, `trace`, `log`. `./run-mynos.sh --help` lists the options. `/disk` (the file `disk.img`) keeps what you save between runs. Check the download with `sha256sum -c mynos-@VERSION@.tar.gz.sha256`.

## What is in it

- A microkernel: processes and threads, memory with copy-on-write, ports and channels, drivers in user space, an event recorder.
- Services as processes, over typed IPC: the FAT file system and the disk driver in OCaml, TCP/IP with TLS, a console, a display server.
- The OCaml 5.5 runtime, unmodified: the shell, the toplevel, `ocamlc` inside MyNOS, domains and threads.
- A graphical session with a Tour that explains how an operating system works, replaying what the processes say to each other.
- Language models and an agent (bring your own key: `llm.env.example`).

The manual: [doc/manual](https://github.com/ctrl-z-bg/mynos/blob/main/doc/manual/README.md).

MyNOS is under the GNU GPL, version 2 or later; the software it contains keeps its own licences (`licenses/` in the archive).

# 14. C Programs and OCaml Programs

MyNOS runs two kinds of programs. A **C program** is a static Linux
executable for the i386, built with musl and with `libmynos`, the C
library of MyNOS. An **OCaml program** is a bytecode file, executed by
`ocamlrun`, which is itself such a C program. Both are ordinary
processes: the kernel starts them the same way, they reach files, the
console and the services through the same library, and `sh` runs either
by name. This chapter tells how to write, build, install and run each
kind. How the pieces work inside is in the appendices: the Linux
interface in appendix D, the OCaml runtime in appendix F, the build in
appendix H.

## 14.1 What a program is made of

```
   C program                         OCaml program
   ─────────                         ─────────────
   your code                         your code (bytecode)
       │                                 │  Mynos, Fs, Ipc... (mynos.cma)
       │                                 │  Stdlib, Unix, Thread
       │                                 ▼
       │                             ocamlrun: the bytecode interpreter,
       │                               a C program like the one at left
       ▼                                 ▼
   libmynos ──── IPC ────► services: files, console, registry, ...
       │   (mynos-lib: files, stdio, the native calls)
   musl  (malloc, strings, stdio, pthreads, maths)
       │
       ▼
   int 0x80: Linux calls          int 0x90: MyNOS's native calls
   (memory, threads, time)        (IPC, ports, semaphores, spawn)
                     MyNOS kernel
```

Everything in the left column is linked into one static file, loaded by
the kernel at `0x40000000`. `libmynos` is linked **before** musl, so its
`open`, `read`, `write` and the other file functions replace musl's at
link time (appendix D.4): a call to `open("/disk/a.txt")` is an IPC
request to the file service, written by a library inside the program.
The OCaml runtime gets the same functions, so the standard library's
`open_in` reaches the same services.

## 14.2 What a C program can use

| Area | What there is | Where it comes from |
|---|---|---|
| The C library | strings, `malloc` (on `mmap`), `printf`, maths, `time`, `getenv` | musl, unchanged |
| stdio | `fopen`, `fprintf`, `fgets`, `fseek`, `fclose`, `stdin`, `stdout` | musl, with its five I/O functions and `fopen` taken from `libmynos` (`mynos-lib/src/stdio.c`) |
| Files | `open`, `read`, `write`, `lseek`, `close`, `stat`, `fstat`, `lstat`, `unlink`, `rename`, `mkdir`, `rmdir`, `opendir`, `readdir`, `rewinddir`, `closedir`, `chdir`, `getcwd` | `libmynos` (`fileio.c`), over the file services (chapter 18) |
| The terminal | `tcgetattr`, `tcsetattr`, the window size (`ioctl`) | `libmynos`'s `ioctl`, over the console service |
| Threads | `pthread_create`, mutexes, condition variables | musl, on the kernel's `clone` and `futex` (chapter 15) |
| Processes | `mynos_spawn`, `waitpid`, `mynos_kill`, `fork`, `getpid` | `mynos.h` and the kernel (chapter 15) |
| IPC | ports, channels, messages, the registry, semaphores | `mynos.h`, `mynos_registry.h` (chapter 16) |
| Typed IPC | the wire format: writer, reader, replies | `mynos_wire.h` |
| Time | `mynos_sleep`, `nanosleep`, `clock_gettime`: 10 ms ticks | the kernel |
| The log | `mynos_log(fmt, ...)`: a line on the log port (COM2) | `libmynos` |

What is not there: `execve` (a program starts another with
`mynos_spawn`), `pipe`, `dup`, `select`, sockets (the network is the
OCaml module `Net`: mynos-t9l), signal handlers (none is ever called),
and `freopen` and `tmpfile`, which still open with musl's own raw call.
Appendix D.3 lists every Linux call the kernel answers.

The headers are in `mynos-lib/include`:

| Header | What it declares |
|---|---|
| `mynos.h` | the native calls: IPC, ports, semaphores, threads, sleeping, processes, the console mode, the log; the error codes `MYNOS_ERR_*` |
| `mynos_registry.h` | registry/1, and `mynos_registryRegister`, `mynos_registryLookUp`, `mynos_registryList` (included by `mynos.h`) |
| `mynos_wire.h` | the wire format of typed IPC, for C services and clients |
| `mynos_fs.h` | fs/1: the file services' requests and errors |
| `mynos_console.h` | console/1: the console's requests and mode bits |

Native calls return a non-negative result, or a negative error:

| Code | Name | Usually means |
|---|---|---|
| −1 | `MYNOS_ERR_FULL` | a table or a queue is full; no memory |
| −2 | `MYNOS_ERR_BUSY` | someone else holds it (a port being listened on) |
| −3 | `MYNOS_ERR_INVALID` | no such object, a bad argument, a name not found |
| −4 | `MYNOS_ERR_DENY` | not yours, or a privilege you lack |
| −5 | `MYNOS_ERR_BROKEN` | the other end has gone |
| −6 | `MYNOS_ERR_EXPIRED` | a timeout passed |

## 14.3 Building a C program

A C program is built in the `dev` container (appendix H.1), with the
compiler and flags of `mynos.mk`. A Makefile for a program kept outside
the tree, with the repository at `/mynos` as the container mounts it:

```make
# a C program for MyNOS, outside the tree
MYNOS = /mynos
include $(MYNOS)/mynos.mk

CC      = $(MYNOS_CC)
CFLAGS  = -Wall -O2 -I$(MYNOS)/mynos-lib/include
LDFLAGS = -L$(MYNOS)/mynos-lib/lib -lmynos $(MYNOS_LDFLAGS)

hello: hello.o
	$(CC) hello.o -o hello $(LDFLAGS)

clean:
	rm -f hello hello.o
```

and a program that uses both the C library and a native call:

```c
/* hello.c: a C program for MyNOS */
#include <stdio.h>
#include <unistd.h>
#include <mynos.h>

int main(int argc, char ** argv)
{
  mynos_stats_t st;
  int i;

  mynos_stats(&st);
  printf("hello from pid %d, parent %d\n", getpid(), getppid());
  printf("%u processes, %u threads, %u KB free\n",
         st.numProcesses, st.numThreads, st.freeppages * 4);
  for (i = 1; i < argc; i++)
    printf("argument %d: %s\n", i, argv[i]);
  mynos_log("hello: %d arguments", argc - 1);
  return 0;
}
```

```
$ tools/in-container.sh dev make -C path/to/hello
musl-gcc -Wall -O2 -I/mynos/mynos-lib/include   -c -o hello.o hello.c
musl-gcc hello.o -o hello -L/mynos/mynos-lib/lib -lmynos -static
  -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code -Wl,--build-id=none
  -Wl,-u,__stdio_read -Wl,-u,__stdio_write -Wl,-u,__stdout_write
  -Wl,-u,__stdio_seek -Wl,-u,__stdio_close
```

(`tools/in-container.sh` mounts only the repository: a program kept
elsewhere is built with `podman run` and a second `-v`, or copied under
the tree.) Each part of the link line has a reason:

- `-lmynos` before the C library, which `musl-gcc` adds last: the linker
  takes `open`, `read`, `write`... from the first archive that has them.
- `-static` and `-Ttext-segment=0x40000000`: one image, where the kernel
  loads every program (appendix H.3).
- The five `-u` options make the linker take musl's internal stdio
  functions from `libmynos` (appendix D.4). Without them a program links
  and runs, but its `printf` writes with musl's own system call: the
  output reaches the text screen even in a terminal window, and is not
  redirected by `sh`. The container's environment sets `MYNOS_LDFLAGS`
  too, **without** these options; `mynos.mk` appends them. Link through
  `mynos.mk`, not with the environment's value alone.

A program in the tree is built the same way: `tests/stdio/Makefile`
and `tests/abi/Makefile` are short examples, with `../../` for `/mynos`.

## 14.4 Building an OCaml program

An OCaml program is compiled to bytecode with the build machine's
`ocamlc` (OCaml 5.5.2, in the container). A program that uses only the
standard library needs nothing more:

```
$ ocamlc -o domains.byte domains.ml
```

A program that uses the MyNOS library (`Mynos`, `Fs`, `Ipc`, `Console`,
and the other modules of appendix F.8) names the library, where its
interfaces are, and MyNOS's list of primitives:

```
$ ocamlc -use-prims /mynos/mynos-runtime/primitives -I /mynos/mynos-lib/ocaml \
         mynos.cma -o hello.byte hello.ml
```

```ocaml
(* hello.ml: an OCaml program for MyNOS *)
let () =
  let st = Mynos.stats () in
  Printf.printf "hello from pid %d, parent %d\n" (Mynos.getpid ()) st.Mynos.ppid;
  Printf.printf "%d processes, up for %.2f s\n" st.Mynos.processes (Mynos.uptime ());
  Array.iteri (fun i a -> if i > 0 then Printf.printf "argument %d: %s\n" i a) Sys.argv
```

Without `-use-prims` the link fails: `ocamlc` checks the program's
primitives against the standard runtime's list, which has no
`caml_mynos_getpid` (appendix F.3). A program and the runtime that runs
it must agree on that list; after a primitive is added to the runtime,
rebuild both.

A program with threads adds the compiler's `unix.cma` and `threads.cma`,
and `-noautolink`, since the static runtime cannot load the shared
libraries those archives would ask for (appendix F.6):

```
$ ocamlc -use-prims /mynos/mynos-runtime/primitives -I /mynos/mynos-lib/ocaml \
         -I +unix -I +threads -noautolink \
         mynos.cma unix.cma threads.cma -o prog.byte prog.ml
```

`Unix` alone (for `Unix.read` on a descriptor, `Unix.sleepf`,
`Unix.gettimeofday`) takes `-I +unix -noautolink unix.cma`. Domains,
`Mutex`, `Condition`, `Atomic` and effects are in the standard library.

## 14.5 Compiling inside MyNOS

The compiler is on the RAM disk, with the standard library, `unix.cma`,
`threads.cma`, `mynos.cma` and its interfaces, and `primitives`, all at
the root (appendix F.9). At `sh`:

```
mynos:/$ ocamlc -use-prims /primitives mynos.cma -o /disk/hi.byte /disk/hello.ml
mynos:/$ /disk/hi.byte x y
hello from pid 21, parent 13
11 processes, up for 106.02 s
argument 1: x
argument 2: y
```

No `-I` is needed: `sh` starts programs with `OCAMLLIB=/`, and the
library's interfaces are in the same flat directory. Threads compile
the same way, without `-I +unix` (`unix.cma` is at the root too):

```
mynos:/$ ocamlc -use-prims /primitives mynos.cma unix.cma threads.cma \
           -noautolink -o /disk/th.byte /disk/othreads.ml && /disk/th.byte
```

In the toplevel (`ocaml`), `compile "/disk/hello.ml";;` does the first
command and writes `/disk/hello.byte`. The compiler is slow on an
emulated processor: count tens of seconds. There is no C compiler inside
MyNOS; C programs are built outside, in the container.

## 14.6 Putting a program on the disk

A program runs from any file service. Where to put it:

| Where | Seen as | How it gets there |
|---|---|---|
| the disk image `system/disk.img` (FAT32) | `/disk/...`; it stays | from the host, with QEMU stopped: `mcopy` |
| `/disk/bin` | a command, by name | the same; `sh`'s `PATH` is `/disk/bin:/` |
| the RAM disk | `/NAME`, read-only | in the tree: add it to `FILES` in `system/Makefile` |
| `/tmp` | `/tmp/NAME`, until shutdown | from inside: `cp`, the compiler, `fetch -o` |

From the host, with the mtools of the container:

```
$ tools/in-container.sh dev mmd -i system/disk.img ::/bin
$ tools/in-container.sh dev mcopy -i system/disk.img hello ::/bin/hello
$ tools/in-container.sh dev mcopy -i system/disk.img hello.byte ::/bin/
```

The image must not be in use: QEMU and mtools would each write the FAT
without knowing of the other. From inside a running system, `fetch -o
/disk/bin/hello http://10.0.2.2:8000/hello` copies a file from a web
server on the host (QEMU's user network makes the host `10.0.2.2`;
chapter 19).

## 14.7 Running a program

At `sh`, a program is named by its path, or by its name if it is in
`PATH`; `NAME` also finds `NAME.byte`. `sh` reads the first four bytes
of the file: an ELF image is started as it is, anything else is taken
for bytecode and started as `ocamlrun FILE ARGS...` (`sh/sh.ml`,
`run_program`):

```
mynos:/$ /disk/hello a b
hello from pid 19, parent 13
11 processes, 27 threads, 194444 KB free
argument 1: a
argument 2: b
mynos:/$ echo $?
0
```

`$?` is the exit code, or 128 plus the signal for a program that was
killed (137 after Ctrl-C). An OCaml program that ends with an uncaught
exception prints it and exits with code 2. In the toplevel,
`run "/disk/hello.byte" ["a"; "b"];;` starts a program and returns its
`Mynos.status`.

**As a boot module.** For a test, or a program that needs no file
system, the program can be given to the kernel directly: every ELF
module is started as a process at boot, with the arguments written after
its name (appendix H.6). Bytecode is the module after `ocamlrun`:

```
$ tools/run-qemu.sh mynos-runtime/ocamlrun hello.byte services/registry/registry \
      "hello one two" -- -display none -serial null -serial file:hello.log
```

The kernel keeps at most 127 characters of a module's command line,
path included, and cuts the rest without a word
(`mynos-core/kernel/main.c`, `MODULE_CMDLINE`): give modules short
paths. The output of every process, and `mynos_log`'s lines, are in
`hello.log`, the second serial port.

**A program's first output.** The first time a C program writes to
standard output, `libmynos` asks the registry for the console service
(to choose line buffering, with `ioctl`). In the full system it is
there. In a boot without `consoled` the library waits up to about a
second for it to register, then goes on: a minimal test program pays
that second once.

> **THE MyNOS FACTOR — The C library is the client.**
> On Unix, `open` is a system call and the file system is in the kernel.
> In MyNOS, `open` is a function of `libmynos`, inside the program, that
> writes an fs/1 request and sends it to a service it found by name.
> The C program, `ocamlrun`, `sh` and the toplevel reach files, the
> console and the services in exactly the same way, and the kernel knows
> nothing of any of them. To give C programs a new kind of file, nothing
> in the kernel changes: a library function and a service do.

## 14.8 Known limits

- No C compiler inside MyNOS; no shared libraries; every C program is
  static and carries its own copy of musl and `libmynos`.
- A C program built without `mynos.mk`'s `-u` options gets musl's own
  stdio output (14.3).
- Bytecode linked against one `primitives` list needs a runtime with all
  of its names (appendix F.11).
- A boot module's command line is cut at 127 characters (14.7).

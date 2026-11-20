# 8. Programming inside MyNOS

MyNOS carries its own programming tools: the OCaml toplevel, where you
type OCaml and see the answer at once; two text editors; and the OCaml
bytecode compiler, `ocamlc`. A program can be written, compiled, run
and kept on `/disk` without leaving MyNOS. This chapter shows how, one
tool at a time, then puts them together.

Everything here is on the RAM disk: the toplevel (`shell.byte`), the
compiler (`ocamlc.byte`), the standard library (`stdlib.cma` and the
`.cmi` interfaces), the `unix` and `threads` libraries, and `mynos.cma`,
the MyNOS library, with the interfaces of its modules (`Mynos`, `Block`,
`Fs`, `Net`, `Tracer`, `Gui`...). The language is OCaml 5.5.

## 8.1 The OCaml toplevel

Type `ocaml` at `sh`'s prompt:

```
  mynos:/$ ocaml

  MyNOS shell. Type help ();; for help.
  OCaml version 5.5.2
  Enter #help;; for help.

  # _
```

The `#` is the toplevel's prompt. Type an OCaml **phrase**, end it with
two semicolons, and press Enter: the toplevel compiles it, runs it, and
prints its value with its type.

```
  # let rec fact n = if n = 0 then 1 else n * fact (n - 1);;
  val fact : int -> int = <fun>
  # fact 10;;
  - : int = 3628800
```

A phrase may take several lines: nothing happens until the `;;`. A
mistake is reported, and the toplevel waits for the next phrase:

```
  # cat "nothere";;
  Exception: Sys_error "nothere: No such file or directory".
```

Things to know:

- **Line editing is the console's** (6.6): Backspace, and Up and Down
  for the phrases typed before, kept in `/disk/.history` across
  restarts. The cursor cannot be moved back into the line.
- **To leave**, type `#quit;;` or press Ctrl-D: you are back in `sh`.
- **Ctrl-C ends the whole toplevel**, not only the phrase that is
  running, and what you defined is lost; `sh`'s prompt comes back
  (6.10).
- **A script**: `#use "/tmp/a.ml";;` runs the phrases of a file, and
  `ocaml < FILE` runs a file of phrases from `sh` (7.7).

## 8.2 Module `Shell`

The toplevel opens a module of commands, `Shell`, when it starts: its
functions can be called by their names. `help ();;` lists them.

| Phrase | What it does |
|---|---|
| `help ();;` | the list of commands |
| `ls ();;`, `ls ~dir:"/disk" ();;` | list a directory, with sizes (dot files included) |
| `cd "/disk";;`, `pwd ();;` | change, print the current directory |
| `cat "FILE";;` | print a file |
| `write "FILE" "TEXT";;` | make FILE contain TEXT |
| `rm "FILE";;` | remove a file |
| `run "PROG" ["ARG"; ...];;` | start a program, wait for its end, give its status |
| `compile "FILE.ml";;` | compile it into `FILE.byte` (8.6) |
| `edit "FILE";;` | edit a file with `edit` (8.3) |
| `sh ();;` | a command shell; its `exit` comes back here |
| `free ();;` | free memory |

`run` looks for a program named without a directory first in the
current directory, then at the root of the RAM disk. A name ending in
`.byte` is run by `ocamlrun`. It returns how the program ended:

```
  # run "hello.byte" [];;
  Hello from OCaml on MyNOS!
  ...
  - : Mynos.status = Mynos.Exited 0
```

Note the difference with `sh`: in `/disk`, `run "hello.byte" []` runs
`/disk/hello.byte` if there is one, while `sh`'s `hello` always runs
`/hello.byte` (6.3).

All of OCaml's standard library is there too, and the whole of MyNOS:
module `Mynos` has the system calls (`#show Mynos;;` lists them), and
the services can be called directly, with their requests checked by the
type checker:

```
  # Mynos.getpid ();;
  - : int = 30
  # let d = Block.connect ();;
  val d : Block.t = <abstr>
  # Block.call d Block.Info;;
  - : int = 131072
```

The last answer is the size of the hard disk, in sectors of 512 bytes:
64 MB. The Programmer's Guide (Part III) describes these modules.

## 8.3 The editor `edit`

`edit` is a small full-screen editor, written in OCaml for MyNOS. From
`sh`:

```
  mynos:/disk$ edit hello.ml
```

(from the toplevel, `edit "hello.ml";;`). The file is shown on the whole
screen; a file that does not exist yet is made when you save. The last
two lines are the **status line**, with the file's name, `(modified)`
when there are unsaved changes, and the cursor's position, and the
**message line**, which lists the keys:

```
  ~
   hello.ml (modified)  -  line 2/2, column 1
  Ctrl-S save  Ctrl-Q quit  Ctrl-K cut  Ctrl-U paste  Ctrl-F find
```

| Key | Effect |
|---|---|
| arrows, Home, End, Page Up, Page Down | move |
| typing | inserts |
| Enter, Backspace, Delete | split and join lines, erase |
| Tab | spaces up to the next multiple of 8 |
| Ctrl-S | save |
| Ctrl-Q | quit; with unsaved changes, press it twice |
| Ctrl-K | cut the cursor's line |
| Ctrl-U | paste the cut line above the cursor's line |
| Ctrl-F | search: type the text and Enter; Enter again for the next match, any other key to stop; Esc gives up |

`edit` works with UTF-8 text: accented letters are typed, shown, erased
and saved like any other, and the cursor counts characters, not bytes.
Bytes that are not UTF-8 are shown as `?` and kept as they were. The
tabs of a file become spaces when it is read. Ctrl-C is an ordinary key
in `edit`: Ctrl-Q quits.

## 8.4 The editor `kilo`

`kilo` is Salvatore Sanfilippo's small editor in C, `third_party/kilo`,
built for MyNOS. It colours C programs.

```
  mynos:/disk$ kilo notes.txt
```

| Key | Effect |
|---|---|
| Ctrl-S | save |
| Ctrl-Q | quit; with unsaved changes, press it three more times |
| Ctrl-F | search |

`kilo` takes Ctrl-C as a key: it does not end it. When `kilo` ends, its
last screen stays behind the prompt: type `clear` (or Ctrl-L at the
prompt).

## 8.5 Compiling a program with `ocamlc`

`ocamlc`, the OCaml bytecode compiler, runs inside MyNOS as it does on
any other system. A first program, step by step:

**Step 1.** Write it. With `edit hello.ml`, or in one line from `sh`:

```
  mynos:/$ cd /disk
  mynos:/disk$ echo 'let () = print_endline "Hello from /disk"' > hello.ml
```

**Step 2.** Compile it, and run it if the compilation succeeded:

```
  mynos:/disk$ ocamlc -o hello.byte hello.ml && ./hello
  Hello from /disk
```

The compiler takes several seconds in QEMU. Besides `hello.byte`, the
program, it leaves `hello.cmi` and `hello.cmo`, the compiled interface
and module, which can be removed.

**Step 3.** Run it again later as `./hello` or `/disk/hello.byte`. To
call it by its name from anywhere, put it in `/disk/bin`, which is in
`PATH`:

```
  mynos:/disk$ mkdir /disk/bin
  mynos:/disk$ cp hello.byte /disk/bin/greet.byte
  mynos:/disk$ greet
  Hello from /disk
```

`sh` finds `.byte` files and gives them to `ocamlrun`, the bytecode
interpreter, which is itself a MyNOS program.

## 8.6 Programs that use MyNOS

A program that uses the MyNOS library needs two more things on the
compiler's command line:

```
  mynos:/disk$ echo 'let () = print_endline ("I am process " ^ string_of_int (Mynos.getpid ()))' > me.ml
  mynos:/disk$ ocamlc -use-prims /primitives mynos.cma -o me.byte me.ml && ./me
  I am process 24
```

- `mynos.cma` is the library. Without it the compiler says
  `No implementation provided for the following modules: Mynos`.
- `-use-prims /primitives` gives the compiler the list of the C
  functions ("primitives") that MyNOS's `ocamlrun` contains. The
  compiler checks that every primitive a program uses exists; its own
  list is that of the standard OCaml runtime, which knows nothing of
  MyNOS. Without it: `The external function caml_mynos_getpid is not
  available`.

The libraries are found at the root of the RAM disk because `sh` sets
`OCAMLLIB=/` for every program.

## 8.7 Programs with threads

OCaml's threads (modules `Thread`, `Mutex`, `Condition`, `Event`) need
the `unix` and `threads` libraries, and one more option:

```
  mynos:/disk$ echo 'let () = Thread.join (Thread.create print_endline "from a thread")' > th.ml
  mynos:/disk$ ocamlc -use-prims /primitives unix.cma threads.cma -noautolink -o th.byte th.ml && ./th
  from a thread
```

`-noautolink` is needed because, on other systems, these libraries ask
the bytecode interpreter to load their C parts from shared libraries
(`dllunixbyt...so`) when the program starts. MyNOS has no shared
libraries: those C parts are already linked into its `ocamlrun`.
Without `-noautolink` the compiler looks for the shared library, and
stops with `I/O error: dllunixbyt-...so: No such file or directory`.
Add `mynos.cma` as well if the program also uses MyNOS's modules.

OCaml 5's domains (`Domain.spawn`) need nothing special: they are in the
standard library. MyNOS runs them on one processor, in turn.

## 8.8 Compiling and running from the toplevel

The toplevel has the same tools as functions. `compile` calls `ocamlc`
with `-use-prims /primitives mynos.cma`, so programs compiled this way
may use MyNOS. It also links each of these libraries whose modules the
source names:

- `unix.cma`, for `Unix`;
- `threads.cma`, for `Thread` and `Event`;
- `str.cma`, for `Str`;
- `nums.cma`, for `Num` and `Big_int`;
- `graphics.cma`, for `Graphics` (20.6).

The result goes next to the source:

```
  # write "/disk/aaa.ml" "let () = print_endline (String.make 3 'A')";;
  - : unit = ()
  # compile "/disk/aaa.ml";;
  - : Mynos.status = Mynos.Exited 0
  # run "/disk/aaa.byte" [];;
  AAA
  - : Mynos.status = Mynos.Exited 0
```

`compile ~output:"/disk/bin/x.byte" "/disk/a.ml"` chooses the program's
name. A failed compilation prints the compiler's message and returns
`Mynos.Exited 2`.

## 8.9 The whole cycle

```
            edit a.ml                       ocamlc ... -o a.byte a.ml
   ┌──────────────────────┐            ┌──────────────────────────────┐
   │ edit / kilo          │──Ctrl-S──► │ /disk/a.ml  ──►  /disk/a.byte│
   └──────────────────────┘            └──────────────┬───────────────┘
              ▲                                       │ ./a
              │      the error, the wrong output      ▼
              └───────────────────────────────── ocamlrun runs it
```

A session that goes round it once, from `sh`:

```
  mynos:/$ cd /disk
  mynos:/disk$ edit a.ml                 (write, Ctrl-S, Ctrl-Q)
  mynos:/disk$ ocamlc -o a.byte a.ml && ./a
  mynos:/disk$ edit a.ml                 (Up recalls the commands)
  mynos:/disk$ ocamlc -o a.byte a.ml && ./a
```

or try a piece of it first in the toplevel with `#use "/disk/a.ml";;`.
Everything stays on `/disk` for the next session.

> **THE MyNOS FACTOR — The compiler lives on the system it compiles for.**
> `ocamlc` is an OCaml bytecode program like any other: MyNOS runs it on
> its own `ocamlrun`, which reads the source and writes the program
> through `fatfs`, while the type checker uses the `.cmi` files of the
> RAM disk. Nothing is compiled on another machine and copied in: the
> program you just wrote, the compiler that compiled it and the
> services it calls are all processes of the same running system, and
> the toplevel can call those services as typed functions.

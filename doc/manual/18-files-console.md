# 18. Files and Console

Files and the console are not in the MyNOS kernel. Files are kept by
three **file services** that speak fs/1; the keyboard and the screen of
programs belong to **console services** that speak console/1. A
program's `open`, `read`, `printf` and `tcsetattr` reach them through
`libmynos`, and an OCaml program can also speak both protocols itself,
with modules `Fs` and `Console`. This chapter shows both ways. The
services themselves are described in appendix E.6 to E.11; how
`libmynos` replaces the C library's file functions, in appendix D.4.

## 18.1 Where files are

| Path | Service | What it is |
|---|---|---|
| `/` | `memrofs` (C) | the RAM disk: the system's programs and files; read-only, flat |
| `/tmp/NAME` | `tmpfs` (OCaml) | files in memory, lost at shutdown; writable, flat |
| `/disk/PATH` | `fatfs` (OCaml) | the FAT16 or FAT32 disk: directories, files that stay |

`libmynos` makes a path absolute against the current directory, cleans
it (`.`, `..`, doubled `/`), and chooses the service by its first
component; the rest is the path inside the service, at most 63 bytes.
Listing `/` shows the RAM disk's files and, after them, the mount points
of the services that are running (`tmp`, `disk`). Nothing else is
shared: there are no owners, permissions or links, and a descriptor
belongs to the process that opened it.

## 18.2 fs/1

Every file service answers the same ten requests (`mynos-lib/ocaml/fs.mli`,
`mynos-lib/include/mynos_fs.h`):

| Case | Request (`Fs`) | Reply |
|---|---|---|
| 0 | `Open (path, flags)`; flags `o_write`, `o_creat`, `o_trunc`, `o_append`, `o_excl` (0: read) | a descriptor of the service |
| 1 | `Close fd` | `unit` |
| 2 | `Read (fd, max)`, at most `io_max` = 16384 bytes | the bytes; `""` at the end |
| 3 | `Write (fd, data)`, at most 16384 bytes | bytes written |
| 4 | `Seek (fd, offset, whence)`, whence 0 1 2 | the new position |
| 5 | `List path` | `(name, size)` list; size −1 for a directory |
| 6–8 | `Remove path`, `Mkdir path`, `Rmdir path` | `unit` |
| 9 | `Rename (from, to)`, within the service | `unit` |

An error is an Error reply whose message starts with a name. `libmynos`
turns the name into `errno`; in OCaml, `Fs.error_of message` gives its
number:

| Name | `errno` | When |
|---|---|---|
| `not_found` | `ENOENT` | no such file or directory |
| `exists` | `EEXIST` | the name is taken |
| `read_only` | `EROFS` | writing to memrofs, or to a read-only file |
| `is_dir`, `not_dir` | `EISDIR`, `ENOTDIR` | a directory where a file was wanted, or the reverse |
| `not_empty` | `ENOTEMPTY` | `rmdir` of a directory with files in it |
| `denied` | `EACCES` | a descriptor of another process |
| `too_many`, `no_space` | `EMFILE`, `ENOSPC` | the service's limits |
| `not_open`, `invalid` | `EBADF`, `EINVAL` | |

**What `libmynos` does with it.** `open` sends an `Open` to the right
service and keeps the service's descriptor in a table of 64 entries; the
program sees descriptors from 20 up. `read` and `write` send as many
`Read` and `Write` requests of 16 KB as the call needs: a `read` of a
file returns everything asked for unless the file ends, as on Linux.
`opendir` and `readdir` send one `List`. `stat` opens the file and
asks for its size with a `Seek` to the end. Each request is one connection (appendix C.5); when a service
has ended and `init` has restarted it, the request is sent to the new
one. Every program linked with `libmynos` does this, `ocamlrun`
included: OCaml's `open_in` and `Sys.readdir` are the same requests.

## 18.3 Files from C

```c
/* files.c: files from C, with stdio and with the calls beneath it */
#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

int main(void)
{
  FILE * f;
  char line[100], dir[100];
  struct stat st;
  DIR * d;
  struct dirent * e;
  int fd;

  /* write a file on /tmp (tmpfs), read it back */
  if ((f = fopen("/tmp/notes.txt", "w")) == NULL) {
    perror("/tmp/notes.txt");
    return 1;
  }
  fprintf(f, "first line\nsecond line\n");
  fclose(f);
  f = fopen("/tmp/notes.txt", "r");
  while (fgets(line, sizeof line, f))
    printf("read: %s", line);
  fclose(f);

  /* the same file with open, write, stat */
  fd = open("/tmp/notes.txt", O_WRONLY | O_APPEND);
  write(fd, "third line\n", 11);
  close(fd);
  if (stat("/tmp/notes.txt", &st) == 0)
    printf("size: %ld bytes\n", (long)st.st_size);

  /* a relative name, from the current directory */
  chdir("/tmp");
  rename("notes.txt", "old.txt");
  printf("in %s:", getcwd(dir, sizeof dir));
  d = opendir(".");
  while ((e = readdir(d)) != NULL)
    printf(" %s", e->d_name);
  printf("\n");
  closedir(d);
  unlink("old.txt");

  /* errors are errno values */
  if (open("old.txt", O_RDONLY) < 0)
    printf("old.txt: %s\n", strerror(errno));
  if (fopen("/hello.txt", "w") == NULL)
    printf("/hello.txt: %s\n", strerror(errno));
  return 0;
}
```

```
read: first line
read: second line
size: 34 bytes
in /tmp: old.txt
old.txt: No such file or directory
/hello.txt: Read-only file system
```

`readdir` gives no `.` and `..` entries. The current directory is the
process's own; a child starts in its parent's (chapter 15.5).

## 18.4 Files from OCaml

The standard library works on MyNOS's files unchanged: channels,
`In_channel` and `Out_channel`, `Sys.readdir`, `Sys.rename`,
`Sys.remove`, `Sys.file_exists`, `Sys.chdir`; and `Unix`'s file
functions, compiled as in 14.4. Module `Fs` speaks fs/1 itself, to one
service by name, with paths inside it:

```ocaml
(* files.ml: files from OCaml, with the standard library and with Fs *)
let () =
  (* the standard library: libmynos speaks fs/1 underneath *)
  Out_channel.with_open_text "/tmp/notes.txt" (fun oc ->
      output_string oc "first line\nsecond line\n");
  let text = In_channel.with_open_text "/tmp/notes.txt" In_channel.input_all in
  Printf.printf "read %d bytes\n" (String.length text);
  Sys.rename "/tmp/notes.txt" "/tmp/old.txt";
  Printf.printf "/tmp: %s\n" (String.concat " " (Array.to_list (Sys.readdir "/tmp")));
  Printf.printf "/: %d entries\n" (Array.length (Sys.readdir "/"));
  (match open_out "/hello.txt" with
   | _ -> ()
   | exception Sys_error e -> Printf.printf "error: %s\n" e);
  (* fs/1 itself: names inside the service, descriptors of the service *)
  let tmp = Fs.connect "tmpfs" in
  List.iter (fun (name, size) -> Printf.printf "tmpfs: %s, %d bytes\n" name size)
    (Fs.call tmp (Fs.List ""));
  let fd = Fs.call tmp (Fs.Open ("old.txt", 0)) in
  let first = Fs.call tmp (Fs.Read (fd, 5)) in
  Fs.call tmp (Fs.Close fd);
  Printf.printf "first 5 bytes: %S\n" first;
  Fs.call tmp (Fs.Remove "old.txt");
  match Fs.call tmp (Fs.Open ("old.txt", 0)) with
  | _ -> ()
  | exception Ipc.Remote_error (service, m) ->
    Printf.printf "%s: %s (error %d)\n" service m (Fs.error_of m)
```

```
read 23 bytes
/tmp: old.txt
/: 6 entries
error: /hello.txt: Read-only file system
tmpfs: old.txt, 23 bytes
first 5 bytes: "first"
tmpfs: not_found (error 1)
```

(The RAM disk of this run held five files; the sixth entry of `/` is the
mount point `tmp`.) `Fs` is the right tool when a program wants the
sizes of a directory's files in one request, talks to a file service by
its name, or is itself a file service: `Fs.serve name { Fs.handle }`
serves fs/1 with a typed handler, as `tmpfs` and `fatfs` do. Descriptors
from `Fs.Open` are the service's, not `libmynos`'s: they cannot be
given to `read` or to a channel.

## 18.5 Standard input and output

| Descriptor | Without redirection | Redirected by `sh` |
|---|---|---|
| 0 | the console service: a `Read` request | `MYNOS_STDIN=path` |
| 1, 2 | the kernel's screen; a terminal window's console service when `MYNOS_CONSOLE` names one | `MYNOS_STDOUT`, `MYNOS_STDERR`; `>>path` appends |

There are no inherited descriptors in MyNOS: `sh`'s `<`, `>` and `>>`
are environment variables of the child (chapter 15.5), which `libmynos`
reads at the first use of descriptor 0, 1 or 2 and opens. A pipeline
`a | b` runs `a` with its output in a file of `/tmp`, then `b` with that
file as input. A redirected program's output then goes to the file:

```
mynos:/$ /disk/hi.byte z > /tmp/o.txt; cat /tmp/o.txt
hello from pid 22, parent 13
11 processes, up for 112.66 s
argument 1: z
```

C's `stdout` is then fully buffered instead of line by line
(`libmynos`'s `ioctl` says that a redirected descriptor is not a
terminal, and so does `isatty`, which `libmynos` provides too).

## 18.6 The console

A console service owns a keyboard and a screen: `consoled`, the text
console (registered as `console`), or a terminal window of the
graphical session. It serves console/1 (`mynos-lib/ocaml/console.mli`,
`mynos_console.h`):

| Case | Request (`Console`) | Reply |
|---|---|---|
| 0 | `Read max` | a line in line mode, keys in raw mode; `""` at the end of input or when VTIME passes |
| 1 | `Mode (mode, vmin, vtime)`; bits `canon` 1, `echo` 2, `nosig` 4 | `unit` |
| 2 | `Keymap layout`: `layout_us`, `layout_it`, −1 to ask | the layout in use |
| 3 | `Write data` | `unit` |
| 4 | `Foreground pid` | `unit` |

**Line mode** (`canon`, the default) edits the line in the service:
Backspace, Ctrl-D for the end of input (and in `consoled`, Up and Down
for the last lines);
a `read` returns a whole line. **Raw mode** passes keys as they come,
the arrows and editing keys as VT100 sequences (`ESC [ A` for Up). In
raw mode `vmin` and `vtime` mean what they mean in termios: with
`vmin` 1 a read waits for a key; with `vmin` 0 and `vtime` *t* it waits
at most *t* tenths of a second and may return `""`. A raw mode belongs to
the process that set it: when another process reads, the console goes
back to line mode, so a program that ended without restoring it leaves
no harm behind. The screen is 80 × 25 and understands VT100 sequences;
`TIOCGWINSZ` says so.

A C program sets the mode with termios; `libmynos` translates `ICANON`,
`ECHO`, `ISIG`, `VMIN` and `VTIME` (the other flags are kept but mean
nothing):

```c
/* keys.c: keys one by one, with termios, until q */
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

int main(void)
{
  struct termios saved, raw;
  unsigned char c;

  tcgetattr(0, &saved);
  raw = saved;
  raw.c_lflag &= ~(ICANON | ECHO);      /* no line editing, no echo */
  raw.c_cc[VMIN] = 1;                   /* each read: at least one byte */
  raw.c_cc[VTIME] = 0;
  tcsetattr(0, TCSANOW, &raw);
  printf("press keys, q to quit\n");
  fflush(stdout);
  while (read(0, &c, 1) == 1 && c != 'q')
    printf("key %3d %c\n", c, c >= ' ' && c < 127 ? c : '.');
  tcsetattr(0, TCSANOW, &saved);        /* back to line mode */
  return 0;
}
```

Typing `a`, `B`, Up and `q`:

```
press keys, q to quit
key  97 a
key  66 B
key  27 .
key  91 [
key  65 A
```

An OCaml program calls `Mynos.console_mode` (or speaks `Console.Mode`
itself) and reads descriptor 0:

```ocaml
(* keys.ml: keys one by one, in OCaml, until q *)
let () =
  Mynos.console_mode ~canon:false ~echo:false ();
  print_endline "press keys, q to quit";
  let buf = Bytes.create 16 in
  let rec loop () =
    let n = Unix.read Unix.stdin buf 0 16 in
    let keys = Bytes.sub_string buf 0 n in
    Printf.printf "keys %S\n%!" keys;
    if n > 0 && not (String.contains keys 'q') then loop () in
  loop ();
  Mynos.console_mode ~canon:true ~echo:true ()
```

(compiled with `-I +unix -noautolink unix.cma`). `Unix.read` returns
what one `Read` request brought: here `"x"`, `"y"`, `"q"`, one key at a
time. The standard library's `input_char stdin` works too, through its
buffer.

## 18.7 Ctrl-C and the foreground program

MyNOS delivers no signals. Ctrl-C is the console **killing** a program:
the one that the shell said it waits for. `sh` names each command it
runs in the foreground with `Foreground pid` (`Mynos.console_foreground`,
`mynos_consoleForeground`), and names none (0) when it ends. The console
accepts only a child of the caller. When Ctrl-C is typed and the mode
has interrupts on, the console kills that program, shows `^C` and drops
what was typed for it; its parent's `wait` sees `Signaled 9`, and `sh`
sets `$?` to 137:

```
mynos:/$ /disk/worker.byte forever
worker 18: GREETING=(none), args [forever]
^C
mynos:/$ echo status $?
status 137
```

A program that starts others does the same as `sh`:

```ocaml
(* fg.ml: a program in the foreground, ended by Ctrl-C *)
let () =
  let pid = Mynos.spawn "ocamlrun" [| "ocamlrun"; "worker.byte"; "forever" |] in
  Mynos.console_foreground pid;          (* Ctrl-C now ends it *)
  let st = Mynos.wait pid in
  Mynos.console_foreground 0;
  match st with
  | Mynos.Exited n -> Printf.printf "fg: exited with %d\n" n
  | Mynos.Signaled s -> Printf.printf "fg: killed (signal %d)\n" s
```

```
worker 9: GREETING=(none), args [forever]
^C
fg: killed (signal 9)
```

A program that wants Ctrl-C as a key (an editor) turns interrupts off:
termios without `ISIG`, or the mode bit `Console.nosig`. Then Ctrl-C is
byte 3 in its input. Since the program cannot catch a kill, anything it
must undo on the screen is undone by its parent: `sh` resets colours,
the cursor and the alternate screen after a program that was killed.

> **THE MyNOS FACTOR — Ctrl-C is a request, not a signal.**
> Unix's terminal driver sends SIGINT to a process group, and every
> program inherits the machinery of signal handlers. MyNOS's console is
> an ordinary service that was told, by the shell, which child it may
> end; it ends it with the same `kill` any program can call. Who may be
> interrupted, and by whom, is decided in a few lines of a service.

## 18.8 A terminal window is a console

A terminal window of the graphical session (`gui/terminal.ml`) is a
console service of its own, registered as `term<pid>`. It starts `sh`
with `MYNOS_CONSOLE=term<pid>` in its environment; `libmynos` then sends
that program's reads, modes and foreground to that service instead of
`console`, and its output on descriptors 1 and 2 as `Write` requests.
Children inherit the variable, so everything started from that shell
reads and writes the window. A program needs to do nothing for this.

Any program can be a console in the same way, for a child of its own: a
test harness, a window, a log. It serves console/1 under a name, keeps
reads that cannot be answered yet (chapter 17.7), and starts the child
with `MYNOS_CONSOLE` naming it. A minimal one, which gives its child no
input and keeps its output:

```ocaml
(* capture.ml: the console of another program. It serves console/1
   under a name of its own and starts a child with MYNOS_CONSOLE naming
   it: the child's output comes here, and its input is "" (the end). *)
let answer ch msg =
  (try Mynos.send ch msg with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let serve port lines =
  while true do
    let ch = Mynos.listen port in
    match Mynos.recv ~timeout:1.0 ch with
    | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ())
    | msg ->
      match Console.decode msg with
      | Error reply -> answer ch reply
      | Ok (Console.Protocol.Request r) ->
        let ok (type a) (r : a Console.request) (v : a) = answer ch (Console.reply r v) in
        (match r with
         | Console.Write s -> Mutex.protect (fst lines) (fun () -> Buffer.add_string (snd lines) s); ok r ()
         | Console.Read _ -> ok r ""                   (* no input: the end *)
         | Console.Mode _ -> ok r ()
         | Console.Keymap _ -> ok r Console.layout_us
         | Console.Foreground _ -> ok r ())
  done

let () =
  let name = Printf.sprintf "cap%d" (Mynos.getpid ()) in
  let port = Mynos.register name in
  let lines = (Mutex.create (), Buffer.create 256) in
  ignore (Domain.spawn (fun () -> serve port lines));
  let env = Array.append (Mynos.environment ()) [| "MYNOS_CONSOLE=" ^ name |] in
  let pid = Mynos.spawn ~env "ocamlrun" [| "ocamlrun"; "worker.byte"; "0" |] in
  ignore (Mynos.wait pid);
  let child = Mutex.protect (fst lines) (fun () -> Buffer.contents (snd lines)) in
  Printf.printf "capture: the child wrote %S\n" child
```

```
capture: the child wrote "worker 6: GREETING=(none), args [0]\n"
```

The service runs in a domain of its own, because the main domain waits
in `Mynos.wait`; a real console would also answer `Read` later, when it
has input, and kill its `Foreground` program on Ctrl-C, as
`gui/terminal.ml` does.

## 18.9 Known limits

- memrofs and tmpfs are flat; only fatfs has directories. No owners,
  permissions, links or file locks.
- A process has at most 64 open files; a path inside a service is at
  most 63 bytes.
- No pipes: `sh` runs a pipeline one command after the other, through
  files.
- `freopen` and `tmpfile` bypass `libmynos` (appendix D.9).
- A console has no notion of sessions or job control: one foreground
  program, killed rather than interrupted.

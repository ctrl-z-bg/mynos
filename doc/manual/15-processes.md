# 15. Processes, Threads and Domains

A MyNOS program can start other programs, wait for them and end them;
inside one program it can run several threads. This chapter shows how,
from C and from OCaml: `spawn`, `wait` and `kill`; the environment and
the privileges a child gets; programs in the background; C threads;
OCaml's domains and threads, and which MyNOS calls let the other threads
run while one waits. What the kernel does underneath is in appendix A.4
and A.9 (processes and threads) and appendix D.7 (Linux threads).

## 15.1 Starting a program

MyNOS has no `execve`. A process starts another with **spawn**: it names
a program file, the arguments, the environment and the privileges, and
gets the pid of a new child process. `libmynos` reads the file through
the file services (the kernel cannot open files) and hands the bytes to
the kernel, which loads them as a new process (appendix A.9).

| C (`mynos.h`) | OCaml (`Mynos`) |
|---|---|
| `int mynos_spawn(const char * path, char ** argv, char ** envp)` | `spawn : ?env:string array -> ?io:bool -> string -> string array -> int` |
| `int mynos_spawnPriv(path, argv, envp, int privileges)` | `spawn ~io:true ...` |

- **The path.** A name without `/` is looked for at the root of the RAM
  disk, then in the current directory; anything else is a path, relative
  to the current directory or absolute. `sh`'s `PATH` search is `sh`'s
  own, not `spawn`'s.
- **The program** must be an ELF image. A bytecode file is started
  through the runtime, with the file as its first argument:
  `spawn "ocamlrun" [| "ocamlrun"; "/disk/prog.byte"; "arg" |]`.
- **`argv.(0)`** is by convention the program's name.
- **The result** is the child's pid. The child starts in the caller's
  current directory. A missing file, or a file that is not an ELF image,
  gives `MYNOS_ERR_INVALID` in C and `Mynos.Error ("spawn", -3)` in OCaml
  (`error_name` says `"invalid"`).

`fork` exists (appendix D.3), copying the caller copy-on-write, but with
no `execve` after it a forked child can only go on running the parent's
program. It is useful for that and little else; `spawn` is the way to
start a program.

## 15.2 Waiting for a program

A parent collects the end of its children with **wait**. In C it is the
ordinary `waitpid` (with `WIFEXITED`, `WEXITSTATUS`, `WIFSIGNALED`,
`WTERMSIG`); `WNOHANG` is the only option. In OCaml:

| Function | What it does |
|---|---|
| `Mynos.wait pid` | wait for that child: its `status` |
| `Mynos.wait_any ()` | wait for any child: `(pid, status)` |
| `Mynos.process_info pid` | `Some { alive; io }`, or `None` if it was collected; never waits |

```ocaml
type status =
  | Exited of int     (* the program called exit with this code *)
  | Signaled of int   (* killed: 9 by kill or Ctrl-C, 11 for an invalid
                         memory access *)
```

An OCaml program that ends with an uncaught exception prints it and
exits with code 2. Waiting with no child left raises
`Mynos.Error ("wait", -3)`. Until its parent waits for it, a process that
ended keeps its pid and its slot (a zombie); its memory is freed
without waiting for that. A child whose parent ends goes on running, as an orphan.

## 15.3 Ending a program

`mynos_kill(pid)` in C, `Mynos.kill pid` in OCaml, end a process at once,
as if it had been killed by signal 9: its parent's `wait` sees
`Signaled 9`. It is not a signal: the program runs no handler and has no
chance to clean up; its ports and channels are freed by the kernel, and
its clients see `MYNOS_ERR_BROKEN` (appendix C). Two processes cannot be
killed: `init`, and one with a privilege the killer lacks (only a driver
can end a driver). Only the process named ends; its children go on. A
whole tree is ended by walking `Mynos.processes ()`, as a terminal
window does when it closes (`gui/terminal.ml`).

`Mynos.processes ()` lists the live processes: pid, parent, `io`
privilege, threads, name, and whether it is bytecode. In C,
`mynos_processes(buf, max)` fills `mynos_process_t` records.

## 15.4 An example

A parent and a child, in OCaml. The child prints its arguments and a
variable of its environment, then exits with the code it was given, or
runs for ever:

```ocaml
(* worker.ml: started by procs.ml *)
let () =
  let greeting = Option.value (Sys.getenv_opt "GREETING") ~default:"(none)" in
  Printf.printf "worker %d: GREETING=%s, args [%s]\n%!" (Mynos.getpid ()) greeting
    (String.concat " " (List.tl (Array.to_list Sys.argv)));
  match Sys.argv with
  | [| _; "forever" |] -> while true do Mynos.sleep 1.0 done
  | [| _; code |] -> exit (int_of_string code)
  | _ -> exit 0
```

```ocaml
(* procs.ml: starting programs, waiting for them, ending them *)
let show = function
  | Mynos.Exited n -> Printf.sprintf "exited with %d" n
  | Mynos.Signaled s -> Printf.sprintf "killed by signal %d" s

let start ?env args =
  Mynos.spawn ?env "ocamlrun" (Array.append [| "ocamlrun"; "worker.byte" |] args)

let () =
  (* one child, our environment *)
  let pid = start [| "3" |] in
  Printf.printf "procs: %d %s\n%!" pid (show (Mynos.wait pid));
  (* another environment: ours, with one variable more *)
  let env = Array.append (Mynos.environment ()) [| "GREETING=ciao" |] in
  let pid = start ~env [| "0" |] in
  Printf.printf "procs: %d %s\n%!" pid (show (Mynos.wait pid));
  (* two at once, collected in the order they end *)
  let a = start [| "5" |] and b = start [| "7" |] in
  for _ = 1 to 2 do
    let pid, st = Mynos.wait_any () in
    Printf.printf "procs: %s %d %s\n%!" (if pid = a then "a" else if pid = b then "b" else "?")
      pid (show st)
  done;
  (* one in the background, ended by us *)
  let bg = start [| "forever" |] in
  Mynos.sleep 0.5;
  (match Mynos.process_info bg with
   | Some { Mynos.alive = true; _ } -> Printf.printf "procs: %d is running\n%!" bg
   | _ -> ());
  Mynos.kill bg;
  Printf.printf "procs: %d %s\n%!" bg (show (Mynos.wait bg));
  (* a program that is not there *)
  (match Mynos.spawn "nothing" [| "nothing" |] with
   | _ -> ()
   | exception Mynos.Error (fn, code) ->
     Printf.printf "procs: %s: %s\n%!" fn (Mynos.error_name code));
  print_endline "procs: done"
```

Both compiled with `-use-prims ... mynos.cma` (chapter 14), with
`worker.byte` and `ocamlrun` on the RAM disk, this prints (the kernel's
own lines, such as `process 5 exited with code 3`, left out):

```
worker 5: GREETING=(none), args [3]
procs: 5 exited with 3
worker 6: GREETING=ciao, args [0]
procs: 6 exited with 0
worker 7: GREETING=(none), args [5]
procs: a 7 exited with 5
worker 8: GREETING=(none), args [7]
procs: b 8 exited with 7
worker 9: GREETING=(none), args [forever]
procs: 9 is running
procs: 9 killed by signal 9
procs: spawn: invalid
procs: done
```

The same in C, with `waitpid`:

```c
/* run.c: start a program, wait for it; start another, end it */
#include <stdio.h>
#include <sys/wait.h>
#include <mynos.h>

int main(void)
{
  char * argv1[] = { "ocamlrun", "worker.byte", "4", NULL };
  char * argv2[] = { "ocamlrun", "worker.byte", "forever", NULL };
  char * env[] = { "GREETING=from C", NULL };
  int pid, st, info;

  pid = mynos_spawn("ocamlrun", argv1, env);
  if (pid < 0) { printf("run: spawn: %d\n", pid); return 1; }
  waitpid(pid, &st, 0);
  if (WIFEXITED(st)) printf("run: %d exited with %d\n", pid, WEXITSTATUS(st));

  pid = mynos_spawn("ocamlrun", argv2, NULL);
  mynos_sleep(500000);                     /* half a second */
  info = mynos_processInfo(pid);        /* negative: no such process */
  printf("run: %d alive: %s\n", pid,
         info >= 0 && (info & MYNOS_PROC_ALIVE) ? "yes" : "no");
  mynos_kill(pid);
  waitpid(pid, &st, 0);
  if (WIFSIGNALED(st)) printf("run: %d killed by signal %d\n", pid, WTERMSIG(st));
  return 0;
}
```

```
worker 5: GREETING=from C, args [4]
run: 5 exited with 4
worker 6: GREETING=(none), args [forever]
run: 6 alive: yes
run: 6 killed by signal 9
```

## 15.5 The environment

A child gets an environment of `NAME=value` strings: the one given to
`spawn`, or the caller's own when none is given (`envp` NULL in C,
`?env` left out in OCaml). In OCaml, `~env:[||]` also means "ours": a
child cannot be given an empty environment. `spawn` always replaces
`PWD` with the caller's current directory. A program reads its
environment with `getenv` and `environ` in C, `Sys.getenv_opt` and
`Mynos.environment ()` in OCaml.

Some variables mean something to MyNOS:

| Variable | Read by | Meaning |
|---|---|---|
| `PWD` | libmynos | the current directory the process starts in |
| `MYNOS_STDIN` | libmynos | a file that descriptor 0 stands for |
| `MYNOS_STDOUT`, `MYNOS_STDERR` | libmynos | a file for descriptor 1 or 2; `>>path` appends |
| `MYNOS_CONSOLE` | libmynos | the console service to use instead of `console`: a terminal window (chapter 18) |
| `OCAMLLIB` | `ocamlc`, the toplevel | where the standard library is: `/` inside MyNOS |
| `PATH`, `HOME` | `sh` | where commands are looked for (`/disk/bin:/`); `~` |

`sh` gives every program all its variables. `NAME=value prog` gives one
more to that program only; `export` and `unset` change the shell's own.
Redirections are variables too: `prog > /tmp/out.txt` starts `prog` with
`MYNOS_STDOUT=/tmp/out.txt` (chapter 18).

## 15.6 Privileges

A process has at most one privilege today, **`io`** (`MYNOS_PRIV_IO`):
port I/O with `in` and `out`, interrupts, device memory
(`mynos_mapPhysical`), and the well-known ports below 16. It is given at
spawn (`mynos_spawnPriv(..., MYNOS_PRIV_IO)`, `Mynos.spawn ~io:true`),
and only by a process that has it: `init` gives it to the lines of
`init.rc` marked `driver`. `sh` has none, so nothing started from the
shell has it. A service learns whether its caller has it from the kernel
(`Ipc.caller`'s `io` field, chapter 17), never from the request; and
`kill` refuses to end a process with a privilege the killer lacks. The
rules are in `doc/decisions/identity-and-permissions.md`.

## 15.7 Programs in the background

A process that does not wait for its child leaves it running. That is
all "background" means: from a program, spawn and go on, and collect the
child later with `wait`, `wait_any`, or `process_info` to see whether it
is still alive. At `sh`, `&` does it, `$!` is the pid, and `kill` takes a
pid or the name a service registered:

```
mynos:/$ /disk/kv.byte &
[14]
mynos:/$ echo started $!
started 14
mynos:/$ /disk/kv.byte set colour green
mynos:/$ /disk/kv.byte get colour
green
mynos:/$ kill kv
mynos:/$ GREETING=hi /disk/worker.byte 0
[14] done, status 137
worker 17: GREETING=hi, args [0]
```

(`kv.byte` is the service of chapter 17.) `sh` collects the programs it
started with `&` before each command line, and says how they ended:
`137` is 128 plus signal 9.

## 15.8 Threads in C

A C program has two kinds of threads. **POSIX threads** are musl's
`pthread_create`, `pthread_join`, mutexes and condition variables, on the
kernel's Linux `clone` and `futex` (appendix D.7); each has its own
thread-local storage, so it can call any C library function. They are
what a C program should use. **Native threads** (`mynos_threadCreate`,
2002) run a function on a stack the caller provides, and end by
returning from it or with `mynos_threadExit`; they share their
creator's thread-local storage (its `errno`, and the identity musl's
locks use), so they must not call the C library. `consoled`'s input
threads are native threads that only translate keys. MyNOS's
**semaphores** (`mynos_initSem`, `mynos_P`, `mynos_tryP`, `mynos_V`,
`mynos_freeSem`) work with both:

```c
/* cthreads.c: POSIX threads, and MyNOS's own */
#include <stdio.h>
#include <pthread.h>
#include <mynos.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static long counter = 0;

static void * add(void * arg)
{
  int i;
  for (i = 0; i < 10000; i++) {
    pthread_mutex_lock(&lock);
    counter++;
    pthread_mutex_unlock(&lock);
  }
  return arg;
}

static int done;                         /* a MyNOS semaphore */
static char stack[16384];
static long squares;

/* a native thread shares its creator's TLS: no C library calls here */
static void * native(void * arg)
{
  long i, n = (long)arg;
  for (i = 1; i <= n; i++) squares += i * i;
  mynos_V(done);
  return NULL;
}

int main(void)
{
  pthread_t t[3];
  int i;

  for (i = 0; i < 3; i++) pthread_create(&t[i], NULL, add, NULL);
  for (i = 0; i < 3; i++) pthread_join(t[i], NULL);
  printf("pthreads: counter %ld\n", counter);

  done = mynos_initSem(0);
  mynos_threadCreate(native, (void *)100, stack + sizeof stack, 0);
  mynos_P(done);                         /* wait for it */
  mynos_freeSem(done);
  printf("native thread: squares %ld\n", squares);
  return 0;
}
```

```
pthreads: counter 30000
native thread: squares 338350
```

The stack argument of `mynos_threadCreate` is the **top** of the stack:
the library pushes the argument and a return address into
`mynos_threadExit` below it.

## 15.9 OCaml domains

OCaml 5's domains (`Domain.spawn`, `Domain.join`, `Atomic`, `Mutex`,
`Condition`, `Domain.DLS`) work as on Linux; they need no flag and no
library beyond the standard one:

```ocaml
(* domains.ml: OCaml 5 domains *)
let rec fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

let () =
  let ds = List.map (fun n -> Domain.spawn (fun () -> (n, fib n))) [ 20; 21; 22 ] in
  List.iter (fun d -> let n, f = Domain.join d in Printf.printf "fib %d = %d\n" n f) ds;
  let hits = Atomic.make 0 in
  let ds = List.init 4 (fun _ ->
      Domain.spawn (fun () -> for _ = 1 to 1000 do Atomic.incr hits done)) in
  List.iter Domain.join ds;
  Printf.printf "hits: %d\n" (Atomic.get hits)
```

```
fib 20 = 6765
fib 21 = 10946
fib 22 = 17711
hits: 4000
```

MyNOS runs on one processor (mynos-awn): domains take turns and are not
faster than one. They are a way to structure a program: a terminal window
serves its console requests in one domain and draws in another, and
`init` serves power/1 in a domain of its own. Each domain is a Linux
thread, with a second "backup" thread of the runtime (appendix F.7).

## 15.10 OCaml threads

Threads (`Thread`, `Mutex`, `Condition`, `Event`) run inside one domain
and take turns with its runtime lock: a thread runs OCaml code only while
it holds it. Compile with `unix.cma threads.cma -noautolink` (14.4). A
thread gives the lock up:

- every 50 ms, when the runtime's tick asks it to;
- at `Thread.yield`, `Thread.delay`, `Mutex.lock` that waits,
  `Condition.wait`, `Event.sync`;
- in a call that waits outside OCaml: reading and writing files and the
  console through the standard library, `Unix.sleepf`, and the `Mynos`
  calls that can wait.

The `Mynos` calls that can wait release the lock; the others return at
once and keep it (appendix F.4):

| Release the lock (they can wait) | Keep it (they return at once) |
|---|---|
| `send`, `recv` | `free_channel`, `channel_peer` |
| `connect`, `listen` | `alloc_port`, `free_port`, `change_port_owner` |
| `sem_p` | `sem_create`, `sem_try_p`, `sem_v`, `sem_free` |
| `sleep` | `getpid`, `uptime`, `time`, `stats`, `log`, `environment` |
| `register`, `lookup`, `registered` | `process_info`, `processes`, `kill` |
| `spawn`, `wait`, `wait_any` | port I/O, `driver_register`, `enable_irq` |
| `console_mode`, `console_foreground` | |

So a thread can wait for a message while the others go on. In this
example one thread waits in `Mynos.listen` and `Mynos.recv` on a port of
the program's own, another prints, and the main thread then sends the
message:

```ocaml
(* othreads.ml: OCaml threads; a thread that waits in a MyNOS call *)
let () =
  let m = Mutex.create () and c = Condition.create () in
  let box = ref None in
  (* a thread waits for a message on a port of ours, with a timeout *)
  let port = Mynos.alloc_port () in
  let server = Thread.create (fun () ->
      let ch = Mynos.listen port in
      let msg = Mynos.recv ~timeout:5.0 ch in
      Mynos.free_channel ch;
      Mutex.lock m; box := Some msg; Condition.signal c; Mutex.unlock m) () in
  (* meanwhile this one goes on: the waiting thread gave the lock up *)
  let ticker = Thread.create (fun () ->
      for i = 1 to 3 do Printf.printf "tick %d\n%!" i; Thread.delay 0.1 done) () in
  Thread.join ticker;
  let ch = Mynos.connect port in
  Mynos.send ch "hello, thread";
  Mynos.free_channel ch;
  Mutex.lock m;
  while !box = None do Condition.wait c m done;
  Mutex.unlock m;
  Thread.join server;
  Printf.printf "got: %s\n" (Option.get !box);
  (* Event: a rendezvous *)
  let e = Event.new_channel () in
  let t = Thread.create (fun () -> Event.sync (Event.send e 42)) () in
  Printf.printf "event: %d\n%!" (Event.sync (Event.receive e));
  Thread.join t
```

```
tick 1
tick 2
tick 3
got: hello, thread
event: 42
```

A thread that loops in OCaml code without allocating, or waits in a C
stub that keeps the lock, holds up the others of its domain; and every
domain waits for it at the next garbage collection. A program that must
wait for several things at once (a service that keeps requests pending
while it watches the keyboard) can choose between threads, domains, and
effect handlers over a small scheduler of its own:

| | Threads | Domains | Effects |
|---|---|---|---|
| Unit | `Thread.t`, in one domain | `Domain.t`, its own heap and lock | a function suspended in user space |
| Taking turns | the runtime lock, tick every 50 ms | the kernel's scheduler | where the program says (`perform`) |
| Libraries | `unix.cma threads.cma -noautolink` | the standard library | the standard library |
| Shares | everything, under the lock | the heap, with `Atomic`, `Mutex` | everything; one thread |

## 15.11 Known limits

- No `execve`, no process groups, no sessions; `waitpid`'s only option is
  `WNOHANG`.
- `kill` is the only way to end another process; there are no signals to
  catch, and no cleanup on the victim's side.
- One processor: domains and threads take turns (mynos-awn).
- A native thread must not use the C library (15.8).
- In OCaml, a child cannot be given an empty environment (15.5).

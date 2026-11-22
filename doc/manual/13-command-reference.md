# 13. Command Reference

This chapter describes, in alphabetical order, every command you can
type at the `sh` prompt: the commands built into the shell and the
programs on the RAM disk. Each entry gives the command's purpose, its
syntax, its type, what it does, examples, and related commands. 13.1
explains the notation, 13.2 summarizes the shell's language, 13.3 holds
the entries, and 13.4 lists the files of the RAM disk that look like
commands but are not meant to be typed.

## 13.1 How to read an entry

```
UPPER CASE        the command's name (type it in lower case)
cat FILE...       words in this type are typed as shown
FILE              a word in capitals is one you choose
[-l]              brackets: an optional part
...               the part before may be repeated
a|b               one or the other
```

**Type** is either *built in* (part of `sh`: it runs inside the shell,
and changes the shell itself, as `cd` does) or *program* (a file on the
RAM disk, started as a process of its own; most are OCaml bytecode,
`NAME.byte`, run by `ocamlrun`). `which NAME` tells which.

A program is found in the directories of `PATH`, which is `/disk/bin:/`:
first `/disk/bin`, where you may put programs of your own, then the RAM
disk. `NAME` finds `NAME` or `NAME.byte`. A name containing `/`
(`./hello`, `/tmp/p.byte`) is taken as a path.

Every command returns an **exit status**: 0 for success; 1 (usually) for
a failure; 2 for a mistake in the command line; 126 if a program could
not be started; 127 for a command not found; 128 plus a number for a
program ended from outside (137: killed, by Ctrl-C or `kill`). `$?` is
the last status.

## 13.2 The shell in brief

Chapters 6 and 7 introduce the shell; this is the summary.

| Write | Meaning |
|---|---|
| `cmd1 ; cmd2` | one after the other |
| `cmd1 && cmd2` | `cmd2` only if `cmd1` succeeded (status 0) |
| `cmd1 \|\| cmd2` | `cmd2` only if `cmd1` failed |
| `cmd &` | start a program and do not wait; `$!` is its pid (a built-in cannot be) |
| `cmd < FILE` | standard input from `FILE` |
| `cmd > FILE`, `cmd >> FILE` | standard output into `FILE`, replaced or appended |
| `cmd1 \| cmd2` | the output of `cmd1` as the input of `cmd2` (run one after the other, through a file in `/tmp`) |
| `'text'`, `"text"`, `\c` | quoting; `$` is expanded inside `"..."`, not inside `'...'` |
| `$NAME`, `${NAME}` | a variable's value |
| `$?`, `$!`, `$#`, `$0`, `$1`... | last status, last background pid, number of arguments, the script's name and arguments |
| `NAME=value` | set a variable (alone on the line), or set it for one command (before the command's name) |
| `*`, `?` | in a word: the file names that match (names starting with `.` only if the pattern does) |
| `# ...` | a comment, to the end of the line |

There is no arithmetic, no `if`, `for` or `while`, no functions and no
command substitution. Variables are expanded when each command runs, so
`X=5; echo $X` prints 5. All variables are passed to the programs the
shell starts. Initially: `PATH=/disk/bin:/`, `HOME=/disk`, `OCAMLLIB=/`.

**Keys at the prompt.** Left, Right, Home (Ctrl-A), End (Ctrl-E) move;
Backspace and Delete erase; Ctrl-K erases to the end, Ctrl-U to the
start, Ctrl-W the word before; Ctrl-L clears the screen; Ctrl-C abandons
the line; Ctrl-D on an empty line leaves the shell. Up and Down recall
earlier lines, kept in `/disk/.sh_history` (the last 200). Tab completes
a command's name or a file's; a second Tab lists the choices. While a
program runs, Ctrl-C ends it; Shift+Page Up and Page Down scroll the
console back.

## 13.3 The commands

---

### . (SOURCE)

Runs the commands of a file in the current shell. See SOURCE.

---

### AGENT

**Purpose** Carries out a task with a language model and the system's
tools, asking before it changes anything.

**Syntax**

```
agent [-p PROFILE] [-s SERVICE,...] [-y] [-n TURNS] [-t FILE] TASK...
```

**Type** Program (`/agent.byte`).

**Description** The words of `TASK` go to the model with the agent's
tools (commands, files, OCaml programs) and the requests of the typed
services named by `-s` (`net` by default). Each action that changes
something is shown with `Do it? [y/N/a]`: `y` yes, `a` yes to all, any
other key no. `-p` chooses the model profile, `-y` answers yes to
everything, `-n` limits the calls to the model (20), `-t` names the
recording's file (`/tmp/agent.trc`). Ends with the tokens used. Status 0
once the model has answered, 1 if it stopped (an error, a refusal, too
many calls), 2 for a bad command line. Needs a configured model.

**Examples**

```
agent Write the IP address of MyNOS in /disk/ip.txt
agent -s net,registry Which services are running?
trace calls /tmp/agent.trc
```

**See also** ASK, LLM, TRACE; chapter 12.

---

### AGENT_WINDOW

**Purpose** The agent in a window.

**Syntax** `agent_window`

**Type** Program (`/agent_window.byte`), graphical.

**Description** Opens the Agent window of the graphical session (the
MyNOS menu's Agent): a task typed at the bottom, the conversation above,
confirmations as Allow, Deny and Allow all buttons, a Recording button.
Outside the session it says so and ends with status 2, like every
graphical program.

**See also** AGENT, GUI; chapter 12, 12.8.

---

### ASK

**Purpose** Asks a language model for a command line, and runs it if you
agree.

**Syntax**

```
ask [-p PROFILE] REQUEST...
```

**Type** Built in.

**Description** The model is told about the shell, its commands, the
current directory and its files, and proposes one command line with an
explanation. `ask` prints both and asks `Run it? [y/N]`; `y` runs the line
in this shell (a `cd` in it stays), anything else does not (status 1).
An answer in words, when no command is needed, is printed instead.

**Examples**

```
ask list the files in /disk with their sizes
ask -p local how much memory is free?
```

**See also** AGENT, LLM; chapter 12, 12.4.

---

### CAT

**Purpose** Prints files.

**Syntax** `cat [FILE...]`

**Type** Built in.

**Description** Writes the files, one after the other, to the standard
output. Without a file, it copies its input (from `<`, a pipe, or the
keyboard until Ctrl-D).

**Examples**

```
cat /init.rc
cat a.txt b.txt > both.txt
cat /disk/notes.txt | cat
```

**See also** ECHO, EDIT; chapter 7.

---

### CD

**Purpose** Changes the current directory.

**Syntax** `cd [DIRECTORY]`

**Type** Built in.

**Description** Without a directory, goes to `$HOME` (`/disk`). The
prompt shows the current directory; programs started afterwards start
there.

**Examples** `cd /disk/docs`, `cd ..`, `cd`

**See also** PWD; chapter 7, 7.5.

---

### CHILD

**Purpose** A test program: prints its arguments and ends with a chosen
status.

**Syntax** `child [CODE|crash]`

**Type** Program (`/child.byte`), used by the tests.

**Description** Prints `spawn child PID (parent PPID): args [...]`, then
ends with status `CODE` (3 without an argument). `crash` makes it fail
on a bad system call.

**Example**

```
mynos:/$ child 7; echo status $?
spawn child 41 (parent 13): args [7]
status 7
```

**See also** HELLO.

---

### CLEAR

**Purpose** Clears the screen.

**Syntax** `clear`

**Type** Built in. (Ctrl-L at the prompt does the same.)

---

### CLOCK

**Purpose** A clock window.

**Syntax** `clock`

**Type** Program (`/clock.byte`), graphical.

**Description** A round clock with the time in UTC, redrawn every
second. In the graphical session only.

**See also** GUI; chapter 10, 10.7.

---

### CP

**Purpose** Copies a file.

**Syntax** `cp SOURCE DESTINATION`

**Type** Built in.

**Description** Copies one file. If `DESTINATION` is a directory, the
copy keeps the source's name in it. Directories are not copied.

**Examples** `cp /init.rc /disk/init.rc`, `cp notes.txt /tmp`

**See also** MV, RM.

---

### ECHO

**Purpose** Prints its arguments.

**Syntax** `echo [WORD...]`

**Type** Built in.

**Description** Writes the words, separated by one space, and a new line.
There are no options.

**Examples** `echo hello > /tmp/a.txt`, `echo status $?`

---

### EDIT

**Purpose** A full-screen text editor, in OCaml.

**Syntax** `edit FILE`

**Type** Program (`/edit.byte`).

**Description** Arrows, Home, End, Page Up and Page Down move; typing
inserts; Backspace, Delete and Enter join and split lines. Ctrl-S saves,
Ctrl-Q quits (twice if there are unsaved changes), Ctrl-K cuts a line,
Ctrl-U pastes it, Ctrl-F searches (Enter: the next match, Esc: done).
Tabs become spaces when the file is read. Text is UTF-8: accented
letters are typed and shown. Ctrl-C is an ordinary key. It works in a
terminal window too.

**Example** `edit /disk/hello.ml`

**See also** KILO, OCAMLC; chapter 8, 8.3.

---

### ENV

**Purpose** Lists the shell's variables.

**Syntax** `env`

**Type** Built in.

**Description** Prints `NAME=value` for each variable, sorted. All of
them are passed to the programs the shell starts.

**See also** EXPORT, UNSET.

---

### EXIT

**Purpose** Leaves the shell.

**Syntax** `exit [STATUS]`

**Type** Built in.

**Description** Ends the shell with `STATUS`, or with the last command's
status. At the console, `init` starts a new shell at once; in a terminal
window, the window closes; in a script, the script ends.

**See also** SHUTDOWN.

---

### EXPORT

**Purpose** Sets variables.

**Syntax** `export NAME=value...`

**Type** Built in.

**Description** Sets each variable. Every variable is passed to programs
anyway: `export X=1` is the same as `X=1`. A word without `=` is ignored.

**See also** ENV, UNSET.

---

### FALSE

**Purpose** Fails: does nothing, with status 1.

**Syntax** `false`

**Type** Built in.

**Example** `false || echo it failed`

**See also** TRUE.

---

### FETCH

**Purpose** An HTTP or HTTPS request from the command line.

**Syntax**

```
fetch [-i] [-o FILE] [-H 'Name: value']... [-d DATA|@FILE] [-X METHOD] URL
```

**Type** Program (`/fetch.byte`).

**Description** Prints the body of the answer. `-i` prints the status and
the headers first; `-o` writes the body into a file; `-H` adds a header;
`-d` sends data (`@FILE`: a file's contents), as a `POST`; `-X` sets the
method. HTTPS certificates are checked against `/cacert.pem` and
`/disk/ca.pem`. Status 0 for an answer below 400, 1 otherwise or on an
error (`fetch: REASON`), 2 for a bad command line.

**Examples**

```
fetch https://example.com/
fetch -i -o /tmp/ex.html https://example.com/
fetch -d "q=1" -H "X-Test: yes" https://httpbin.org/post
fetch -o /disk/notes.txt http://10.0.2.2:8000/notes.txt
```

**See also** HOST, PING; chapter 9, 9.5.

---

### FILES

**Purpose** The file manager.

**Syntax** `files [DIRECTORY]`

**Type** Program (`/files.byte`), graphical.

**Description** Opens the Files window at `DIRECTORY` (`/` by default):
places, the service that serves each, entries; Open, New folder, Rename,
Delete, Copy, Cut, Paste.

**See also** GUI; chapter 10, 10.9.

---

### FREE

**Purpose** Shows the free memory.

**Syntax** `free`

**Type** Built in.

**Example**

```
mynos:/$ free
192056 KB free
```

**See also** PS.

---

### GUI

**Purpose** Starts the graphical session.

**Syntax** `gui [stop|check]`

**Type** Program (`/gui.byte`).

**Description** `gui` switches the screen to graphics, opens the welcome
window, and waits until the session ends (the MyNOS menu's Exit); then it
prints `gui: the graphical session ended`. `gui stop` ends the session
from any program. `gui check` compares the display server's description
of its protocol with the library's (for the tests).

**See also** chapter 10.

---

### HELLO

**Purpose** The smallest OCaml program.

**Syntax** `hello`

**Type** Program (`/hello.byte`).

**Description** Prints `Hello from OCaml on MyNOS!` and five squares.
The Tour's third lesson watches it being born.

---

### HELP

**Purpose** A summary of the shell's commands.

**Syntax** `help`

**Type** Built in.

---

### HOST

**Purpose** Finds a machine's address by its name (DNS).

**Syntax** `host NAME`

**Type** Built in.

**Example**

```
mynos:/$ host example.com
example.com has address 104.20.23.154
```

**See also** PING; chapter 9, 9.4.

---

### IFCONFIG

**Purpose** Shows the network's configuration.

**Syntax** `ifconfig`

**Type** Built in.

**Example**

```
mynos:/$ ifconfig
e0: 52:54:00:12:34:56
    address 10.0.2.15 netmask 255.255.255.0
    gateway 10.0.2.2 dns 10.0.2.3
```

**See also** chapter 9, 9.2.

---

### KEYMAP

**Purpose** Shows or changes the keyboard layout.

**Syntax** `keymap [us|it]`

**Type** Built in.

**Description** Without an argument, prints the layout in use. `it` is
the Italian layout, with AltGr (or Ctrl+Alt) for `@ # [ ] { } ~ €`; `us`
the American one. The choice is kept on `/disk/.keymap`.

**See also** chapter 6, 6.5.

---

### KILL

**Purpose** Ends processes.

**Syntax** `kill PID|SERVICE...`

**Type** Built in.

**Description** Each argument is a pid, or the name a service registered
(`fatfs`, `llm`...), which stands for its process. The process ends at
once (there are no signals: it is killed, status 137). `init` (pid 1)
and the drivers cannot be killed. A service `init` started comes back
(chapter 11, 11.7).

**Examples**

```
kill 43
hello > /tmp/h.txt & kill $!
kill fatfs
```

**See also** PS.

---

### KILO

**Purpose** A small text editor, in C.

**Syntax** `kilo FILE`

**Type** Program (`/kilo`, native).

**Description** Salvatore Sanfilippo's kilo, with two small changes for
MyNOS (in how it reads and saves files): Ctrl-S saves, Ctrl-Q quits
(three times if the file is modified), Ctrl-F finds. It is there to
show that an ordinary C program for a Unix terminal runs on MyNOS.

**See also** EDIT; chapter 8, 8.4.

---

### LLM

**Purpose** Asks a language model a question.

**Syntax**

```
llm [-p PROFILE] [-s SYSTEM] [-v] QUESTION...
llm -l
```

**Type** Program (`/llm.byte`).

**Description** Prints the model's answer. `-p` chooses a profile of
`/disk/llm.env`, `-s` gives a system prompt (one word: quote it), `-v`
adds the model's name and the tokens used, `-l` lists the profiles.
Without a question, it is read from the input.

**Examples**

```
llm -l
llm Which year was OCaml born?
llm -p local -s 'Answer in one word.' Capital of Italy?
llm < question.txt
```

**See also** AGENT, ASK; chapter 12.

---

### LOG

**Purpose** Prints the kernel's log: its messages and the services'
(`Mynos.log`) since boot, the last 64 KB of them.

**Syntax** `log [-f]`

**Type** Program (`/log.byte`).

**Description** Without options, prints what the kernel has kept. `-f`
then follows it: new messages appear as they are logged, until Ctrl-C.
The same messages go to the second serial port, as they always did.

**Example**

```
mynos:/$ log
Welcome to MyNOS - v2026.11-71dc1d2
...
init: started fatfs.byte (pid 8)
fatfs: FAT16, 8167 clusters of 2048 bytes, service fs/1 as fatfs
```

**See also** LOG_WINDOW, TRACE; chapter 11.

---

### LOG_WINDOW

**Purpose** The kernel's log in a window, followed as it grows.

**Syntax** `log_window`

**Type** Program (`/log_window.byte`), graphical; the MyNOS menu's
**Log**.

**See also** LOG; chapter 10.

---

### LS

**Purpose** Lists directories.

**Syntax** `ls [-l] [-a] [PATH...]`

**Type** Built in.

**Description** Lists the entries of each directory (the current one by
default), sorted, directories followed by `/`; names starting with `.`
are not shown. A file is listed by its name. With `-l`, each line starts
with the size (in bytes below 10,000, else in KB, `397K`) or `dir`.

**Examples** `ls`, `ls -l /disk`, `ls /*.cma`

**See also** CD, FILES; chapter 7.

---

### MKDIR

**Purpose** Makes directories.

**Syntax** `mkdir DIRECTORY...`

**Type** Built in.

**Description** Only `/disk` has directories: `/` is read-only and
`/tmp` is one flat directory.

**See also** RMDIR.

---

### MV

**Purpose** Moves or renames a file.

**Syntax** `mv SOURCE DESTINATION`

**Type** Built in.

**Description** If `DESTINATION` is a directory, the file goes into it.
Within one file service it is renamed; between two (`/tmp` and `/disk`)
it is copied, then removed.

**Examples** `mv a.txt b.txt`, `mv /tmp/out.txt /disk`

**See also** CP, RM.

---

### OCAML

**Purpose** The OCaml toplevel.

**Syntax** `ocaml`

**Type** Built in name for the program `/shell.byte`.

**Description** Phrases typed, ended by `;;`, are compiled and run.
Module `Shell` is open (`ls ();;`, `run "hello.byte" [];;`, `sh ();;`);
the system's interface is module `Mynos`. `#quit;;` or Ctrl-D comes back
to `sh`.

**See also** OCAMLC; chapter 8, 8.1.

---

### OCAMLC

**Purpose** The OCaml bytecode compiler, inside MyNOS.

**Syntax** `ocamlc [OPTIONS] FILE.ml...`

**Type** Program (`/ocamlc.byte`), the standard compiler, OCaml 5.5.2.

**Description** Compiles OCaml programs into bytecode that runs on
MyNOS. To use MyNOS's library (`Mynos`, `Net`, `Gui`...), add `-use-prims
/primitives mynos.cma`; for threads, also `unix.cma threads.cma
-noautolink`.

**Examples**

```
ocamlc -o /disk/hello.byte /disk/hello.ml && /disk/hello
ocamlc -use-prims /primitives mynos.cma -o p.byte p.ml
```

**See also** EDIT, OCAML; chapter 8, 8.5–8.7.

---

### PACKAGES

**Purpose** The packages, in a window.

**Syntax** `packages`

**Type** Program (`/packages.byte`), graphical.

**Description** Opens the Packages window: the packages of the index,
the installed ones marked; for the one chosen, its description and
Install, Upgrade, Run, Remove; Update index. Each button runs `pkg` and
shows its output.

**See also** PKG, GUI; chapter 10, 10.14.

---

### PING

**Purpose** Checks that a machine answers.

**Syntax** `ping HOST [COUNT]`

**Type** Built in.

**Description** Sends `COUNT` echo requests (3 by default), one a second,
and prints each round trip time, or why there was none (`timeout`, after
two seconds). `HOST` is an address or a name.

**Examples**

```
mynos:/$ ping 10.0.2.2 2
reply from 10.0.2.2: time 0 ms
reply from 10.0.2.2: time 0 ms
```

**See also** HOST, IFCONFIG; chapter 9, 9.3.

---

### PKG

**Purpose** Installs packages: demos and programs from the web.

**Syntax**

```
pkg list [-i]
pkg search WORD
pkg info NAME
pkg install [-s] NAME...
pkg remove NAME...
pkg update
pkg upgrade
```

**Type** Program (`/pkg.byte`).

**Description** Reads the index of the packages' repository
(`ctrl-z-bg/mynos-packages` on GitHub, or the one `MYNOS_PKG_URL`, or
else the first line of `/disk/pkg/url`, names) and keeps a copy in `/disk/pkg/index.json`; `update` reads it
again. `install` downloads a package's archive, checks its size and
BLAKE2b hash against the index, unpacks it in `/disk/pkg/NAME` and puts
its program in `/disk/bin`, on `PATH`: the bytecode it holds if this
MyNOS can run it, otherwise (or with `-s`) the program compiled from its
sources by `ocamlc`; the packages it needs come first, and its commands
(scripts of one line, `#!PROGRAM`) go beside it. `remove` deletes them.
`upgrade` reads the index and installs the newer versions; `search`
looks in names and descriptions. `list` marks the installed
packages, with their version when it is older than the index's;
`list -i` lists the installed packages only, from `/disk`, without the
network. Status 0
on success, 1 on an error (`pkg: REASON`), 2 for a bad command line.

**Examples**

```
pkg list
pkg install 2048
pkg list -i
pkg info windtree
MYNOS_PKG_URL=http://10.0.2.2:8000/ pkg install -s windtree
pkg remove 2048
```

**See also** FETCH, PACKAGES, WHICH; chapter 9, 9.8; chapter 10, 10.14;
appendix H, H.9.

---

### PLAY

**Purpose** Plays sound: WAV files and tones.

**Syntax** `play FILE.wav` · `play -t HZ [MS]` · `play -v [LEVEL]`

**Type** Program (`/play.byte`).

**Description** Plays a WAV file (PCM, 8 or 16 bits, mono or stereo, any
rate, converted to the card's 22050 Hz stereo) and returns when it has
played; `-t` plays a tone of `HZ` for `MS` milliseconds (200); `-v` sets
the volume (0 to 100) or prints it. Several programs may play at once:
`soundd` mixes them. Without a sound card (`--no-sound`, a machine
without a Sound Blaster 16) it says so and ends with status 1.

**Example**

```
mynos:/$ play -t 440 500
mynos:/$ play /disk/hello.wav
mynos:/$ play -v 50
volume 50
```

**See also** appendix E, E.15.

---

### PS

**Purpose** Lists the processes.

**Syntax** `ps`

**Type** Built in.

**Description** One line per process: pid, parent, threads, `io` for a
process with the hardware privilege, its name, and the names it
registered (its services).

**See also** KILL, SYSTEM; chapter 11, 11.1.

---

### PWD

**Purpose** Prints the current directory.

**Syntax** `pwd`

**Type** Built in.

---

### RECORDINGS

**Purpose** The recordings window.

**Syntax** `recordings [FILE]`

**Type** Program (`/recordings.byte`), graphical.

**Description** Shows a recording of the event recorder as a timeline
or as a list of calls: `FILE`, else `/tmp/agent.trc`, else
`/tmp/last.trace`. It can also record a command.

**See also** SYSTEM, TRACE; chapter 11, 11.4.

---

### RM

**Purpose** Removes files.

**Syntax** `rm FILE...`

**Type** Built in.

**Description** Removes each file; there is no `-r`, and directories are
removed with `rmdir`. Nothing can be removed from `/`.

**See also** RMDIR.

---

### RMDIR

**Purpose** Removes empty directories.

**Syntax** `rmdir DIRECTORY...`

**Type** Built in.

---

### SERVICES

**Purpose** The service explorer.

**Syntax** `services`

**Type** Program (`/services.byte`), graphical.

**Description** Lists the typed services `display`, `net`, `llm` and
`ata0`, their requests from their own descriptions, and makes a form to
call any of them.

**See also** chapter 10, 10.8.

---

### SH

**Purpose** The command shell.

**Syntax**

```
sh
sh FILE [ARGUMENT...]
sh -c COMMANDS
```

**Type** Program (`/sh.byte`).

**Description** Without arguments, an interactive shell (this one).
`sh FILE` runs a script, its arguments in `$1`, `$2`..., `$#`; `sh -c`
runs one line. `init` starts the console's `sh` and starts it again when
it ends. Programs started by `sh -c CMD > FILE` write into `FILE` too.

**Examples**

```
sh /disk/setup.sh one two
sh -c 'cd /disk; ls'
```

**See also** SOURCE; 13.2.

---

### SHELL

The program behind `ocaml` (`/shell.byte`). See OCAML.

---

### SHUTDOWN

**Purpose** Turns the machine off, or restarts it.

**Syntax** `shutdown [-r]`

**Type** Program (`/shutdown.byte`).

**Description** Asks `init`, which ends the graphical session if one is
on, then turns the machine off (QEMU ends) or, with `-r`, restarts it.
If the machine does not turn itself off, MyNOS says it can be turned off
now.

**See also** EXIT; chapter 6, 6.13.

---

### SOURCE

**Purpose** Runs the commands of a file in this shell.

**Syntax** `source FILE [ARGUMENT...]` or `. FILE [ARGUMENT...]`

**Type** Built in.

**Description** Like `sh FILE`, but in the current shell: a `cd` or a
variable set in the file stays set afterwards.

**Example**

```
mynos:/$ echo 'echo script $1 $#' > /tmp/s.sh
mynos:/$ source /tmp/s.sh c
script c 1
```

**See also** SH.

---

### SYSTEM

**Purpose** The System window: MyNOS as it runs.

**Syntax** `system [FILE] [--lesson LESSON]`

**Type** Program (`/system.byte`), graphical.

**Description** Draws the hardware, the kernel, the drivers, the
services and the programs, one box per live process; replays `FILE`, a
recording, on it. `--lesson` (used by the Tour) shows it as a lesson
written in the Tour's format.

**See also** RECORDINGS, TOUR; chapter 11, 11.5.

---

### TERMINAL

**Purpose** A terminal window with its own shell.

**Syntax** `terminal`

**Type** Program (`/terminal.byte`), graphical.

**Description** Runs `sh` in an 80 x 25 window, with 1000 lines of
scrollback. Closing it ends its `sh`.

**See also** chapter 10, 10.6.

---

### TOUCH

**Purpose** Creates empty files.

**Syntax** `touch FILE...`

**Type** Built in.

**Description** Creates each file if it does not exist; an existing file
is left as it is.

---

### TOUR

**Purpose** Lessons on how an operating system works.

**Syntax** `tour`

**Type** Program (`/tour.byte`), graphical.

**Description** Lists the lessons of `/tour.txt` and `/disk/tour.txt`;
each runs a command under the recorder and replays it in the System
window.

**See also** chapter 11, 11.6.

---

### TRACE

**Purpose** Records what the whole system does.

**Syntax**

```
trace [-o FILE] COMMAND...
trace -s SECONDS [-o FILE]
trace show FILE
trace calls FILE
trace json FILE OUT
```

**Type** Program (`/trace.byte`).

**Description** `trace COMMAND` runs the command (with `sh -c`), records
every message, process and interrupt meanwhile, saves the recording
(`/tmp/last.trace`, or `-o FILE`) and prints the calls. `-s` records the
whole system for some seconds. `show` prints a recording's events,
`calls` its calls, nested, with their durations and marks; `json` writes
it for Perfetto. One recording at a time.

**Examples**

```
trace cat /disk/hello.txt
trace -o /tmp/h.trc ls /disk
trace calls /tmp/agent.trc
trace json /tmp/h.trc /disk/h.json
```

**See also** RECORDINGS, SYSTEM; chapter 11, 11.2.

---

### TRUE

**Purpose** Succeeds: does nothing, with status 0.

**Syntax** `true`

**Type** Built in.

**See also** FALSE.

---

### UNSET

**Purpose** Removes variables.

**Syntax** `unset NAME...`

**Type** Built in.

**See also** ENV, EXPORT.

---

### VERSION

**Purpose** Prints the system's version: the year and month it was
built, and the commit it was built from.

**Syntax** `version`

**Type** Built in.

**Example**

```
mynos:/$ version
MyNOS 2026.11-71dc1d2
```

**See also** the boot's first line, `Welcome to MyNOS - v...`.

---

### WELCOME

**Purpose** The welcome window.

**Syntax** `welcome`

**Type** Program (`/welcome.byte`), graphical.

**See also** GUI; chapter 10, 10.1.

---

### WHICH

**Purpose** Tells what a command name is.

**Syntax** `which NAME...`

**Type** Built in.

**Description** For a built-in, prints `NAME: built in`; for a program,
its file. The status is 1 if one of the names is neither.

**Example**

```
mynos:/$ which ls fetch
ls: built in
/fetch.byte
```

## 13.4 Files of the RAM disk that are not commands

`PATH` includes `/`, so every program of the RAM disk can be typed by
name, and Tab offers them all. These are not meant to be started by
hand:

| Name | What it is |
|---|---|
| `init` | the first program, started at boot; it reads `init.rc` and starts the services: not to be started again |
| `ata`, `consoled`, `displayd`, `netd`, `soundd` | drivers, started by `init` with the `io` privilege; started from `sh` they have none: `ata` says so and stops, the others are ended at their first access to the hardware (status 139) |
| `fatfs`, `tmpfs`, `llmd` | services, started by `init` and restarted by it (chapter 11, 11.7) |
| `httpd` | the web server, started by `init`; `httpd [-w] [DIR [PORT]] &` starts another, on another port; it receives files too (`curl -T`) (chapter 9, 9.7) |
| `ocamlrun` | the OCaml runtime, which `sh` uses to run every `.byte` program |
| `primitives`, `runtime-launch-info` | data files for `ocamlc`, not programs: `sh` does not offer them as commands |

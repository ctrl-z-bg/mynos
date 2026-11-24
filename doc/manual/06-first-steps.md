# 6. First steps at the console

When MyNOS has started, the screen belongs to **`sh`**, the command
shell. This chapter shows how to talk to it: how to type commands and
correct them, which commands there are, how to stop a program or leave
one running, how to use a second terminal, and how to turn the machine
off. Files have a chapter of their own (chapter 7).

## 6.1 The prompt

```
  mynos:/$ _
```

The **prompt** says that `sh` is waiting for a command. Between the
colon and the dollar sign is the **current directory**, here `/`, the
root. Type a command, press Enter, and `sh` runs it; when it has
finished, the prompt comes back.

`sh` is a small shell in the style of the Unix shells, written in OCaml
(`sh/sh.ml`). MyNOS has a second, very different shell, the OCaml
toplevel, which `ocaml` starts (chapter 8). The console itself, the
keyboard and the screen, is a service of its own, `consoled`.

## 6.2 Your first commands

Type `help` and press Enter. `sh` prints a short summary of everything it
knows. Then try these, one at a time:

```
  mynos:/$ echo hello world
  hello world
  mynos:/$ pwd
  /
  mynos:/$ which ls edit
  ls: built in
  /edit.byte
  mynos:/$ free
  2012032 KB free
```

`echo` repeats its words; `pwd` prints the current directory; `which`
says where a command comes from; `free` prints the free memory. Now
`ps`, which lists the processes:

```
  mynos:/$ ps
    pid  ppid thr io  name            services
      0     0   1     kernel
      1     0   4 io  ocamlrun        power
      2     0   1 io  registry        registry
      3     0   1 io  memrofsd        memrofs
      5     1   3 io  consoled        console
     ...
      9     1   1     fatfs           fatfs
     ...
     17     1   1     sh
```

Each line is a process: its number (`pid`), its parent's, its number of
threads, `io` if it may touch the hardware, its name, and the names it
registered as a service. Process 1, shown as `ocamlrun`, is `init`, an
OCaml program run by the bytecode interpreter; process 17 is the shell
you are typing to.

## 6.3 Built-in commands and programs

A command is either **built into** `sh` or a **program**: a file that
`sh` starts as a new process.

| Built in | What it does |
|---|---|
| `help` | the summary |
| `cd`, `pwd` | change, print the current directory (chapter 7) |
| `version` | the system's version (also the boot's first line) |
| `ls [-l] [-a]`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `rmdir`, `touch` | files (chapter 7) |
| `echo WORDS` | print the words |
| `export NAME=value`, `unset NAME`, `env` | variables |
| `which NAME` | where a command comes from |
| `source FILE` (or `. FILE`) | run the commands of a file in this shell |
| `free` | free memory |
| `ps`, `kill PID` or `kill SERVICE` | processes (6.10) |
| `keymap [us\|it]` | the keyboard layout (6.4) |
| `ifconfig`, `ping HOST [COUNT]`, `host NAME` | the network (chapter 9) |
| `ask REQUEST` | a command proposed by a language model (chapter 12) |
| `clear` | clear the screen |
| `true`, `false` | succeed, fail |
| `exit [N]` | leave the shell (6.13) |
| `ocaml` | start the OCaml toplevel (chapter 8) |

Programs are files. `sh` looks for a name in the directories of the
variable `PATH`, which is `/disk/bin:/`: first `/disk/bin` (yours, on the
disk), then `/`, the RAM disk. It tries the name as it is, then with
`.byte` added, so `edit` finds `/edit.byte`. A bytecode file is run by
`ocamlrun`; a file that starts like an ELF program is run directly.

| Program | What it is |
|---|---|
| `edit FILE`, `kilo FILE` | text editors (chapter 8) |
| `ocamlc` | the OCaml compiler (chapter 8) |
| `hello` | a small test program |
| `trace` | the event recorder (chapter 11) |
| `log [-f]` | the kernel's log, since boot (`-f`: follow it) |
| `fetch URL` | HTTP and HTTPS (chapter 9) |
| `pkg` | packages: demos and programs from the web, installed in `/disk/bin` (chapter 9) |
| `llm`, `agent` | language models (chapter 12) |
| `gui` | the graphical session (chapter 10) |
| `shutdown [-r]` | turn the machine off, or restart it |

The current directory is **not** in `PATH`. To run a program of the
current directory, name it with a `/`: `./hello` runs `hello.byte` of
the current directory, while `hello` alone runs `/hello.byte` of the
RAM disk. A program you want to call by its name from anywhere goes into
`/disk/bin`.

After every command, `$?` holds its **exit status**: 0 for success.
`sh` itself uses 127 for "command not found" and 137 for a program ended
by Ctrl-C or `kill`.

```
  mynos:/$ nosuch; echo $?
  sh: nosuch: command not found
  127
```

## 6.4 Several commands, quotes and variables

```
  mynos:/$ X=5; echo "x is $X" 'and $X'
  x is 5 and $X
  mynos:/$ true && echo yes || echo no
  yes
```

- `;` separates commands; `A && B` runs B only if A succeeded, `A || B`
  only if A failed.
- `NAME=value` sets a variable, `$NAME` or `${NAME}` uses it. Inside
  `"double quotes"` variables are replaced, inside `'single quotes'`
  nothing is. Every variable is given to the programs `sh` starts.
- `#` begins a comment, to the end of the line.
- `sh FILE ARGS` runs a file of commands (a script), where `$1`, `$2`...
  are its arguments and `$#` their number; `source FILE` runs it in the
  current shell, so that its variables and `cd` stay.

The language stops there: there are no `if`, `for` or `while`, no
functions, no arithmetic and no command substitution.

## 6.5 The keyboard

The keyboard starts as a US keyboard. For an Italian one:

```
  mynos:/$ keymap it
```

`keymap` alone says which layout is in use; `keymap us` goes back. The
choice is saved on the disk (`/disk/.keymap`) and comes back at the next
boot.

On the Italian layout, the characters that are not on the keys are
typed with **AltGr**, the right Alt key, or with **Ctrl + Alt** on
keyboards without one:

| AltGr + | gives | | AltGr + | gives |
|---|---|---|---|---|
| `è` | `[` | | `+` | `]` |
| `7` | `{` | | `0` | `}` |
| `8` | `[` | | `9` | `]` |
| `ò` | `@` | | `à` | `#` |
| `ì` | `~` | | `'` | `` ` `` |
| `5` or `e` | `€` | | `\` | `¬` |

Accented letters are shown on the screen, and reach programs as UTF-8.
The screen is the PC's text mode, whose font has the accented
lower-case letters; MyNOS redraws six of its characters at boot for À
È Ì Ò Ù and €. A character the font cannot draw is shown as `?`.

## 6.6 Correcting the line

`sh` lets you move along the line and change it before pressing Enter:

| Key | Effect |
|---|---|
| Left, Right | move by one character |
| Home or Ctrl-A, End or Ctrl-E | to the start, to the end of the line |
| Backspace, Delete | erase before, under the cursor |
| Ctrl-K | erase to the end of the line |
| Ctrl-U | erase to the start of the line |
| Ctrl-W | erase the word before the cursor |
| Ctrl-L | clear the screen |
| Up, Down | the previous, the next line of the history (6.7) |
| Tab | complete (6.8) |
| Ctrl-C | abandon the line |
| Ctrl-D | on an empty line: leave the shell (6.13) |

A line longer than the screen scrolls sideways.

Other programs that read lines from the keyboard (the OCaml toplevel,
`cat` reading what you type) get the console's own, simpler editing:
Backspace, Up and Down (or Ctrl-P and Ctrl-N) for the history, Enter,
and Ctrl-D for "end of input". There the cursor cannot be moved back
into the line: erase up to the mistake and type again. A line has at
most 255 characters.

## 6.7 The history

Press Up: the last command comes back, ready to be run again (Enter) or
changed. Up again goes further back, Down forward again.

`sh` keeps its history in `/disk/.sh_history`, and reads the last 200
lines of it when it starts, so the commands of earlier sessions come
back too. The lines typed to other programs, the toplevel's phrases for
example, have a history of their own, the last 64 lines, kept by
`consoled` and the terminal windows in `/disk/.history`. Without a disk, both live only until
the machine stops.

## 6.8 Completing with Tab

Type the start of a name and press Tab: `sh` completes it as far as it
can.

- At the start of the line it completes **commands**: the built-ins and
  the programs of `PATH`.
- Anywhere else it completes **file names**, with their directory:
  `cat /disk/RE` and Tab gives `cat /disk/README.TXT `.

A complete name gets a space after it, a directory a `/`. A name with a
space (or a character the shell reads, such as `$` or `&`) is completed
between double quotes: `cat /disk/my` and Tab gives
`cat "/disk/my file.txt" `; a directory's quote stays open, so that Tab
goes on inside it. Tab also completes inside quotes you have opened
(`cat "/disk/my f`). When several names fit, Tab completes their common
part, and a second Tab lists them:

```
  mynos:/$ sh            (Tab, Tab)
  sh        shell     shutdown
  mynos:/$ sh_
```

## 6.9 Looking back

The screen has 25 lines. What scrolls off the top is not lost: the last
500 lines are kept. **Shift + Page Up** shows the previous page, with
the number of lines back in the top right corner (`[-24]`); **Shift +
Page Down** comes forward again. Any other key, or any output, brings
back the live screen. The full-screen editors have a screen of their
own, which is not kept.

## 6.10 Stopping a program; programs in the background

**Ctrl-C** ends the program `sh` is waiting for:

```
  mynos:/$ trace -s 30
  ^C
  mynos:/$ echo $?
  137
```

MyNOS has no signals. `sh` tells the console which program it is
waiting for; on Ctrl-C the console ends that program, as `kill` would,
and drops what had been typed for it. If the program had changed the
screen (colours, a hidden cursor, a full screen of its own), `sh` puts it
back.

What Ctrl-C does not do:

- **It does not stop a built-in command.** `ping 10.0.2.2 100` goes on to
  the end; `cat` reading the keyboard ends with Ctrl-D.
- **It ends the OCaml toplevel as a whole**, with everything defined
  in it. The editors `edit` and `kilo` take Ctrl-C as an ordinary key:
  they end with Ctrl-Q, and nothing is lost by a stray Ctrl-C.

A program can also be left running while you go on typing: put `&`
after it. `sh` prints its pid in brackets, and `$!` holds it:

```
  mynos:/$ trace -s 30 &
  [18]
  mynos:/$ echo $!
  18
  mynos:/$ kill $!
  mynos:/$
  [18] done, status 137
```

When a program in the background has ended, `sh` says so (`done`, and
its status) the next time you press Enter. `&` runs one program, not a
pipe, and a built-in command after `&` runs in the foreground as usual.

`kill` ends a process by its pid, or by the name of the service it
registered, as `ps` shows it:

```
  mynos:/$ kill fatfs
  mynos:/$ ls /disk
  README.TXT
```

`init` starts a service that ended this way again, within a second: its
clients find it by its name, and go on. `init` itself (`kill 1`) and
the drivers cannot be killed: `kill: 1: not allowed (init, or a
driver)`.

## 6.11 A second terminal: the serial port

QEMU's window is a PC screen, without copy and paste. MyNOS can use the
terminal on your computer as a second console. Start it with:

```
SERIAL=1 tools/run-demo.sh
```

The terminal is connected to MyNOS's second serial port. It shows
everything the screen shows, and what you type there goes to MyNOS as
if typed on its keyboard: there is one console, with two keyboards and
two screens. Line editing, Tab, the history and Ctrl-C work from both.
Your terminal's own scrollback and fonts are used, and accented letters
travel as UTF-8.

Some differences:

- The terminal also shows the messages of the kernel and of the
  services (`init: started ...`, `process 18 (trace) killed by 5`),
  which the screen does not.
- Ctrl-C goes to MyNOS. To stop QEMU, type **Ctrl-A, then X**, or close
  the window.
- MyNOS believes its screen is 80 columns by 25 lines: make the terminal
  that size before using `edit` or `kilo`.
- `SERIAL=1 tools/run-demo.sh -- -display none` opens no window at all.

## 6.12 Copy and paste

QEMU's window cannot paste text from your computer into MyNOS (MyNOS's
own clipboard serves its windows, chapter 10). With `SERIAL=1` (6.11) your terminal's copy and paste work:
select text, copy it, paste it into the terminal, and MyNOS receives it
as typed. Several lines pasted at once run one after the other, as if
each had been typed and followed by Enter.

Inside MyNOS, `edit` moves whole lines with Ctrl-K (cut) and Ctrl-U
(paste) (chapter 8), and the graphical session's Files window copies
files (chapter 10).

## 6.13 Leaving the shell, turning off

`exit`, or Ctrl-D on an empty line, ends `sh`. `init` then starts a new
one at once, in the root directory: the greeting and the prompt come
back. This is also how to start afresh with a clean set of variables.

To turn the machine off:

```
  mynos:/$ shutdown
  MyNOS: turning the machine off.
```

and QEMU ends. `shutdown -r` restarts MyNOS instead: the kernel boots
again, `/tmp` is empty, and `/disk` keeps your files (chapter 7).

> **THE MyNOS FACTOR — The console is a program you can replace.**
> On Unix, in canonical mode (the default), the line you are typing is
> edited by the terminal driver, in the kernel. In MyNOS the kernel only draws characters: `consoled`, an
> ordinary process, owns the keyboard, edits lines, keeps the history,
> knows the Italian layout and ends a program on Ctrl-C; `sh` edits its
> own line on top of it. A terminal window of the graphical session
> answers the same requests, so `sh` runs there unchanged, with no idea
> that its keyboard is now a window.

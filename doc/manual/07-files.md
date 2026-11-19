# 7. Files and disks

MyNOS keeps files in three places: the RAM disk, a disk in memory, and
the hard disk. They look like one tree of directories, but each is
served by a different program and behaves differently. This chapter
explains what each is for, how to name files and move among them, how
`sh` sends a program's output to a file or to another program, and what
is still there after the machine restarts.

## 7.1 Three places

```
  /                  the RAM disk         memrofs   read-only
  ├── edit.byte
  ├── sh.byte
  ├── ...
  ├── tmp/           in memory            tmpfs     writable, lost at shutdown
  │   └── notes.txt
  └── disk/          the hard disk        fatfs     writable, kept
      ├── README.TXT
      └── notes/
          └── todo.txt
```

| | `/` | `/tmp` | `/disk` |
|---|---|---|---|
| What it is | the system RAM disk | a disk in memory | the hard disk (`system/disk.img`) |
| Served by | `memrofs` (C) | `tmpfs` (OCaml) | `fatfs` (OCaml), over `ata` (OCaml) |
| Writable | no | yes | yes |
| Directories | no: one flat list | no: one flat list | yes |
| After a restart | the same (it is the system) | empty | as you left it |
| Size | the system's files | as much as memory allows | 64 MB |

## 7.2 `/`: the RAM disk

The RAM disk holds the system: `init` and its list `init.rc`, the
services, the shells, the programs, the OCaml compiler with its
libraries, fonts and certificates. It is loaded with the kernel at every
start, and nobody can change it while MyNOS runs:

```
  mynos:/$ echo hi > /x.txt
  sh: /x.txt: Read-only file system
```

It has no directories: `ls /` lists its files, and among them `tmp/`
and `disk/`, the places where the other two services are mounted. One file is older
than the rest: `AUTOEXEC.BAT`, the test file of the RAM disk in 2002.

## 7.3 `/tmp`: a disk in memory

`/tmp` is for files you need only for a while: what a program writes
before another reads it, a test, a copy. It is fast, and it is emptied
when the machine stops or restarts. It is one flat list of files:
`mkdir` there fails (`Invalid argument`). `sh` itself uses it for pipes
(7.8).

## 7.4 `/disk`: the hard disk

`/disk` is the place for your work. It is a FAT32 file system, the kind
used by memory cards and by MS-DOS and Windows, on the disk image of
chapter 5. It has directories, and long names with spaces and lower case:

```
  mynos:/disk$ echo fine > "A rather long file name.txt"
  mynos:/disk$ ls
  A rather long file name.txt
  README.TXT
```

As on any FAT disk, names are compared without regard to case:
`readme.txt` and `README.TXT` are the same file.

MyNOS keeps a few files of its own there, with names starting with a
dot, which `ls` does not show: `.sh_history` and `.history` (6.7),
`.keymap` (6.5); and `llm.env`, if you have one (5.7). It is also your
**home directory**: `cd` without a directory goes to `/disk`. MyNOS's
web server, `httpd`, shows the files of `/disk` to a browser (chapter 9).

## 7.5 Paths and the current directory

A file is named by its **path**. A path that starts with `/` is
**absolute**: it starts at the root. Any other path is **relative**: it
starts at the current directory, which the prompt shows.

```
  mynos:/$ cd /disk
  mynos:/disk$ mkdir notes
  mynos:/disk$ cd notes
  mynos:/disk/notes$ pwd
  /disk/notes
  mynos:/disk/notes$ cd ..
  mynos:/disk$ cd
  mynos:/disk$
```

`.` is the current directory and `..` the one above it. Every program
starts in the directory `sh` is in, and gets it in its environment
(`PWD`).

Inside `/tmp` or `/disk`, a path may be at most 63 characters long,
counted from the place's own root: `/disk/notes/todo.txt` counts
`notes/todo.txt`. A longer one is refused with `Filename too long`.

## 7.6 Working with files

A short session, step by step, in `/disk`:

```
  mynos:/disk$ cd notes
  mynos:/disk/notes$ echo first line > todo.txt
  mynos:/disk/notes$ echo second line >> todo.txt
  mynos:/disk/notes$ cat todo.txt
  first line
  second line
  mynos:/disk/notes$ ls -l
        23  todo.txt
  mynos:/disk/notes$ cp todo.txt /tmp
  mynos:/disk/notes$ mv /tmp/todo.txt /disk/notes/copy.txt
  mynos:/disk/notes$ rm copy.txt
```

| Command | What it does |
|---|---|
| `ls [-l] [PATH...]` | list a directory (`-l`: sizes, `dir` for a directory; `24K` for 24 kilobytes) |
| `cat FILE...` | print files, one after the other |
| `cp FROM TO` | copy a file; `TO` may be a directory |
| `mv FROM TO` | rename or move a file; `TO` may be a directory |
| `rm FILE...` | remove files |
| `mkdir DIR...`, `rmdir DIR...` | make, remove directories (`rmdir`: only empty ones) |
| `touch FILE...` | make an empty file, if it does not exist |

`cp` and `mv` take one file at a time; there is no copy of a whole
directory. `mv` from one place to another, from `/tmp` to `/disk`
for example, copies the file and removes the original, since the two
places are two different services.

**Changing only the case of a name.** `mv Notes.txt notes.txt` on
`/disk` renames the file: the names are the same file to FAT, and the
new spelling replaces the old one. (Until November 2026 this lost the
file: mynos-qaw.)

**Patterns.** In a word without quotes, `*` stands for any characters
and `?` for one, and the word is replaced by the names that match, in
order:

```
  mynos:/disk/notes$ ls *.txt
  todo.txt
  mynos:/disk/notes$ cat t*
  first line
  second line
```

A pattern that matches nothing stays as it is (`echo *.ml` prints
`*.ml`). Patterns match the names of one directory: `/disk/*/x` is not
expanded. Names starting with a dot match only a pattern that starts
with a dot.

## 7.7 Redirections

A command normally reads the keyboard and writes on the screen. `sh` can
connect it to files instead:

| Form | Effect |
|---|---|
| `COMMAND > FILE` | its output goes to FILE, which is made empty first |
| `COMMAND >> FILE` | its output is added at the end of FILE |
| `COMMAND < FILE` | it reads FILE instead of the keyboard |

They work for built-in commands and for programs alike:

```
  mynos:/$ hello > /tmp/h.txt
  mynos:/$ cat < /disk/notes/todo.txt
  first line
  second line
  mynos:/$ echo "1 + 2;;" > /tmp/s.ml
  mynos:/$ ocaml < /tmp/s.ml
  ...
  # - : int = 3
```

To write a file by typing it, use `cat` with only an output, type the
lines, and end with **Ctrl-D** at the start of a line:

```
  mynos:/$ cat > /tmp/typed.txt
  line one
  line two
  (Ctrl-D)
  mynos:/$
```

Only the standard output can be redirected: there is no `2>` for error
messages, and no `/dev/null` (write to a file in `/tmp`, and remove it).

**How it works.** A MyNOS program does not inherit open files from the
program that started it, as a Unix program does. `sh` puts the names of
the files in the program's environment instead (`MYNOS_STDIN`,
`MYNOS_STDOUT`), and the MyNOS library in the program opens them the
first time the program reads its input or writes its output.

## 7.8 Pipes

A **pipe**, `|`, sends the output of one command to the input of the
next:

```
  mynos:/$ ls / | cat > /tmp/list.txt
  mynos:/$ cat /tmp/list.txt | cat | cat
```

In MyNOS the commands of a pipe run **one after the other**, not at the
same time: the first one's output is written to a file in `/tmp`
(`/tmp/.pipe` followed by numbers), the second reads it when the first
has finished, and so on; the files are removed at the end. The result
is the same as on Unix for commands that end, but:

- nothing comes out until the first command has finished;
- a pipe whose first command does not end (a program that runs until it
  is stopped) never reaches the second;
- a pipe cannot be put in the background with `&`.

## 7.9 What survives a restart

| What | After `shutdown -r`, or a new `tools/run-demo.sh` |
|---|---|
| files in `/disk` | kept |
| `sh`'s history, the console's history, the keyboard layout | kept (they are on `/disk`) |
| files in `/tmp` | gone |
| variables set with `export`, the current directory | gone (they live in the running `sh`) |
| programs left running with `&` | gone |
| the files of `/` | the same as before: they are the system |

To see it for yourself:

```
  mynos:/$ echo tmp > /tmp/keep.txt; echo disk > /disk/keep.txt
  mynos:/$ shutdown -r
  ...
  mynos:/$ cat /tmp/keep.txt /disk/keep.txt
  sh: cat: /tmp/keep.txt: No such file or directory
  disk
```

`fatfs` writes every change to the disk at once, so a file is safe on
`/disk` as soon as the command that wrote it has ended.

> **THE MyNOS FACTOR — A file is whatever a process gives you over IPC.**
> The kernel of MyNOS knows nothing about files. When a program opens
> `/disk/notes/todo.txt`, the MyNOS library inside it looks at the path,
> sees `disk`, and sends a message, "open `notes/todo.txt`", to the
> process registered as `fatfs`; `fatfs` asks the service `ata0` for the
> disk's sectors, and `ata` reads them from the controller. For `/tmp`
> the message goes to `tmpfs`, which keeps files in an OCaml hash table;
> for anything else, to `memrofs`. Three programs, written in two
> languages, store files in three different ways, and `cat` cannot tell
> them apart: to it, a file is whatever answers the file protocol. Kill
> `fatfs` and `init` starts it again; the next `ls /disk` finds the new
> one by its name.
>
> ```
>   cat ──"open notes/todo.txt"──► fatfs ──"read sectors"──► ata ──► disk
>    │                              (OCaml)                  (OCaml)
>    └──"open notes.txt"──────────► tmpfs   (for /tmp/notes.txt)
> ```

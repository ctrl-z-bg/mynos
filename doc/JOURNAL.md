# MyNOS — Engineering Journal

A diary of what was found while bringing MyNOS back to life: symptoms, how
they were diagnosed, causes, fixes, and what we learned. `doc/STATUS.md` says
*where the project is*; this file says *how we got there*. Newest entries at
the bottom.

---

## 2026-11-15 — Checking the repository

The project had been moved from SourceForge CVS into four separate git
repositories (`mynos-byterun`, `mynos-core`, `mynos-lib`, `services`) and
later merged into this one. Before touching anything we checked that the
merge lost nothing.

- **Files:** `diff -r` between the working trees, ignoring `.git`: identical
  (209 files).
- **History:** 205 commits here against 6 + 182 + 15 + 19 = 222 in the four
  repositories. For every commit of each sub-repository we looked up its
  tree hash among the trees of the matching subdirectory in this history:
  all 222 states are present, and no extra ones exist. The difference is
  only that 13 commits here touch two or three subdirectories at once
  (192·1 + 9·2 + 4·3 = 222): commits made together were merged.

**Lesson:** comparing tree hashes per subdirectory proves two histories hold
the same states even when the commits themselves differ.

---

## 2026-11-16 — Reading the code again

A full read of the code to understand what MyNOS was meant to be (summary in
`doc/STATUS.md`, "Architecture"). Notable discoveries:

- The kernel exposes **two system call interfaces**: the native MyNOS one on
  `int 0x90`, and a small Linux-compatible subset on `int 0x80`. The second
  one lets user programs be ordinary static Linux binaries built with
  dietlibc: MyNOS never needed a libc of its own.
- `ocamlrun` is loaded as a normal process; its "bytecode file" is simply
  GRUB module 1, served by a fake `read()` in the kernel.
- `mynos-byterun` is **OCaml 3.06**: the import commit message says so, and a
  diff against the 3.06 tarball (ignoring CVS `$Id$` lines) shows only the
  MyNOS changes in `main.c`, `startup.c`, `floats.c`, `dynlink.c` and the
  Makefile.

---

## 2026-11-16 — Choosing a toolchain from the past

The host has gcc 15 without 32-bit multilib and a dietlibc for x86_64 only:
it cannot build a 32-bit system that runs Linux i386 binaries. So builds run
in containers.

The first idea was Debian 3.1 "sarge" (2005, gcc 3.3), close to the 2002–2004
development. It failed at once: `cc1: unrecognized option -fno-stack-protector`.
That flag was added in the **last commits, November 2008**, when Ubuntu
started enabling the stack protector by default (gcc ≥ 4.1). So the last
state of the code expects gcc 4.3: we moved to Debian 5.0 "lenny" (gcc 4.3.2,
the same version as Ubuntu 8.10). Sarge is kept only to compile OCaml 3.06,
whose binaries run on newer glibc since they need just libc, libm and libdl.

QEMU's built-in multiboot loader (`-kernel`, `-initrd "a,b,c"`) replaces GRUB
for development.

**Lesson:** a compiler flag in the build files dates the code better than the
commit history does.

---

## 2026-11-16 — Bug 1: the timer handler lived in `.bss`

**Symptom.** The kernel printed its whole initialization, then
`int6: Invalid opcode` as soon as the timer was enabled.

**Diagnosis.** `qemu -d int` showed the `#UD` at `0x209fb4`, which `nm` placed
inside `readyQueue`, a variable. `nm` also listed `pit_ISR` as `B` (bss) and
`int7_TRAP` as `D` (data).

**Cause.** Interrupt, trap and syscall entry points are top-level `asm` blocks
with no section directive. gcc emits them in whatever section is current at
that point; gcc 4.3 happened to be in `.bss` after a variable. The handler's
code was therefore in memory zeroed at boot: the first real timer tick jumped
into zeros.

**Fix.** Wrap every top-level block in `.pushsection .text` / `.popsection`.

---

## 2026-11-16 — Bug 2: one gigabyte for a 24-page program

**Symptom.** With `ocamlrun` as a module, the boot stopped right after the
first process was created, interrupts disabled. Same with 128 MB of RAM, same
after 30 s: a hang, not slowness.

**Diagnosis.** gdb attached to QEMU showed the CPU in
`__pg_free_pages_from_page`. Walking the frame pointers by hand: `__OS_askPages`
had been called by `spawnProcess` with `npages = 0x3fc08`, about 1 GB.

**Cause.** In `spawnProcess` the variable `baseaddr` is tested with
`if (baseaddr == 0) baseaddr = p_vaddr` without ever being initialized. With
gcc 3/4 of the time that stack slot was zero by luck; here it held a leftover
value, and the image size `lastaddr - baseaddr` exploded.

**Fix.** Initialize `baseaddr` and `lastaddr` to 0.

---

## 2026-11-16 — Bug 3: a host tool built for the wrong OS

`memrofs/tool/createDisk` builds the RAM disk image on the development
machine, but its Makefile was copied from the services: dietlibc, `-lmynos`,
text at `0x40000000`. It crashed on Linux. It is now built with plain gcc.

After this the whole original system ran: OCaml hello world, registry,
keyboard and serial drivers, and memrofs reading a file over IPC. Tagged
`revival-baseline`.

---

## 2026-11-16 — Porting to gcc 14

The first build with gcc 14 (Debian trixie i386, dietlibc 0.34) showed only
five compile errors (K&R parameter, missing `<unistd.h>`, `errno` declared
by hand, `return;` in a non-void function) and one link error: `_insertBlock`
was a plain `inline` function, which in C99 provides no external definition.
Fixing them took minutes. Running the result took much longer.

### Processes were never started

**Symptom.** Kernel up, no process created, no error.

**Diagnosis.** The kernel was rebuilt with `-g`. A first breakpoint on the
`return NULL` lines of `spawnProcess` was misleading (a line holding both a
call and its `return`); stepping with `next` showed the failure at the
allocation of the process image.

**Cause.** `readelf -l`: modern `ld` with `-Ttext 0x40000000` moves only the
code. The ELF headers and a `.note.gnu.build-id` stay in an extra `LOAD`
segment at the default `0x08048000`, so the image spans `0x08048000` to
`0x40024000`. The kernel loads one contiguous image starting at the first
segment.

**Fix.** Link MyNOS programs with `-Wl,-N -Wl,--build-id=none`: one segment
at `0x40000000`, entry point at `0x40000000`, as the old linker produced. The
kernel now also uses the ELF entry point instead of a hardcoded address.

### A page fault inside the context switch

**Symptom.** Processes created, then a kernel page fault in `switchTo`.

**Diagnosis.** The disassembly showed every static variable accessed as
`0x142cc(%eax)`: Debian's gcc builds **position-independent code** by
default, and `%eax` held the base address. Right before, an `asm` block did
`movl %0,%%eax; movl %%eax,%%cr3` without declaring `%eax` as clobbered.

**Fix.** Build the kernel with `-fno-pie` (it was never meant to be
relocatable) and rewrite the asm as `movl %0,%%cr3` with an `"r"` input.

### `syscall 243 is not yet implemented!`

dietlibc 0.34 calls `set_thread_area` at startup to set up thread-local
storage. Disassembling its `__setup_tls` showed it tolerates a failure, but
its `__errno_location` always reads `%gs:0`: without TLS, the first failing
system call would crash the program. So we implemented it as Linux does on
i386: one GDT slot (index 5) for user TLS, its base and limit saved in each
thread's `tss_t`, and the descriptor rewritten from the incoming thread on
every context switch, just before `%gs` is reloaded. `fork` and threads
inherit it because they copy the whole `tss_t`.

### `argv[0]` was NULL

The next fault was a user-mode read of address 0 in dietlibc's `stackgap`,
which scans `argv[0]` for the program name. The 2008 kernel started every
process with an empty, lazily allocated stack: `argc = 0`, `argv[0] = NULL`.
The kernel now allocates the top stack page eagerly and writes a minimal
Linux initial stack: `argc = 1`, `argv = {"mynos", NULL}`, empty `envp`,
`auxv` with only `AT_NULL`.

### `mmap2`

dietlibc 0.34 allocates with `mmap2` (192) instead of the old `mmap` (90).
Same arguments, but in registers: the handler pushes them as a
`struct mmap_args` and reuses the old code. `mmap` now returns `-ENOMEM`
instead of `NULL` on failure, since libcs test for `-4095..-1`.

### The channel number was a TLS pointer

**Symptom.** Everything ran except memrofs: a kernel page fault in
`getChannel` with channel number `0xffbf8d40`.

**First guess, wrong.** The `mynos-lib` wrappers set each register in a
separate `asm` statement between `pushal` and `popal`, which is undefined
behaviour. We rewrote all 24 of them around one `asm` with proper constraints
(`mynos-lib/src/syscall.h`). Necessary, but the crash stayed.

**Diagnosis.** A conditional breakpoint `getChannel if c >= 100` plus
`p *currThread` showed the bad channel number was **exactly the thread's
`tls_base`**. The process was the memrofs server, not the client: its main
loop called `process_request(sender, request)`, and `sender` was never
assigned (gcc 14 had warned about it). It is used as the channel to reply on.
With gcc 4.3 that stack slot held the right channel by chance; with gcc 14 it
held the TLS pointer dietlibc had just stored there.

**Fix.** Reply on the channel returned by `mynos_listenPort`.

### Result

The demo ran identically with gcc 14 and gcc 4.3. Other bugs found on the
way: `pqNElem` called itself instead of `listNElem`, and the idle thread's
setup assigned `prev` twice instead of `next` and `prev`.

**Lessons.**
- Every serious bug of the port was an old bug that the 2008 compiler hid:
  uninitialized variables whose stack slots happened to be right, and inline
  asm that relied on the compiler not touching registers.
- Compiler warnings pointed at two of them (`sender`, the recursion) before
  we found them the hard way.
- The kernel with `-g` and `qemu -s -S` plus gdb pays off immediately;
  `qemu -d int` is the quickest way to see which exception happened where.

---

## 2026-11-16 — Small fixes and automated tests

- **Alt key.** `keyboardd` tested `(!control_keys & CK_ALT)`: the `!`
  applies before the `&`, so the Alt flag was set only when no other modifier
  was active. Now `!(control_keys & CK_ALT)`.
- **`semFree`.** The kernel dispatched number 9 to both `semInit` and
  `semFree`, and `mynos_freeSem` in the library used 10, which is
  `driverRegister`. `semFree` now has its own number, 13, on both sides.
- **Unknown system calls** used to panic the whole kernel. Now an unknown
  Linux call returns `-ENOSYS`, like Linux, and is reported once per number;
  an unknown native call returns `MYNOS_ERR_INVALID`. Newer libcs and
  runtimes probe for system calls and need to see the error.
- **Tests without screenshots.** The kernel mirrors everything it prints to
  COM2, so `tools/run-tests.sh` can boot QEMU headless, log the console to a
  file and check the expected lines. `tests/abi` checks the system calls
  above. Both toolchains pass.

---

## 2026-11-16 — Running modern OCaml runtimes on MyNOS

To decide on the runtime (mynos-4er, `doc/decisions/ocaml-runtime.md`) we
built the bytecode runtimes of OCaml 4.14.5 and 5.5.2 for MyNOS and ran them
on the kernel. Getting there taught us more about the kernel than about OCaml.

### dietlibc gives up, musl does not

Configuring OCaml with `CC="diet gcc"` failed first on the target triple
(`i686-pc-linux-dietlibc` is unknown to `config.sub`), then on missing C99
float functions, then on `fmin`, `isfinite`, `nextafter`, `UINT64_C`...
Switching to musl (`musl-gcc`, static) built both runtimes unchanged on the
first try. Linking for MyNOS needed `-Ttext-segment=0x40000000` rather than
`-Ttext`, because musl's `crti.o` has an `.init` section that `-Ttext` leaves
at the default address.

### Linux preserves registers; the MyNOS entry point did not

**Symptom.** Right after `set_thread_area`, a user-mode fault writing
address `0x28`.

**Cause.** musl's `__set_thread_area` keeps a pointer in `%ecx` across
`int $0x80`, as Linux allows: Linux preserves every register except `%eax`.
The MyNOS dispatcher pushed only the argument registers it needed, and the C
handler clobbered `%ecx`. dietlibc never relied on it.

**Fix.** The Linux dispatcher now saves all six argument registers on entry
and restores them on exit. As a bonus the six pushes are exactly the cdecl
argument list of every handler, and the `struct mmap_args` of `mmap2`: the
dispatcher became a plain table.

### The fake bytecode file needed real file semantics

The 2008 kernel served GRUB module 1 for any `open`, and its `_llseek`
treated every offset as relative to the end of the file and never wrote the
result back. OCaml 3.06 only ever seeked from the end, so it worked. Newer
runtimes seek from the start and the current position, and musl uses `lseek`
and `fstat64` too. The single file now has a position, `lseek`/`_llseek`
honour `SEEK_SET`/`SEEK_CUR`/`SEEK_END`, and `stat64`/`fstat64` report its
size. It is still one file (mynos-nxa).

### Modules above 4 MB were invisible and unprotected

**Symptom.** The 5.5 runtime read the right offsets of its bytecode, but the
16-byte trailer came back as zeros.

**Diagnosis.** gdb showed the kernel copying from `0x412c9f`, inside module
1 as reported by multiboot, and the memory there was all zeros.

**Cause.** Two bugs. The kernel marks only the first 4 MB of physical memory
as used, and `start.asm` identity-maps only those 4 MB. A module loaded
partly above 4 MB (the 5.5 bytecode ends at `0x412caf`) was neither reserved
(its frames could be handed out by the allocator) nor mapped at its address
(the kernel read some other page). The old modules were small enough to fit
below 4 MB.

**Fix.** `mynos_main` registers each module's range before `init_memory`,
which marks those frames as used and maps them at linear = physical **before
the first allocation**. The first attempt did the mapping after the GDT was
allocated, and since the GDT had been given linear `0x400000` the mapping
replaced it: a reboot loop. Order matters.

### Fresh pages were not zeroed

**Symptom.** The 4.14 runtime died on a `hlt` inside musl's `malloc`.

**Cause.** musl's allocator checks that memory it just obtained from `mmap`
is zero, as Linux guarantees for anonymous mappings. MyNOS allocates those
pages on first access and handed out frames with whatever their previous
owner left there. That was also an information leak between processes.

**Fix.** `__allocateOnUse` clears the page after mapping it.

### Result

With these fixes plus small additions (`writev`, `exit_group`,
`set_tid_address`, `mprotect` accepted, and for 5.x `sigaltstack`,
`rt_sigaction`, `rt_sigprocmask` accepted and ignored), **both OCaml 4.14.5
and 5.5.2 run on MyNOS**, floats included. Effect handlers work out of the
box; `Domain.spawn` stops at the missing `clone`.

**Lessons.**
- A complete libc matters more than a small one: musl removed a whole class
  of problems at once.
- Every runtime that ran on MyNOS so far was also a kernel test: each one
  exercised paths the previous ones never touched.
- "Report the unknown system call and return -ENOSYS" turned the kernel into
  a measuring instrument: the list of missing calls was the to-do list.

---

## 2026-11-16 — Moving to musl and OCaml 5.5

Decision accepted (`doc/decisions/ocaml-runtime.md`). The dev container now
builds OCaml 5.5.2 twice: the compiler for the build host, and the bytecode
runtime with musl. MyNOS's `mynos-runtime/` holds only a ten-line `main()`
and a Makefile that links it with the upstream `libcamlrun.a`: no OCaml
sources in the repository, so a new OCaml release is a version bump. The
user-space Makefiles read `MYNOS_CC` and `MYNOS_LDFLAGS` from `mynos.mk`;
the dev container sets them to musl, the legacy one keeps dietlibc.

The hello world ran at once. The whole system did not, and each failure was
a kernel or library bug that dietlibc and the small 3.06 runtime had never
exercised.

- **Another 4 MB victim.** The 5.5 `ocamlrun` is 1.7 MB, so the modules after
  it land above 4 MB. `mynos_main` looked for the `.RAMDISK` signature in
  every module *before* `init_memory` had mapped them: an early kernel page
  fault and a reboot loop. The check now runs after `init_memory`.
- **The RAM disk was invisible to the linear space map.** The kernel maps
  the RAM disk at `0x40400000` in every process but did not record it in the
  per-process map that `mmap` allocates from. OCaml 5 reserves a large area
  for its minor heaps at startup; the map offered addresses overlapping the
  RAM disk and the allocation failed: `Not enough heap memory to reserve
  minor heaps`. The 4 MB slot is now reserved in the map.
- **A crashing program stopped the whole machine.** CPU exception handlers
  were `while (1)` loops with interrupts off. OCaml's fatal error called
  `abort()`, musl tried `tkill`, then executed a privileged instruction on
  purpose, and the kernel froze. Now an exception or an invalid access in
  user mode prints the cause and terminates only that process, and `kill`,
  `tkill`, `tgkill` aimed at oneself terminate it as a fatal signal would.
  First attempt forgot that `killProcess()` returns: `exit` calls `sched()`
  after it to switch away, and so must every other path.
- **Boot race.** Services start together; memrofs asked the registry for a
  port before the registry had opened its own, and got `-3`. With dietlibc
  the timing happened to be right. The registry client now retries.
  Sleeping was not possible: the kernel's timer queue is never checked, so
  the retry spins (mynos-e1k).
- **Threads without TLS.** The registry serves each request in a thread
  created with `mynos_threadCreate`. musl's `malloc` reads the stack canary
  at `%gs:0x14`; the new thread started with `%gs` set to the plain data
  segment and read address `0x14`. New threads now start with their
  creator's TLS segment (shared, until threads get their own: mynos-l9h).
- **The fork child had the wrong `%gs`.** musl makes system calls through
  `call *%gs:0x10`. A forked child resumes inside `_linux_syscall_fork`, not
  through `switchTo`'s segment pops, so `%gs` still cached the previous
  thread's TLS base: the child called address 0. The child now reloads
  `%gs` before returning to user space.
- `mynos_recv` was defined as `int32_t` but declared `int`; dietlibc's
  headers had hidden the missing `<stdint.h>`.

**Result.** With musl and OCaml 5.5 the whole test suite passes, plus an
effect handler test; the legacy toolchain still passes too.

**Lessons.**
- A new libc is a new test of the kernel: musl relies on the Linux ABI more
  strictly (TLS everywhere, the vsyscall pointer, registers preserved).
- Hardware state that is not saved explicitly (here the segment descriptor
  caches) bites on paths that skip the usual code, like a fork child.
- A user program must never be able to stop the kernel: that one fix made
  every later failure readable.

---

## 2026-11-16 — Timers: the bug was in my reading, not in the queue

When the boot race forced a retry loop, I filed "kernel timers never fire",
because `timerQueueExtractExpired()` seemed to have no caller. Wrong: my
search had excluded `sched.c`, where `sched()` calls it on every tick. The
timer queue works and `recv` timeouts fire. The real problems were next to
it:

- `mynos_setTimer(usec)` only stored a wake-up time in the thread, never
  queued it nor blocked it, and converted microseconds with `/ 10` (the tick
  length in milliseconds) instead of `/ 10000`.
- There was no way for a Linux program to sleep or read the time.

Now `kernel/time.c` reads the CMOS real-time clock at boot (the wall clock
is that plus the ticks since), `mynos_setTimer` really sleeps (`mynos_sleep`
is the new name), and the Linux calls `time`, `gettimeofday`,
`clock_gettime`, `nanosleep` and `clock_nanosleep` exist, including the
64-bit-time variants that musl 1.2 uses on i386. No 64-bit division in the
kernel: it would need libgcc. `tests/abi` measures a 200 ms `nanosleep`
(220 ms: sleeps round up to the next 10 ms tick) and the registry client
sleeps instead of spinning.

**Lesson.** Before declaring code dead, search without filters: an
exclusion meant to hide noise hid the one caller.

---

## 2026-11-16 — OCaml bindings, and a 2002 bug that ate four bytes

### The Mynos library

`mynos-lib/ocaml/mynos.ml` gives OCaml programs the MyNOS API: channels
and ports, semaphores, sleeping, the registry, statistics. Its primitives
(`mynos-runtime/mynos_stubs.c`) are thin wrappers over `libmynos`; errors
raise `Mynos.Error`. To add primitives without touching the OCaml sources,
`mynos-runtime/gen_prims.sh` regenerates the runtime's primitive table
from the upstream list (kept in the dev image) plus ours, appended at the
end. The first test is an OCaml client of the C memrofs service: it looks
the service up in the registry and reads `AUTOEXEC.BAT` over IPC, building
the C request structures with `Bytes.set_int32_le`.

Small find on the way: the kernel's `tryP` returns 0 when it took the
semaphore and 1 when it would block; the stub first treated any
non-negative value as success.

### The effects test went silent

With the new runtime the effect handler test printed nothing and exited
with code 0, while hello world kept working.

**Wrong leads.** First suspect: the 2004 `safe_alloc.c` in `libmynos`,
which replaces `malloc`/`free`/`realloc` with semaphore-protected versions
on top of the libc's internal ones (with musl that mixes two allocators).
Linking without it changed nothing. Second suspect: the order of the
primitive table, since mine sorted our primitives in among the upstream
ones. Reading `caml_build_primitive_table` showed that bytecode resolves
primitives by name; appending ours at the end is still the safer choice,
but it was not the cause.

**The clue.** Building variants of `ocamlrun` showed something odd: the
same `prims.c`, compiled the same way, worked or not depending on what else
was linked. Every failing variant had exactly the same file size. Padding
the working binary with zeros to that size broke it; padding the failing
one made it work. The code was innocent: *where the next module landed in
memory* decided.

**Diagnosis.** gdb dumped the bytecode module from memory at the moment
`ocamlrun` opened it. Against the file, four bytes differed, at module
offset `0x24ffc`, which is physical `0x3ffffc`: the last four bytes before
4 MB. They read `78 56 34 12`.

**Cause.** `0x12345678` is the test pattern of the RAM size probe in
`start.asm`, written in 2002: it stores the pattern in the last dword of
every megabyte (`0x1ffffc`, `0x2ffffc`, ...) and reads it back, never
restoring what was there. QEMU loads the modules right after the kernel,
so any module crossing a megabyte boundary lost four bytes. With small
modules nothing important happened to sit there; with a 1.7 MB runtime the
bytecode crossed 4 MB, and the damaged instruction silently ended the
program.

**Fix.** Take the RAM size from the multiboot information (`mem_upper`),
which the bootloader provides; without it, probe saving and restoring each
word. While there: the entry code pushed onto the bootloader's stack, which
the multiboot specification leaves undefined; the kernel now sets up its
own boot stack first.

**Lessons.**
- When behaviour depends on the size of a binary, suspect memory layout
  before code.
- Bisecting by padding (same code, different addresses) separates the two.
- A recognizable test pattern in corrupted memory names its culprit.

---

## 2026-11-16 — The console service

The terminal design (`doc/decisions/terminal.md`) was accepted with I/O in
user space: `libmynos` provides its own `read`, `open`, ... which replace
the C library's at link time and talk IPC to the services.

First piece: `services/console/consoled.c`. It owns the keyboard (the scan
code tables moved from `keyboardd.c` to a shared `keymap.h`), edits the
current line (echo, backspace, Ctrl-D for end of file) and hands complete
lines to clients that ask for input. On the client side,
`mynos-lib/src/fileio.c` replaces `read`: on descriptor 0 it asks the
console, otherwise it makes the system call itself, with inline assembly
so that it does not depend on which libc is underneath. An OCaml program's
`read_line ()` now goes OCaml → `read` → IPC → `consoled`.

Two design points:
- `consoled` needs to wait for both interrupts and clients, so it has a
  keyboard thread and a serving thread. MyNOS threads still share their
  creator's TLS (mynos-l9h), so the keyboard thread uses no C library
  function that touches thread state: only MyNOS calls, port I/O, `memcpy`
  and a raw `write`.
- The kernel's screen driver learned the backspace (`\b`), so the echo of
  a deleted character is `\b \b`.

`tools/run-tests.sh` now types on the keyboard: it opens QEMU's monitor and
sends key presses (`sendkey h`, `sendkey shift-o`, `sendkey backspace`,
`sendkey ctrl-d`), then checks that the OCaml program saw the right lines.

---

## 2026-11-16 — Files, and a kernel heap that wrote into its neighbours

### Files through memrofs

`libmynos` now also replaces `open`, `close`, `read`, `lseek`, `fstat`,
`stat` and `lstat`: paths are opened on memrofs over IPC and get
descriptors from 20 up; the rest still goes to the kernel. `read` on such
a descriptor loops until it has everything asked for, like a regular file
on Linux: the OCaml runtime reads whole bytecode sections in one call and
treats a short read as `truncated bytecode file`.

memrofs got a new protocol (`mynos-lib/include/mynos_memrofs.h`), because
the 2002 one had several problems: open files were owned by the client's
*channel number* (reads worked only because channel numbers get reused),
its structures used `off_t`, whose size differs between dietlibc and musl,
`LSEEK` was an empty case, `READ` subtracted an offset from a pointer and
read past the end of short files, and data was sent straight from the RAM
disk pages, which a client's `munmap` could release to the allocator.

`ocamlrun` now runs `init.byte` from the RAM disk when it exists, so a
system can boot with no bytecode module at all; without it the kernel's
module 1 is still used. `tests/files` reads files with `open_in`,
`input_line`, `seek_in`, `in_channel_length` and `Sys.file_exists`.

### The page directory that got overwritten

**Symptom.** As soon as the runtime read its bytecode in 16 KB chunks, the
machine rebooted: a page fault in `switchTo`, then a double fault.

**Diagnosis**, step by step with gdb:
1. The fault wrote to the outgoing thread's `tss`, a kernel heap address,
   right after loading the incoming thread's page directory. Logging every
   context switch showed the incoming process was `ocamlrun`, whose page
   directory had worked a few switches earlier.
2. A conditional breakpoint could not even read that page directory
   through its recursive mapping: the page was no longer a page directory.
3. A watchpoint on the kernel's shared page table entry for the page never
   fired, so the mapping was intact: the *contents* of the page changed.
4. Watchpoints on the page directory itself, through the kernel address it
   had when `spawnProcess` allocated it, caught the writer:
   `_insertBlock`, inside `kmalloc`.

**Cause.** Two bugs in the kernel heap allocator (`mem/dynalloc.c`, 2003):
- To place a block in the gap between two heap blocks, it treated any page
  within reach as heap memory if the block spanned fewer than three pages.
  But kernel pages are also handed out by `__OS_askPages` for other uses,
  such as page directories, interleaved with heap pages. A 40-byte block
  crossing the end of a heap page wrote its header into the next page:
  `ocamlrun`'s page directory.
- When freeing a block it computed the first page it could release, then
  released from the block's first page anyway, possibly freeing a page
  still holding the previous block.
Larger IPC messages made the kernel allocate more often, which made the
first bug hit.

**Fix.** A block may only use the page where the previous block ends and
the page where the next one starts; anything else is requested from the
page allocator, which refuses pages that are taken. Free from the right
page.

**Lessons.**
- When memory changes but its mapping does not, watch the memory, through
  any address that reaches it.
- Allocators that share an address space must agree on who owns each
  page; "adjacent to mine, so mine" is not a rule.

## 2026-11-16 — Spawn

### Programs starting programs

**Design.** A native call (30) takes an ELF image in the caller's memory,
an `argv` and an `envp`, and starts a child process; `waitpid`/`wait4`
(Linux 7 and 114, musl uses the latter) collect its exit status. Reading
the file stays in user space (`mynos_spawn`, through the same `open`/`read`
that go to memrofs): the kernel builds processes, it does not know about
files. The boot modules go through the same `createProcess`, with the old
`argv = {"mynos"}`. Each process now has `exitStatus` (Linux encoding),
`reaped`, and `childSem`, a semaphore V'd once per child that ends:
`wait4` scans the children, and if none has ended sleeps on it and scans
again. Checking before sleeping on a counting semaphore means no wake-up
is lost, and a stale count only costs one extra scan.

`spawnProcess` used to put the new thread in the ready queue first and
build it afterwards; harmless at boot, it is now inserted last (system
calls run with interrupts off anyway). It also now checks the whole image
(segments inside the file, everything in the one page table at
`0x40000000`) before allocating anything, since the image now comes from a
process.

**One surprise:** the child ran but `Sys.argv` was empty. The MyNOS `main`
of `ocamlrun` rebuilt `argv` as `{"ocamlrun", prog}`, dropping the rest; it
now passes its own `argv` to `caml_main` when it has one.

### The page after the boundary

**Symptom.** After a spawn of a file that is not an ELF program failed
cleanly, the next spawn stopped the kernel: `page fault`, at `_insertBlock`
(`dynalloc.c`), writing at `0x6fb000`, a page-aligned address.

**Diagnosis.** `qemu -d int` gave the faulting EIP and CR2; `addr2line`
named the function. The failed spawn had called `kfree` on the new process
descriptor, the only block in its page: `kfree` gave the page back to the
page allocator, correctly.

**Cause.** The fix of the previous story let a new block use "the page
where the previous block ends", computed as the page of the block's *end
address*. When the previous block ends exactly at a page boundary, its end
address is the first byte of the next page, which is not the heap's: here,
the page just given back. The same off-by-one was in the "room at the end
of the last block" case. (And a 2003 branch returned the block's size
field instead of the block: unreachable in practice, fixed anyway.)

**Fix.** The page where a block ends is the page of its last byte,
`end - 1`.

**Lesson.** An end address is one past the end: every "which page"
question about it needs the `- 1`. Failure paths (a spawn that fails and
frees) exercise allocators in ways the happy path does not.

### A negative channel id

The test's child raised an exception on purpose by sending on channel
`-1`. The kernel used the id as an index into its channel table without a
bound check (ports had one) and faulted. `getChannel` now rejects ids out
of range: every value a process passes is untrusted.

## 2026-11-16 — The shell

### The OCaml toplevel as the shell

The shell is the toplevel of OCaml 5.5 itself: `shell/main.ml` sets the
include path to the RAM disk, opens module `Shell` (a few commands: `ls`,
`cat`, `run`, `help`, `free`) and calls `Topmain.main`. Linked without
`-g`, the toplevel is 3.8 MB (the system's `ocaml` is 28 MB, mostly debug
information). What it needed from MyNOS:
- **Its interfaces**: the standard library's `.cmi` files (830 KB) on the
  RAM disk. Some names are 28 characters long (memrofs allowed 19: now 63)
  and the disk grew to 5.5 MB, beyond the one page table (4 MB) the
  kernel mapped it with. The RAM disk now takes as many page tables as it
  needs, built once and shared by every process; its pages are read-only,
  so fork's copy-on-write leaves them alone.
- **Finding files**: an interactive toplevel looks for `.cmi` files with
  `Sys.file_exists` on each directory of the load path (not through a
  `readdir` cache, as the batch compiler does), so a flat filesystem
  works: the include path is `/`, and `libmynos` drops leading `/` and
  `./`. `readdir` over a new memrofs LIST request came anyway, for `ls`.
- **Memory**: 256 MB in QEMU for the demo and the test.

### The free list that pointed into freed memory

**Symptom.** In the shell, `run "hello.byte" []` killed the shell with
`Out of memory`; the kernel had refused a 17-page `mmap` with 59 000 free
physical pages. Boots also printed "Problems releasing pages" since the
move to musl (mynos-dha).

**Diagnosis.** Printing the process's free linear space list when `mmap`
failed showed garbage: `0x1-0x1 0x1C-0x3 0x9A9D08-...`.

**Cause.** `__lmt_freeArea` (`lmemtrack.c`, 2003), when a freed area
joined the free areas on both sides, unlinked and freed the second one
without updating its successor's `prev` pointer, which kept pointing into
freed kernel heap. It also could not free an area above the last free one
(the "Problems releasing pages": the area simply leaked), and treated the
inclusive bounds of an area inconsistently. Separately, `spawnProcess`
reserved the right number of pages for the stacks, but at the very top of
the address space, where the page table mapping is, instead of where the
stacks are.

**Fix.** A rewritten `__lmt_freeArea`: find the free areas just before and
after, refuse overlaps, merge, fix every link. Sizes are `end - bgn + 1`.
`__OS_askPages` checks the allocation result (it used to map page 1 on
failure) and gives the area back if mapping fails. The stacks are reserved
where they are.

**Lesson.** musl's allocator `mmap`s and `munmap`s far more than dietlibc
did; old code paths that were never exercised get exercised. A message
that "only" warns ("Problems releasing pages") can be the visible end of a
corruption.

### Thirty-two seconds to a prompt

**Symptom.** The shell took 32 s to print its prompt, 14 of them before
its first line of output; exactly the same with KVM.

**Diagnosis.** Identical times with and without hardware virtualization
mean the time is not spent computing. Sampling the CPU's EIP through the
QEMU monitor (`info registers`, 80 times) found it in the kernel's idle
loop every single time.

**Cause.** The ready queue is a round robin that includes the idle thread.
A client that sends a request and blocks calls the scheduler, which picks
the next thread in the queue; when that was the idle thread, it spun until
the next timer tick (10 ms) before the server got the CPU. The toplevel
starts with hundreds of IPC exchanges (its 3.8 MB in 16 KB reads, then the
`.cmi` files).

**Fix.** The scheduler skips the idle thread when another thread is ready;
the idle loop halts the CPU (`hlt`) instead of spinning. The prompt now
appears about 1 s after boot, and every test boot got faster.

**Lesson.** When a system is slow, first find out whether it is busy or
waiting: sampling the instruction pointer answers in a minute.

## 2026-11-16 — Processes that give their memory back

### Freeing what you stand on

**Problem.** `killProcess` (2002) freed ports and channels; the rest was a
`TODO`. Each program the shell ran kept 0.5–1 MB until reboot.

**Design.** A process ends inside `killProcess`, on its own kernel stack
and with its own page directory loaded: it cannot free them. So it only
releases what others see (IPC, semaphores, its children become orphans),
records its page directory and joins a list of zombies. `reapZombies`,
called at the start of every `sched()` and by `wait4`, frees the zombies
other than the current process: it reads the dead page directory and page
tables through the kernel's one-page window onto physical memory
(`externalmem.c`), and drops one reference on every present frame
(physical pages are reference-counted, so copy-on-write and IPC-shared
pages are handled), then on the page tables, the directory and its
mirror. The two shared kernel ranges (the kernel itself, the RAM disk's
page tables) are skipped. The descriptor and pid go when the parent has
collected the status, or at once when nobody can.

**The catch: aliases.** `spawnProcess` and `fork` build a process's pages
(directory, page tables, program, stacks) in the kernel's linear space,
then map the same frames into the process. The kernel mappings stayed
forever: freeing the frames would have left them pointing at memory
given to someone else, and kept kernel linear space in use. Once a
process is built they are now dropped (`__OS_releasePages(.., free = 0)`,
a pattern `externalmem.c` already used), so each frame belongs to the
process alone.

**Threads.** An exited thread's `tss` and kernel stack (which lives in the
process's space) cannot be freed by the thread itself; they are kept on
a list and reused by the next thread the process creates, and freed with
the process.

### The leaks the measurement found

With the memory freed, a loop of spawns still lost about 3.5 pages per
program. Measuring the free pages around separate loops (file operations
alone, spawns alone) and fixing what showed up:
- **The registry** started a thread per request on a `malloc`ed stack it
  never freed (and those threads used the C library while sharing their
  creator's TLS, mynos-l9h). Requests are short: it now serves them one at
  a time, with a timeout on the receive.
- **`listenPort`** took each connection request off the port's queue and
  never freed it.
- **`__OS_ipc_freeChannel`**: the first side to close a channel returned
  before removing the id from its own channel list. One list node per
  connection, and every file operation is a connection; at the process's
  end, those stale ids were "freed" again.
- What remained, about a page per 30 operations, was not a leak: the
  parent's OCaml minor heap (1 MB, allocated on first touch) filling up.
  The test touches it all before measuring.

Twenty programs in a row now leave the free memory unchanged.

**Lessons.**
- Measure the cost of each operation separately, then repeat the loop: a
  constant cost per round is a leak, a decreasing one is warming up.
- Memory reachable through two mappings has two owners in practice; give
  each frame one.

## 2026-11-16 — Boot, init and the first OCaml service

### Three steps

- **Clean boot screen.** Once user space starts, kernel messages go only
  to the log port (`kernel_on_screen`, unless the kernel command line says
  `verbose`), and services log through a new native call (31) instead of
  printing: the screen belongs to the shell.
- **init in OCaml.** A boot module's command line is now its `argv`, so
  `ocamlrun` could be told what to run; but the better structure was to
  make the first bytecode program, `init`, read `init.rc` and start the
  rest from the RAM disk: consoled, tmpfs, and the shell, restarted when
  it ends. Only the registry and memrofs (which serves the disk) remain
  GRUB modules.
- **tmpfs**, the first service in OCaml: 200 lines, a hash table of
  files, the same request format as memrofs (parsed with
  `String.get_int32_le`). memrofs's protocol became the file service
  protocol, with `WRITE` (request, then data, then reply: the server must
  take the data even to refuse it, or the client stays blocked in its
  send) and `UNLINK`.

### The leak that depended on where a buffer was

**Symptom.** With the new `fileio.c`, the spawn test lost 31 pages per
program. The old `fileio.c` lost none, although the reading code in both
was the same, line for line.

**Diagnosis.** A careful rerun of each variant, everything rebuilt each
time, gave consistent results only when looked at from the side of
memrofs: `memrofsd` links `libmynos` too, and the new `fileio.c` has a
larger table, which moved memrofs's static read buffer. With the new
library it landed at `0x40011000`, page-aligned.

**Cause.** `__OS_ipc_send` (2004) computed the last page of a message as
`(start + size) >> 12`, the page *after* the last byte when the message
ends at a page boundary. A page-aligned 16 KB message was mapped into the
receiver as five pages; the receiver unmapped four (it knows the size).
One leaked page per read. The first experiments were misleading: they
swapped the library in the runtime, while memrofs kept whichever library
it had last been linked with. The culprit was a binary not under
suspicion.

**Fix.** `(start + size - 1) >> 12`.

**Lessons.**
- The third "one past the end" bug of the week (the heap allocator, the
  free list, now IPC): every end address deserves a second look.
- A change in one binary can move data in another that links the same
  library. When results contradict the code, rebuild everything and vary
  one thing at a time.

## 2026-11-16 — Threads and OCaml domains

**Goal.** `Domain.spawn` is `pthread_create`, which in musl is the Linux
`clone` call, with futexes behind every lock and condition, and
`CLONE_CHILD_CLEARTID` behind `pthread_join`.

**Design** (`mynos-core/kernel/lthreads.c`):
- **clone** makes a MyNOS thread in the calling process. The child must
  come back from the system call as if it had made it: `eax = 0`, the new
  stack, and every other register as the parent's, because musl's
  `__clone` keeps the function to call in `ebp`. The kernel's thread start
  (`startThread`) only restored segment registers; `startClonedThread`
  also pops the general ones (`popal`) before the `iret`. The parent's
  return address and flags are read from its own system call frame, just
  above the six registers the entry code pushes. The TLS comes from the
  `user_desc` passed with `CLONE_SETTLS`: each thread has its own, loaded
  in the GDT at every switch, as `set_thread_area` already did.
- **exit** (1) now ends only the calling thread, clearing and waking its
  `clear_child_tid` (that is how `pthread_join` learns); `exit_group` (252)
  ends the process. A process's last thread ending ends the process, so
  dietlibc's `_exit`, which uses 1, still works.
- **futex**: a table of waiters keyed by process and address. A waiter
  blocks on its private semaphore, with an optional timer. One subtlety: a
  waiter woken by its timer must not also be woken by a `FUTEX_WAKE`
  before it runs, or its private semaphore stays at 1 and its next
  blocking call (an IPC receive...) returns at once. A wake therefore
  signals a timed waiter only if it can still take it off the timer
  queue. `REQUEUE`/`CMP_REQUEUE` move waiters (musl's condition variables
  use them); `WAIT_BITSET` takes an absolute time.
- Thread ids: a process's first thread has its pid, the others ids above
  the pid range. `set_tid_address`, `gettid`, and `tkill` on one's own
  threads.

**Result.** The domains test (results through `join`, an atomic counter,
a producer and a consumer with `Mutex` and `Condition`, `Domain.DLS`, an
exception through `join`, a full major GC with three domains allocating)
passed at the first run, as did `Domain.spawn` in the shell. One CPU:
domains take turns (SMP is mynos-awn). The `Thread` module needs more of
the runtime (mynos-09i).

**Lesson.** A thread born inside a system call has to be built to look
exactly like a thread returning from one: knowing the caller's
conventions (here, which registers musl's `__clone` relies on) decides
what the kernel must restore.

## 2026-11-16 — Storage in OCaml: an ATA driver and a FAT filesystem

### The design

Storage is two OCaml programs, ordinary MyNOS processes:
- **`ata`** (`services/ata`), the disk driver: the processor runs MyNOS
  processes with I/O privilege, so the driver talks to the IDE controller
  through `Mynos.inb`/`outb` and moves sectors with `insw`/`outsw` (`rep
  insw` in the runtime's stubs). PIO, LBA28, polling, controller interrupts
  off. It serves sectors over IPC (`mynos_block.h`; OCaml client: module
  `Block`).
- **`fatfs`** (`services/fatfs`), a FAT16/FAT32 filesystem (the format was
  chosen, with the owner, to be standard and simple: images are made and
  checked with `mkfs.fat`, mtools and `fsck.fat`, no root needed). It reads
  the disk through `ata`, keeps the whole FAT in memory and writes it back
  to every copy after each change; directories, 8.3 names with the
  lower-case flags of Windows NT, VFAT long names read and written. It
  speaks the same file service protocol as memrofs and tmpfs, extended with
  paths, `MKDIR` and `RMDIR`; `libmynos` mounts it at `/disk`, normalizes
  paths and replaces `mkdir` and `rmdir`.

The test writes and reads through OCaml's standard library only
(`open_out`, `Sys.readdir`, `Sys.mkdir`...), on a FAT16 and a FAT32
image; afterwards `fsck.fat -n` must find the images consistent and
mtools must read what MyNOS wrote.

A detail of OCaml on i386: `int` has 31 bits, so 32-bit fields with high
bits set (FAT32 entries keep 4 reserved high bits, the FSInfo signature
`0x41615252`) are handled as two 16-bit halves.

### A test that failed one time in six

**Symptom.** The FAT test hung about one run in six (FAT32: almost
always): the driver and the registry each accepted a connection on
which no request ever came ("recv: expired"), and nothing moved again.

**Diagnosis.** gdb attached to QEMU's gdbstub while hung: the timer queue
held garbage (a "thread" whose pid and wake-up time were real-mode
interrupt vectors, i.e. read from address 0), so no sleeping thread was
ever woken. A trace of the last timer-queue operations, checked after
each one, showed the first bad state: right after a thread was inserted,
its node could not be found in the queue. On the way, two more checks
were built: a consistency check of the kernel heap's block list at every
`kmalloc`/`kfree`, which found a real bug (below), and a check that the
reaper never frees a frame the kernel still maps, which found none.

**Causes.**
1. `listInsertOrdered` (`list.c`, 2002): inserting an element whose key
   equals the head's (two receive timeouts started in the same tick)
   went through the "insert in the middle" branch, which stopped at the
   head, wrote through its NULL `prev`, and linked the new node before
   the head without updating `q->head`. The node was unreachable, the head
   had a wrong `prev`, and when the head was later extracted `q->head` was
   left pointing to freed memory. It also allocated, and dropped, an extra
   node at every insertion at the tail.
2. `_removeBlock` (`dynalloc.c`, 2003): to know whether the previous block
   still used the first page of the freed block, it took the page of
   `_BLOCK_END(prev) - 1` with `_GET_PAGE_BLOCK`, a macro meant for blocks
   that steps back 4 bytes over the size field. When the previous block
   ended in the first 4 bytes of a page (its list pointers), that page was
   given back while still in use.

**Fix.** A rewritten ordered insertion (after every element not greater
than the new one); `_GET_PAGE_ADDRESS` in `_removeBlock`.

**Lessons.**
- Ties are where ordered structures break: test with equal keys.
- A bug that depends on timing is still deterministic for a given order of
  events: trace the operations on the corrupted structure, check it after
  each, and the first bad step names the culprit.
- The kernel heap allocator of 2003 has now had four fixes; its checker
  stays in the code (`HEAP_CHECK` in `dynalloc.c`), off by default.

## 2026-11-16 — The compiler inside MyNOS

Running `ocamlc` inside MyNOS took less than expected, which says something
about the layers below: the compiler is just another bytecode program for
the runtime, and the files it needs are reached through the same file
functions. What was missing, found by trying:
- **`rename`**: the linker writes the executable to a temporary file next
  to it and renames it (`Misc.output_to_file_via_temporary`). The file
  service protocol got `RENAME` (the new name in a second message, as the
  data of a `WRITE`); fatfs makes a new entry for the same clusters and
  deletes the old one, updating `..` when a directory moves.
- **`runtime-launch-info`**, a file the 5.x linker reads from the
  standard library directory, which is `Config.standard_library` (a path
  of the build machine) unless `OCAMLLIB` says otherwise: the shell now
  starts programs with `OCAMLLIB=/`, the root of the RAM disk, where the
  library's files are. Spawn's environment, added for this kind of need,
  got its first use.
- **`getrandom`**, for `Random.self_init` (it had a fallback, but the
  kernel reported the missing call): a xorshift seeded with the time-stamp
  counter, not cryptographic.

## 2026-11-16 — A terminal for text user interfaces

The plan was to move the screen from the kernel to the console service, so
that the terminal would be a user-space service like the others. It ran
into musl: its stdio writes `stdout` and `stderr` with direct `writev`
system calls, which `libmynos` cannot replace, so C programs' output would
have reached the screen behind the service's back and the cursor would
have drifted. The terminal emulator went into the kernel's screen driver
instead, where every output already arrives: about 300 lines for the
VT100 subset text interfaces use (cursor moves and positioning, erasing,
SGR colours, a hidden cursor, an alternate screen that saves and restores
the shell's screen, inserting and deleting lines and characters). It can
move to a service once the kernel forwards writes.

Input stays in the console service: a raw mode (keys one by one, Enter as
`\r`, Backspace as DEL, the arrows and editing keys as `ESC [` sequences,
VMIN/VTIME reads), which `libmynos` maps from termios: it replaces
`ioctl` for `TCGETS`, `TCSETS*` and `TIOCGWINSZ`. musl's `isatty` asks the
kernel directly, so the kernel answers `TIOCGWINSZ` for fds 0-2. A raw
mode belongs to the process that set it: a read from another process
(the shell, after an editor that crashed) brings line editing back.

kilo, Salvatore Sanfilippo's 1000-line editor, was the test: it needed
two changes, both for the same reason as above (musl's stdio reads files
with direct system calls), and then worked, full screen.

One trap on the way: after changing the console protocol (the request grew
from 8 to 24 bytes), the shell hung at its first command. Only `libmynos`
and the services had been rebuilt, not the runtime that links it, and
the service silently dropped requests of the old size. A full rebuild
fixed it; the lesson is to rebuild everything after a protocol change.

### The editor, on Notty

With the terminal in place, the editor is an OCaml program on
[Notty](https://github.com/pqwy/notty), a declarative library for terminal
interfaces, pure OCaml apart from its Unix backend. MyNOS's backend
(`third_party/notty/notty_mynos.ml`, 60 lines) does what `Notty_unix.Term`
does without the Unix library: raw console mode through a new
`Mynos.console_mode`, output to stdout, input from stdin decoded by Notty's
own `Unescape`. Two details: Notty 0.2.3 predates the `out_width` field
OCaml 5.2 added to `Format`'s output functions (one line), and the console
sends Enter as CR, which Notty only understands as LF (on Unix, termios's
`ICRNL` translates it): the backend maps it.

The first full-screen frame came out as one long line: Notty ends lines
with `ESC E` (NEL), which the terminal ignored, and assumed that the
alternate screen starts blank, as in real terminals. Both added, `edit`
worked, and the loop closed: write a program in MyNOS, compile it with
`ocamlc` in MyNOS, run it, find it again after a reboot.

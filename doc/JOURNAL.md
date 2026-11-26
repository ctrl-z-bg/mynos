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

## 2026-11-16 — sh, and redirections without file descriptors

A command shell needs redirections, and on Unix they work because a child
inherits its parent's file descriptors. MyNOS processes inherit none: a
descriptor of `libmynos` is an index into a table of the process, standing
for a descriptor of a file service owned by that pid. Rather than adding
descriptor passing to the kernel and the services, the redirection
travels in the child's environment (`MYNOS_STDOUT=/disk/out.txt`, with
`>>` to append), and `libmynos` opens the file at the first use of fd 0,
1 or 2. It then rewrites the variable to append, so that the child's own
children add to the file instead of truncating it. Pipes, without
concurrent descriptors either, run their commands one after the other
through a file in `/tmp`, as on MS-DOS: enough for `cat *.txt | cat > all`,
not for a producer that never ends.

One shell bug worth noting: the first version expanded variables while
reading the line, so `X=5; echo $X` printed nothing and `$?` was always
the status before the line. Words now keep their parts (quoted text,
unquoted text, variables) and are expanded when their command runs.

## 2026-11-17 — Tab completion, and a date in 1980

Tab completion cannot live in the console service, which knows nothing
of commands or of the shell's current directory; as in Unix, where bash
links readline, the shell edits its own line. `sh` switches the console
to raw mode while it reads a command, and back to line mode while the
command runs, so that programs see the console as before. Long lines
scroll horizontally, which keeps the redrawing to one screen line.

Checking the demo disk with mtools showed files dated `1980-10-30 31:63`.
fatfs computed the date from `int_of_float (Mynos.time ())`: about 1.8
billion seconds since 1970, which does not fit OCaml's 31-bit `int` on
i386 (the same trap as the FAT32 fields, in another place). Days and
seconds are now split while the value is still a float; the FAT test
checks the year of a file MyNOS wrote.

## 2026-11-17 — A new kernel heap, and what a stress test found

**The allocator.** Four bugs in two days in `dynalloc.c` (2003), all about
which page belonged to which block, were reason enough to replace it
rather than review it again. The new one has size classes (32 bytes to
2 KB, each with a free list, one page taken at a time) and whole pages
above; every block has a header with a magic number, so a double free or
the free of something that is not a block is reported with its caller
instead of corrupting the heap.

**Twenty years of zeroed memory.** With `HEAP_CHECK` (freed blocks filled
with `0xDB`) the first boot faulted with the kernel executing on a user
stack. Leaving the poison in one size class at a time pointed at the
256-byte class, and there at `tss_t`: `createProcess` never set
`justForked`, `queue`, `kstack` or the general registers. Blocks used to
come almost always from fresh, zeroed pages; with garbage in `justForked`
the scheduler took the new process for a forked one. The tss is now
cleared, and `kmalloc` always returns zeroed blocks. *Lesson: poisoning
freed memory finds bugs that zeroed memory hides; test with it on.*

**The stress test** (`tests/stress`) starts copies of itself as clients
that send messages of awkward sizes (1, 8, 9, 4095, 4096, 4097... 64 KB),
runs threads whose timers expire together, ping-pongs semaphores, and
passes invalid arguments and pointers to every system call it can. Each
step found something:

- *Unchecked indexes.* `changeOwner(3000)` read past the port table and
  page-faulted the kernel; `allocPortP` too; semaphore calls turned a
  negative id into an index before the table (and locked a "mutex"
  there). A negative channel was a "kernel channel": a 2003 stub that
  answered 0 to anything.
- *A panic that did not stop.* `KPANIC` printed and spun with interrupts
  on: the timer kept switching to other processes, which ran on a broken
  kernel and produced nonsense (system call numbers that were ASCII
  text). It now disables interrupts and halts.
- *Clobbered registers.* The native system call entry let the C handlers
  change `ecx` and `edx`. libmynos declares them clobbered, so only the
  test's raw calls noticed; the entry now saves them, as Linux's does.
- *Pointers.* The kernel used processes' pointers as given. One into the
  kernel (below 1 GB) does not even fault: `recv` and `stats` would have
  written their results into the kernel. `send` mapped the kernel's own
  pages into the receiver ("TODO CHECK AREA", 2003). `__mem_userArea`
  now checks every pointer a system call reads or writes, native and
  Linux: inside the user part of the address space, user pages only (a
  thread's kernel stack lives there too), no wrap around. A kernel page
  fault on a user address now ends the process instead of the system.
  One false start: `mmap2` passes its arguments as a struct on the
  *kernel* stack (the entry pushes the registers), which the check
  refused; only the old `mmap` gets a user pointer.
- *Leaks that only a long run shows.* With `stress 20` (2400 processes),
  everything stopped after 660 processes: semaphores ran out, 682 in use
  for 9 processes. Two causes. `allocateSemaphore` used the first slot
  looked at as the id, but the semaphore went into the first *free* slot
  after it: when slots were skipped, `freeSemaphore` looked in the wrong
  slot and gave up. And libmynos's `malloc` makes a semaphore in every
  process, which nobody freed: semaphores now record the process that
  made them (`initSem`), and are freed when it ends. Then memory: 20
  pages lost; `HEAP_CHECK` now counts blocks in use by caller, and the
  count for `__lmt_newPdListEl` grew by one per process. `lmemtrack`'s
  forced allocation, splitting the *first* free area, created the new
  element but did not make it the head of the list: one element lost per
  process, and with it the free space between a program and its stack.

*Lessons:* a short stress run finds the crashes, only a long one finds
the leaks; count resources (semaphores, channels, heap blocks by caller)
from gdb when something runs out; check pointers at the system call
boundary, because the kernel's own addresses never fault.

## 2026-11-17 — Back to the 2002 idea: typed IPC

Re-reading `doc/website/why.html` with the owner: the microkernel, the
services as processes and the OCaml virtual machine as a process are as
planned in 2002, but what we had built on top in the last two days was a
small Unix (files, a shell, a terminal), and even the OCaml services
talked like C programs, through structs packed with `Bytes.set_int32_le`.
The presentation's aim was "a new, higher level and yet strong abstraction
to the machine through OCaml". Decision (`doc/decisions/typed-ipc.md`):
keep the Unix-like layer as the floor, and give OCaml programs typed IPC.

A protocol is a GADT of requests indexed by the reply type
(`Read : int * int -> string request`), so `call` returns the right type
and a service's handler is a polymorphic function. The codecs come from
combinators (`Wire`), not `Marshal`: a service must survive any client,
and `Marshal` trusts its input. The format (zigzag LEB128 ints,
length-prefixed strings, variants as case numbers) is simple enough for
the C side the network service will need. Reading counts and lengths are
bounded by the bytes left, so a malformed message cannot make a service
allocate much.

Two small traps. `Wire` defines an exception `Error`, which shadows the
constructor of `result` inside the module: `Stdlib.Error` there. And a
request string in a test was written with its length as a plain byte; the
length is itself a zigzag int (7 is the byte 14), which the test caught.

*Lesson:* the useful check for "is this still MyNOS?" was a document
written twenty years ago; worth re-reading before each new layer.

## 2026-11-17 — The network: lwIP and an NE2000 in one process

**Shape.** netd is one C process holding lwIP (2.2.1, the raw API with
`NO_SYS`: no threads inside lwIP) and the NE2000 driver: a frame goes from
the card to the stack with a function call, not two IPC messages. lwIP's
raw API is callback-based, which fits a server answering typed IPC: a
request that has to wait (`Recv`, `Accept`, `Connect`, `Ping`, `Resolve`)
keeps its channel open, and the lwIP callback that ends the wait sends the
reply on it. Since MyNOS has no "wait for any of these" call, a second
thread (a pthread, so that it has its own TLS) blocks in `listenPort`,
queues each request and signals a condition variable; the lwIP thread
waits on it with a 10 ms timeout, polls the card, runs lwIP's timers and
handles the queue. Polling, because the kernel only routes IRQs 1, 3 and
4 to user space (mynos-8v4).

**The card.** The DP8390 is driven through I/O ports only, so no kernel
support for DMA was needed. QEMU's PROM holds each MAC byte twice; its
remote DMA wraps at the end of the receive ring by itself, so a frame that
wraps is read in one go. The ring is empty when the page after BNRY is
CURR.

**Typed IPC across languages.** "net/1" is defined by the OCaml GADT in
`net.ml`; the C side follows its case numbers with `mynos_wire.h` (a
writer that grows, a reader that never fails loudly but sets an error
flag). The OCaml test sends the same malformed messages to netd as to the
OCaml block driver, and both answer them with an error reply.

**Small things.** lwIP's `init.c` includes PPP's option headers even with
PPP off; `lwip_strerr` lives in the netconn API we did not import. An
or-pattern over GADT constructors does not refine the type (`Ping _ |
Connect _ -> Wire.int` does not compile): one case each. In
`run-tests.sh`, `kill` of a helper that had already ended stopped the
whole script under `set -e`.

It worked the first time it booted: DHCP from QEMU's user network, ping,
DNS to the internet through the host, TCP both ways (the host fetches a
page from httpd, in OCaml, through a forwarded port).

## 2026-11-17 — A web server that kept the browser waiting

*Symptom:* the owner's browser waited many seconds for
http://localhost:8080/. *Diagnosis:* measured before guessing: a single
`curl` got its page in 50 ms; with one idle connection open first, as
browsers do to save time later, the next request got nothing in 30 s.
*Cause:* httpd served one connection at a time, and sat in `Recv` on the
connection that never sent a request, until the browser gave it up.
*Fix:* 8 worker domains take accepted connections from a queue (the
`Mynos` stubs release the runtime around blocking calls, so a domain
waiting in IPC does not hold up the others' garbage collection); and a
per-socket timeout in "net/1" (`Set_timeout`, added as a new case, so old
clients still work), which netd checks in its loop, so that idle
connections free their worker after 10 s. *Lesson:* a server tested with
`curl` only is tested with the politest client there is.

## 2026-11-17 — The event recorder: what a `cat` really does

The owner's idea: record every interaction between the parts of the
system and play it back. In a microkernel every interaction already goes
through the kernel, so the recorder is a few hooks (spawn, exit, the IPC
connection, send, receive, free) writing 96-byte events into a ring
buffer; programs read it with a system call. Processes got a name for it
(the program's base name, or the bytecode's for `ocamlrun X.byte`).

The first bytes of a message are enough to say what it means: typed IPC
messages start with their protocol id and case number, and the old C
protocols have fixed layouts known by the service's name. Calls are
rebuilt from channels, as spans in distributed tracing: with one
connection per call, the client's first send and its last receive on a
channel bound the call; the server's own calls in between are nested in
it.

The first recording of `cat /disk/README.TXT` under `sh` was a lesson in
itself: `sh -c` starting means reading the 530 KB `ocamlrun` image from
memrofs in 16 KB requests; the runtime looks for itself in `PATH` (a
`NOT_FOUND` from fatfs for `bin/ocamlrun`), reads its own trailer, looks
for `ld.conf`; then `cat` itself is a handful of fatfs calls, each a
sector read on ata0, and writing 57 bytes to a file costs fatfs five
sector writes (the data, both FAT copies, the directory entry) and
3.6 ms.

*Snags:* the OCaml toplevel's compiler libraries already have a module
`Trace` (for `#trace`): ours is `Tracer`. The kernel has no `uint16_t`
(`ushort16_t`) and no `kstrcmp`. The sender of a message received after
the sender freed its end of the channel is unknown to the kernel: the
player takes it from the channel's ends.

## 2026-11-17 — Interrupts for every driver, and a web page 4 times faster

The 2004 kernel had handlers for IRQs 1, 3 and 4 only (the keyboard and
the serial ports), each a `V` on the driver's semaphore; the driver sent
the EOI to the PIC itself, from user space. Every other line went nowhere,
so netd polled the card every 10 ms and the disk driver polled its status.

Now one dispatcher serves IRQs 1 and 3-15 (0 is the timer, 2 the cascade
to the second PIC): it acknowledges the PICs (the second one too for
8-15), `V`s the driver's semaphore, and, if the idle thread was running,
calls `sched()` as the timer does, so the driver runs at once instead of
at the next tick. A line with no driver is masked; a driver's lines are
freed when it ends; a line can be taken by one live process only, and 0
and 2 cannot be taken or masked by anyone. The old drivers still send
their own EOI: by then nothing is in service, and a non-specific EOI with
nothing in service does nothing, so they work unchanged (the legacy demo's
`keyboardd` and `seriald` too).

The NE2000 now interrupts on received frames. A subtle point: the driver
acknowledges the card's "received" bit *before* looking at the ring, not
after finding it empty; otherwise a frame arriving between the look and
the acknowledgement would raise no new interrupt (the line is edge
triggered) and wait for the next one. netd's loop still wakes every
100 ms for lwIP's timers.

Measured from the host, a small page from httpd: 42.6 ms median before,
10.7 ms after. The recorder, which now records interrupts too, shows the
IRQ waking netd while the CPU was idle, and the rest of the time: httpd
opens the file twice and seeks three times to learn its size.

## 2026-11-17 — TLS: an old port, a new mbedTLS, and where the randomness comes from

**Goal.** Programs in MyNOS calling web APIs over `https://` (the LLM
service of mynos-wsd first). TLS went into netd, under lwIP's `altcp`
layer, which puts TLS or plain TCP under the same callbacks: netd's
sockets moved from `tcp_*` to `altcp_*` calls, and one request,
`Connect_tls (host, port)`, was added to "net/1". Clients do not change:
`Send` and `Recv` carry the clear bytes.

**Which mbedTLS.** lwIP 2.2.1's port (`altcp_tls_mbedtls.c`) says it is
for mbedTLS 2.x, whose last branch, 2.28, has had no security fixes since
the end of 2024. 4.x moved the cryptography to a separate PSA library.
3.6 is the LTS; the port needed five changes: private fields of
`mbedtls_ssl_context` (`MBEDTLS_ALLOW_PRIVATE_ACCESS`), the internal
`mbedtls_ssl_flush_output` declared by hand, `mbedtls_pk_parse_key` with
a random number generator, `mbedtls_ssl_get_max_out_record_payload` for
the fragment length, and the `net_sockets.h` error codes. Two more are
MyNOS's: a failed handshake leaves its mbedTLS error and the certificate
check's flags in globals, so that the client gets "TLS: bad certificate:
The certificate validity has expired" instead of "connection closed";
and a list of authorities is accepted when some of its certificates
cannot be parsed (the port refused the whole list). `psa_crypto_init()`
is called at netd's start (TLS 1.3 needs PSA).

**Randomness.** TLS keys are only as good as the random numbers, and
`getrandom` was an xorshift seeded by the time-stamp counter: fine for
OCaml's hash tables, predictable for an attacker. The kernel now keeps a
pool (`random.c`): the time-stamp counter at every timer tick and every
interrupt (keys, frames), whose low bits depend on when things really
happen, plus RDRAND/RDSEED at boot when the processor has them. QEMU's
default `qemu32` processor does not announce them, but TCG implements
them: `-cpu qemu32,+rdrand,+rdseed` in `run-qemu.sh`. The mixing function
is SHA-256's compression function (in the kernel: no library there);
output blocks are the compression of the pool with a counter, and after
each request the pool is replaced by another compression of itself, so
an earlier output cannot be recomputed from a later state. mbedTLS on
"Linux" asks for its entropy with `syscall(SYS_getrandom)`, which is
this.

**Smaller things.** TCP's window grew from 8 to 16 segments: lwIP warns
that a window smaller than a TLS record (16 KB) can stall the receiving
side. The certificates are read at the first `Connect_tls`, not at boot:
parsing Mozilla's 118 roots takes about 1.5 s in QEMU, and most sessions
never use TLS.

**Tests.** A test authority, made once with openssl and kept in
`tests/net/tls/` (20 years), replaces Mozilla's list on the test RAM disk.
`net-peer.py https` serves HTTPS on the host: 47443 with a certificate
for 10.0.2.2 from the test authority, 47444 from an unknown authority,
47445 for another name. MyNOS posts to the first through `Http` and gets
a chunked answer; the other two are refused, with the reason. By hand,
from MyNOS: example.com in 1.9 s the first time (the certificates), 0.2 s
after; google.com (87 KB), api.anthropic.com (401 without a key, as it
should); expired.badssl.com and wrong.host.badssl.com refused.

**Lesson.** The old port's comments listed its "mandatory security
configuration" (a strong entropy source) but nothing checks it: TLS
would have worked, with keys an attacker could guess. Behaviour tests
do not show that; it had to be read and fixed on purpose.

## 2026-11-17 — The stress test that hung: port 0 given away

**Symptom.** After the TLS work, `tools/run-tests.sh` failed once: the
stress test printed "allocPort ok" and nothing more. Alone, it hung 3 runs
in 10; with the previous commit's kernel, 1 in 10: an old bug, made more
frequent by new timings (the random number pool's work at each tick, the
processor's options).

**Diagnosis.** Phase prints placed the hang at the first `spawn`, which
reads the program through memrofs and so asks the registry. A gdb script
on the hung kernel (processes, ready and timer queues, semaphores with
waiting threads) showed no registry process at all; memrofsd and stress
were waiting on their private semaphores. The console said why: "Error
registry allocating port: -2", then "process 1 exited".

**Cause.** The registry takes the well-known port 0 with `allocPortP(0)`.
`getFreePort`, behind `allocPort`, started its search at 0 too. All
modules start at boot together; when stress ran its `allocPort` before the
registry, it got port 0, and the registry, finding it busy, ended. Every
client then waited forever for an answer on port 0, now stress's.

**Fix.** `getFreePort` starts at 1 and wraps to 1 (`FIRST_FREE_PORT`); it
also returns "full" instead of looping when only well-known ports are
free. 15 runs in 15 pass.

**Lesson.** A well-known resource must be reserved where it is handed
out, not merely taken first by convention. And a rare hang is worth a
look when it appears: here it was the boot order, and any program could
have met it.

## 2026-11-17 — Who is calling: generational ids and one privilege

**The state found.** Every process ran with IOPL 3 (the 2002 default in
`INITIAL_EFLAGS`): any program, even a phrase typed in the toplevel, could
reprogram the interrupt controller or the disk with `Mynos.outb`. Any
process could `P`, `V` or free any semaphore, including a thread's private
one. `allocPort` took the owner's pid as an argument from user space. Pids
were reused round robin over 999 slots, and channel ids over 100.

**Identity.** The first draft added a serial to each process, never
reused. The owner asked whether it could be more elegant: two numbers for
one identity leave the pid ambiguous everywhere else. The kernel already
had the answer, from the semaphore fix of a few days ago: ids that carry
their slot and a generation (`id % size` is the slot, the object keeps its
id, a lookup compares). Pids, channels and ports now follow it; a slot's
generation grows when its object is freed. `proc(pid)` replaced 71 direct
`processTable[pid]` lookups; `currProcess` stays the slot, `CURRPID` is
the pid. Well-known ports keep generation 0, so the registry's port stays
0 across restarts.

**A trap.** Thread ids (for threads other than a process's first) moved
above the pids, first at 2^30. Every multi-threaded program then aborted
(signal 6): musl keeps a mutex's owner as `tid & 0x3fffffff` and uses the
bits above as flags (`FUTEX_OWNER_DIED` is 2^30). Thread ids are now
between 10^9 (pids stay below) and 2^30 - 1.

**Privilege.** One, `io`: IOPL 3 and IRQs. Boot modules have it; `spawn`
has a flags argument (the native call had a free register) and a child
gets at most its parent's; `init.rc` says `driver consoled`, `driver
ata.byte`, `driver netd`. A process without it runs with IOPL 0, and `inb`
ends it with a protection fault. Semaphores made by `initSem` belong to
their process (the system calls check it; the kernel's own, owner -1, are
out of reach), an IRQ's semaphore to its driver; `enableIrq` and
`disableIrq` act on the caller's own lines only.

**Two calls.** `channelPeer(ch)`: the pid at the other end, which a service
asks about the channel of a request. `processInfo(pid)`: privileges, and
whether it still runs; with generations, "no such pid" is final.

**Lesson.** An invariant that already worked in one place (semaphore ids)
was the right shape for the others; asking "is there a more elegant way"
before writing the code avoided a second identity that every later
feature would have had to carry.

## 2026-11-17 — Sockets with owners, and threads that cannot call each other

**Owners in netd.** The listener thread now asks `channelPeer` for each
request's channel; the main loop handles the request with that pid as the
current caller, and a new socket is the caller's. A connection accepted by
lwIP before anyone called `Accept` belongs to the listener's owner, then
to whoever accepts it. Every second, netd checks each owner once with
`processInfo` and closes the sockets of those that ended: since pids are
not reused, "no such pid" is final, and nothing can be closed by mistake
because a later process got the same number. UDP came with it: lwIP's
raw `udp_*` API, a queue of 32 datagrams per socket, and `Recv_from`
waiting like `Recv` (and timing out like it).

**A limit found on the way.** A test meant to check the caller through a
real service served it from a second domain of the test program and
called it from the first: it hung. The two ends of a channel are told
apart by pid (`getMyReadChannel` compares the receiver with the caller's
pid), so when both ends are the same process, both sides read the same
half: the request and the reply never meet. It has always been so; the
check now uses the handler directly, and the live path is covered by the
registry and netd. Noted in STATUS as a known limit.

**Lesson.** "Who is calling" was one system call away once the kernel
kept a stable name for processes: the work in netd was mostly deciding
the owner in the less obvious cases (accepted connections, a listener's
backlog).

## 2026-11-17 — Safe copies: a fault the kernel expects

**The case.** The kernel checks user pointers at the entry of a system
call, and it is not preempted, so between the check and the access
nothing can change, unless the call blocks. `recv` does: it waits for a
message, then writes the message's description into the receiver's
memory. Meanwhile another thread of the same process may unmap that
memory. The kernel then faulted on a user address and, since the
robustness work (mynos-0fw), ended the process: a correct program (its other
thread was entitled to unmap) killed by the kernel's own access.

**The fix, as Linux does it, with a table of one.** `copy_user` is a few
lines of assembly around one `rep movsb` whose address is known
(`copy_user_insn`). The page fault handler now receives the interrupted
frame (its assembly wrapper pushes a pointer to the saved registers, with
eip after them); a fault in kernel mode at that instruction resumes at
`copy_user_fault`, which returns -1. Faults that are legitimate (pages
allocated on use, copy on write) are still served first; only a fault
that would have ended the process is turned into an error. `recv` and
`wait4` write through `copy_to_user` after blocking; calls that do not
block keep the entry check, which is enough.

**The test.** In the stress test a thread calls `recv` (the native call,
with the description's address in a page of its own), the main thread
waits 100 ms and unmaps the page, a child sends the message 300 ms
later. With this kernel the call returns `MYNOS_ERR_INVALID` and the
test goes on; with the previous one the stress process was killed
("invalid memory access at 0x40079008"). Reading `recv` again also showed
two small bugs: a broken channel stayed locked on the early returns, and
`send` on a channel the caller is not part of read through a NULL pointer.

**Limits.** Running out of a kernel table now says so once ("kernel: the
channel table is full") instead of failing silently.

**Lesson.** The pre-check was right for every call that does not sleep;
the bug class was exactly "check, block, then use", which a review by
that question found in two places.

## 2026-11-17 — A channel's ends, told apart by id

**Symptom.** A test served the `Block` protocol from a second domain of a
process and called it from the first: the call never returned.

**Diagnosis.** A channel is two one-way queues, `c1` and `c2`, each with
its `receiver` pid. `send` and `recv` found "my" queue by comparing the
caller's pid with the receivers: with one process at both ends, both
threads matched `c1`, both read it, and both wrote into `c2`, which nobody
read.

**Cause.** The channel id named the channel, not an end; the end was
inferred from who called. That was right in 2002, when one process meant
one thread of control talking to others; with threads and OCaml domains a
process can be both client and server.

**Fix.** Each end has its own id: `2 * (slot + 4096 * generation) +
side`. `listen` returns the even one, `connect` the odd one; the kernel
takes the end from the id and checks that its receiver is the caller's
process (the ownership check stays). The recorder keeps naming the channel
(`TRACE_CHANNEL`, the even id), so its pairing of requests and replies did
not change. The generation bounds were also lowered so that channel and
port ids stay below 2^30: OCaml's `int` on i386 has 31 bits, and an id
above `max_int` would have turned negative, years of uptime from now.

**Lesson.** A handle should name what it is used for: an id that names a
shared object and lets the kernel guess the side from the caller works
only while "caller" and "side" are the same thing.

## 2026-11-17 — A model as a service: two APIs, one protocol

**The question.** The AI direction (mynos-wsd) needs a way for any program
to ask a language model, optional, configured like keys usually are (a
`.env` file), and not tied to one provider: at least Claude, OpenAI's
models, vLLM and Ollama.

**Finding.** Four providers are two APIs: OpenAI, vLLM, Ollama (and
llama.cpp, LM Studio, OpenRouter) speak Chat Completions; Claude speaks
the Messages API. So `llmd` has two adapters, and "llm/1" is a neutral
shape: blocks of text, tool calls, tool results. The two APIs differ most
where agents need them: tool results are blocks of a user message for
Claude and separate `tool` messages for Chat Completions (which must
follow the assistant's `tool_calls`), and Claude returns thinking blocks
that must come back unchanged in the next request of a tool loop. Those
travel as `Opaque` (their JSON), given back to the API that made them.
OpenAI's own newer models refuse `max_tokens` (`max_completion_tokens`),
the self-hosted servers expect `max_tokens`: chosen by the URL.

**Tests without keys.** The fake provider (`tools/net-peer.py llm`) is
strict where the real ones are (headers, block types, non-empty text,
tool results answering known calls, the thinking block back unchanged),
so the network test exercises the translation, not just the plumbing.

**First real call, and a false alarm.** The first try with a real key got
"401 invalid x-api-key". The key was valid from the host; the copy in the
disk image differed from `llm.env` inside the key: the file had been saved
again one second after the copy. A second copy worked: `llm` in MyNOS,
through llmd, netd and TLS, got Claude Opus 5.5's answer.

**Lesson.** When an external service says the credential is wrong, compare
what was sent with what was meant (here: the disk's copy against the
file, byte for byte, without printing the key) before suspecting the
code.

## 2026-11-17 — Codecs that know their shape

**The question.** Step 3 of the AI direction: make every typed service a
tool a model can call, "with no glue code". A model sees JSON and JSON
Schemas; a service reads `Wire` bytes. Something must sit between them
for every protocol.

**Choice.** Not a translator per protocol, but one derived from data:
each `Wire` codec now carries its shape (a lazy value, so that `fix` can
name its recursion: inside, `Var "t"`; outside, `Rec ("t", ...)`). A
protocol's request list gives each request's argument and reply codecs,
so their shapes come from the very codecs that encode them; for `Block`,
the arguments' codecs are now defined once and used by both
`write_request` and the description. JSON maps onto shapes by a few rules
(named tuple components are object fields; nested unnamed tuples are
flattened, so `conv`'d records read naturally; variants are a case name or
a one-field object), and `Tools` writes and reads the bytes by walking the
shape. `llm_chat`, with lists of variants of records, goes through it.

**The C service.** netd describes itself from a table in a compact
notation (`"(socket:I,max:I)"`), parsed by `wire_put_shape`. The same
description now exists twice, in C and in `net.ml`; the network test
compares them (the structure, not the prose), so a change to one without
the other fails.

**Discovery.** The registry cannot list names, and asking a 2004 service
(memrofs, the console) a typed question risks confusing it: descriptions
are asked by name, with a timeout. The agent is told which services it
may use.

**Lesson.** Making the codec the single source of truth (bytes and
shape from the same value) is what keeps descriptions honest; the one
place where that is impossible (C) got a test instead.

## 2026-11-17 — The agent's first real run, and the shell's lost redirections

**Symptom.** In the first run of `agent` with Claude, `fetch -i
https://example.com` (run through `run_command`) printed its answer on the
console; the model got "exit status 0" and nothing else, and ran it again.
The run then stopped making progress.

**Diagnosis.** `run_command` starts `sh -c COMMAND` with `MYNOS_STDOUT`
(and `MYNOS_STDERR`, `MYNOS_STDIN`) pointing at files of `/tmp`. `sh`
itself honoured them, but at start it drops these variables from the
table it builds its programs' environment from (so that `> FILE` on one
command does not leak to the next): its programs got neither the output
file nor the empty input. Their output went to the console, and a
program reading its input waited for the keyboard.

**Cause.** MyNOS has no inherited file descriptors; redirection travels in
the environment, and a shell must pass on its own as Unix passes fds.

**Fix.** `sh` keeps the redirections it was started with and gives them
to its programs unless a command has its own; outputs as `>>` (the file
is already the shell's). The agent creates the output file first and
appends to it, so `sh` and its programs share it in order.

**Also.** With prompt caching on, Claude's `usage.input_tokens` counts only
the uncached part: the first report said "10 tokens in". llmd now adds
the cache's reads and writes, so `input_tokens` is the whole prompt.

**Lesson.** An agent is a harsh user of the system: it runs commands in
contexts no person does (output to a file, no keyboard), and a quiet
inconsistency (a shell that forgets its own redirections) shows up at
once as a model repeating itself. The recorder made the rest visible: the
second run's file shows the agent, llmd, netd, fatfs, ata and fetch, each
call nested in the one that caused it.

## 2026-11-17 — The console: glyphs, fake shifts, and a semaphore ahead of its queue

**What was asked.** Lines scrolled off the screen, accented letters, and
copy and paste with the host (`doc/decisions/console.md`).

**Glyphs.** VGA text mode draws code page 437: à è é ì ò ù are there, À
È Ì Ò Ù and € are not. Rather than a font of our own, the kernel redraws
six glyphs MyNOS has no use for (₧ ƒ ⌐ ⌠ ⌡ ∙) at boot, through plane 2:
each capital is the font's own letter one row lower, with two rows of
accent above; € is drawn. The tests read the screen back from VGA's
memory through QEMU's monitor (`xp`) and look for the code page's bytes.

**Fake shifts.** Shift + Page Up did nothing. With Shift held, a keyboard
sends grey keys wrapped in "fake shifts" (`E0 AA` before, `E0 2A` after)
so that old software sees an unshifted key; `consoled` took `E0 AA` for
the release of Shift. They are now ignored. QEMU's `altgr` key, for its
part, arrived as a plain Alt: Ctrl + Alt is AltGr too, as on Windows,
which also serves keyboards without the key.

**An extra byte.** The scrollback then opened and closed at once:
`consoled` wrote its 5-byte sequences with a length of 6, and the
trailing NUL counted as output, which returns the view to the live
screen. The lengths are right now, and the terminal ignores NUL.

**A semaphore ahead of its queue.** Typing on the serial port (as a host
terminal does), the shell ran the command and then exited, again and
again. Each piece of input V's `available`; a reader P's once and takes
the whole queue. A burst (a paste, a terminal sending a line at once)
left `available` ahead by the number of bytes taken together, and the
next reads woke to an empty queue: 0 bytes, an end of file. The keyboard
rarely showed it, one key per interrupt. A wake-up to an empty queue
without an end of file now waits again; the test pastes two lines and
checks that the same shell goes on.

**Lesson.** Count-based semaphores and "take everything" readers do not
mix: either one V per read, or a reader that tolerates being woken for
nothing. A second input device made a latent race ordinary.

## 2026-11-17 — A serial port that is not there

**Symptom.** Right after the console work, the owner found MyNOS unusable
in QEMU's window: the shell took some 25 seconds to come, `ls` took
seconds, and the shell kept restarting. Every test passed, and in the
tests the shell came within a second.

**Diagnosis.** The tests always give QEMU two serial ports (COM2 is their
log); QEMU with its window, as `tools/run-demo.sh` starts it, has COM1
only. Booted that way, the shell did not answer a typed `ls` within 6
seconds.

**Cause.** `consoled` emptied COM2 at start with `while (LSR & 1)
read()`. A port that does not exist reads 0xFF, whose bit 0 says "a byte
is waiting": the loop never ended. `consoled` spun on port I/O (each
access a trip out of the virtual machine), slowing everything; it never
registered the console, so the shell, unable to read, ended and was
started again by init, over and over.

**Fix.** `consoled` uses COM2 only if it is there (LSR is not 0xFF, and the
UART's scratch register keeps what is written to it), and every loop on
the port is bounded. A new test boots without COM2 and reads the
shell's answer from the screen through QEMU's monitor.

**Lesson.** The tests ran a configuration the owner never uses. The
default way of running the system (`tools/run-demo.sh`, a window) needs
its own test, especially when a change touches hardware that may be
absent. And a loop that waits on a device's status must have a bound.

## 2026-11-17 — A graphical session that leaves the text console intact

**Goal.** Windows, owned by separate processes, on QEMU's VGA, and a way
back to the text console (`doc/decisions/gui.md`).

**Shared video memory.** The first return to text mode showed coloured
stripes. Two causes. QEMU's Bochs extension (BGA), when enabled, sets
VGA's registers for graphics and does not restore them when disabled
(a BIOS would set mode 3 again): `displayd` now saves the sequencer,
CRTC, graphics and attribute registers before and writes them back after.
And the frame buffer is the same memory as VGA's planes: drawing from its
start would erase the text screen and the font (plane 2). The picture
starts 256 KB in (BGA's Y offset) and the card is enabled with "keep the
memory": the console returns as it was, font included.

**Mouse bytes out of step.** In the tests, the pointer went to the wrong
place. The PS/2 mouse answers its setup commands with 0xFA, whose bit 3,
set, is the mark of a packet's first byte: the driver took it as one, and
read every later packet one byte off. 0xFA is skipped outside a packet.
QEMU's monitor, for its part, can only move the mouse relatively, which
vmmouse in absolute mode ignores: the tests turn vmport off.

**A window drawn with the wrong focus.** The graphical test found both
windows' title bars blue: `set_focus` redrew the window losing the focus
before changing `focus`, so it was redrawn as focused. In the first
manual try a later redraw had hidden it.

**31-bit time.** The clock showed "-5:-28:-19": on i386, OCaml's `int` has
31 bits, and seconds since 1970 (1.79e9) overflow it. The time of day is
now `Float.rem now 86400.`.

**Lesson.** Hardware shared between two modes (text and graphics) needs
its state saved by whoever changes it, as a BIOS would; and a graphical
test that checks a few pixels' colours catches what a person's eye
forgives.

## 2026-11-18 — Scrolling, and a wheel that turned the other way

**The question.** Windows must scroll, a terminal first; and whether to
write it or adopt microui. The answer and its reasons are in
`doc/decisions/gui.md` ("Scrolling"): our toolkit, microui's design.

**A test that scrolled nothing.** The first try turned the wheel through
QEMU's monitor (`mouse_move 0 0 -4`) and the terminal did not move. A
trace in displayd showed the packets arriving with the wheel's byte at
+1: QEMU's monitor maps a negative `dz` to the wheel *down*, and a view
at the bottom cannot go lower. With `dz` positive, three notches moved
the view nine lines up, and the scrollbar's thumb with it. Each command
sends one notch, whatever its size.

**The PS/2 wheel.** A PS/2 mouse reports a wheel only once switched to
IntelliMouse mode: sample rates 200, 100 and 80 in a row, then its ID is
3 and its packets have four bytes. Each command's acknowledgement (and
the ID) is now read as it comes, before the mouse's IRQ is on.

**Lesson.** Before deciding that a feature does not work, look at what
reaches it: one line of logging in the server told the sign convention
apart from a bug.

## 2026-11-18 — The third boot: a page given twice

**Symptom.** The owner: `shutdown -r` in a terminal window restarted into a
kernel panic, "lmemtrack.c: Block not found". Reproduced without the GUI:
boot, `shutdown -r`, `shutdown -r` again: the third boot panics, always,
right after "RAMDISK found", preceded by "kernel heap: free list corrupted".
A cold boot with the same disk is fine.

**Diagnosis, step by step.**
- The kernel did not zero its BSS (`start.asm`): after a reset its
  variables would start with the previous run's values. A real bug, fixed
  (`rep stosb` from `__bss_start` to `_end` at entry), but the panic stayed.
- The `.data` section is reloaded at each reset (a variable that starts at
  1 and is set to 0 at the end of boot read 1 each time), and the modules
  are the same (checksums, taken once their memory was mapped: a first try
  read them before, faulted before the IDT existed, and the machine reset
  in a loop with nothing on the log).
- `HEAP_CHECK` (poisoned blocks) changed nothing: no use of uninitialized
  heap memory. Zeroing every fresh frame changed nothing either.
- A sentinel walking the heap's free lists after each boot step, then
  after each step of `createProcess`: the heap broke when the first
  process's page directory was zeroed. The broken block was all zeros: the
  page directory's frame *was* a page of the kernel heap.
- So the physical page bitmap was wrong. `pmem_createPhyMemManager` set
  `initialized = 1` first, then called `kmalloc` for its bitmap and its
  array of reference counts. Those allocations took pages, and `pmem_set`,
  seeing the manager initialized, used `pmemdes.page[page].countref`
  before the array existed: a null pointer (a stale one, before the BSS
  was zeroed), so a count read in the first pages of memory. A cold start
  has zeros there; after resets, the BIOS leaves its own values. A count
  found not 0 was only incremented, the page was not marked in the
  bitmap, and it was given again.

**Fix.** The manager is marked ready at the end, once its arrays exist and
hold the counts; the pages taken meanwhile go through the bitmap alone,
which is then copied with them. Kept from the hunt: the BSS zeroed at
entry, and fresh frames zeroed (nothing of a previous owner leaks). A test
restarts three times.

**Lesson.** "Works at the first boot" proves little for code that reads
memory it did not write: QEMU's cold memory is all zeros, and a zero is
the value that hides most of these bugs. A reset is a cheap way to give
such reads something else to find.

## 2026-11-18 — Retiring the legacy toolchain

**The question.** The owner asked whether the legacy build (Debian lenny,
gcc 4.3, dietlibc 0.31, OCaml 3.06 in `mynos-byterun/`) was worth keeping.

**What it had been for.** In the first days of the revival it was the
reference: the system had to run as in 2008 before anything changed, and
comparing the two toolchains surfaced real bugs (a stack slot gcc 4.3
happened to fill correctly, the libc's differences in `off_t` and
`mmap`). But those bugs showed up in the new toolchain; the old one
was the baseline, not the detector.

**What it had become.** It built only the C half (kernel, libmynos, the
2004 services, `abi` and `stress`): everything since (init, sh, storage,
network, models, GUI) needs OCaml 5. It passed every verification of the
last weeks, and found nothing dev had not. Its cost: about half an hour
per kernel or library change (clean, build, test, clean, rebuild dev),
code kept compilable with gcc 4.3 and dietlibc, and a tree in the legacy
configuration meanwhile, which once left the owner's demo without a shell.

**Decision.** Retired, history kept: `legacy-2008` is the original code,
`revival-baseline` the original running again, `legacy-last` the last
commit the period toolchain builds. The runtime, the container, the
dietlibc branches and the 2008 demo are gone; the scripts take no
toolchain argument.

**Lesson.** A second toolchain is worth its cost while it is the
reference something is measured against; once the system has moved where
it cannot follow, it checks less and less at the same price. A tag keeps
what it showed.

## 2026-11-18 — The agent window: one loop, two faces

**Design.** The agent's loop lived in `agent/agent_main.ml`, mixed with
its printing and its y/n/a prompt. A window needs the same loop with a
different face, so the loop moved into the library (`Agent`): it emits
events (`Task`, `Said`, `Action`, `Result`, `Note`) and asks a function
for confirmations (`Yes`, `No`, `All`). The command became forty lines
of printing and key reading, and its output did not change (the tests
that check it passed untouched).

**Two domains.** A model call takes seconds and the window must keep
drawing, so the agent runs in a domain of its own: it appends to the log
under a mutex, and for a confirmation it publishes the question and
waits on a condition; the window's domain draws the question, and a
button sets the answer and signals. Nothing the agent's domain does
touches the display.

**Where the buttons go.** First drawn inside the conversation, under the
action: their place then depends on everything said before, which a
test cannot click without reading the screen, and the field for the
next task stayed live beside them. They took the field's place instead:
same spot every time, no task typed while one is waiting, no click on
the field that lands on Allow.

**Lesson.** An interface that asks the user something is easier to put
behind two faces when the asking is a function the face supplies, not a
read from stdin inside the loop.

## 2026-11-18 — The System window: the architecture as data

**The idea** (the owner's). A window where MyNOS's architecture is seen
as it is now: the microkernel at the bottom, the services above, the
boxes coming and going, a recording replayed as arrows of who talked to
whom; and an agent that adds a service, whose box appears.

**What was missing.** The kernel could tell about one pid (`processInfo`)
but not list them; the registry could look a name up but not list its
names; an agent could not leave a program running (its tools wait for the
end, and a service never ends). Added: native call 33 (the processes,
with names, parents, privileges, threads), the registry's LIST, `&` in
`sh`. With those, the picture is a function of the system's state.

**Layers from facts.** No list of "which program is a service" was
written: a driver is what has the io privilege (and was started by a
process: the boot modules have it too); a service is what registered a
name, or what the kernel or init started; a program is the rest. The
two exceptions (boot modules, sh started by init) are rules, not names.

**Arrows through the kernel.** A call could be drawn from client to
server directly; it is drawn down into a lane of the kernel and up
again, because that is what happens in a microkernel, and the point of
the window is to show it. The drivers' wires to the hardware go beside
the kernel, for the same reason the other way.

**Lesson.** A system that can describe itself (its processes, its
names, its protocols, its messages) gets its documentation drawn for
free, and kept true.

## 2026-11-18 — kill: ending a process from outside it

**The problem.** `killProcess` ended the *current* process: it runs on
that process's kernel stack and page directory, and takes the page
directory to free from `currThread`. Ending another process looked like
it needed the target to run first (a pending flag, checked on the way
back to user mode, and every blocked call taught to wake up for it).

**What made it simple.** On one processor, a process that is not the
current one is not running: each of its threads is in some queue, the
ready queue, a semaphore's, the timers'. That is exactly the state of the
*other* threads of a process whose thread calls `exit`, and
`killProcess` already handles them: it takes each thread out of its
queue, frees ports, channels, semaphores, futexes, IRQ lines, and leaves
the memory to `reapZombies`, which runs from another process anyway. So
the body became `endProcess(p, status, pgdir)`, with the page directory
passed in (the target's first thread's); `killProcess` and `kill` call it.

**The rule.** Not init (its end is the machine's), not the idle process,
and not a process with a privilege the caller lacks: a program cannot end
a driver. One user, so otherwise anything goes, as Unix lets a user kill
their own processes.

**Lesson.** Before adding a mechanism (pending kills, interrupted
waits), look for the state the system already handles that the new case
reduces to.

## 2026-11-18 — A terminal closed with its box left its sh behind

**Symptom** (the owner). Leaving a terminal window with Ctrl-D kept the
number of processes steady; closing it with its close box made it grow
every time.

**Diagnosis.** Ctrl-D ends sh, and the terminal, seeing its child gone,
closes: both end. The close box ends the terminal only. Its sh stayed,
reading from a console service that no longer existed: libmynos turned
the failed call into an error (EIO), not an end of file, so sh (and any
program reading) did not know it had to end.

**Fix.** As Unix does on a hang-up: a read from a console that has gone
returns the end of the input; and the terminal, closed while its sh
runs, ends sh and every process under it (now that `kill` exists).
Services an agent started have left the tree (their parent ended) and
stay.

**Lesson.** A process's end has to reach what depended on it: here, the
far end of a console. "Nobody answers" is an end of file, not an error to
retry.

## 2026-11-18 — The tests in parallel, and the result that erased the others

**Change.** The test run had grown to 10-11 minutes: a dozen QEMU boots,
one after the other. They share almost nothing, so they now run in five
lanes at once (16 cores). Two things were shared: the fake model's port
(47090, used by the network boot, the graphical session and the seventh
boot: the session got 47091) and the main log (each lane writes its own
part; they are joined before the checks).

**Bug.** A lane is a subshell: the results its boots set (`gui_ok=yes`,
`fat_checks`...) die with it. Each lane wrote them to a file, read back
after all ended. The first parallel run failed checks in three lanes
whose boots had passed: every lane wrote *every* result variable,
including the empty ones of other lanes, and reading the files one after
another, an empty value from a later lane erased a good one from an
earlier lane.

**Fix.** A lane saves only what it found (non-empty values).

**Lesson.** When separate workers report into one place, each must
report only what it knows: "I did not see it" is not "it is not so".

## 2026-11-18 — Ctrl-C without signals, and the Ctrl-C that ended the GUI

**Asked** (the owner). A graphical program started from the text console
did nothing and could not be stopped.

**Two causes.** displayd made the window although the graphical session
was off: never shown, its program waited for events forever. And MyNOS
had no Ctrl-C at all: no signals, and the console did not know which
program was "in front".

**Design.** As Unix's terminal driver: sh names its foreground program
to the console (only a child of the caller is accepted), and the console
kills it on Ctrl-C when interrupts are on (termios ISIG). displayd now
refuses windows outside the session, and `Gui.run` explains.

**Bug found by the test.** The first full run lost the whole graphical
session at the Ctrl-C typed in a Terminal window: consoled killed `gui`.
In the graphical session every key goes through consoled first (displayd
reads it in raw mode), and displayd had left ISIG on, so the Ctrl-C meant
for the window was an interrupt for the text console's foreground
program, which is `gui`. displayd now clears ISIG, as an editor does.

**Lesson.** A key passes through every layer that reads it; each one in
raw mode must say whether it wants the key itself or its meaning.

## 2026-11-18 — Two readers of /disk: where the time went

**Symptom** (the owner). Two `cat` of the same file on /disk at once did
not scale.

**Measured** with the event recorder, not guessed: a `cat` of 400 KB on
`system/disk.img` made 25 READ requests of 16 KB to fatfs, 15-20 ms each;
each READ was 32 requests to the ata driver, one per 512-byte sector,
about 0.31 ms each (`mkfs.fat` had chosen one-sector clusters for a
64 MB FAT32). Most of the time was spent passing messages, not reading
the disk. Nothing was cached: a second reader read everything again, and
every command started from sh looked up `/disk/bin` (first in PATH)
through the same two directory sectors. fatfs walked the file's cluster
chain from the start at every READ. fatfs and ata serve one request at a
time, so two readers simply took turns.

**Fix.** In fatfs: missing sectors are read in runs, one request for
consecutive ones (a contiguous file: one request per READ); a cache of
4096 sectors, oldest first, written through; the chain kept in the open
file while the FAT's version does not change. A READ is now 2.85 ms, or
0.64 ms from the cache. The disk image's format was left alone: with runs,
the cluster size no longer matters for contiguous files.

**Tests had to change**: two of them read a file they had just written,
which now comes from the cache and never reaches ata. They read files of
the disk image that the boot had not touched.

**Lesson.** The recorder answered in one run what reading the code would
have taken longer to find, and showed the cost was in the messages, not
the device. A microkernel makes many small requests expensive: batch them.

## 2026-11-18 — A killed service left a port that swallowed its clients

**Symptom.** With init restarting services, `kill fatfs` brought a new
fatfs up on a new port; the next command in sh, even `echo`, never
returned (sh writes its history to /disk first).

**Diagnosis.** sh's libmynos still had the old port. Connecting to it
should have failed, and the client then looked the service up again. It
did not fail: the old port was still there. The kernel's `connect` queues
the request and waits for the owner to `listen`; nobody would ever listen.

**Two causes.** `kill` ends another process with the code that ends the
current one (`endProcess`, generalised earlier today); it freed the dead
process's ports with `freePort`, which checks that the *caller* owns the
port: the caller was sh, the answer was "denied", and the ports stayed.
Fixed by having the kernel act as the dying process while it frees its
ports and channels (system calls run with interrupts off). Then the port
still stayed: fatfs died *listening*, and a listened port is locked,
which `freePort` refuses too. A new `__OS_port_freeDead` frees it
regardless, and wakes whoever is queued to connect with
`MYNOS_ERR_BROKEN` (the "TODO free the req queue" of 2002).

**Lesson.** Code written for "the current process" carries that
assumption in every check it calls; generalising it to "a process" means
following each callee. A test that kills a service and then uses it
found what a test that only killed it did not.

## 2026-11-18 — The file services move to typed IPC

**Why.** The last big C-struct protocol was the files': a fixed 84-byte
request with the client's pid written in it, an 8-byte reply, data in a
second message, a directory read one entry per request. Programs could
not use it typed, the agent could not call it, recordings needed special
decoding.

**How.** One protocol, fs/1, defined once in OCaml (`Fs`) and mirrored in
C by `mynos_wire.h`: the three services and libmynos changed together.
The services kept their logic: tmpfs and fatfs got a typed handler around
the same functions (fatfs's took the old request as an array, which the
handler builds), memrofs kept its 2002 structures. The client's identity
now comes from the kernel (`channelPeer`) instead of the request.

**One surprise**: the first edit of libmynos replaced the *prototype* of
`open` (declared early for the redirections) instead of its definition,
leaving the old one in place; a search for the old struct names, before
building, showed two definitions. An edit by "first occurrence" needs the
definition's own text as its anchor, and a look afterwards.

**And the build.** The first full run failed two tests that seemed
unrelated: the shell history was no longer saved on /disk, and the kernel
stress test failed to start its clients, though it passed when run alone.
Both programs are C, linked with libmynos, and their Makefiles did not
depend on `libmynos.a`: consoled and the stress test were not linked
again, kept the old struct protocol, and were refused by the new
services. (Run alone, the stress test had been rebuilt by hand.) Every C
program now depends on the library it links. Lesson: when a protocol
changes, the build must rebuild every speaker of it; a test that passes
alone and fails in the suite may be testing a different binary.

## 2026-11-18 — OCaml's threads, and a bytecode that asked for DLLs

**Done.** The systhreads and unix C stubs, built with musl from sources
the container now keeps, linked into `ocamlrun` with their primitives;
the compiler's own `threads.cma` and `unix.cma` link against them. The
first test passed whole: three threads under a Mutex, a Condition, an
Event, `Thread.delay`, and threads that keep running while another waits
in a MyNOS call.

**The one catch.** Linked the usual way, a threaded program's bytecode
lists `dllunixbyt` and `dllthreads` among the shared libraries to load at
start; MyNOS's runtime is static and loads none. `-noautolink` leaves
them out: the primitives are found in the runtime's own table.

**Why the waiting calls were already right.** The stubs that wait (IPC,
sleep, wait, semaphores) gave the runtime lock up since the domains came:
a domain waiting in a call while holding it would have stopped the
others' garbage collection. Threads of one domain needed the same; only
the console's two requests were missing.

**Lesson.** Work done for one feature (domains) often carries most of
the next (threads): reading what is already there first turned an
estimate of two or three days into an afternoon.

## 2026-11-18 — The registry and the console speak typed IPC

**Done.** The two protocols left from 2002, C structs with a pid written
inside, moved to typed IPC: registry/1 and console/1. Every MyNOS service
now speaks it, and describes itself.

**Two design points.** A terminal window keeps a read waiting until a key
comes, so its handler cannot return the reply: `Ipc.Make` now offers
`decode` (the request, or the reply to send at once: a description, an
error) and `reply`, and the terminal keeps the channel with the request.
And the registry could not describe itself, since it was not in its own
table: it now registers "registry" at start, and answers `describe` like
any other service.

**What the caller says vs. what the kernel says.** Both old protocols
carried the client's pid in the request (consoled used it for "who owns
the raw mode"). As for fs/1, the kernel now says who is calling
(`channelPeer`): a program can no longer claim to be another.

**Lesson.** The test that compares a C service's description with the
OCaml module's caught nothing this time, but it is what makes a protocol
written twice (C and OCaml) safe to change: a mismatch fails the suite.

## 2026-11-18 — Documenting the kernel found its bugs

**What happened.** The architecture appendices of the manual were
written with one rule: every statement checked in the code, not copied
from STATUS or from comments. Explaining how a context switch works
meant reading `switchTo` line by line, and it saves no floating-point
state at all (mynos-t6p). Explaining how the kernel reads a process's
pointers meant asking which calls check them: `_llseek` writes its
result anywhere (mynos-3po). Explaining copy-on-write meant asking what
happens when the kernel itself writes: CR0.WP was never set, so the
kernel's writes ignore read-only pages (mynos-bvz). About twenty
findings in all, filed as issues; and a dozen lines of STATUS and the
decision docs that had drifted from the code (pids "reused", messages
"copied up to 8 bytes, larger can be shared", tmpfs's old protocol).

**Why tests had not found them.** The tests exercise what programs do
when they behave. None of these bugs shows up unless a program misbehaves
(a bad pointer, a huge message, an `munmap` of the RAM disk) or two
threads use floats at the same moment, which the suite never arranges.

**Lesson.** Writing the explanation for someone else is a code review
with a different question: not "does it work?" but "what exactly does it
do?". Documentation written from the code, and not from memory, is worth
doing for that alone.

## 2026-11-18 — One FPU for every thread

**Symptom.** None seen: found while documenting the context switch
(appendix A). `switchTo` saved the integer registers only.

**Diagnosis.** Nothing in the kernel saved the floating-point state: no
`fsave` or `fxsave` anywhere, CR0.TS never set (so the lazy-switching
trap, `int 7`, which only did `clts`, never ran). Every thread of every
process shared the x87 stack, its control word, and the SSE registers.
A test (`tests/fpu`) shows it: two threads that keep values on the x87
stack and their own rounding mode while they spin find both changed by
the other, on the old kernel, every time.

**A second finding on the way.** On the old kernel the same test died at
its first SSE instruction: "invalid opcode". CR4.OSFXSR had never been
set, so SSE was off; programs ran only because nothing compiled for
MyNOS (gcc's i386 code, musl, OCaml's runtime) uses SSE.

**Fix.** Eager save and restore in `switchTo`, `FXSAVE`/`FXRSTOR` when
the processor has them (`FNSAVE`/`FRSTOR` otherwise; all three cases
tested with QEMU's CPU options), an area in each `tss_t`, a clean state
recorded at boot for new threads, the parent's state for a forked child,
SSE turned on, and the kernel compiled with `-mgeneral-regs-only` so that
it can never touch the registers it saves. Eager rather than lazy: a few
hundred cycles per switch, and no trap to get right.

**Lesson.** A bug that corrupts data only when two threads compute with
floats in the same 10 ms is invisible to a test suite of programs that
behave. Writing down how a mechanism works, from the code, is what made
the missing half visible.

## 2026-11-18 — CR0.WP, and a kernel that never asked to write

**Symptom.** Found by the appendices' review: with CR0.WP clear, ring 0
ignores the read-only bit. `tests/abi` showed it: a thread sends 8 KB, the
sender then calls `clock_gettime` with the buffer as its result, and the
receiver's message changes, because the kernel wrote into the frame both
mappings share.

**Turning WP on was the easy line.** The kernel then did not boot at all.
Since 2002 it had mapped its own memory with the present bit only:
`start.asm`'s identity map, its stack and page-table windows,
`createProcess`'s kernel stacks and process info pages, the window into
another process's memory (`| 0x1`), the copy-on-write window (flags 0),
`__OS_askPages` for kernel pages. With WP off, "read-only" meant nothing
in ring 0, so nobody had noticed. Each was found by booting under
`qemu -d int` (a fault with `cpl=0`, `e=0003`: present, write,
supervisor) and `addr2line` on its EIP, then by a log line the handler
now prints for any kernel write to a read-only page; the full suite runs
with none.

**Fix.** WP set in `mynos_main` before the first task switch; kernel
mappings writable by rule (`__OS_askPagesFrom` adds R/W to supervisor
pages) and at each place that writes entries by hand. The page fault
handler needed nothing: copy-on-write and allocation on use never looked
at who faulted.

**Lesson.** A protection the hardware does not enforce is a convention,
and conventions drift: twenty-four years of code had "read-only" kernel
pages that were written all the time.

## 2026-11-18 — A failure value that was a valid page number

**Symptom.** None in use; found by the appendices' review, then shown by
a test: a process fills its linear space with `mmap` (cheap: pages are
taken on first use), frees 64 MB, and sends a 128 MB message to itself.
The machine resets, again and again (79 boots in 40 seconds).

**Cause.** `__lmt_allocArea` returns 1 when there is no room ("1 cannot
be a user page"); `__OS_mapPagesTo` used it as the first page of the
mapping, and `__OS_ipc_send` checked only for negative values. The
message's pages were mapped from linear page 1: into page table 0, the
kernel's identity map, shared by every process, and past it.

**Fix.** One line: a page below `USERMINPAGE` is a failure, and the send
returns `MYNOS_ERR_FULL`.

**Lesson.** An error value inside the range of valid results is a trap
for every caller; here the caller checked for the convention of the rest
of the kernel (negative errors) and not for this function's own.

## 2026-11-18 — A placeholder that was a page table

**Symptom.** None in use. The appendices' review noticed that page
directory entry 255 pointed at physical page 0 with the user bit; a test
showed what it meant.

**Diagnosis.** In 2002 `init_memory` allocated page tables for the
kernel's gigabyte and "tagged" the last entry as allocated by pointing it
at address 0, to keep the kernel from using those 4 MB. A directory entry
is not a tag: the processor reads the page it points to as a page table.
Page 0 holds the BIOS's interrupt vectors and, at its very first word,
the EAX that the page fault handler saves there (it uses address 0 as
scratch). So a program could set EAX to `7` (frame 0, present, writable,
user), touch a fresh page (a fault the kernel resolves, and returns from),
and then read physical page 0 at `0x3FC00000`. Any other frame number
works the same way. `tests/abi` does it in a forked child: without the
fix the child reads and exits normally.

**Fix.** Entry 255 stays empty; `__OS_askPages` stops at entry 254 for
kernel pages, so it never needs a table there.

**Three more from the same review.** `munmap` of the RAM disk (after
CR0.WP, a kernel panic, since the shared page tables are read-only in
the kernel's window); a freed channel end that woke nobody: the check
used `getMyWriteChannel` after the end had been marked free, which then
returns NULL; and a connector that ended while queued, whose request
`listenPort` answered by writing into the dead thread's memory (the
listener was the one killed).

**Lesson.** Encoding "reserved" in a structure the hardware reads
gives the hardware a vote. Reserve in the software's own bookkeeping
instead.

## 2026-11-19 — stdio that went round libmynos

**Symptom.** Found by the appendices' review: a C program's `fopen`
opened the kernel's one built-in file whatever the path, `fgets(stdin)`
failed, and `printf` in a terminal window went to the hidden text screen.

**Cause.** libmynos replaces `open`, `read`, `write` at link time, but
musl's stdio does not call them: its internal `__stdio_read` uses
`readv` (not implemented), `__stdio_write` uses `writev`, and `fopen`
makes the raw `open` system call. The OCaml runtime and kilo use `read`
and `write`, so nothing in the system had noticed.

**Fix.** libmynos defines those five internal functions and `fopen`.
Two details: nothing names them in a program, so the linker would take
musl's (an archive member is extracted only for a symbol already
wanted): `mynos.mk` adds `-u` for each. And they work on musl's private
`struct _IO_FILE`, copied from musl 1.2.5's source: a later musl could
change it, and `tests/stdio` is what would say so. `__stdio_read` does
one `read` where musl does one `readv` into two buffers: two reads could
wait at the console for a second line.

**Lesson.** "We replace the C library's file functions" was true of the
functions a program calls, not of the ones the C library calls itself.

## 2026-11-19 — A rename that emptied the file, found by the user's guide

**Symptom.** Writing chapter 7, `mv README.TXT readme.txt` on `/disk`
left no file at all.

**Diagnosis.** Two pieces, each reasonable alone. fatfs refuses a new
name that already exists, comparing without case, as FAT does: so a
rename that changes only the case failed with `exists`. And `sh`'s `mv`,
when a rename fails, falls back to copy-and-remove, meant for moves
between two services (`/tmp` to `/disk`). Here the copy's destination was
the source itself: opening it for writing emptied it, and the remove
then deleted it.

**Fix.** fatfs ignores the entry being renamed when it checks for a
duplicate, and finds the old entry again by its slot, not by its name;
`mv` copies only when the rename fails with `EXDEV` (another service),
and reports any other error. Tests: `tests/fat` and the seventh boot.

**Also from the manual's runs.** A C program's redirected stdout kept
only its first line: libmynos closed the redirected file in an `atexit`
handler, which runs before the C library flushes stdio; it now flushes
first. The bug was new: until the day before, stdio did not reach
libmynos at all.

**Lesson.** A fallback that destroys (copy then remove) must be taken
only for the one error it was written for.

## 2026-11-19 — A read served to a dead program

**Symptom.** Found writing chapter 6: after Ctrl-C on a program waiting
for a line (the toplevel at its prompt, `edit`), the next line typed
vanished, and `sh`'s prompt came back only after it.

**Cause.** consoled serves one request at a time, and a read waits in
it until input comes. Ctrl-C killed the program, but consoled was still
inside that program's read: the next line went to it, and the reply to
a dead process was lost.

**Fix.** consoled remembers whose read it is serving; Ctrl-C, after the
kill, wakes the waiting read, which gives up when its reader is no
longer alive. The line typed next goes to the next reader, `sh`. A test
in the seventh boot: Ctrl-C on a program waiting for a line, then a
command, which must run.

**Also from the same review.** Two small ones with a common shape: a
timer that restarted at every event (a window's ticks stopped while the
mouse moved: the wait is now until the tick is due), and a check done
again from the start at every piece (Http parsed the whole answer after
every packet: the body's end is now worked out once). And a missing
build dependency: the OCaml library's Makefile did not know that every module uses `Mynos`, so a change to
`mynos.mli` stopped the build with "inconsistent assumptions".

**Lesson.** A server that keeps a request waiting holds a promise to a
process; when the process goes, the promise must be dropped, or the next
caller pays for it.

## 2026-11-19 — Two bugs of 2002 that only GRUB could see

**Symptom.** The first ISO, made with GRUB 2, stopped at "Booting
'MyNOS'": the machine reset in a loop. The same kernel, with the same
modules, boots every day under QEMU's `-kernel`.

**First cause.** With `-no-reboot -d int`, a page fault in
`init_memory`, writing a page table that was not there; a gdb watchpoint
on the page directory showed `clear_page_table` writing it. The 2002
routine starts at the last byte of the first entry and clears one byte
every four: the high byte of each entry. Its low byte, with the present
bit, kept whatever was in memory. QEMU's loader gives zeroed memory, so
the directory came out clean anyway; GRUB leaves its own data there (the
page directory held GCC's version string), and some entries looked
present. Fixed: each entry cleared whole.

**Second cause.** Then a general protection fault at the first `iret`,
with CS 0x10. `start.asm` never loads a GDT: the kernel runs on the boot
loader's until `_init_gdt`, which loads MyNOS's with `lgdt` but did not
reload the segment registers. QEMU's loader uses 0x08 for code and 0x10
for data, the same numbers as MyNOS's GDT; GRUB 2 uses 0x10 and 0x18,
which in MyNOS's GDT are the kernel's data and the users' code. Fixed: a
far jump to 0x08, and the data registers loaded with 0x10.

**And a third, of the test itself.** With a FAT disk attached, the BIOS
booted the disk, not the CD, and stopped on "not a bootable disk":
`-boot d`.

**Lesson.** A program that has run in one environment only depends on it
in ways nobody wrote down. Both bugs needed only a second boot loader to
show.

## 2026-11-19 — A letter cut in two by a read

**Symptom.** The test of `edit` with accented letters passed, then failed
on the next run: "perché  così", the "è" gone.

**Cause.** The test types on the serial terminal, which delivers one byte
at a time; `edit` reads what the console has. A read can end after the
first byte of "è" (0xC3), and the next one bring the second (0xA8).
Notty's decoder takes a lone first byte, and a lone continuation, as
malformed input, and drops them. From the keyboard an accented letter
arrives whole, in one piece of input, so it had always worked; from the
serial terminal it worked or not depending on the timing.

**Fix.** The MyNOS backend of Notty keeps the start of a character cut
by a read and puts it before the next read's bytes; a read that brings
only such a start reads on (an empty input would be the end, to Notty).

**Lesson.** A stream has no boundaries but its own: whatever is decoded
from it must survive being cut anywhere. A test that passed once was a
test that had not yet been cut in the wrong place.

## 2026-11-19 — MyNOS in the browser, on v86

**Symptom.** None: the question was whether the release could run in a
web page, for people who will not install QEMU.

**Diagnosis.** v86 (0.5.473, with SeaBIOS) booted the release's ISO and
clean disk unchanged: GRUB, the banner in 1.3 s and the prompt in 3.4 s
under Node; in Chrome the graphical session, the absolute mouse (v86
emulates VMware's, which displayd already knew), the Tour and its replay.
v86 emulates an NE2000 too, so netd starts, finds no DHCP and falls back
to its fixed address: the network is the one thing missing.

**Cause of the one difficulty.** The first page loaded both images whole,
96 MB, mostly an empty disk. v86 can load an image on demand, either by
HTTP Range requests or in fixed-size parts; a GitHub Pages page answered
a Range request with the whole file, so parts it is.

**Fix.** `tools/make-web.sh` cuts each image in 1 MB parts compressed
with zstd, named as v86 asks for them; v86 decompresses them itself. The
site is about 10 MB; the disk's zero parts are a few dozen bytes each,
and only two of them are read at boot. Writes stay in v86's memory.

**Lesson.** An emulator that implements real hardware well needs no port:
the ISO built for QEMU ran as it was, and so did every driver.

## 2026-11-20 — What of OCaml's distribution runs, measured

**Symptom.** None at first: the question was which OCaml programs could
run on MyNOS. Reading the runtime's primitive list says what links, not
what works, so a probe called about 80 functions inside MyNOS (on a
fresh disk, with tmpfs and fatfs). Three results were wrong without
failing: `Sys.time ()` was 9.2e18, `Unix.getuid ()` was -38, and opening
an existing file with `O_CREAT | O_EXCL` succeeded.

**Diagnosis and causes.**
- `Sys.time` calls `getrusage`, and OCaml does not check its result. The
  kernel answered `-ENOSYS`, and the structure stayed as the stack had
  it. `times`, the fallback, was no better: a counter that grew by 10 at
  each call. The kernel kept no CPU time at all.
- `getuid` cannot fail on Linux, so musl returns the system call's
  result as it is: `-ENOSYS` became uid -38.
- fs/1 had no flag for `O_EXCL`: `libmynos` dropped it, and the services
  opened the existing file. `Filename.temp_file` relies on it, so two
  programs could get the same temporary file.

**Fix.**
- Each process descriptor counts the timer ticks that find it running
  (`cpuTicks`, in `pit_handler`). `getrusage`, `times` and the
  CPU-time clocks report it.
- The uid and gid calls answer 0.
- fs/1 has `o_excl`, and tmpfs and fatfs fail with `exists`.
- `Str` and `Num` were added to the runtime. `Str`'s stub is part of
  the distribution, kept by the container in a layer of its own. `Num`
  is vendored, compiled with its portable C digits.
- `tests/libs` checks all of these.

**Lesson.** A missing system call that returns an error is honest. The
dangerous ones are the calls whose callers cannot imagine them failing,
`getrusage` and `getuid`: their error becomes a value. When adding a
Linux layer, list the calls that "never fail" first.

## 2026-11-20 — OCaml's Graphics, without C

**Symptom.** None: programs written for OCaml's `Graphics` (games,
teaching examples, 2048-ml, the debugger of a Z-machine interpreter) did
not link on MyNOS. The library's C part speaks X11 or Win32, neither of
which MyNOS has.

**Diagnosis.** `Graphics` needs little that `Display` and `Gfx` lack: a
window, filled rectangles, lines, text, pixels read back, events. So it
was written again in OCaml, with the same interface, and programs compile
unchanged against `graphics.cma`. Two things did not map at once:
- **When to show the drawing.** X11 queues drawing commands and flushes
  them cheaply. On MyNOS each `damage` is an IPC round trip, so a program
  that plots a pixel at a time would make one per pixel.
- **Reading the keys without waiting.** `next_event`'s smallest timeout
  is not small: displayd checks timeouts every 100 ms. A game loop that
  calls `key_pressed` every frame would run at 10 frames a second.

**Fix.**
- Everything is drawn into a buffer of the program's own (X11's backing
  store). The rectangle of the changes is copied and damaged in one
  request: at most every 20 ms while drawing, at every read of the
  input, and at `synchronize`.
- `next_event` with a negative timeout answers at once, with a tick if
  nothing is queued. `Display.poll` wraps it.

The test draws every kind of shape and reads the pixels back with
`point_color`. 2048-ml compiled unchanged and played inside MyNOS. So did
a Graphics program compiled by `ocamlc` inside MyNOS.

**Lesson.** A protocol that only knows "wait at most T" has no zero: the
service's timer decides how long zero is. A poll is a different request,
even when it looks like a small timeout.

## 2026-11-20 — The agent could not link Graphics

**Symptom.** Asked for a test program, the agent inside MyNOS wrote a
fractal tree in the wind with `Graphics`. Its `build_ocaml` tool failed:
"No implementation provided" for `Graphics`. The agent then ran `ocamlc`
itself through `sh`, adding `graphics.cma`, and the program worked. It
said so in its answer.

**Cause.** The three places that compile inside MyNOS linked
`mynos.cma` only: the toplevel's `compile`, and the agent's `run_ocaml`
and `build_ocaml`. `graphics.cma` was on the RAM disk, but nothing asked
for it.

**Fix.** Linking every library always was not possible: `unix.cma`,
`threads.cma` and `str.cma` are "force link", so every program would
carry them, and start the threads library. Instead
`Agent.ocamlc_libraries` reads the source and adds each library whose
modules it names (`Unix`, `Thread`, `Str`, `Num`, `Graphics`). A
comment naming one costs only a larger program. The tools' descriptions
now list those modules.

**Lesson.** A library installed is not a library available: the paths
that build programs must know of it too. The agent found the gap and
worked around it, and its report is how we learned of it.

## 2026-11-20 — Two modules named Gui

**Symptom.** 2048-ml, built by a Makefile from `third_party/2048-ml` with
`-I src`, failed: "The implementation src/gui.ml does not match the
interface", and the interface it quoted was MyNOS's `Gui`, from
`mynos-lib/ocaml`. Built from inside `src`, the same files compiled.

**Cause.** The game has a module `Gui` of its own, and so has
`mynos.cma`. To check `gui.ml`, `ocamlc` looks for `gui.cmi` on its load
path: the current directory first, then the `-I` directories in the
order given. With `-I src` after `-I mynos-lib/ocaml`, the library's
`gui.cmi` was found first. Linking is no problem: a module of a `.cma` is
linked only if something uses it, and `graphics.cma` does not use
MyNOS's `Gui`.

**Fix.** The Makefile compiles inside `src`, as the earlier manual build
did.

**Lesson.** OCaml's modules share one flat namespace per program. A
library's common names (`Gui`, `Json`, `Http`) can collide with a
program's own; the current directory wins, then the first `-I`.

## 2026-11-20 — Packages, and what a bytecode program depends on

**Context.** New demos should reach MyNOS without a new RAM disk: a small
package manager, `pkg`, with an index and archives in a repository of
their own (`doc/decisions/packages.md`).

**The question.** When can a `.byte` built on the host today run on a
MyNOS built later? It depends on three things: the bytecode's format
(the magic number at its end, which changes with OCaml), the primitives
it calls (the `PRIM` section lists them by name, and the runtime looks
each up by name when it loads the program: new primitives break
nothing, a missing one stops it) and the copy of `mynos.cma` linked into
it, which speaks the services' protocols (versioned by name). The
MyNOS version string says none of this: it changes at every commit.

**Decision.** `pkg` reads the program's trailer (the section table at
its end: name, length, then the count and the magic number) and checks
the first two directly; the third is the protocols' names. When the
check fails the package's sources are compiled by the `ocamlc` of the
RAM disk, so every package carries them.

**Lesson.** Ask the artefact, not its label: the bytecode file says what
it needs, a version number only says when it was made.

## 2026-11-20 — A window that read too often

**Symptom.** In the Packages window, Remove failed on `windtree`:
"pkg: /disk/pkg/windtree/installed: Permission denied". The same
`pkg remove` from `sh` worked, in the tests and by hand.

**Diagnosis.** `fatfs` answers `denied` to a `Remove` of a file that is
open (`is_open`, a FAT file has no link count to outlive its name). The
window drew its list and the chosen package at every frame, four times a
second and at every event, and each drawing opened and read
`/disk/pkg/NAME/installed` for every package. `pkg`, a process of its
own, removed the same files meanwhile: now and then it met one the
window had open.

**Fix.** The window reads the installed packages once at the start and
once at the end of each job of `pkg`, into its state; it draws from that.
While `pkg` works, the window touches only `pkg`'s output in `/tmp`.

**Lesson.** An immediate-mode window redraws often, so whatever it reads
while drawing it reads all the time. On a file system where an open file
cannot be removed, polling a file is holding it: read the state when it
changes, not when you draw it.

## 2026-11-21 — A listener that outlived its network

**Symptom.** Found reading the code for appendix E, not seen: if `netd`
ended and `init` started it again, `httpd` would log `accept: ...` in a
loop for ever and never serve again.

**Cause.** `httpd`'s socket was `netd`'s: a number in the old process's
table. The new `netd` knew nothing of it, so every `Accept` failed at
once, and `httpd` simply tried again.

**Fix.** Three failures in a row mean the socket is gone: `httpd` connects
to the network service again and listens anew; each connection now
travels to the workers with the service it came from.

**Lesson.** A handle given by a service lives as long as that service,
not as long as its name. A client of a service that `init` can restart
must be ready to find its handles void, and to start again from the
name.

## 2026-11-21 — Connecting has no Set_timeout

**Symptom.** `Http`'s `~timeout` bounds each wait for the server, but a
`fetch` to an address that does not answer took about 27 s and ended with
"connection aborted"; a TLS server that accepts and then says nothing
could hold a `fetch`, `pkg`, or the agent, for ever.

**Cause.** `Set_timeout` applies to a socket's `Recv` and `Accept`; there
is no socket before `Connect` answers. lwIP gives up on an unanswered SYN
by itself, after its retries; the TLS handshake had no bound at all.

**Fix.** `netd` gives `Connect` and `Connect_tls` a deadline of 20 s,
DNS and handshake included, and answers "timeout". A name still being
resolved at the deadline keeps its socket until DNS answers, so that the
callback never lands in a socket that was handed out again.

**Lesson.** A timeout on "each wait" leaves out the waits that happen
before there is anything to set it on.


## 2026-11-21 — Ten commands weigh as much as one

**Symptom.** The package `utils`, ten small commands each its own
program, made an archive of 3.4 MB: each program about 330 KB, for a
few dozen lines of OCaml.

**Diagnosis.** A program that prints "hello" is 140 KB of bytecode;
one that uses `Printf` is 265 KB. Almost all of it is OCaml's standard
library, linked into each program: the runtime of OCaml 5 starts with
domains, effects and their friends, and `Printf` brings
`CamlinternalFormat`.

**Fix.** One program, `utils.byte`, holds the ten commands; `pkg`
installs each command as a script of one line, `#!/disk/bin/utils.byte`,
and `sh` learned to run such files (the program, then the script's path,
then its arguments; the program finds the command in the script's
name). The archive is 400 KB. The first try ran nothing: OCaml's
bytecode executables begin with a `#!` line of their own, naming the
host's `ocamlrun`, so a program is now looked at as bytecode before it
is looked at as a script.

**Lesson.** In a system where every program carries its own library,
the size of a program is the size of the library; share the program,
and let the names be cheap. And a file format can wear another's
first line.

## 2026-11-21 — A click that closed the file picker went through

**Symptom.** In `life`, a pattern chosen in the file picker with a
double click was placed at once where the picker had been, before the
user had clicked on the board.

**Cause.** The picker makes Gui's widgets ignore the pointer while it
is open, but the board is not a widget: the program reads `clicked` and
the pointer itself. The picker was drawn (and answered) first, closed,
and in the same frame the board saw the click that had closed it.

**Fix.** The board asks `Gui.hovered`, which knows about the picker, and
the picker is drawn last, after the board has read the pointer: in the
frame where it closes, it is still open for the board.

**Lesson.** A modal panel is modal only for those who ask whether it is
open. Code that reads the pointer itself must go through the same
question, and in the same order, as the widgets.

## 2026-11-21 — Three suits of diamonds

**Symptom.** The first `solitaire` dealt cards whose suits were all
diamonds.

**Cause.** The screen's font, Terminus, has the diamond (it is in the
VGA's code page) but not the spade, heart or club; `Gfx.text` draws a
missing character as its replacement, which happens to look like a
diamond.

**Fix.** The suits are drawn as small bitmaps of 9 by 9.

**Lesson.** A replacement glyph that is itself a plausible character
hides the miss; test the characters a program needs, not the string
that holds them.

## 2026-11-21 — Thirty-one bits for a thirty-two bit checksum

**Symptom.** The PNG reader of `view` did not compile in the dev
container: "Integer literal exceeds the range of representable integers
of type int", on CRC-32's polynomial, `0xEDB88320`.

**Cause.** MyNOS is a 32-bit system: OCaml's `int` has 31 bits there.
CRC-32 and Adler-32 need 32, as do BMP's signed sizes. `Int32` has them,
but each value is boxed: a CRC over a 1 MB picture allocated millions of
them, and saving a drawing took seconds.

**Fix.** CRC-32 kept as two halves of 16 bits (a table of pairs),
Adler-32 as its two sums, written byte by byte; `Int32` only where a
value is read once (BMP's header).

**Lesson.** Code that is right on the 64-bit host can be wrong on the
target, and a checksum is where it shows first; on MyNOS, any
arithmetic modulo 2^32 needs a plan.

## 2026-11-21 — Clicks lost behind a slow frame

**Symptom.** In the first `paint`, a test that clicked a tool, a colour
and then drew, quickly, got nothing from most of the clicks: the
strokes came out with the pencil, in black.

**Diagnosis.** Each frame copied the canvas into the window a pixel at a
time, in OCaml: some 400,000 pixels, a second or more in QEMU. Events
wait in `displayd`'s queue for the window, 64 at most, and when it is
full a new mouse event is dropped (a key pushes the oldest out). The
test's clicks came faster than the frames; most likely the queue
filled, and the presses and releases were the events that were lost.

**Fix.** The canvas is a `Gfx.t` of its own, drawn by the C primitives
and copied into the window by `Gfx.blit`; a shape being drawn is drawn
on the window only, inside a clip. `view` keeps the image scaled for the
window, and scales it again only when the image, the zoom or the place
change. Clicks are answered at once.

**Lesson.** In an immediate-mode toolkit, every frame pays for all that
is drawn; what does not change must be drawn once and copied. A slow
frame does not only look slow: what the user does meanwhile can be lost.

## 2026-11-21 — A Scheme from 2004 meets immutable strings

**Symptom.** OCS, a Scheme in OCaml of 2003-2004, did not compile with
OCaml 5: "strings are immutable, there is no assignment syntax for
them", in its ports and in `string-set!`.

**Cause.** OCaml's strings became immutable in 4.06 (2017); OCS keeps
Scheme's strings, which are mutable, as OCaml strings, and its ports'
buffers too. Its ports also read and write Unix file descriptors, with
`Unix.select` for `char-ready?`, which MyNOS's console does not have.

**Fix.** Scheme strings are `bytes` (`Sstring of bytes`), converted at
the few places where they meet OCaml's strings (printing, file names,
symbols, numbers); ports are written again on OCaml's channels, which
buffer by themselves. Thirty-odd lines changed outside the ports
(`third_party/ocs/mynos.patch`).

**Lesson.** The type a program chose for its data decides how far a
language change reaches into it: OCS put Scheme's mutable strings in
OCaml's string type, and the change of 2017 reached every primitive on
strings. Old OCaml code ports well once that one decision is redone.

## 2026-11-21 — Ten ticks a second, for everyone

**Symptom.** The Game Boy emulator, whose benchmark ran 357 frames a
second inside MyNOS under KVM, showed 9 in its window; emulating and
drawing a frame took under 10 ms.

**Diagnosis.** The window asked `Gui.run` for a tick every 1/60 s, and
got one about every 110 ms. `Display.next_event`'s timeout is kept by
`displayd`, whose timer thread woke every 100 ms to look at the
deadlines.

**Cause.** A period chosen for the clock in the bar (and for noticing
windows of dead programs) also bounded every window's ticks. Nobody saw
it: the first animations ticked at 0.1 s; `snake` and `blocks`, asking
for 0.02 and 0.03, quietly got 0.1.

**Fix.** The timer sleeps 10 ms (the kernel's resolution) for two
seconds after any window asks for a timeout under 100 ms, else 100 ms
as before. The Game Boy runs the frames due by the clock (a tick of
1/60 s comes every 20 ms at that resolution), drawing only the last:
60 frames a second.

**Lesson.** A timeout is only as fine as the clock that checks it; a
service that keeps deadlines for others must check them as often as
the shortest one asks, and an animation that seems slow should be
timed before its drawing is suspected.

## 2026-11-21 — Who may write to /disk

**Symptom.** Bringing a file from the host into MyNOS took two steps: a
web server started on the host, then `fetch -o` typed inside MyNOS, one
file at a time.

**Diagnosis.** `httpd` already reached MyNOS from the host's browser and
`curl`; what it lacked was writing. The question was not how (`PUT`, and
a form for the browser) but who: on QEMU's user network only the host
can reach port 80, on a real network with an NE2000 anyone could.

**Cause.** A server that writes is a door; the same program runs in QEMU
and on a PC, from the same RAM disk, so a flag in `init.rc` could not
tell them apart, and the kernel's command line does not reach programs.

**Fix.** The connection tells: on QEMU's user network MyNOS is 10.0.2.15,
the gateway 10.0.2.2, and the host's forwarded connections arrive from
10.0.2.2; writes are allowed to that peer, to anyone with `httpd -w`.
The browser is the other way in: a page of any site can post a form to
`localhost:8080`, so a write must name this server in `Host` (which a
name pointed at 127.0.0.1 does not) and in `Origin` when there is one.
A file arrives into a hidden name and replaces the old one only whole.
Timing it showed the next limit: 3 MB take 28 s, as long as `cp` of the
same file inside MyNOS (fatfs, mynos-ipg).

**Lesson.** Before deciding what a server may do, ask who can reach it;
here the network itself said it, at no cost. And a page in the user's
own browser is a client too.

## 2026-11-21 — Mario stops when he jumps

**Symptom.** In a Game Boy game, holding Right and pressing the jump key
made Mario jump and then stand still, Right still held.

**Diagnosis.** MyNOS's windows got keys, never their release; camlboy
counted a key as held for 0.15 s after each press, kept alive by the
keyboard's repeat. A PS/2 keyboard repeats only the last key pressed:
the jump stopped Right's repeat, and 0.15 s later camlboy let Right go.

**Cause.** The releases existed (each key's scan code with bit 7 set)
and consoled read them, but used them only for Shift, Ctrl and Alt: its
protocol had line editing and raw keys, and a raw key was text.

**Fix.** A mode bit, `CONSOLE_RELEASES`: in raw mode consoled follows a
key's release with a sequence in the form of kitty's keyboard protocol
(`ESC [ code ; 1:3 u`, the arrows' own finals), naming the text the
press sent (consoled remembers it by scan code; Shift may change
meanwhile). displayd asks for it, cuts its input into keys (a read could
carry several, given to a window as one) and sends `Key_up`; `Gui` keeps
the keys held, and forgets them with the focus. camlboy reads the held
keys. A terminal on the serial port sends no releases: its keys are
released at once, so nothing stays held for ever.

**Lesson.** A workaround built on a device's habit (the repeat) breaks
where the habit has an exception; the information was there one layer
down, thrown away by a protocol that had no word for it.

## 2026-11-21 — A sync for every sector

**Symptom.** Copying 3 MB inside MyNOS took 23 s, under KVM; reading
the same file took a quarter of a second.

**Diagnosis.** Measured step by step (a program timing writes and reads
inside MyNOS, and `Block` calls straight to `ata`). With QEMU told to
ignore flushes (`cache=unsafe`) the copy took a fifth of the time: the
drive's cache was flushed after every `Block.Write`, and QEMU turns each
flush into a sync of the image on the host. The disk has 512-byte
clusters and `fatfs` wrote one cluster per request, plus two FAT copies
and the directory entry: about 2300 syncs a megabyte. `fatfs` also
walked the file's whole chain at every write and appended new clusters
at the end of a list, one at a time.

**Cause.** Choices that were safe and small for the first files on the
disk (a flush per write, a cluster per write) multiplied with size. And
one more, which the numbers showed after the first fixes: without
flushes, a 32-sector write still took 20 ms against 1 ms for a read.
Without KVM it took 1.4 ms: KVM leaves `rep insw` in one trip to QEMU
but `rep outsw` costs one per word.

**Fix.** `fatfs` keeps the chain as an array and writes runs of
neighbouring clusters in one request; `ata` writes 16 sectors a block
(`WRITE MULTIPLE`) and flushes the cache half a second after the last
write, from a domain of its own, or when asked (`Block.Flush`, which
`init` sends before turning the power off). 1 MB: 7.6 s to 1.24 s. The
KVM part is left: 32-bit PIO would halve it, DMA would remove it, at the
cost of the kernel giving a driver memory with known physical addresses.

**Lesson.** Measure with one cause switched off at a time: here a QEMU
option took the flushes away without touching the code, and a missing
KVM did the same for the port, and each answer moved the suspicion.

## 2026-11-22 — The bug the comment warned about

**Symptom.** Remove, in the Packages window, on camlboy: "pkg:
/disk/pkg/camlboy/package.json: Permission denied". Not every time.

**Diagnosis.** fatfs refuses to remove a file that is open. The window
draws four frames a second, and since the Run button was limited to the
packages that open a window (2026-11-21), each frame read the selected
package's `package.json`; when `pkg remove` reached that file while a
frame had it open, the remove failed.

**Cause.** The same race had been met and fixed before: a comment on the
window's state says why the installed packages are read only at the
start and after each job. The new read went into the drawing code,
three screens below the comment.

**Fix.** The packages' windows (`run`) are read with the installed list,
at the same moments. `pkg` tries again, for a second, a file it cannot
remove, since the Applications window still reads `package.json` when it
gets the focus.

**Lesson.** A frame function runs four times a second: whatever it reads
from the disk, it holds open four times a second. Keep the reads where
the comment about them is.

## 2026-11-22 — Where to put 64 KB below 16 MB

**Symptom.** A Sound Blaster plays from RAM by ISA DMA: below 16 MB, not
across a 64 KB boundary, at a physical address the driver knows. MyNOS's
drivers could map a device's memory, never RAM.

**Diagnosis.** The obvious place, a fixed address, was measured before
being chosen: a temporary line in the kernel printed the modules'
addresses. QEMU's multiboot loader puts them right after the kernel, from
2.5 MB, the RAM disk up to 31 MB; GRUB puts `registry` and `memrofsd`
between 1.15 and 1.32 MB and the RAM disk from 4.3 MB. Below 16 MB, the
only room common to both was inside the first 4 MB, which the kernel
keeps whole but uses only for its page directory (1 MB) and its image
(2 MB).

**Cause.** The kernel's reservation of the first 4 MB dated from when its
image was loaded at 1 MB; it moved to 2 MB, and the gap stayed reserved
and empty. And a bootloader may use that gap, which a fixed address
would have collided with under GRUB.

**Fix.** At boot, before any allocation, the kernel chooses 64 KB on a 64
KB boundary in that gap, avoiding the modules and the bootloader's
structures (now registered as reserved too), else above 4 MB in free
pages, and logs where (0x110000 under both loaders today). Call 29 maps
it, counted as shared pages are. A prototype driver, a tone in the area
and one DMA transfer, worked at once in QEMU (recorded with `-audiodev
wav`) and, after one surprise, in v86: there the card asks for samples
only when the browser's audio adapter asks it for data, so under Node no
interrupt came until the script played the adapter's part.

**Lesson.** Before fixing an address, print the ones the bootloaders
chose: two loaders, two layouts. And an emulator's device may be driven
by its host side: a silent card can be a missing listener.

## 2026-11-22 — A window of a new size is a new window's pixels

**Symptom.** None: a feature. Windows had the size their program asked
for at creation, and the Terminal was 80 x 25 for ever.

**Diagnosis.** A window's pixels are a message shared between the
program and displayd, of exactly width x height; a new size cannot be
the same memory. And programs laid out with constants (`let width = 720`).

**Cause.** The design made resizing a protocol matter, not a drawing
one: displayd cannot stretch pixels it does not own.

**Fix.** displayd only proposes: a grip (an outline while dragged) or a
double click on the title (the whole screen, or back) sends the program
an event `resize`; the program answers with the request `resize` and new
shared pixels, as `attach` did at the start; until then the old ones
show. Only windows that ask (`resizable`, with a minimum) get a grip, so
nothing changes for the others. `Gui.run ~resizable` does it for a
program; its frame lays out by `Gui.width`/`Gui.height`. The Terminal
also had to tell the programs inside it: console/1 got `size`, which
libmynos uses for `TIOCGWINSZ`, so kilo, edit (through notty), sh's line
editing and man's pager see the new size when they start or redraw.

**Lesson.** When pixels are shared, not sent, a size is part of the
contract: changing it is a conversation (propose, answer with new
memory), and the side that owns the memory must be the one to answer.

## 2026-11-22 — An index and an archive from two different minutes

**Symptom.** Right after the packages were published again, Install
paint, after Update index: "packages/paint-1.0.tar: its BLAKE2b hash is
not the index's".

**Diagnosis.** Fetched by hand: raw.githubusercontent.com answered the
index from its cache (`x-cache: HIT`, `max-age=300`), the previous
build's, and the archive as just pushed. Both were right, five minutes
apart. A query string did not get past the cache.

**Cause.** An archive's name was the same for every build of a version
(`NAME-VERSION.tar`), and each publish rebuilt them all (the archive
records the MyNOS it was built on): for five minutes, an old index and
a new archive met under one name.

**Fix.** The name carries the start of the archive's hash
(`NAME-VERSION-HASH.tar`): a new archive is a new name, never cached
before. `tools/pkg-publish.sh` copies a build into the repository's
clone and keeps the archives of the index it replaces, removing older
ones: an index served from the cache still finds its own. `pkg`, which
takes the archive's path from the index, did not change.

**Lesson.** Files that must agree, served through a cache, must not
share names across versions: name them by their content, and keep the
previous generation as long as a cache can hold its pointer.

## 2026-11-22 — A lock handed to a thread that never ran

**Symptom.** Exit, in the MyNOS menu, with a window program started from
a Terminal (`clock &`, `text &`, Studio): the session ended, and the text
console answered no more. QEMU turned at 100% of a processor. The same
on a build of two days before: an old bug, found by Studio's test.

**Diagnosis.** The registers sampled from QEMU's monitor were always in
the kernel, under the Terminal's page directory; a temporary line
printing each process's CR3 named it. gdb on QEMU's stub gave the stack:
the Terminal's `kill` of the program, `endProcess`, the freeing of the
program's semaphores, and `__lock` on one of them, yielding for ever.

**Cause.** A `V` that wakes a waiting thread does not free the
semaphore's lock: it hands it over ("pass the critical section to the
woken process"), and the woken thread frees it when it runs. At the
session's end displayd woke the program (its window's Close) and the
Terminal, closing too, killed it at once: woken, never run, the lock
held for ever; freeing that semaphore then spun in `__lock`, with
interrupts off, in the kernel.

**Fix.** A thread remembers the lock a `V` handed it (`semHeld`, set by
`V`, cleared by `P`); `endProcess` frees it for each thread of the
process it ends (`__OS_sem_threadEnded`), the `V` staying (its value
raised, for nobody). On the way, a second lesson: the field, added in
the middle of `tss_t`, made a kernel that no longer booted, because the
kernel's Makefiles knew no header dependencies and linked objects of
the old layout with new ones. They now do (`-MMD -MP`, the `.d` files
included).

**Lesson.** A handed-over lock is state that lives in a thread: whatever
ends threads must know about it. And a build that does not know what a
header changes will one day link two versions of one struct.

## 2026-11-22 — The clipboard: a service of its own

**Symptom.** Text and Studio each had a clipboard of their own (a
reference in Textarea): what one copied, the other could not paste, and
a Terminal or sh had none.

**Diagnosis.** The clipboard is state shared by every program, and
outlives the program that copied. In X it belongs to the display server;
here displayd is C and knows windows, not text, and the console (sh,
text mode) has no display at all.

**Decision.** A service, `clipboard` (OCaml, a few lines, protocol
clipboard/1: get, set), started by init in text mode as well: Textarea
and Gui's fields copy and paste through it, a Terminal pastes on a right
click, `clip` (utils) reads it and copies from a pipe. Without the
service (an older system) Textarea falls back on its own copy.

**Lesson.** In a microkernel a shared piece of state is a service: it
cost one file, a protocol of two requests, and every program, the agent
included, can use it, described like any other.

## 2026-11-22 — A completion list that stayed "reading"

**Symptom.** In Studio, after a Build, `Gui.` showed "Gui: reading its
interface..." for ever; without a Build first it showed the list.

**Diagnosis.** No ocamlc was left in `ps`, and its files in /tmp were
gone: the interface had been read. The list is made again only on a key,
or while something is being read; the condition was "an interface is
pending", tested each frame.

**Cause.** A race: the frame that last asked found the interface still
being read; the domain finished before the next frame, which saw nothing
pending and did not ask again. The Build only changed the timing.

**Fix.** A counter of interfaces read (an Atomic, incremented by the
domain): the list is asked again when it differs from the one seen when
the list was made.

**Lesson.** "Is it still busy?" polled from another thread misses the
moment it stops; a count of completions does not.

## 2026-11-22 — Selecting text in an immediate-mode toolkit

**Problem.** Gui keeps no widget tree: each frame draws text and forgets
it, so there is nothing to select. Text is drawn by `label`, `paragraph`
and, in most windows, `Gfx.text` directly, in scroll boxes.

**Decision.** Each frame registers what it draws as pieces (position,
cells, the clip it was drawn in); `Gfx.text` calls that show content
became `Gui.text`, which draws and registers. The selection is two
points on the window (the press, the pointer): a cell is selected when
one point is after it in reading order and the other not, among the
pieces drawn in the same clip as the press (a scroll box's lines, not
the next column's). After the frame, Gui mixes the selection colour
into the pixels and copies on release. Buttons and list items draw with
`Gfx.text` and stay clickable, not selectable. The Terminal has cells
and a scrollback: there the selection is lines and columns, the lines
numbered from the first that ever scrolled, so that it stays on its
text while output scrolls.

**Lesson.** An immediate-mode toolkit can still answer "what is under
the pointer": by remembering, for one frame, what it drew.

## 2026-11-22 — No microphone on QEMU's Sound Blaster

**Question.** Could soundd record (a microphone) as it plays?

**Finding.** The SB16's DSP has input commands, but QEMU's emulation
(10.2) does not implement them: its binary says "ADC not yet supported".
v86 emulates only the SB16 too. Recording needs another card: QEMU's
ES1370 or AC97 (PCI, bus-master DMA) capture from the host's input.

**Decision.** Not done now: a second driver (PCI, which displayd
already reads to find the frame buffer), and only under QEMU. Playback
stays on the SB16, which both emulators have.

## 2026-11-22 — A second domain slowed camlboy by a tenth

**Symptom.** With the Game Boy's sound on, camlboy ran at 54 frames a
second under KVM instead of 60; with the sound off (M), 60 again.

**Diagnosis.** The sound's emulation costs 15% on the host (329 frames
a second without, 273 with): far from the margin, CAMLBOY doing 357
inside MyNOS. So not the CPU. The other change was a domain that sends
the samples to the sound service. Changed to a thread (module Thread):
60 frames a second, with the sound.

**Cause.** In OCaml 5 a minor collection stops every domain. A domain
waiting (a Condition, an IPC call) takes part through its backup
thread, which the runtime must wake; in MyNOS a thread wakes at the
scheduler's pace, so each of camlboy's many minor collections waited for
it.

**Fix.** Threads, not domains, for helpers that mostly wait (camlboy's
sound, GAV's tones). Threads share their domain's lock: no stop the
world to join.

**Lesson.** In MyNOS a domain is for work that runs in parallel and is
worth its cost at every collection; something that waits is a thread.

## 2026-11-22 — GavML stood still at each beep

**Symptom.** Under QEMU with the host's audio (PipeWire), GavML froze a
moment at every bounce and every hit, and QEMU printed "audio: Writing
to disabled voice sb16" again and again.

**Diagnosis.** Not reproduced here: with KVM or without, sound to a
file, to "none" or to PipeWire with MyNOS's volume at 0, GavML drew 50
frames a second, each in about 3 ms (`GAVML_DEBUG=1`). The messages did
appear, 19 in a minute. GavML plays a short tone at each bounce and hit;
soundd paused the card after half a second of silence and resumed it
with the next sound.

**Cause (probable).** Each pause and resume of the SB16's DMA makes
QEMU turn its audio voice off and on, which with a real backend opens
and closes the host's stream; the machine waits meanwhile.

**Fix.** soundd pauses after 20 s of silence, not half a second: a
game's beeps keep the card running. GavML turns its sounds off with M
(or a button). Without any sound: `run-mynos.sh --no-sound`, or
`SOUND= tools/run-demo.sh`.

**Lesson.** An emulated device's cost is the host's too: what is cheap
on the card (pausing it) may be dear for the emulator.

## 2026-11-22 — QEMU's GTK window froze with the sound card playing

**Symptom.** With sound, as soon as GavML's ball was touched, the whole
screen froze, the pointer too; the game went on (its beeps were heard).
QEMU printed "audio: Writing to disabled voice sb16" now and then.

**Diagnosis.** The game going on meant MyNOS was not stuck: displayd
answers every frame of GavML, which would have stopped with it. `top -H`
on the host: QEMU's main thread at 100%, its vCPU (KVM) at 8%. The main
thread draws QEMU's window and reads the mouse and the keyboard; the
guest runs in the vCPU. gdb on it: in its main loop's ppoll. The same
with PipeWire and PulseAudio; not with SDL's window; not without a
window (here: the main thread at 1 to 17%, whatever the backend).

**Cause.** In QEMU (10.2), its GTK window and the SB16 playing make the
main loop spin; not MyNOS's.

**Fix.** run-demo.sh and run-mynos.sh open SDL's window when there is a
sound card and this QEMU has SDL (`QEMU_DISPLAY=gtk`, `--display gtk`
choose GTK again). Along the way, two things that could have made
MyNOS's side worse are gone: soundd pauses the card after 20 s of
silence, not half a second (a game's beeps no longer pause and resume it
again and again), and displayd asks soundd for the volume without
holding its lock (the pointer never waits for soundd).

**Lesson.** "Everything froze but the sound goes on" points out of the
guest: look at the emulator's threads before the system's.

## 2026-11-23 — What a page fault costs, measured

**Symptom.** To decide on an external pager (mynos-vzp) its costs were
measured first (mynos-0ho, `tests/bench/bench`, rdtsc). Under KVM a page
allocated on use took 7,600 cycles (2.85 µs), a copy-on-write 8,100:
several times what a fault costs on Linux on the same machine.

**Diagnosis.** The first guess was the TLB: `INVALIDATE_THE_CACHE` has a
variant that reloads CR3, which empties it whole. It is not the one in
use: `ARCH386` is off, so it is `invlpg`. The second was the work on the
page: `kbzero` calls `kmemset`, and the copy `kmemcpy`, both loops a byte
at a time. A trial with `rep stosl` and `rep movsl` for whole pages
brought the two faults to 2,600 and 3,200 cycles (0.97 and 1.18 µs).

**Cause.** The kernel's string functions of 2002, written for clarity, on
4 KB at every fault.

**Fix.** Not yet: the trial was reverted, the change is mynos-4d6.

**Lesson.** Measure before guessing, and read the macro before blaming
it: the CR3 reload was in the source, but not in the build.

## 2026-11-23 — A page fault that waits

**Symptom.** None yet: a design constraint, found reading the handler
before the external pager (mynos-vzp). Its entry began with `movl %eax,
(0)` and ended with `movl (0), %eax`: EAX kept at physical address 0,
since the error code was popped into EAX before `pushal`.

**Diagnosis.** It worked because the handler never waited: a fault was
resolved, or the process ended, with interrupts off, before anything
else could fault. A thread that waits for the pager inside the handler
lets another thread fault meanwhile, and the second fault overwrites the
first's EAX at 0: the first thread would resume with the other's
register.

**Cause.** A shortcut of 2002 that needed the handler to be atomic.

**Fix.** `pushal` first, the error code read from above the registers
(`32(%ebx)`), dropped with `addl $4, %esp` before `iret`; `copy_user`'s
fix-up finds EIP at `frame[9]`, past the error code.

**Lesson.** A handler that may block keeps its state where the thread
keeps it: on its own kernel stack.

## 2026-11-23 — The pager's pages in the places that read entries

**Symptom.** None: an audit before marking pages that are not present
with a meaning of their own (bit 9, `PF_PAGER`, and a token).

**Diagnosis.** Every reader of page table entries was checked. The
processor ignores a non-present entry but for bit 0; the kernel does
not: `releasePages` (munmap) wanted `PRESENT` or `LOGICAL_PRESENT` and
refused the region; fork's `copy_page_table` copied only those two, so a
child lost its mappings; `__mapPageTo` tested `PF_SHARED` first and
would have copied a page that is not there; `__IS_PAGE_PRESENT` would
have called the region's pages free. The teardown frees only present
frames, and `__mem_userArea` refuses entries without those bits: both
right as they were.

**Fix.** `IS_PAGER_ENTRY`: munmap accepts it, fork copies it (the child
asks the pager with the same tokens), messages refuse it, and the free
page search counts it as used.

**Lesson.** Giving a meaning to a bit the hardware ignores means reading
every line that looks at it; the tests (eleven checks in tests/abi) are
the second half of the audit.

## 2026-11-23 — Studio froze when its agent ran a program that used Studio

**Symptom.** In Studio, the agent wrote and ran `ide_demo.ml`, a program
calling Studio's own service (ide/1: files, read, find, build...). The
agent never answered, and Studio stood still. Run by hand from a
Terminal, the same program worked.

**Diagnosis.** Two threads of one process, each waiting for a child:
the agent's domain waited for `ide_demo` (`Mynos.wait`), and the domain
serving ide/1, asked for a build, waited for `ocamlc`. A test in
tests/abi with that shape (a thread waiting for a child of 1.5 s, the
main thread for a child of 0.1 s) took 1390 ms for the quick one: it was
not woken when its child ended. `wait4` slept on the process's
`childSem`, which a child's end V'd once: the thread woken was the first
to wait, the agent's; its child alive, it slept again with the wakeup,
and the thread whose child had ended slept on. In Studio the other child
was `ide_demo`, waiting for that very build: neither could end.

A first fix, V'ing `childSem` once for each waiting thread, did not
work, and a trace of the kernel showed why: the first V hands the
semaphore's lock to the thread it wakes, the second V waits for that
lock by giving up the processor, and the process that does it is ending:
it is never run again, and the second V never comes.

**Cause.** A wakeup meant for "whoever waits for this child" given to
one waiter of the whole process, from the days of one thread a process.

**Fix.** A thread waiting in `wait4` lists itself in its process
(`childWaiting`, 16 places; beyond them `childSem` as before) and waits
on its own private semaphore; a child's end wakes every listed thread,
one V on each one's own semaphore, so no V waits for another.

**Lesson.** Code that runs in an ending process must not wait for
anything, not even a lock; and "a V for an event" wakes one thread,
which is a broadcast only when one thread can wait.

## 2026-11-23 — The browser stood still on Wikipedia's style sheets

**Symptom.** With CSS (browser 1.6), Wikipedia's window stayed empty;
`browser --dump` printed the first pass (the page's own `<style>`) and
nothing after its two style sheets came.

**Diagnosis.** The same page and sheets, through `css.ml` compiled on
the host (the build container), hung too: reading the sheets took 24 ms,
so it was the cascade. Its `var()` replaced a variable by its value and
looked again: Wikipedia's variables name each other, and a pair that
does so in a circle never ends.

**Cause.** A substitution without a bound, in a language (CSS custom
properties) that lets values refer to each other.

**Fix.** At most 12 substitutions; past them the declaration is dropped,
as a browser drops a cyclic one.

**Lesson.** A tool's core that is plain OCaml can run on the host: the
loop was found in a minute there, not by booting MyNOS again.


## 2026-11-23 — The swap wrote pages that had nothing to keep

**Symptom.** The first run of `mapcat -a 64 16` (64 pages of pagerd's
memory, a budget of 16) read every page back right, but counted 112
pages written to the swap for 64 read from it: more writes than pages.

**Diagnosis.** The test writes each page, then reads them all. A page
taken back during the reading pass had been read back from the swap and
not written since, yet went to the swap again; a page of zeros never
touched would have gone too.

**Cause.** pagerd sent every page of memory it took back to the swap,
whatever the Dirty bit said. The kernel's `query` reported it (4), and
the pager did not look.

**Fix.** A page goes to the swap only if written since it was last
supplied (Dirty): one never written reads again as zeros, one read from
the swap and not changed still has its slot, which is kept until the
region goes. The same rule already held for shared mappings (written
back to the file only if dirty). The same test now writes 64 pages to
the swap and reads 64 back.

**Lesson.** A pager's cost is its writes: the processor keeps the bit
that says which pages have changed, and a policy that ignores it does
twice the work the measurement then shows.

## 2026-11-23 — malloc made two system calls

**Symptom.** NetSurf, compiled for MyNOS, laid out a saved Wikipedia page
in 5 s, 25 times slower than on Linux on the same processor. A test
program of 2 million small malloc and free took 1.61 s in MyNOS, 0.08 s
on Linux; computing and large blocks took the same time on both.

**Diagnosis.** The same test linked with musl's allocator called
directly, skipping libmynos's malloc, ran in 0.08 s in MyNOS too.

**Cause.** libmynos replaces malloc, free and realloc with versions that
take a kernel semaphore around musl's (`safe_alloc.c`, 2002): dietlibc's
allocator was not safe with threads. Each call made two system calls (P
and V). musl's allocator is safe with threads, but it learns of them
from `pthread_create` only: MyNOS's native threads (`mynos_threadCreate`)
still need the lock.

**Fix.** `mynos_threadCreate` sets a flag; until it is set, the three
functions call musl's directly. 0.09 s for the test; NetSurf's page from
5.0 to 4.2 s (the rest is the timer: see mynos-zeu).

**Lesson.** A layer written for one library outlives it: when the C
library changed, what it protected against should have been checked
again, and it costs every program, every time.

## 2026-11-23 — A wait of 1 ms lasted 20

**Symptom.** NetSurf, in MyNOS, loaded a saved Wikipedia page in 4.3 s,
0.23 s on Linux, though computing and memory measured as fast as there.
Sampling the processor's EIP from QEMU's monitor during the load found
it mostly in the kernel's idle loop: NetSurf was waiting, not working.

**Diagnosis.** NetSurf works in scheduled steps (each fetch, each style
sheet), and waits between them, for a few milliseconds. A test of
nanosleep and select from 0 to 20 ms: on Linux each lasts what it asked
plus 0.2 ms; in MyNOS a wait of 0 lasted 10 ms, of 1 to 10 ms lasted 20,
of 11 to 20 lasted 30. `select` is not there at all (it fails at once).

**Cause.** The timer ran at 100 Hz, as in 2002. A sleep is rounded up to
whole ticks, and wakes at the tick after its last (`timeToWake <
timerTicks`), so that it lasts at least what was asked: a tick more
than the rounding. With 10 ms ticks, every short wait cost 10 to 20 ms;
the clocks, made of the same ticks, could not even measure it.

**Fix.** The timer at 1000 Hz (`PIT_FREQ`). The scheduler keeps its
10 ms quantum (`SCHED_TICKS`): between two rounds a tick schedules only
to wake a sleeper whose time has come, or when the idle thread runs.
What the system calls report as ticks (`times`, native 38, the
recorder's header) stays in 10 ms units, so sysmonitor and the recorder
read the same numbers. Waits now last what they ask plus 1 ms; the page
loads in 0.68 s.

**Lesson.** A program's speed is also how fast it is woken: the first
measure of NetSurf counted computing and memory, which were fine, and
the idle loop held the answer.

## 2026-11-23 — NetSurf's own log made it look slow

**Symptom.** With the timer at 1000 Hz, NetSurf's verbose log (`-v`)
still put Wikipedia's parse at 1.3 s in MyNOS against 0.19 s on Linux,
and "DOM to box" at 0.6 s against 0.03 s.

**Diagnosis.** A measure without the log (NetSurf writes the time when
it stops its throbber, `NSFB_TIME=1`) gave 0.68 s for the whole page
against 0.23 s on Linux: the gap was a third of what the log showed.

**Cause.** On Linux the log went to a file; in MyNOS to the console,
each of its 340 lines a request to the console service and the screen.
The measure measured the measuring.

**Fix.** The load time from inside the program, with nothing else on
(`ports/netsurf/patches/04-load-time.patch`); the log only to see the
order of events.

**Lesson.** Before comparing two systems, the instrument has to cost
the same on both: a log is cheap where it goes to a file.

## 2026-11-23 — NetSurf's SVG images: four faults in a row

**Symptom.** With libsvgtiny built in, SVG images in NetSurf (Wikipedia's
logo, a test circle) were not drawn at all; on Wikipedia the logo was a
pink "broken object" box; once drawn, Wikipedia's tagline had lines
across it, and shapes had borders they did not ask for.

**Diagnosis.** One at a time, each on the host (NetSurf's Linux build,
the "ram" surface writing a PPM) and then in MyNOS:
1. The framebuffer front end's path plotter only logged "path
   unimplemented"; libsvgtiny turns every shape into a path.
2. A printout of the paths showed a curve with control points at x=316
   in a 140-wide drawing, after relative `q` and `t` commands.
3. `content/handlers/image/svg.c` sets a path's colours but not its fill
   and stroke types, which held whatever was on the stack.
4. The broken box: a log in svg.c showed the path call failing with
   NSERROR_INVALID, which the new plotter never returns. The knockout
   plotters flush their queue before a path, and a queued clip outside
   the window had failed `nsfb_plot_set_clip`: the error was the clip's.

**Cause.** NetSurf's framebuffer port never drew SVG; libsvgtiny 0.1.8
kept a relative `q` control point relative and added the current point
twice to a `t`'s; an element placed off the screen (Wikipedia hides
links so) is an error to libnsfb.

**Fix.** Paths drawn (curves as segments, a scan-line fill with the
non-zero rule, strokes), fill and stroke chosen by colour as GTK does,
an off-screen clip made an empty one; libsvgtiny's `q` and `t` fixed
(ports/netsurf/patches/11, 12).

**Lesson.** When an error code comes from a call that cannot return it,
look at what ran just before: a queue of deferred operations reports
its failures on whoever empties it.

## 2026-11-23 — Seven images "cannot resolve" a name that resolved

**Symptom.** Loading Wikipedia's article on OCaml in NetSurf, seven
fetches from thumb.wikimedia.org failed at once with "cannot resolve",
while other fetches from the same host, a moment later, worked: the
page had holes where images were.

**Diagnosis.** The failures took 0 to 40 ms, too fast for a DNS query:
netd refused them. They all started together, the page's thumbnails.

**Cause.** lwIP's DNS keeps a table of names being resolved and, with
LWIP_DNS_SECURE (its default), attaches a request for a name already
being asked for to that name's entry, in a table of DNS_MAX_REQUESTS
places; both default to 4. The fifth request for a host still being
resolved got ERR_MEM, which netd reports as "cannot resolve".

**Fix.** services/net/lwipopts.h: 16 names, 64 requests, their queries
sharing at most 4 UDP ports (lwIP reuses one when it cannot open more).

**Lesson.** A library's defaults are sized for a sensor, not a browser:
the first program that asks many things at once finds them.

## 2026-11-24 — The seventeenth TLS connection: "out of memory"

**Symptom.** NetSurf on www.repubblica.it: 411 of 437 fetches failed
with "out of memory", the page came without its style sheets, and every
page opened after it failed the same way, even Hacker News.

**Diagnosis.** The message is netd's, from `altcp_tls_new` in
`tls_start`: no TLS connection could be made, though netd's memory was
fine. The site takes its resources from five hosts; NetSurf kept up to
four connections open to each, and never closed an idle one unless it
reused it.

**Cause.** In lwIP a TLS connection is two altcp pcbs, TLS over TCP;
MEMP_NUM_ALTCP_PCB defaults to MEMP_NUM_TCP_PCB (32), so netd allowed 16
TLS connections at most. The fetcher, keeping connections to every host
of a page and of the pages before, used them all up.

**Fix.** netd: MEMP_NUM_ALTCP_PCB is twice MEMP_NUM_TCP_PCB. The fetcher:
at most 12 connections in all; one idle for 20 s is closed, and when a
new one is needed past the 12, the oldest idle one of another host is
closed first.

**Lesson.** Keeping connections open moves a resource from "per fetch"
to "per session": its limit must be counted for the whole session, not
for one page.

## 2026-11-24 — Google needed JavaScript, but only over HTTPS

**Symptom.** Google searches in NetSurf ended on a blank page, after the
consent page. I concluded that Google's results now need JavaScript and
that nothing could be done; the user then showed NetSurf 3.11 on Linux
showing Google's results.

**Diagnosis.** NetSurf's log in MyNOS (`-V FILE`) showed Google's loader
script failing ("identifier 'performance' undefined", then 'Image') and
no navigation after it. curl with NetSurf's user agent got the loader
page whatever the user agent, the consent cookie or the parameters of
Google's home page form; the one difference that mattered was the
scheme: over http:// the results are in the HTML, over https:// they
come from the script.

**Cause.** Google serves two pages: a JavaScript loader over HTTPS, the
results themselves over HTTP. NetSurf on Linux had reached the HTTP one
through Google's home page.

**Fix.** The address bar's web search and the welcome page's form use
http://www.google.com/search (DuckDuckGo's lite page next), the user's
choice, knowing the query is then unencrypted.

**Lesson.** "It cannot work" needs the same proof as "it works": a
working example on another system is the first thing to look for, and
the variables to vary are all of the request's, the scheme included.

## 2026-11-24 — A backward copy over the GDT: the direction flag

**Symptom.** Opening Slashdot in NetSurf froze MyNOS, about one time in
four: "int13: General Protection in the kernel" in `switchTo`, at
`popw %fs`, switching to a thread of displayd, then of consoled, then of
netd: always another process than NetSurf.

**Diagnosis.** The selector being loaded was 0x23, the user data
segment, which is legal: so the GDT's entry 4 had changed. A dump of the
GDT at the fault showed its high word as 0x0020381F instead of
0x00CFF300; a trap on the GDT's physical frame never fired (nobody freed
or reused it). A hardware watchpoint on that word, through QEMU's gdb
server, caught the writer: `kmemcpy` called by `tls_load` from
`switchTo` on a timer interrupt, copying the TLS descriptor into entry 5,
with DF set in EFLAGS: `rep movsl` ran backwards, from entry 5 into 4.

**Cause.** The direction flag belongs to the interrupted program
(musl, like any libc, may run with DF set around a backward copy); an
interrupt or a system call does not clear it, and no kernel entry did
`cld`. The kernel's C code assumed DF clear, as the ABI says; that did
not matter while `kmemcpy` was a byte loop. On 2026-11-23 (mynos-4d6)
`kmemcpy` and `kmemset` became `rep movsl` and `rep stosl` to make page
faults three times faster (commit 98cd6c9), and from then on any kernel copy made while a
program had DF set went backwards.

**Fix.** `cld` first thing at every kernel entry: the ISR and trap
wrappers (IRQs too), the timer, the page fault, both system call traps,
and the exceptions' C function. tests/abi: two threads switched by the
timer with DF set, then a fork; before the fix it faults the kernel the
same way. Slashdot: eight loads, no fault.

**Lesson.** A faster primitive brings the contract of the instructions
it uses: `rep movs` reads a flag the caller owns. And a corrupted table
found far from its writer is a case for a watchpoint, not for guessing:
the last two hypotheses were wrong.

## 2026-11-24 — Sockets for C, and who else picks them up

**Symptom.** C programs had no network (mynos-t9l): musl's `socket`
makes the Linux `socketcall`, and the kernel answers `-ENOSYS`. OCaml's
`Unix.socket` failed the same way.

**Diagnosis.** The pieces were there: `net/1` already has every request
a BSD socket needs (connect, listen, accept, send, recv, UDP), and
`fileio.c` showed how to replace the C library's functions at static
link time (libmynos comes first on the link line; musl keeps one
function per object file).

**Cause.** Nobody had written the mapping. Two design points: `read`,
`write` and `close` live in `fileio.c` and must reach sockets too, yet a
program without sockets should not carry them; and netd keeps one
waiting `Recv` and one `Send` per socket, on the channel each came on.

**Fix.** `mynos-lib/src/socket.c`: descriptors from 84 up, after the
files'; each call one request on a channel of its own (a thread may
wait in `recv` while another sends); netd's error strings mapped to
`errno`; `getaddrinfo` over `Resolve`. `fileio.c` calls through a
pointer, `__mynos_sock_ops`, that `socket()` sets: a program that never
calls it never links `socket.o`. Programs that do pick it up without a
change: `ocamlrun` (its `Unix` stubs reference `socket`), so
`Unix.socket` now works. The test found one more thing: a `write` to a
socket already closed went on to the kernel, whose `write` ignores the
descriptor and printed the byte on the screen; `fileio.c` now answers
`EBADF` for any descriptor of its ranges (files, sockets) that is not
open.

**Lesson.** A replaced libc function is replaced for every caller in
the link, not only for the program being written: check who else
references the symbol (`nm`), here to find a feature, elsewhere to find
a surprise.

## 2026-11-24 — fork copied threads it never ran

**Symptom.** From the reference's review (mynos-1ev): a process that
forks with several threads gave its child copies of all of them,
counted in its thread count; and a fork out of memory returned -1 and
kept the pages it had taken.

**Diagnosis.** `copyThreads` (2002) copied the whole thread list;
`readyQueueInsert` was called on the caller's copy only ("TODO: other
threads!!!"), the rest of the loop under `#if 0`. The copies were
never run, but `numThreads` counted them, the processes' monitor showed
them, and an exiting thread of the child checked that count.

**Cause.** The 2002 code meant to run the copies (Solaris's `forkall`),
then stopped half way. POSIX `fork` copies only the calling thread.

**Fix.** `copyThread` copies the caller alone, the child counts one.
On failure, `forkFailed` frees what was built: the child's directory,
page tables and the pages they took or referenced (the same walk as
`reapZombies`, split out), and returns `-ENOMEM`; the parent's pages
left copy-on-write become writable at their next write, as their only
user's. tests/abi: a fork while a second thread waits; the child's
thread count (`procstat`) is 1.

**Lesson.** A `#if 0` and a TODO in old code mark a half-made decision:
finish it one way or the other, and make the counters say what runs.

## 2026-11-24 — poll and select: what to wait for

**Symptom.** `select` and `poll` failed at once (`-ENOSYS`, mynos-x8i):
a program that sleeps with `select(0, …, &tv)` spun, and none could wait
on a socket and the keyboard together.

**Diagnosis.** The descriptors live in three places: sockets in netd,
stdin in a console service (consoled, or a Terminal window, or Studio's
runner), files in the file services (always ready). Nothing in the
kernel knows them, so `poll` belongs in libmynos, and each service must
say whether its descriptor is ready.

**Cause.** No request asked that. The first draft of netd's `Poll` took
a list of sockets and answered when any flag was set: a writable socket,
polled for reading only, answered at once, every time, and the caller
looped on a request that never waited.

**Fix.** net/1 `poll` (case 14) takes (socket, events) pairs and answers
when one of the events asked for is ready (or the peer closed, or it
failed), or at its deadline; netd checks its pollers after every pass of
its loop, and wakes for the nearest deadline. console/1 `ready` (case 6)
says whether a `read` would answer at once. libmynos's `poll` asks
both: netd waits when there are only sockets; with the console too, it
waits 20 ms at a time between questions to the console. `select`,
`ppoll` and `pselect` go through `poll`; a socket's `O_NONBLOCK` asks
`Poll` with no wait before a call and gives `EAGAIN`. An older console
that does not know `ready` counts as ready (the read then waits, as
before).

**Lesson.** A readiness question must carry what the asker waits for;
otherwise the service answers the wrong question quickly.

## 2026-11-24 — The recorder called a Write a Size

**Symptom.** Found by the book's review, not by a test: the recorder's
player decodes console/1 requests by their case number, and its table
listed `Read, Mode, Keymap, Size, Write, Foreground`. A `Write` (case 3)
was shown as `console/1 Size`, a `Foreground` as `Write`, a `Size` as
`Foreground`.

**Cause.** `Size` was added on 2026-11-22 as case 5, after `Foreground`,
in the protocol; in the player's table it was put after `Keymap`, where
it read well, not where its number is. The table is a list indexed by
position, so the order is the protocol.

**Fix.** The table in the protocol's order, with a comment that says
so; `Ready` (case 6) and net/1's `Poll` (case 14) named too.

**Lesson.** A table indexed by position must be written in the order of
the numbers it stands for, and say so: a name in the wrong slot is not
an error anyone sees, only a wrong word in a recording.


## 2026-11-24 — The toplevel had no history in a terminal window

**Symptom.** Reported by the owner: in the OCaml toplevel, Up and Down
did nothing. On the console they brought back the last phrases.

**Diagnosis.** The toplevel reads lines in line mode, so its editing is
the console service's. On the console that is consoled, which has had a
history since 2026-11-16; in a terminal window it is `gui/terminal.ml`,
whose line mode dropped every escape sequence ("no editing keys in line
mode"). `sh` was not affected: it reads in raw mode and keeps its own.

**Cause.** console/1 has two servers, written at different times; the
second copied the first's protocol, not its line editing.

**Fix.** The terminal window keeps the last 64 lines, as consoled does,
and shares them with it through `/disk/.history` (read at the first Up,
appended to at each line). Up/Down and Ctrl-P/Ctrl-N, the draft line
kept while browsing.

**Lesson.** Two servers of one protocol must be compared by what a user
does with them, not only by their requests: line editing is not in the
protocol, and is what the user sees.

The owner had meant Left and Right: the cursor could not be moved back
into a line in either server (the book said so). Both now keep a cursor
in the line and redraw only what follows it, with Backspace to move left
and the characters themselves to move right: nothing but what every
terminal understands, so the same writes serve the screen, the serial
port and the window. A second lesson, for the agent: "the arrows" was
read as Up and Down because those were the ones missing in one place;
asking which arrows would have saved a round trip.

## 2026-11-24 — httpd serves /disk/web, not /disk

**Decision.** The owner's: the web server publishes a directory made
for it, `/disk/web`, created at its first start, and receives uploads
there. Before, it served the whole of `/disk`, the home directory too,
with the shell's history and whatever a program saved; the `.env` and
hidden-file filters (mynos-n16) were the only line between the disk and
a browser.

**Why.** A filter of names refuses what one thought of; a directory of
its own publishes only what one put there. The filters stay, for a
`.env` copied into `/disk/web` by mistake or a server started on
another directory (`httpd /disk 8081`).

**Lesson.** Publish by placing, not by excluding: the default should be
that nothing is on the web until someone puts it there.

## 2026-11-24 — dmaAlloc zeroed its own page table

**Symptom.** In the suite's virtio boot (256 MB, a disk, a network card,
a keyboard, a tablet, a GPU) `displayd` was killed when the graphical
session started: "invalid memory access at 0x42401000". The same boot
without the disk and the card, or by hand with 512 MB, worked.

**Diagnosis.** The address was one page past a 4 MB boundary, in the
3 MB frame buffer `displayd` had just asked `dmaAlloc` for. Its first
4 MB were fine; the next page table was not.

**Cause.** `__OS_allocDma` chose a run of free physical pages first,
then reserved the linear pages with `__OS_askPagesFrom`, which makes the
page tables the range needs and takes their pages from the same free
pool: one page table landed inside the run. The run was then mapped and
zeroed, and the zeroing wiped that page table. Whether it happened
depended on what the other drivers had taken before.

**Fix.** The linear pages, and their page tables, first; the physical
run after.

**Lesson.** When a function takes two resources from the same pool, the
one taken first must not be counted as free by the search for the
second: order them so that the search sees the pool as it will be.

## 2026-11-24 — A key became a mouse event

**Symptom.** After the virtio tablet was added to `displayd`, no key
reached a window of the graphical session: the Terminal, `edit`, the
keys test, all silent. The mouse worked; the text console too.

**Diagnosis.** By halves: the old `consoled` with the new `displayd`
failed, the new `consoled` with the old `displayd` worked.

**Cause.** The virtio tablet's code defined Linux's event types as
macros, `#define EV_KEY 1`, after `displayd`'s own `enum { EV_KEY,
EV_MOUSE, ... }` of the events it posts to windows. From that line on,
every key was posted as kind 1: a mouse event.

**Fix.** The virtio constants are `VEV_*`, in `displayd` and in
`consoled`.

**Lesson.** A macro defined late silently overrides a name declared
early, with no warning; constants taken from another vocabulary (Linux's
input events) get a prefix of their own.

## 2026-11-25 — x86-64: the graphical session without text

**Symptom.** On x86-64 the graphical session came up with windows,
buttons and the logo, but not a letter: every label empty. The font
file read fine from the toplevel, and `Gfx.text t 0 0 "hi" 0` answered
0 cells.

**Diagnosis.** `Gfx.text` has an optional limit of cells, `?max`, whose
default is `max_int / 2`. The stub `caml_gfx_text` read it with
`int max = Long_val(vmax)`.

**Cause.** On the i386 `max_int / 2` is 2^29, which fits an `int`. At 64
bits it is 2^61: truncated to 32 bits it is −1, and the loop
`cells < max` never ran.

**Fix.** The stub reads the limit as a `long` and clamps it to
`0x7FFFFFFF`.

**Lesson.** OCaml's `int` follows the word; C's `int` does not. A stub
that narrows `Long_val` to `int` is safe only for values bounded by
something real (a pixel, a length), not for "no limit" defaults built on
`max_int`.

## 2026-11-25 — Two test binaries in git

**Symptom.** At 64 bits the FPU test did not start ("module is not a
valid MyNOS program") and the stdio test was killed by a general
protection fault, though both had been rebuilt.

**Diagnosis.** In `build/x86_64/tree`, `tests/fpu/fpu.o` was a 64-bit
object and `tests/fpu/fpu` a 32-bit program. `git ls-files` listed
`tests/fpu/fpu` and `tests/stdio/stdio`.

**Cause.** Both binaries had been committed with the sources
(ee0aa74). The copy of the tracked files made them newer than their
objects, so make did not link them again: the i386 programs ran on the
x86-64 kernel.

**Fix.** Out of git, into `.gitignore` next to their sources.

**Lesson.** A build product in git is invisible on one architecture and
wrong on the next. Look for ELF files among the tracked ones when a
second toolchain arrives.
## 2026-11-25 — The browser version, half old and half new

**Symptom.** Right after MyNOS 1.0 was published, the browser version
booted a kernel that said `v2026.11-89918d5`, the previous release, and
its `sh.byte` failed: "has not the right magic number".

**Diagnosis.** GitHub Pages served 1.0 (`index.html` said so), with
`cache-control: max-age=600`. The page and the images' chunks have the
same names in every release (`images/mynos-0-1048576.iso.zst`...).

**Cause.** The browser still held, for up to ten minutes, the previous
release's page and some of its chunks, and fetched the others new: one
disk image made of two releases.

**Fix.** `tools/make-web.sh` puts the chunks under a directory named by
the version (`images/1.0/`), and the page asks for them there. A page
held from before asks for its own directory (gone: it fails to load,
for ten minutes at most), never for a mix. For the owner: a forced
reload.

**Lesson.** Files that belong together and change together must change
their names together; a cache only knows names.

## 2026-11-25 — x86-64: every network request four seconds late

**Symptom.** On x86-64 `ask` took 14 s where the i386 took 2 to 8, the
network test needed 124 s against 22, and in the suite the keyboard-
driven boot fell behind the keys typed into it. Alone, the system was as
fast as the i386 at everything tried: files, the console, `spawn`, the
toplevel.

**Diagnosis.** Timing one command at a time on both architectures, with
the network on: `fetch` from the host 3.3 s on the i386, 7.5 s on
x86-64; `llm` 2.6 s against 7.2. A constant of about four seconds per
connection. `netd`'s main loop sleeps in `pthread_cond_timedwait` (at
most 100 ms) and is woken by the card's interrupt thread.

**Cause.** `_linux_syscall_futex_time64` took its fourth argument, the
pointer to the timeout, as `uint32_t`. On x86-64 a program's stack is
above 4 GB: the pointer was cut, the kernel found it outside the
program's memory and answered `-EFAULT` at once. Every timed wait
returned immediately, and `netd`'s loop spun, taking the processor from
the other threads until each tick. Without a network card `netd` ends at
boot, which is why the system looked as fast when tried alone.

**Fix.** `vaddr_t arg4` in both futex entries. The other Linux and
native calls x86-64 uses were checked for 32-bit parameters: all are
values, not addresses. After it, `fetch` and `llm` take the i386's time.

**Lesson.** A parameter typed `uint32_t` that holds an address is a
64-bit bug waiting; and a fast system "alone" may only mean that the
spinning service did not start. Measure with the same devices the slow
case had.

## 2026-11-25 — The disk under KVM: not the driver's loop

**Symptom.** With KVM, copying 1.5 MB to `/disk` and reading it twice
took 11.5 s, and `ata` used 98% of the processor; with the processor
emulated (TCG) it took 2.55 s.

**Diagnosis.** `ata` waits for each sector by reading the status port in
a loop; under KVM every port access leaves the virtual machine. The
guess: the loop. The driver was changed to wait for the controller's
interrupt (IRQ 14) instead. Nothing changed under KVM (11.6 s, `ata`
95%), and under TCG it became 15% slower (2.94 s against 2.55, twice):
waking a process at each interrupt costs more than a few status reads
when the emulated disk answers at once. The same workload on the virtio
disk (`VIRTIO=1`, `vblkd`, DMA): 0.20 s under KVM.

**Cause.** QEMU's emulation of the IDE disk in PIO mode: each sector
moves through the data port, and under KVM each transfer is an exit to
QEMU's emulation. The driver's waiting was a small part of it.

**Fix.** None to `ata`: the interrupts were taken out again. A disk that
must be fast under KVM is the virtio one (or an IDE driver with
bus-master DMA); the issue for it is in beads.

**Lesson.** Measure the alternative before the fix: the virtio disk,
tried first, would have said in one run that the cost was the device's
emulation, not the loop.

## 2026-11-25 — x86-64: the terminal shows no output (an empty auxiliary vector)

**Symptom.** On x86-64 the Terminal window showed sh's prompt and what
was typed, but nothing a program wrote: not sh's banner, not `echo`'s
line, not `cat`'s file; a stray block at the start of each such line.

**Diagnosis.** The terminal received the text (a log of each Write) and
drew the rows (`Gfx.text` returned their cells), and displayd accepted
the damage. A small program then showed it: a window filled from a
second domain (or a Thread) stayed red on x86-64, green on the i386;
the domain read back red right after its own `Gfx.fill`, while a direct
`Bigarray.set` worked. `Gfx.fill` from any thread but the first drew
nothing: `clip_on`, a `__thread` variable meant to start at 0, read
-26000, and its neighbours held a return address in musl's `__clone`
and the domain's start function: the top of the new thread's stack. The
terminal draws programs' output from its service domain, and the
prompt from its main thread: hence one seen, the other not.

**Cause.** The kernel gave every program an empty auxiliary vector (on
both architectures). Without `AT_PHDR` musl finds no `PT_TLS`, takes
the TLS block as empty, and gives each new thread a TLS area of nothing:
its `__thread` variables lie on its stack's top, where `pthread_create`
writes its start arguments and `__clone` pushes a return address. On the
i386 the offsets happened to miss what mattered.

**Fix.** The kernel builds a real auxiliary vector on both
architectures: `AT_PHDR` (the program's headers in memory, inside the
loaded segment that holds them), `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ`,
`AT_ENTRY`, and `AT_RANDOM` (16 bytes from the kernel's generator: musl's
stack canary had none). `tests/abi` checks that a new thread's TLS
starts at zero and that the vector is there.

**Lesson.** "It works" on one architecture can be luck in the layout:
a libc's startup contract (here the auxiliary vector) is part of the
ABI, and an empty one fails silently.

## 2026-11-25 — SMP: what one processor had been hiding

**Symptom.** With the other processors started and the big kernel lock
in place, the x86-64 suite at four processors failed 21 checks: programs
killed by "invalid memory access" in musl's `free`, the graphical
session gone, the abi test failing one run in three, a lost write in the
new `tests/smp`, once a kernel panic (general protection) reading the
current thread right after a semaphore wait.

**Diagnosis and causes**, one at a time, each run several times in
parallel QEMUs:
1. *A fault resolved by another processor.* Two threads of a process
   fault on the same page; the big lock serialises the handlers, and the
   second finds the page already allocated (or copied): present and
   writable. The handler knew only "not allocated, not copy-on-write":
   the process was killed. On one processor the faulting thread is the
   only one that can retry.
2. *Fresh pages zeroed after being mapped.* `__allocateOnUse` set the
   entry, then zeroed the page through the user's address: a thread on
   another processor wrote into it in between, and the zeroing erased it
   (`tests/smp`: a lost increment).
3. *`fork` flushed only its own TLB*, after marking the parent's pages
   copy-on-write: a processor running another of the parent's threads
   kept writable translations, and wrote into the page now shared with
   the child. The shootdown also missed the direct map.
4. *A thread of a dead process going on.* Processor A kills a process
   while B, running one of its threads, waits for the big lock to enter
   a call: when B gets it, it runs the call for a process that no longer
   exists. The panic was its trace. Fixed at a call's start and at the
   way back to a process (not at the entry: an interrupt's handler must
   run, for its EOI).
5. *`reapZombies` checked "busy" by a process-table slot*, which may
   already be free or reused: now by the pid of each processor's thread.
6. *A test that assumed one processor* (`abi`: the connector freed its
   channel before the listener had looked at it), and the user-space
   malloc lock's `bts` without `lock`.

**Fix.** Each as above; the page-fault handler returns when the access
is allowed now (after flushing its own TLB entry); fresh pages are
zeroed through the kernel's window before the entry is set; `fork`
shoots down the address space; `smp_leave_if_dead` schedules away. The
suite passes at four processors; `tests/smp` covers 1-3.

**Lesson.** On one processor "the kernel runs one at a time" also meant
"no user code runs while the kernel works": the big lock keeps only the
first. Anything the kernel does to a process's memory in two steps
(map, then fill) is now visible half-done; and anything decided before
waiting for the lock may be false after it.

## 2026-11-25 — AArch64: three things a PC had been hiding

**Symptom.** The first AArch64 kernel (a) panicked in the physical page
finder, "KERNEL ERROR IN __find_first_free_physical_page"; (b) received
no modules from QEMU; (c) once programs ran, hung: the big kernel lock
held for ever after `ocamlrun`'s first sleep.

**Causes.**
- (a) `char` is unsigned on AArch64, signed on x86. The bitmap's bytes
  are `byte_t` (a `char`): `~byte` of a full byte is 0 when it is -1, and
  0xFFFFFF00 when it is 255, so a full byte looked like one with room.
  The kernel's C, and MyNOS's user-space C, were written where `char` is
  signed: both are built with `-fsigned-char` on AArch64.
- (b) QEMU passes `-initrd` and `-append` to Linux images only (its
  bootloader stub writes them into the device tree's `/chosen`); an ELF
  kernel gets neither. The modules now come as one archive that QEMU puts
  at 64 MB into RAM (`-device loader`), carrying the kernel's command line
  too (`tools/mkmodules.py`, `arch/aarch64/dtb.c`).
- (c) The thread's FP and SIMD state is 528 bytes (32 Q registers, FPCR,
  FPSR), stored at the first 16-byte boundary inside a 528-byte area: up
  to 15 bytes past it, over `kdepth`, the thread's big-lock depth. The
  idle thread came back with depth 0, `kernel_exit` never released the
  lock, and the next entry spun on it. Found by recording the lock's
  taker (an `svc #0x90` of `mynos_sleep`) and printing switches whose
  depths were not 1. The area is 16 bytes larger on AArch64.

**Lesson.** A port finds assumptions, not only missing code: the sign of
`char`, a bootloader's contract, a buffer sized for one instruction set's
save format.

## 2026-11-25 — AArch64: from OCaml's hello to the shell

**Symptoms and causes**, in the order met:
- *init.byte "has not the right magic number"*: ocamlrun found no file
  system, memrofs could not register. The registry had opened its port
  before `mynos_main` called `initIPC()`, which cleared the port table:
  the processes of the boot modules are made, the timer is on, and a
  quick process runs before the kernel goes on. Under emulated AArch64
  the registry was quick enough; on the PC never so far. `initIPC()` now
  runs before the modules' processes (all architectures).
- *consoled jumped to 0*: the thread start code of libmynos is a label in
  top-level assembly, local. Debian's gcc builds position-independent
  code and takes a function's address through the GOT; a GOT relocation
  against a local label keeps the section and loses the offset: the
  thread started at the section's first function. The label is global.
- *no keys*: the virtio queues' addresses given to the device were
  MyNOS's physical ones, numbered from RAM's base (doc/decisions/
  aarch64.md, choice 3); the device needs the real ones. `allocDma`
  returns `ARCH_BUS_ADDR`, the real address on AArch64.
- *no virtio device found*: `mapPhysical` took any address below RAM's
  size for RAM and refused any above 4 GB (the i386's rules); on AArch64
  devices have real addresses, which RAM's numbering does not share:
  `ARCH_DEVICE_PHYS_OK`. And no firmware assigns PCI windows on `virt`:
  libmynos's `virtio_find` gives each slot its own 1 MB and the line of
  virt's swizzle.

**Lesson.** Moving RAM's numbering made three kinds of address: the
kernel's (from 0), the CPU's (real) and the device's (real): every place
where an address leaves the kernel says which it is.

## 2026-11-25 — OCaml domains 13 times slower on one processor (mynos-c6a)

**Symptom.** `par.byte` (tests/cpu/par.ml) building and dropping lists
in one domain: 6.93 s on one processor, 0.51 s on four, under KVM.
Computation alone ran at the same speed on both.

**Diagnosis.** A first guess, that the runtime's back-off sleeps of some
microseconds lasted a whole tick on MyNOS, was measured and was wrong
(sub-tick sleeps made a yield: no change). Counting the system calls
showed almost the same on one processor as on four: the time was not in
the kernel. The timer then sampled the user program counter at each
tick, and a snapshot of the process's threads at each time slice:
the domain's thread was in `caml_try_run_on_all_domains_with_spin_work`
and `caml_empty_minor_heaps_once`, and another thread of the process,
the main domain's backup thread, was ready, at every slice. OCaml's GC
log (`OCAMLRUNPARAM=v=0x800`) told the rest: 2220 retries of
"requesting stw empty_minor_heap" by domain 1 while domain 0 had not yet
closed the previous section.

**Cause.** At a minor collection the allocating domain leads a
stop-the-world section and wakes the main domain's backup thread (a
futex). Both do their part; the domain finishes first, allocates again,
and at the next collection finds the section still open (the last one
out closes it): it retries in a loop, without a system call. The backup
thread, woken and ready, ran only when the domain's 10 ms slice ended:
about 10 ms lost at each of some 50 collections. On Linux the woken
thread preempts its waker (CFS's wake-up preemption), and nobody waits.

**Fix.** `FUTEX_WAKE` hands the processor to the first thread it woke
(`sched_handoff`), the waker staying ready in its place, unless another
processor idles and takes it. One domain: 6.93 s to 1.05 s on one
processor (0.48 on four). With more domains than processors the leader
also waits for domains that are ready but were not woken by it: the
slice's length still decides there (a 4 ms slice halves those times;
left to the owner, doc/decisions/smp.md).

**Lesson.** A spin that is not in the kernel cannot be seen by counting
calls: sample where the processor is. And a mere "the thread I woke is
ready" means nothing to a scheduler that lets the waker keep its slice.

## 2026-11-25 — The other processors started after the first programs

**Symptom.** A new check, `tests/smp` printing `sysconf(_SC_NPROCESSORS_ONLN)`
(which musl answers with `sched_getaffinity`, added today), read 1 on
x86-64 with four processors; `nproc` typed in `sh` read 4.

**Cause.** `mynos_main` started the other processors last, in what then
becomes processor 0's idle thread: after the boot's processes had been
made, with the timer on. The idle thread runs only when nothing else is
ready, so the first program (here the test, a module) ran before the
others were up; under load the processors could come up later still.

**Fix.** `arch_smp_start` before the ports and the boot's processes, as
Linux starts its processors before init; the boot's work that follows,
on the kernel's tables, under the big lock (`arch_boot_lock`, a no-op on
the i386 and on AArch64, one processor), since the other processors may
run the scheduler from then on.

**Lesson.** "Started at boot" must mean before the first program, or
the first program sees a different machine from the others.

## 2026-11-25 — AArch64: the console on the UART, run-demo.sh

**Symptom.** `ARCH=aarch64 tools/run-demo.sh` booted the i386 system:
run-demo.sh knew only i386 and x86_64. Once it booted AArch64, nothing
could be typed: the system has no display there yet, and consoled read
COM2's keys with `inb`, which on ARM user space was a stub reading 0xFF.

**Fix.** The kernel's table of the PC ports it answers on AArch64
(`arch/aarch64/io.c`, already COM2's output for the log) gained COM2's
input from the PL011 (data, line status, scratch, receive interrupt);
drivers reach it through a native call (102) that libmynos's `inportb`
and `outportb`, and OCaml's `Mynos.inb`/`outb`, use on ARM. The rest
reads 0xFF: ata now finds no disk and ends with 0, where it raised
"no I/O ports" and init restarted it five times. The PL011's interrupt
is level-triggered: consoled registers it as a PCI line (masked at each
interrupt, unmasked after reading), on line 1. run-qemu.sh and
run-demo.sh take `ARCH=aarch64` (doc/decisions/aarch64.md, choice 9).
On the way: virtio-net-pci wanted a boot ROM the container's QEMU has
not (`romfile=`); a test of mine, `pkill -f` with a pattern in its own
command line, killed its own shell.

**Lesson.** A port I/O table in the kernel, which was there for the log,
was the shortest way to a serial console: the driver did not change.

## 2026-11-26 — AArch64 SMP: a byte skipped by copy_user, and three more

**Symptom.** With two or more processors, displayd died in musl's `free`
(called from `mynos_freeMsg` in its main loop) as soon as the graphical
session had events (keys or the mouse); a client of it (ocamlrun) too.
Never with one processor, never on x86-64 with the same virtio devices
and four processors.

**Diagnosis**, by elimination (each a few boots of a script that types or
moves the mouse in the session): not the futex handoff, not the TLS, not
`malloc` and `mmap` in parallel, not IPC with shared pages, not musl's
locks, not the TLB (a full broadcast flush changed nothing). The
registers at the crash: the pointer given to `free` was not aligned (its
low bits 4): a `mynos_msg_t` with wrong contents. Sending long messages
by copy instead of copy-on-write made it go away, and so did copying only
displayd's.

**Cause.** `copy_user` on AArch64 is a loop, `LDRB` then `STRB`, each
moving its pointer on. A fault in it was resumed at the loop's start
(for mem.c's fixup, which looks for one address, the i386's single
instruction). After a faulting `STRB` the `LDRB` had moved the source
on: starting over skipped a byte, and the rest of the copy came out
shifted. `recv` writes the message's description into the receiver's
memory; in displayd that was a page of its heap another of its threads
had just sent a reply from, copy-on-write: the kernel's write faulted,
the copy was made, and the description came out shifted by a byte.

**Fix.** The fault is handled with the loop's start as the address
mem.c knows; if it was resolved, the copy resumes at the instruction
that faulted.

**On the way**, found and fixed (each real, none the cause):
- a receiver waiting with a timeout could be woken twice, by its timer
  and by a sender that still found it waiting: its private semaphore
  left at 1, its next wait returned at once (every architecture; ipc.c,
  channel.c);
- the drivers assigned PCI's memory windows on AArch64, each for every
  device it looked at, under the owner's feet: the kernel does it once at
  boot now (arch/aarch64/pci.c), as the PC's BIOS;
- `clrex` before every return from the kernel (a reservation of another
  thread must not survive a switch).

**Lesson.** A fault in the middle of a multi-instruction copy must resume
where it stopped. And a bug seen only with many processors is not always
a race on shared data: here the processors only made two rare events
meet often.

## 2026-11-26 — AArch64 SMP: a stack seen through two page tables

**Symptom.** The other processors started ("Processor 0 started", three
times), `tests/smp` failed with two of them: `pthread_join` returned
ETIMEDOUT without a timeout, and the counters were short.

**Diagnosis.** A futex wait woke with its waiter still listed: the
thread's private semaphore had gone below zero, never V'd. A P had
returned from `sched()` without being woken: `sched` found nothing else
ready and, with no idle thread on that processor (`arch_cpu()->idle` was
0), went back to the thread that was blocking. `ap_main` did set it: it
printed `c->idle` right, and `arch_cpu()->idle` 0 just after. `c` was
`&cpus[0]`, and its number 0.

**Cause.** A processor started by PSCI turns its MMU on with the boot's
tables (`pt_l0_lo`). Its stack, a page the kernel allocated, is mapped by
the kernel's tables (`kernel_pml4`) and is elsewhere in the boot's.
`ap_main` saved its argument on the stack, switched to the kernel's
tables, and read it back from another physical page: 0. So every
processor wrote its idle thread into processor 0's `struct cpu`.

**Fix.** start.S switches to the kernel's tables (their real address,
`ap_ttbr0`) before it touches the stack.

**Lesson.** Changing the page tables under one's own stack is changing
the stack.

## 2026-11-26 — x86-64 with KVM: no graphics (PCI's two ports)

**Symptom.** `ARCH=x86_64 tools/run-demo.sh`: `gui` answered "no display
service"; displayd had found "no Bochs VGA". The suite (no KVM) passed,
and so did the demo with `KVM=`. It had worked before x86-64 had four
processors.

**Cause.** PCI's configuration space is read in two port accesses: the
address to 0xCF8, then the data from 0xCFC. displayd and libmynos (netd,
vblkd, consoled's virtio keyboard) each did both. At boot they all look
for their devices at once; with KVM four processors really run them
together, and another driver's address came in between: displayd read
someone else's register. Under emulation the window was too small to
be hit; on the i386 a timer switch between the two could do the same.

**Fix.** A native call (103) does both accesses in the kernel (interrupts
off, the big lock); libmynos's `pci_read32` and `pci_write32`, and
displayd, use it.

**Lesson.** A pair of ports holding a state between two accesses is a
lock nobody takes. On one processor it was safe by luck.

## 2026-11-26 — The kernel's heap corrupted at boot, under load

**Symptom.** The suite on AArch64 (emulated, nine lanes at once): in the
stress test's boot, "memrofs service port: -2" (BUSY: a port whose queue
of connections is full, at boot), then "kernel heap: free list corrupted"
in `newPort`, then a kernel page fault. Alone, the same boot passed every
time.

**Cause.** `mynos_main` makes the boot's processes after `tsksw()`, with
interrupts on (`init_idt` turns them on early) and the timer running. The
timer switched it out in the middle of a `kmalloc` or of `createProcess`,
to a process just made whose system calls changed the same tables. The
big lock did not help: it is the processor's, and a thread of the same
processor took it again. On the PC, fast, the window was never hit; the
`initIPC` race of 2026-11-25 was the same one, seen from another side.

**Fix.** The boot's processes are made with this processor's interrupts
masked (and, for the others, under the big lock): `arch_irq_disable`
around the work after `arch_smp_start`.

**Lesson.** Code that runs with interrupts on and no lock of its own is
preemptible kernel code: MyNOS's kernel is not written for that, and
the boot was the one place doing it.

## 2026-11-25 — AArch64: the pager's dirty bit, kept by faults

**Symptom.** `tests/abi`, ported to AArch64, failed one check: "pager:
copy: the page, its writes forgotten". After `mynos_pagerCopy` the page
still read as written.

**Cause.** ARMv8.0 (the Cortex-A72 of the Pi 4) has no dirty bit the
kernel can use, and AArch64's `pte_mark_clean` did nothing: a writable
page was "written" until given again (a limit noted in the code). The
accessed bit was the same: `pte_mark_old` cleared MyNOS's bit, but the
hardware's access flag stayed on, and nothing set the bit again.

**Fix.** Kept by faults, as on processors without them: forgetting the
use clears the access flag too, and the next access faults; writing a
page back makes it read-only for the hardware (MyNOS's writable bit
kept), and the next write faults. The page fault handler's "the access
is allowed" path (a fault resolved meanwhile by another processor) calls
`pte_fault_fixup`, which on AArch64 sets the access flag and the
accessed bit, and on a write the hardware's writable bit and the dirty
one; on x86 it does nothing (the processor keeps the bits). Only pages
the pager has looked at pay the extra fault.

**Lesson.** A test ported to a new architecture finds the shortcuts
taken there: this one was written down, and still wrong.

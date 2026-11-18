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


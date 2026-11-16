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

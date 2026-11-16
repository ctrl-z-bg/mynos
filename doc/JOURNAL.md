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

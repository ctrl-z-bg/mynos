# Appendix B. Memory

The memory code of the kernel lives in `mynos-core/kernel/mem/`: about
2,000 lines of C (license headers included) in six files. `physicalmem.c`
counts physical pages, `mem.c` builds and edits page tables and handles
page faults, `lmemtrack.c` keeps each process's free linear space,
`dynalloc.c` is the kernel's `kmalloc`, `externalmem.c` reaches into
the address space of a process other than the current one, and
`pager.c` serves the external pager (B.14). Building and
freeing a whole address space is in `kernel/process.c`.

## B.1 The model

Every segment of the GDT spans the whole 4 GB (appendix A.3), so all
protection comes from the 386's page tables: a page is present or not,
writable or not, reachable from ring 3 or not. A page directory of 1,024
entries points to page tables of 1,024 entries, each mapping a 4 KB page:
one page table covers 4 MB.

Each process has its own page directory, loaded into CR3 when the
scheduler switches to one of its threads. The kernel has no address space
of its own: it runs in the address space of whichever process is current,
which lets a system call read the caller's arguments where they are. That
works because the first gigabyte is the same in every process.

## B.2 The linear address space

```
  0xFFFFFFFF ┌─────────────────────────────────┐
             │ the page tables, mirrored       │ PDE 1023: table i at
  0xFFC00000 ├─────────────────────────────────┤   0xFFC00000 + 4 KB × i
  0xFFBFF000 │ the page directory              │ 1 page      ┐
  0xFFBFD000 │ process information             │ 2 pages     │ kernel
  0xFFBF9000 │ kernel stack of the 1st thread  │ 4 pages     ┘ only
             ├─────────────────────────────────┤
             │ user stack                      │ 256 pages (1 MB): the top
  0xFFAF9000 ├─────────────────────────────────┤   page built, the rest on use
             │                                 │
             │ free: mmap, IPC messages,       │ the process's free list
             │ other threads' kernel stacks    │ (lmemtrack)
             │                                 │
             ├─────────────────────────────────┤
             │ the RAM disk, read-only         │ up to 64 MB, page tables
  0x40400000 ├─────────────────────────────────┤   shared by every process
             │ the program (text, data, bss)   │ at most 4 MB
  0x40000000 ╞═════════════════════════════════╡ ── user space above
             │ PDE 255: empty, never used      │
  0x3FC00000 ├─────────────────────────────────┤
             │ two one-page windows at         │
             │ 0x3FBFE000 (copy) and 0x3FBFF000│
             │ (another process's frame)       │ the kernel: page tables
             │ the kernel heap, page tables,   │ 0-254 allocated at boot
             │ kernel allocations              │ and shared by every
  0x00400000 ├─────────────────────────────────┤ process
             │ first 4 MB, identity-mapped:    │
             │ the kernel at 0x200000          │
  0x00000000 └─────────────────────────────────┘
```

**The 64-bit kernels** (x86-64, AArch64) keep the program at
`0x40000000` but give it up to 256 MB, and map the RAM disk far above
it, at `0x4000000000` (256 GB; `MYNOS_RAMDISK` in `mynos.h`): a native
OCaml program carries its runtime, and the compiler itself, `ocamlopt`,
is 11 MB. Their user space ends at 512 GB, the stack at its top.

**The kernel's gigabyte.** Page directory entries 0–255 (`KLAST_PAGE_DIR_ENTRY_USED`
is 255 in `start.asm`) are copied into every new page directory. At boot
`init_memory` (`mem.c`) allocates a page table for entries 0–254, pages
that may stay empty for ever; entry 255 stays empty, and `__OS_askPages`
never allocates in it. (Until November 2026 it pointed at physical page 0
with the user bit set, "to tag it as allocated": low memory, where the
page fault handler saves EAX, was read as a page table, so a program
could put a value in EAX, cause a harmless fault, and get any physical
frame mapped for itself at `0x3FC00000`: mynos-vm8.) The point is that the kernel never adds
a page table to its own space after boot: if it did, the new directory
entry would have to be written into every process's page directory. With
all of them in place, a kernel mapping made in one address space appears
in all of them, since they share the tables themselves. The pages of the
kernel are supervisor pages (no `U` bit), so ring 3 cannot touch them.

**The program** must be an ELF image whose loadable segments start at
`0x40000000` (`USERMINPAGE`, page `0x40000`) and end within 4 MB of it:
`spawnProcess` refuses anything else before allocating a byte. The
segments are copied into fresh frames, the bss zeroed, and all of it
mapped user, present and writable, under one page table.

**The RAM disk** (the GRUB module that starts with `.RAMDISK`) is mapped
read-only at `0x40400000` in every process, by page tables built once, by
`buildRamdiskPTs` at the first spawn, and then pointed to by every new
page directory: at most 16 of them (`RAMDISK_MAXPTS`), so 64 MB. Its range
is also marked as taken in the process's free list; when it was not
(JOURNAL, 2026-11-16), `mmap` handed out addresses that overlapped it,
and OCaml 5 failed to reserve its minor heaps.

> **THE MyNOS FACTOR — Every process can read the RAM disk.**
> The system's files (`init`, `init.rc`, the programs, the OCaml
> interfaces) are in the address space of every process, at the same
> address, at the cost of a few page directory entries. memrofs, the
> process that serves them as files, reads them where they already are;
> the kernel never copies them.

**The top of the space** holds the user stack (its top page, built at
spawn, holds `argc`, `argv`, `envp` and the auxiliary vector as Linux lays
them out), the first thread's kernel stack, at the same address in every
process, two pages of process information (used today only by the 2002
in-kernel service table, calls 11 and 12), and the page tables. The kernel
stacks of later threads come from the process's free space, as supervisor
pages (`PF_SUPERVISOR_IN_USER_SPACE`, `threads.c`).

## B.3 How the kernel reaches the page tables

To change a mapping, the kernel must write into a page table, which is a
physical page; and with paging on, it can write only through a linear
address. MyNOS maps each process's page tables into its own address space
(the 2002 design, `mynos-core/doc/MyNOS-note.txt`):

```
  page directory                          "mirror" page table
  ┌──────┐                                ┌──────┐
  │    0 │──► page table 0                │    0 │──► page table 0
  │  ... │                                │  ... │
  │ 1022 │──► page table 1022 ──┐         │ 1022 │──► page table 1022
  │ 1023 │──► mirror ──────┐    │         │ 1023 │──► mirror itself
  └──────┘                 │    │         └──────┘
       ▲                   │    └─ entry 1023 ──► the page directory
       └───────────────────┼──────────────────────┘   (at 0xFFBFF000)
                           └─► at 0xFFC00000: page table i is the page
                               at 0xFFC00000 + 4 KB × i
```

The mirror holds a copy of every directory entry, so page table `i`
appears at `0xFFC00000 + 4 KB × i`, and the macros of `mem.h`
(`__GET_PAGE_TABLE_ENTRY`, `__GET_PAGE_DIR_ENTRY`) turn "entry `j` of
table `i`" into an address. The directory itself is the last page of
table 1022, at `0xFFBFF000`. A new page table is entered twice, in the
directory and in the mirror (`__SET_PAGE_DIR_ENTRY`). The mirror's own
directory entry has no `U` bit: user code cannot see any of it.

## B.4 Physical memory: a bitmap and reference counts

The amount of RAM comes from the multiboot information (or, without it,
from probing each megabyte). `init_memory` builds a bitmap with one bit
per page, at first at the fixed physical address `0x32000`, and marks as
used the whole first 4 MB (the kernel, its boot page directory at
`0x100000` and its first tables) and the GRUB modules wherever they are.
Then `pmem_createPhyMemManager` (`physicalmem.c`) moves the bitmap into
the kernel heap and adds a descriptor per page: a reference count.

| Function | What it does |
|---|---|
| `pmem_findAFreePhysicalPage()` | a free page, searching from where the last search stopped, a byte (8 pages) at a time; 0 if none |
| `pmem_set(p)` | one more reference: marks the page used at the first |
| `pmem_unset(p)` | one reference less: free at the last; a page with no reference is a panic |
| `pmem_countref(p)` | the count |

The counts are what make sharing safe: a page mapped in two processes
(copy-on-write, a message, `MYNOS_IPC_SHARED`) is freed only when the last
of them lets it go. Pages beyond the end of RAM (a frame buffer mapped by
`mapPhysical`) are never counted: `pmem_set` and `pmem_unset` ignore them.

The manager is marked ready only once its arrays exist: marked first, it
counted its own pages through a null pointer, and after two `shutdown -r`
a page was handed out twice (JOURNAL, "The third boot").

## B.5 Linear space: who gets which addresses

**In the kernel's gigabyte**, `__OS_askPages(n, alloc_now, flags)` looks
for `n` consecutive free linear pages, first fit, from address 0 (the
identity-mapped first 4 MB are taken, so in practice from `0x400000`).
A linear page is free when its entry is empty: neither present nor
reserved.

**In a process**, the free space is a list, `lmemmap` in the process
descriptor (`lmemtrack.c`): areas of free pages in address order, each
with its first and last page (both included). A new process starts with
one area, pages `0x40000` to `0xFFFFF`, from which `spawnProcess` removes
the program, the RAM disk and everything from the bottom of the user stack
to the top (`__lmt_forceAllocation`).

| Function | What it does |
|---|---|
| `__lmt_allocArea(list, n)` | first fit: the first page of `n` free pages, or 1 if there is no room (1 cannot be a user page) |
| `__lmt_freeArea(list, first, n)` | gives an area back, merging it with its neighbours; refuses an area partly free already |
| `__lmt_forceAllocation(list, first, n)` | takes a given area (the program, the stacks, the RAM disk) |
| `__lmt_copyList`, `__lmt_freeList` | for `fork`, and for a process that ended |

Everything a process gets in user space comes from this list: `mmap`, the
pages of a message it receives (appendix C), `mapPhysical`, and the kernel
stacks of its threads. The 2003 `__lmt_freeArea` left a dangling pointer
when it merged three areas: a 17-page `mmap` then failed with 59,000 free
pages (JOURNAL, "The free list that pointed into freed memory").

## B.6 The kernel heap: kmalloc and kfree

`kmalloc` (`dynalloc.c`, 2026) serves the kernel's small objects: process
descriptors, thread `tss_t`s, channels, messages, list elements. Every
block starts with an 8-byte header, a magic number and a size; the caller
gets the bytes after it.

| Request (with the header) | Comes from |
|---|---|
| up to 32, 64, 128, 256, 512, 1,024, 2,048 bytes | a free list per size class; an empty list takes one page from `__OS_askPages` and cuts it into blocks |
| more than 2,048 bytes | whole pages of their own, given back at `kfree` |

Blocks are returned zeroed. A page given to a size class stays with it.
The magic numbers (`MAGIC_SMALL`, `MAGIC_LARGE`, `MAGIC_FREE`) make a
double `kfree`, or the `kfree` of something that is not a block, a line on
the log with its caller's address, instead of a corrupt heap; a corrupt
free list is reported, dropped and started again.

**`HEAP_CHECK`**, a `#define` at the top of `dynalloc.c` (off by default),
fills freed blocks with `0xDB` and checks the pattern when a block is
given again ("block written after kfree"), records each block's caller,
and keeps `kheap_owners`: blocks in use by caller, to print from gdb. A
leak is a count that grows. Its first run found fields of a new `tss_t`
left unset, which zeroed fresh pages had hidden for twenty years (JOURNAL,
"A new kernel heap").

## B.7 Page table entries and the page fault

A page table entry has three bits for the system (9–11). MyNOS uses all
three:

| Bit | Name | Meaning |
|---|---|---|
| 11 (`0x800`) | `PF_LOGICAL_PRESENT` | reserved: no frame yet, one on the first access |
| 10 (`0x400`) | `PF_COW` | copy-on-write: shared, read-only until written |
| 9 (`0x200`) | `PF_SHARED` | shared on purpose: copy-on-write leaves it alone; in an entry not present, `PF_PAGER`: a page of the external pager (B.14) |

The page fault handler (`_page_fault_handler`, `mem.c`; vector 14, an
interrupt gate) decides by the entry of the faulting address:

```
  the external pager's entry, in user mode ──► wait for the pager (B.14)
  page table missing, or entry neither reserved nor copy-on-write
      ├─ fault in user mode ──────────────► the process ends (SIGSEGV)
      ├─ fault at copy_user's instruction ─► the copy returns -1 (B.10)
      ├─ kernel, on a user address ───────► the process ends
      └─ kernel, on a kernel address ─────► kernel panic
  no free physical page ──────────────────► kernel panic ("full memory!")
  PF_LOGICAL_PRESENT ─────────────────────► allocate on use
  PF_COW ─────────────────────────────────► copy on write
```

**Allocation on use.** `mmap` and most of the user stack only mark their
entries `PF_LOGICAL_PRESENT`. The first access takes a frame, maps it with
the flags the entry held, and zeroes it. Zeroing is not a courtesy: musl's
allocator checks that fresh memory from `mmap` reads as zero, as Linux
guarantees, and without it a frame showed whatever its previous owner had
left (JOURNAL, "Fresh pages were not zeroed"). So OCaml 5 can reserve
large areas at startup and pay only for the pages it touches.

**Copy-on-write.** `fork` and the sending of a message (appendix C) mark a
writable page `PF_COW` and read-only in both places, and count one more
reference on its frame. On a write fault, `__cowManager` looks at the
count: if this process is the last one holding the frame, it simply makes
the page writable again; otherwise it copies the page into a new frame
through a fixed kernel window (`0x3FBFE000`), maps the copy writable, and
drops one reference on the old frame.

**The kernel writes by the same rules.** The processor's write-protect
bit (CR0.WP) is on (since November 2026, mynos-bvz): in ring 0 too, a
write to a read-only page faults. So when a system call writes into a
copy-on-write page (a call that returns a value into a buffer the
process has just sent as a message), the handler copies the page first,
and the frame the receiver sees is left alone. Every page of the kernel
is mapped writable on purpose: the boot's identity mapping, the kernel
stacks, the page table windows (`start.asm`, `__OS_askPagesFrom`,
`createProcess`). A kernel write to a page that is read-only and not
copy-on-write is a bug: it is logged ("kernel write to a read-only
page") before the process ends or the kernel stops. Before WP was set,
those writes silently went through: into a frame shared with another
process, or into the RAM disk.

**Counting.** The handler counts the faults it resolves, for each process
and for the system since boot, by kind: allocated on use and copied on
write. `ps -f` lists them (system call 36, `mynos_faults`;
`Mynos.faults` in OCaml). A boot to the shell resolves about 8,000
faults of the first kind and 1,600 of the second; the graphical session
with a Terminal about 4,500 and 1,200 more; compiling a small program
with `ocamlc`, 4,700 and 1,000. `tests/bench/bench` measures what each
costs: under KVM about 0.9 µs for a page allocated on use and 1.2 µs for
a copy (3 µs until the kernel zeroed and copied pages four bytes at a
time, mynos-4d6).

## B.8 What the C library sees

musl calls the Linux interface (appendix D), and the kernel answers:

| Call | Number | What MyNOS does |
|---|---|---|
| `mmap` (old), `mmap2` | 90, 192 | `length` rounded up to pages, taken from the free list, reserved (allocated on use), user, writable. The address, `prot`, `flags`, `fd` and `offset` are ignored: memory is anonymous. `-ENOMEM` (-12) when there is no room |
| `munmap` | 91 | checks the range is inside the user area, gives it back to the free list, drops one reference on each frame |
| `mprotect` | 125 | accepted, does nothing |
| `brk` | 45 | not implemented: `-ENOSYS` (mynos-51c) |

Without `brk`, musl's `malloc` gets its memory from `mmap` and returns it
with `munmap`, far more often than dietlibc did: hence the bugs of B.5.

## B.9 Device memory: mapPhysical

`mapPhysical(phys, npages)` (native call 28, `io` privilege only) maps
`npages` of physical memory starting at `phys` into the caller, and
returns their address. `phys` must be page-aligned and beyond the end of
RAM, and the range must end below 4 GB: the call maps a device's memory,
never another process's. The pages are marked `PF_SHARED`, so that a fork
keeps them as they are, and since they are not RAM no reference count
ever touches them. `displayd` maps the graphics card's frame buffer this
way.

**The DMA area** (call 29, `dmaArea`, `io` only) is RAM for a device
that reads memory by itself: ISA DMA, which reaches only the first 16 MB
and whose transfers do not cross a 64 KB boundary. At boot, before any
allocation, `init_memory` chooses 64 KB on a 64 KB boundary below 16 MB
where nothing was loaded: first between the kernel's page directory and
its image (1 to 2 MB, kept but unused), else above 4 MB in pages still
free; the boot log says where. Its pages stay taken for ever. `dmaArea(1)`
returns its physical address, for the DMA controller; `dmaArea(0)` maps
it into the caller, one reference to each page, which the end of the
process drops, as for shared pages. `soundd` plays from it (appendix E).

**DMA memory for PCI devices** (call 39, `dmaAlloc`, `io` only) is the
same idea without ISA's limits: 1 to 4096 pages (16 MB) of RAM in one physical
piece, anywhere above 16 MB, zeroed and mapped into the caller, with
their physical address for the device. virtio's queues and buffers live
there (`vblkd`, appendix E). The pages are found in the physical memory
bitmap as a run of free ones, marked once each: the driver's mapping is
their only reference, so they go back to the free pages when the driver
ends, whatever the way it ends.

## B.10 Pointers from processes

The kernel must not trust a process's pointers: an address below 1 GB
would not even fault, being the kernel's own memory. Two mechanisms:

**`__mem_userArea(start, size)`** (`mem.c`) answers whether the kernel may
use `[start, start + size)` on the caller's behalf: no wrap-around; inside
`[0x40000000, 0xFFBF9000)` (`USER_AREA_START`, `USER_AREA_END`: the end is
the bottom of the first thread's kernel stack); and every page in it
present, reserved or copy-on-write, and a user page. The last test
excludes the kernel stacks of later threads, which live among the user
pages. `__mem_userString` and `__mem_userVector` extend it to a string
and to a NULL-terminated `argv`. Every system call that takes a pointer
checks it at entry; until it returns, nothing else in the kernel runs
(system calls run with interrupts off, under the big kernel lock on
x86-64's several processors). On x86-64, another thread of the process
may run on another processor meanwhile, and change or unmap the memory
the pointer names: the checked copies below fault safely if it does.

**`copy_to_user` and `copy_from_user`** cover the calls that block before
they write: `recv` waits for a message and then writes its description,
`wait4` waits for a child and then writes its status. Meanwhile another
thread of the process may have unmapped that memory. Both functions check
with `__mem_userArea`, then call `copy_user`, a few lines of assembly
around one `rep movsb` whose address is known (`copy_user_insn`). The page
fault handler, given the interrupted frame, sees a fault at that
instruction and resumes at `copy_user_fault` instead, and `copy_user`
returns -1:

```
  recv: check ─► wait ─► copy_to_user ─► rep movsb ──── fault ────┐
                                                                  ▼
        the call fails,  ◄── copy_user_fault: ◄── page fault handler:
        the process goes on     return -1         eip == copy_user_insn?
                                                  then eip ← copy_user_fault
```

A fault that is legitimate there (a page allocated on use) is served
first; only a fault that would have ended the process becomes an
error. It is Linux's exception table, with one entry. Today `recv`,
`wait4`, `trace`, `processes`, `faults`, the pager's `next` and
`procstat` (calls 32 to 38) use it; the other
calls rely on the check at entry.

## B.11 Another process's memory

Mapping a message into its receiver, or freeing a process that ended,
touches an address space that is not loaded. `externalmem.c`
does it through one kernel page, at `0x3FBFF000`, whose entry it points
at any physical frame (`__mem_mapFrame`, `__mem_unmapFrame`). To change
an entry of process `p`, it maps `p`'s page directory there, reads the
frame of the page table, maps that, and writes; a missing page table is
allocated on the way. One window means one frame at a time, which is
enough with interrupts off.

`__OS_mapPagesTo(pid, page, n, mode)` maps `n` pages of the current
process into `pid`, at an area taken from `pid`'s free list, and returns
its first page. Per page, by the sender's entry:

| Sender's page | `mode` without `MYNOS_IPC_SHARED` | with `MYNOS_IPC_SHARED` |
|---|---|---|
| reserved, no frame | the receiver gets a reserved page (zeros) | a frame is allocated first |
| `PF_SHARED` | the receiver gets a private copy | shared |
| writable | both copy-on-write | made private if copy-on-write, then marked `PF_SHARED` in both |
| read-only | the same frame, read-only | the same frame, read-only |

## B.12 Building and freeing an address space

**spawn** (`spawnProcess`, `process.c`) builds the page directory, the
mirror, the page tables, the program's frames, the top page of the stack,
the kernel stack and the process information in the kernel's linear
space, where it can write them, then maps the same frames into the new
directory. At the end it drops the kernel's own mappings ("aliases") of
those frames: each frame then belongs to the process alone. A new process
running `ocamlrun` therefore costs its whole image in fresh frames: the
text of a program is not shared between the processes that run it.

**fork** (`_linux_syscall_fork`, `linux_syscalls.c`) copies the directory
and every user page table; user pages become copy-on-write, with one more
reference each; supervisor pages in user space (kernel stacks) are copied
at once (the comment dates from before CR0.WP was set; copying them is
still right, a kernel stack is the thread's own). The free list is
copied too.

**A process that ends** cannot free its memory itself: it is running on
its kernel stack, with its page directory in CR3 (appendix A.9). It joins
a list of zombies; `reapZombies`, called at the start of every `sched()`
and by `wait4`, frees every zombie except the current process:

```
  freeAddressSpace(z)
    for each directory entry 256 … 1022 (through the window):
        skip it if absent, or if it is one of the RAM disk's page tables
        for each present entry of that page table:
            pmem_unset(frame)          shared and copy-on-write pages just
        pmem_unset(the page table)     lose a reference
    pmem_unset(the page directory)     (unless already met as a page)
    pmem_unset(the mirror)
  then: kfree its tss_t's (live and exited threads), free its lmemmap
```

The kernel's page tables (entries 0–255) are skipped because they are not
the process's, and the RAM disk's because they are everybody's. The
descriptor and the pid remain until the parent collects the status.

## B.13 Limits

| What | Value | Where |
|---|---|---|
| page size | 4 KB | `PAGE_SIZE`, `mem.h` |
| kernel linear space | 1 GB, page directory entries 0–255 | `KLAST_PAGE_DIR_ENTRY_USED`, `start.asm` |
| user space | `0x40000000`–`0xFFBF9000` | `USER_AREA_START`/`END`, `mem.h` |
| program image | 4 MB, at `0x40000000` | `spawnProcess` |
| RAM disk | 64 MB (16 page tables), at `0x40400000` | `RAMDISK_MAXPTS`, `process.c` |
| user stack | 256 pages (1 MB) | `USER_STACK_NPAGES`, `global.h` |
| kernel stack per thread | 4 pages | `KERNEL_STACK_NPAGES`, `global.h` |
| kernel heap classes | 32 B – 2 KB (header included), pages above | `class_size`, `dynalloc.c` |
| physical memory | the RAM in one piece above 1 MB that multiboot reports (`mem_upper`): with QEMU, up to 3583 MB | `start.asm`, `init_memory` |

## B.14 The external pager

The kernel resolves every fault of B.7 by itself, with one exception
(since November 2026, mynos-vzp): pages a process in user space, the
**pager**, has been given. It decides what they hold; the kernel only
moves them. This is Mach's external pager and L4's pager, kept to the
small part that a microkernel needs: the kernel keeps the page tables,
the frames and every fault of its own regions, and only the regions
given to the pager wait for it.

**The entries.** An entry that is not present is ignored by the
processor, but for its bit 0. One with bit 9 set (`PF_PAGER`, the same
bit as `PF_SHARED`, which is only used on present pages) and neither
`PF_LOGICAL_PRESENT` nor `PF_COW` belongs to the pager: bits 12–31 hold
its **token**, the number the pager names that page by; `PF_READWRITE`
says whether the region may be written.

**The calls** (native 37, `mynos_pager*` in `mynos.h`; `Pager` in OCaml):

| Operation | Who | What it does |
|---|---|---|
| `register` | a process with the `io` privilege | becomes the pager (one at a time); gets a semaphore of its own |
| `region (pid, npages, token, writable)` | the pager | reserves `npages` of `pid`'s linear space, entries marked with tokens `token`, `token+1`...: the first page's address |
| `next` | the pager | the next page waited for: pid, address, token, write |
| `supply (pid, address, src)` | the pager | its own page at `src` moves (not copied) to `pid` at that address; its address gets a fresh page at its next use. `src` 0: no page |
| `query (pid, address)` | the pager | a page it gave: 0 if not there any more, else 1, 2 if used since the last query, 4 if written since the last copy; its use forgotten (the processor's Accessed bit) |
| `evict (pid, address, dst, token, writable)` | the pager | that page taken back: its frame moves to the pager's page at `dst`, and `pid`'s entry is the pager's again, with `token`: its next use faults to the pager |
| `copy (pid, address, dst)` | the pager | that page copied into the pager's at `dst`, its writes forgotten (the Dirty bit) |

**A fault** on a pager's entry, in user mode (`mem/pager.c`):

```
  a write to a read-only region, or no pager ──► the process ends (SIGSEGV)
  the page already asked for (another thread) ─► wait with it
  otherwise ─► an entry in the table of waits (64), V the pager's semaphore,
               wait on the entry's semaphore
  answered with a page ──► the instruction runs again, and finds it
  answered with none ────► the process ends
```

The pager is told as a driver is told of its IRQ (A.7): the kernel does
V on its semaphore, and the pager asks `next`. The waiting thread is
blocked as on a semaphore of its own (`__OS_sem_P`); so the fault
handler, which until then never waited, must keep nothing in fixed
places: its entry saved EAX at address 0, which a second thread's fault
would have overwritten, and saves it on the thread's kernel stack now.

**What the kernel does not wait for.** A system call that touches a
page the pager has not given yet fails as for an invalid pointer
(`copy_user`), and a message cannot carry one (`mapPagesTo` refuses
it): the kernel never waits for a process in a call. `fork` copies the
entries as they are: the child's faults reach the pager with the
child's pid and the same tokens. `munmap` frees a region like any
other area.

**When the pager ends,** every thread waiting for it ends with its
process; its regions' pages already given stay. When a waiting
process ends, its waits are freed.

`query`, `evict` and `copy` refuse a page that is not the process's
alone (copy-on-write after a `fork`, shared): the pager then leaves it
where it is. They act on another process, which on the i386 is not
running while the pager is; on x86-64 it may run on another processor,
and the change of its entry is told to it (a TLB shootdown, appendix
A.4).

**pagerd** (`services/pager/pagerd.ml`, started by `init` as a driver)
is the pager of MyNOS (appendix E.16). It gives:

- **files mapped** (`Pager.map_file` in OCaml, `mmap` of a file in C,
  `mapcat` in the shell): read-only; **shared**, whose changes go back
  to the file (`sync`, `unmap`, C's `msync` and `munmap`); or
  **private**, whose changes stay the program's. Each page is read from
  the file when first touched.
- **memory** (`Pager.alloc`): pages of zeros, which may go to the disk.

It keeps at most a **budget** of its pages in memory, all its regions
together (2048 by default, `Pager.set_budget`). To give one more, it
takes one back, chosen by the **clock**: the pages in the order they
were given; one used since the last look (`query`) gets a second chance
and goes to the back. A page taken back goes where it can be read
again, if it was changed: memory and a private mapping's pages to the
**swap**, `/disk/swap`, in slots of 4 KB; a shared mapping's pages to
their file; a page never written, nowhere (it reads again as zeros, or
as the file has it).

```
  a fault on its page ─► pagerd: room?  no ─► the clock: query the oldest
                                               used ─► to the back
                                               not ─► evict ─► swap or file
                         read it: the swap, the file, or zeros ─► supply
```

The swap is pagerd's: only its regions go there. The rest of memory
(programs, heaps, stacks) stays the kernel's, and a machine out of
frames still stops (B.15). Measured under KVM (`tests/bench/bench`,
`mapcat -t`): a fault resolved by the kernel costs about 1 µs, an IPC
round trip between two processes 5.5 µs; a page given by `pagerd`, read
from the RAM disk, 10 to 20 µs.

> **THE MyNOS FACTOR — A page fault is a message.** With the pager, the
> most hidden event of a virtual memory becomes a request between two
> processes, which the event recorder sees (`TRACE_FAULT`, `TRACE_PAGE`)
> and a program in OCaml answers.

## B.15 Known limits

- **No swap for the kernel's memory.** When physical memory runs out,
  an allocation on use or a copy-on-write stops the system ("full
  memory!"). Only the memory of the external pager (B.14) goes to the
  disk; the kernel asking it for frames when it has none is not done.
- A shared mapping's changes reach the file at `sync` or `unmap` (or
  when pagerd takes the page back): a program that ends without either
  loses those still in memory.
- `__mem_userArea` checks that a pointer is in the process's user pages,
  not that a page it accepts for writing is writable: a system call
  writing into the RAM disk now ends the process (the write faults)
  instead of returning an error.
- `munmap` checks only that its range is in the user area, and (since
  November 2026, mynos-q5b) that it does not touch the RAM disk's shared
  page tables; it used to remove the RAM disk from every process.
- A program's segments are all mapped writable: the text is not
  protected. `mprotect` is accepted and does nothing; `mmap` ignores its
  address and flags (mynos-51c).
- Program text is not shared between processes running the same program
  (B.12).
- One processor (mynos-awn): the single kernel window of B.11 assumes
  nothing else runs in the kernel.
- **Less than 4 GB of RAM.** Without PAE, physical addresses have 32
  bits: 4 GB, which RAM shares with the devices (the frame buffer at
  `0xFD000000`, the APICs, the BIOS). The kernel's tables could count a
  frame anywhere in those 4 GB, but it takes the RAM from multiboot's
  `mem_upper`, the part in one piece above 1 MB, not from its memory
  map: RAM past a hole, or remapped above 4 GB, is not used. With QEMU:
  up to `-m 3583` all of it; from `-m 3584`, QEMU keeps 3 GB below the
  devices and puts the rest above 4 GB, and MyNOS uses 3 GB.

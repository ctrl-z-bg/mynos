# Appendix B. Memory

The memory code of the kernel lives in `mynos-core/kernel/mem/`: about
1,500 lines of C (license headers included) in five files. `physicalmem.c`
counts physical pages, `mem.c` builds and edits page tables and handles
page faults, `lmemtrack.c` keeps each process's free linear space,
`dynalloc.c` is the kernel's `kmalloc`, and `externalmem.c` reaches into
the address space of a process other than the current one. Building and
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
             │ PDE 255 (see B.14)              │
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

**The kernel's gigabyte.** Page directory entries 0–255 (`KLAST_PAGE_DIR_ENTRY_USED`
is 255 in `start.asm`) are copied into every new page directory. At boot
`init_memory` (`mem.c`) allocates a page table for every one of them, 254
pages that may be empty for ever. The point is that the kernel never adds
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
| 9 (`0x200`) | `PF_SHARED` | shared on purpose: copy-on-write leaves it alone |

The page fault handler (`_page_fault_handler`, `mem.c`; vector 14, an
interrupt gate) decides by the entry of the faulting address:

```
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
checks it at entry; until it returns, nothing else runs (system calls run
with interrupts off, on one processor).

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
`wait4`, `trace` and `processes` (calls 32 and 33) use it; the other
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
at once, because, as its comment says, the processor does not check the
read-only bit in ring 0 (B.14). The free list is copied too.

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
| physical memory | what multiboot reports, up to 4 GB | `init_memory` |

## B.14 Known limits

- **No swap.** When physical memory runs out, an allocation on use or a
  copy-on-write stops the system ("full memory!"). Paging to disk through
  an external pager is mynos-vzp.
- **The processor's write-protect bit (CR0.WP) is not set** (`start.asm`
  sets only paging). In ring 0 the read-only bit is ignored, so the
  kernel's own writes into a user page do not fault: a `copy_to_user`
  into a copy-on-write page writes the shared frame, and into the RAM
  disk writes the RAM disk. `__mem_userArea` does not check that a page
  it accepts for writing is writable (mynos-bvz).
- **`munmap` drops a reference on any user page**, including the RAM
  disk's, whose page tables are shared: a process that unmaps them
  removes them from every process and frees their frames (mynos-q5b).
- A program's segments are all mapped writable: the text is not
  protected. `mprotect` is accepted and does nothing; `mmap` ignores its
  address and flags (mynos-51c).
- Program text is not shared between processes running the same program
  (B.12).
- Directory entry 255, the last of the kernel's gigabyte, is a
  placeholder that points to physical page 0 (`init_memory`). Its
  "entries" are whatever low memory holds (mynos-vm8).
- A message too large for the receiver's free linear space is mapped at
  page 1, inside the kernel's page table, instead of failing (mynos-py9).
- One processor (mynos-awn): the single kernel window of B.11 and the
  page fault handler, which saves EAX at address 0, assume nothing else
  runs in the kernel.

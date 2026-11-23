# Decision: the external pager

- **Issue:** mynos-vzp (phase 0: mynos-0ho; mynos-4d6 on the way)
- **Date:** 2026-11-23
- **Status:** accepted (2026-11-23: phases 0 to 3 of the plan: measure,
  the kernel's prerequisites, the mechanism, files mapped by `pagerd`;
  then phases 4 and 5: memory that goes to a swap, writable mappings);
  implemented the same day. The kernel asking `pagerd` for frames (a
  swap for all of memory) is left out, by choice.

## The question

Should the memory manager stay in the microkernel, or move out of it?
The processor answers part of it: only ring 0 writes CR3 and the page
tables, and the page fault reaches the kernel. Even L4 and seL4 keep
that. What can move out is the policy: what a page holds, and when.

## Choices

### 1. Mechanism in, policy out, for some regions only

The kernel keeps every page it manages today (programs, heaps, stacks,
copy-on-write) and its speed; a process may hand some regions of memory
to a pager in user space, whose faults wait for it. Moving all of it
out (seL4's untyped memory, an exokernel's library systems) would mean
writing again the kernel of 2002, which needed no correction of its
design, for little gain on one processor and QEMU's ample memory.

A consequence: the pager's own memory, the file system's and the disk
driver's are never paged, since nobody gives them to the pager. L4
needs sigma0 for that, and swap needs care not to deadlock: here both
come for free.

### 2. Measured first (mynos-0ho)

`tests/bench/bench` and the kernel's new fault counters (`ps -f`),
under KVM: a fault the kernel resolves cost 2.9 µs (1 µs after
mynos-4d6), an IPC round trip between processes 5.5 µs, 6.1 µs with a
page; a 4 KB read from a file service about 60 µs. A fault answered by
a pager costs a few microseconds more than one the kernel resolves, and
only in the regions given to it. A boot to the shell resolves about
8,000 faults, compiling a small program 4,700.

### 3. Told like a driver, not over a channel

The kernel tells the pager as it tells a driver of its IRQ: V on a
semaphore the pager waits on; the pager then asks which page
(`next`) and answers (`supply`). No message buffers on the fault's
path, and nothing the kernel must allocate per fault but an entry of a
fixed table (64) and a semaphore.

### 4. A token in the entry

An entry that is not present is ignored by the processor but for its
bit 0: bit 9 marks it the pager's, bits 12-31 hold a token the pager
chose. `fork` copies those entries as they are, and the child's faults
reach the pager with the same tokens: the pager answers whoever asks.

### 5. The kernel never waits in a system call

A call that touches a page not yet given fails as for an invalid
pointer, and a message cannot carry one. Waiting there would let a
pager hold a kernel lock's owner; a review of the locks held during
`copy_user` is the condition for allowing it.

### 6. The page moves, it is not copied

`supply` moves the pager's frame into the waiting process and leaves
the pager a fresh page at that address: no copy in the kernel, and the
pager can reuse one buffer.

### 7. pagerd: files, read-only

The first pager maps files (`Pager.map_file`, `mapcat`), read-only,
each page read from the file when first touched. In OCaml, a mapping is
a Bigarray over the region; addresses go as page numbers, since OCaml's
integers have 31 bits.

### 8. Taking a page back: query, evict, copy

Phases 4 and 5 add three operations, all on a page the pager gave and
the process holds alone: `query` reads and clears the processor's
Accessed bit (and reports Dirty), `evict` moves the frame back to the
pager and makes the entry the pager's again, with a token, `copy`
copies the page and clears Dirty. The policy is all in `pagerd`: a
budget of resident pages, the clock (second chance on Accessed), the
swap in a file of `/disk/swap`, write-back of shared mappings at
`sync`, `unmap` and eviction. A page shared after a `fork` is refused
by the three: the pager leaves it in memory, where the kernel's
copy-on-write handles it.

### 9. Only pagerd's memory goes to the disk

The swap holds the pages of `pagerd`'s regions (`Pager.alloc`, private
mappings), not the kernel's memory: a heap, a stack or a program still
cannot be paged out, and a machine out of frames still stops. Making
the kernel ask the pager for frames would put `pagerd` (and the file
services it reads through) on the path of every allocation: left out,
by choice, for now.

### 10. C's mmap of a file through pagerd

libmynos keeps the path of each open file and maps a file by asking
`pagerd` (pager/1, the same protocol as OCaml): read-only, `MAP_SHARED`
(changes to the file at `msync`, `munmap`) or `MAP_PRIVATE`. Anonymous
memory still comes from the kernel's `mmap`.

## What it does not do

No swap for the kernel's memory, no pages given before they are asked
for, no fault waiting inside a system call, no write-back of a shared
mapping when its program ends without `sync` or `unmap`.

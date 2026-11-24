# 23. Writing a driver

In MyNOS a driver is an ordinary process with one privilege more than
others: it may talk to hardware. It reads and writes the device's I/O
ports, waits for its interrupts on a semaphore, and offers the device to
other programs as a service, through IPC like any other. This chapter
shows how to write one in OCaml: the privilege (23.1), port I/O (23.2),
interrupts (23.3), device memory (23.4), serving (23.5), then the disk
driver `ata` as the worked example (23.6), a complete driver with an
interrupt (23.7), and how a driver is started (23.8). The kernel's side
is in appendix A.7.

## 23.1 The `io` privilege

```
     process with io                        kernel
  ┌──────────────────────────┐          ┌────────────────────────────┐
  │ Mynos.inb / outb ────────┼──────────┼─► not the kernel: IOPL 3,  │──► device
  │                          │          │   the CPU lets it through  │    ports
  │ Mynos.driver_register ───┼─ call 10 ┼─► the IRQ line is ours,    │
  │      "rtc" 8  → sem      │          │   a semaphore for it       │
  │ Mynos.sem_p sem  ◄───────┼──── V ───┼── IRQ 8: EOI to the PICs,  │◄── device
  │   (waits)                │          │   V on the semaphore       │    interrupt
  │ Ipc serve "rtc" ◄────────┼── IPC ───┼── requests of clients      │
  └──────────────────────────┘          └────────────────────────────┘
```

A process with the **`io` privilege** runs with the processor's I/O
privilege level at 3, so the `in` and `out` instructions work in it
directly, with no system call; it may take interrupt lines
(`driverRegister`, call 10) and map device memory (`mapPhysical`, call
28). Who has it:

- the boot modules, which GRUB (or QEMU) loads: the registry, memrofs,
  and `ocamlrun` running `init`;
- the programs of `init.rc`'s `driver` lines (23.8);
- a child started with it by a process that has it:
  `Mynos.spawn ~io:true` (in C, `mynos_spawnPriv(..., MYNOS_PRIV_IO)`).
  A process without it that asks gets `Mynos.Error (_, deny)`.

A process without it that executes `in` or `out` takes a protection
fault and ends; `driver_register` and `mapPhysical` answer `deny`.
`sh` and what it starts have no privilege, so a driver cannot be
started from the shell: see 23.8.

A service learns whether its caller has the privilege from the kernel
(`Ipc.caller`'s `io`, or `Mynos.process_info`): a driver may keep some
requests for other drivers.

## 23.2 Port I/O

```ocaml
val inb : int -> int                 val outb : int -> int -> unit
val inw : int -> int                 val outw : int -> int -> unit
val insw : int -> int -> string      val outsw : int -> string -> unit
```

`Mynos.inb port` reads a byte, `outb port v` writes one (`outb port
byte`: the port first); `inw` and `outw` do the same with 16 bits.
`insw port n` reads `n` 16-bit words from one port into a string of `2n`
bytes, the low byte of each word first, which is how a disk sector
arrives (`insw 0x1F0 256`); `outsw port s` writes a string the same way.
Each is one instruction, compiled into the runtime (`mynos_stubs.c`): no
system call, no message. In C, libmynos has `inportb` and `outportb`.

The PC's real-time clock is a good first device: two ports, an index
(`0x70`) and a data port (`0x71`), and registers that hold the time in
BCD unless register B says binary:

```ocaml
let index = 0x70 and data = 0x71
let get r = Mynos.outb index r; Mynos.inb data
let set r v = Mynos.outb index r; Mynos.outb data v
let bcd v = (v land 0x0F) + 10 * (v lsr 4)

let time () =
  while get 0x0A land 0x80 <> 0 do () done;       (* an update in progress *)
  let binary = get 0x0B land 0x04 <> 0 in
  let read r = let v = get r in if binary then v else bcd v in
  (read 0x04, read 0x02, read 0x00)               (* hours, minutes, seconds *)
```

The kernel itself reads this clock once, at boot, for `Mynos.time`.

## 23.3 Interrupts

```ocaml
val driver_register : string -> int -> int     (* name, IRQ line: a semaphore *)
val enable_irq : int -> unit
val sem_p : int -> unit
```

`Mynos.driver_register name irq` makes the calling process the driver
of line `irq` and returns a semaphore. The line stays masked until
`Mynos.enable_irq irq`. From then on, at each interrupt, the kernel
acknowledges the interrupt controllers (the EOI) and does a `V` on the
semaphore; the driver waits for it with `Mynos.sem_p`, then talks to its
device:

```ocaml
let sem = Mynos.driver_register "rtc" 8 in
(* ... set the device up to interrupt ... *)
Mynos.enable_irq 8;
while true do
  Mynos.sem_p sem;                 (* the kernel's V: an interrupt came *)
  ignore (get 0x0C);               (* the device's own acknowledgement *)
  ...
done
```

Two acknowledgements are involved, and the driver owes only one: the
interrupt controllers' is the kernel's, the **device's** is the
driver's. A device that is not told its interrupt was seen (the clock's
register C must be read, the NE2000's status register written back)
does not interrupt again.

The rules (`kernel/irq.c`): lines 0 (the timer) and 2 (the cascade) are
the kernel's (`invalid`); a line another live driver holds is `busy`;
`enable_irq` and `disable_irq` act only on the caller's own lines; when a
driver ends, its lines are masked and freed, so a restarted driver can
take them again. If the processor was idle when the interrupt came, the
driver runs at once rather than at the next tick.

`sem_p` blocks only the calling thread, and releases the OCaml runtime
lock while it waits. A driver that also serves requests therefore waits
for interrupts in a domain (or a thread) of its own, as 23.7 does; `netd`,
in C, does the same with a pthread.

## 23.4 Device memory

A device whose registers or buffer are memory (a frame buffer) is mapped
with `mapPhysical`, in C:

```c
void * fb = mynos_mapPhysical(0xFD000000, npages);   /* NULL on error */
```

maps `npages` pages from a physical address into the caller and returns
their address. The address must be page-aligned and beyond the
machine's RAM: device memory, never another process's pages. `displayd` maps the
Bochs VGA's frame buffer so (its address is the card's first PCI memory
region, read through ports `0xCF8`/`0xCFC`). The OCaml library has no
binding for it: a driver in OCaml uses ports, as `ata` does, or the
pixels of a window (chapter 20), which are shared memory already.

## 23.5 A driver is a service

What makes a driver useful is the protocol it serves. Typed IPC (chapter
17, appendix E.2) does it in a few lines: a GADT of requests, the
protocol's description, and `Ipc.Make (P).serve name handler`, which
registers the name and answers one request at a time, forever. A block
device need not even define its protocol: module `Block` is
**block/1**, and `Block.serve name handler` serves it.

The rules of every service apply (E.1): refuse a malformed request with
an error reply and go on; check every argument before touching the
device; never trust a request to name its sender. An exception raised by
the handler is the reply: the client gets `Ipc.Remote_error (service,
message)`.

## 23.6 The worked example: the disk driver in OCaml

`services/ata/ata.ml` (197 lines) drives the first ATA disk, the master
of the primary IDE channel, in PIO mode, and serves it as `ata0`. It is
started from `init.rc` as `driver ata.byte`. It reads in four parts.

**The controller's registers** (`ata.ml:17-30`) are ports `0x1F0`–
`0x1F7` and `0x3F6`:

| Port | Read | Written |
|---|---|---|
| `0x1F0` | data (16 bits) | data |
| `0x1F1` | error | |
| `0x1F2`–`0x1F5` | | sector count, LBA bits 0–23 |
| `0x1F6` | | drive and LBA bits 24–27 (`0xE0` = master, LBA) |
| `0x1F7` | status: `BSY` 0x80, `DF` 0x20, `DRQ` 0x08, `ERR` 0x01 | command: `0x20` read, `0x30` write, `0xC5` write multiple, `0xE7` flush, `0xEC` identify |
| `0x3F6` | alternate status | control (`0x02`: no interrupts) |

**Waiting** (`ata.ml:40-56`). The controller needs 400 ns after a
command before its status is meaningful: `delay` reads the alternate
status four times. `wait_not_busy` polls the status until `BSY` clears,
and gives up after ten million reads; `wait_data` then requires `DRQ`
(data ready) and turns `ERR` or `DF` into the exception `Device` with
the error register's value:

```ocaml
let wait_data () =
  let s = wait_not_busy () in
  if s land (st_err lor st_df) <> 0 then
    raise (Device (Printf.sprintf "error %02x" (Mynos.inb error)))
  else if s land st_drq = 0 then raise (Device "no data")
```

**Sectors** (`ata.ml:58-95`). `select` writes the drive, the count and
the 28-bit address; reading is a command and, for each sector, a wait
and 256 words:

```ocaml
let read_sectors lba count =
  select lba count;
  Mynos.outb command cmd_read;
  delay ();
  String.concat ""
    (List.init count (fun _ -> wait_data (); Mynos.insw data 256))
```

Writing sends the sectors with `outsw`, up to 16 for each `DRQ` when
the disk takes WRITE MULTIPLE (`0xC5`). The drive's cache is flushed
(`0xE7`) half a second after the last write, by a second domain, and on
a `Flush` request, which `init` sends before the power goes: a flush
after every write made QEMU sync the disk's file each time.
The driver turns the controller's interrupts off and polls: in PIO the
processor copies every word itself anyway, and a disk request in QEMU is
answered in a millisecond (22.4).

**Identify** (`ata.ml:117-147`) asks the disk its size. A status of 0 or
`0xFF` means no device on the channel; a signature in the LBA registers
means an ATAPI device (a CD), not a disk; otherwise the 256 words of
`IDENTIFY` come: words 60–61 are the number of sectors addressable
with LBA28, word 47 the largest block WRITE MULTIPLE takes (set with
`0xC6`).

**The service** (`ata.ml:151-179`) is a `Block.handler`: a record with
one polymorphic field, `handle`, whose type ties each request to its
reply (`Info` returns an `int`, `Read` a `string`, `Write` and `Flush` a
`unit`); the lock keeps the ports to one domain at a time:

```ocaml
let handle sectors : Block.handler = {
  Block.handle = fun (type a) _caller (r : a Block.request) : a ->
    let check lba count =
      if count < 1 || count > Block.max_count then
        invalid_arg (Printf.sprintf "%d sectors: 1 to %d per request" count
                       Block.max_count);
      if lba < 0 || lba + count > sectors then
        invalid_arg (Printf.sprintf "sectors %d..%d: the disk has %d" lba
                       (lba + count - 1) sectors) in
    let device what f =
      try f () with Device e ->
        Mynos.log (Printf.sprintf "ata: %s: %s" what e);
        failwith ("I/O error: " ^ e) in
    Mutex.protect lock @@ fun () : a ->
    match r with
    | Block.Info -> sectors
    | Block.Flush -> device "flush" flush_now
    | Block.Read (lba, count) ->
      check lba count;
      device "read" (fun () -> read_sectors lba count)
    | Block.Write (lba, bytes) ->
      if String.length bytes mod Block.sector <> 0 then
        invalid_arg "write: not a whole number of sectors";
      let count = String.length bytes / Block.sector in
      check lba count;
      device "write" (fun () -> write_sectors lba count bytes);
      dirty := true;
      last_write := Mynos.uptime ()
}
```

Every request is checked before a port is touched: a count outside 1 to
32, an address beyond the disk, a write of a partial sector are refused
with `invalid_arg`, whose message is the client's error. A controller
error is logged and becomes `I/O error: ...`. The program's main
(`ata.ml:181-197`) is short: without the `io` privilege it refuses to
run; identify; without a disk, log it and end with status 0 (so `init`
does not restart it); with one, log its size, start the flushing domain
and `Block.serve "ata0" (handle sectors)`.

A client needs only `Block`:

```ocaml
let () =
  let d = Block.connect () in
  Printf.printf "ata0: %d sectors of %d bytes\n" (Block.sectors d) Block.sector;
  let s = Block.call d (Block.Read (0, 1)) in
  Printf.printf "sector 0: %S..., ends with %02X %02X\n"
    (String.sub s 0 11) (Char.code s.[510]) (Char.code s.[511]);
  match Block.call d (Block.Read (Block.sectors d, 1)) with
  | _ -> ()
  | exception Ipc.Remote_error (service, m) -> Printf.printf "%s: %s\n" service m
```

On a 16 MB FAT16 image made by `mkfs.fat`:

```
ata0: 32768 sectors of 512 bytes
sector 0: "\235<\144mkfs.fat"..., ends with 55 AA
ata0: sectors 32768..32768: the disk has 32768
```

> **THE MyNOS FACTOR — A disk driver written in OCaml.**
> `ata` is 197 lines of OCaml bytecode, run by the same `ocamlrun` as
> the shell. It touches the hardware through four primitives, `inb`,
> `outb`, `insw` and `outsw`, each one instruction; everything else (the
> checks, the errors, the protocol) is typed code, and the type checker
> sees to it that a `Read` is answered with bytes and an `Info` with a
> number. A bug in it ends a process, which `init` starts again; the
> kernel and the file system above it go on. Its requests are visible to
> the recorder as `block/1 Read (308, 4)`, and a language model can call
> them, from their description, as `ata0_read`.

## 23.7 A complete driver with an interrupt: the clock

`ata` polls. `rtc` below uses an interrupt: it serves the time of day
from the CMOS clock, and counts the clock's periodic interrupts (IRQ 8,
set to 2 Hz), in a protocol of its own, `rtc/1`:

```ocaml
(* rtc: a driver for the PC's real-time clock (the MC146818 in the
   CMOS), served as "rtc" with protocol "rtc/1": the time of day, read
   through ports 0x70 and 0x71, and the number of its periodic
   interrupts (IRQ 8, twice a second) since the driver started. *)

(* ---- the device ---- *)

let index = 0x70 and data = 0x71

let get r = Mynos.outb index r; Mynos.inb data
let set r v = Mynos.outb index r; Mynos.outb data v

let bcd v = (v land 0x0F) + 10 * (v lsr 4)

let time () =
  while get 0x0A land 0x80 <> 0 do () done;       (* an update in progress *)
  let binary = get 0x0B land 0x04 <> 0 in
  let read r = let v = get r in if binary then v else bcd v in
  (read 0x04, read 0x02, read 0x00)               (* hours, minutes, seconds *)

(* ---- the protocol ---- *)

type _ request =
  | Time : (int * int * int) request
  | Ticks : int request

module Protocol = struct
  let id = "rtc/1"
  let summary = "The real-time clock of the PC: the time, and its interrupts."
  let requests = Ipc.[
      request ~safe:true 0 "time" "The time of day (UTC): hours, minutes, seconds."
        Wire.unit Wire.(triple int int int);
      request ~safe:true 1 "ticks" "The clock's interrupts since the driver started."
        Wire.unit Wire.int ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    Wire.write w Wire.int (match r with Time -> 0 | Ticks -> 1)
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Time
    | 1 -> Request Ticks
    | n -> raise (Wire.Error (Printf.sprintf "rtc: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Time -> Wire.(triple int int int)
    | Ticks -> Wire.int
end

module I = Ipc.Make (Protocol)

(* ---- the driver ---- *)

let ticks = Atomic.make 0

let interrupts sem () =
  while true do
    Mynos.sem_p sem;                 (* the kernel's V: an interrupt came *)
    ignore (get 0x0C);               (* the device's own acknowledgement *)
    Atomic.incr ticks
  done

let () =
  let sem = Mynos.driver_register "rtc" 8 in
  set 0x0A ((get 0x0A land 0xF0) lor 15);    (* rate 15: 2 Hz *)
  set 0x0B (get 0x0B lor 0x40);              (* the periodic interrupt on *)
  ignore (get 0x0C);
  Mynos.enable_irq 8;
  ignore (Domain.spawn (interrupts sem));
  Mynos.log "rtc: service rtc, IRQ 8";
  I.serve "rtc" { I.handle = fun (type a) _caller (r : a request) : a ->
      match r with
      | Time -> time ()
      | Ticks -> Atomic.get ticks }
```

The order of `main` matters: take the line, set the device up, clear
any interrupt already pending (reading register C), and only then unmask
the line. The interrupts are counted in a second domain, while the first
serves; the count is an `Atomic`, read by one and written by the other.
The two time requests are marked safe, since they change nothing.

A client needs no OCaml types of the driver: the protocol describes
itself, and `Tools` (21.5) calls it from JSON. Started with
`Mynos.spawn ~io:true "ocamlrun" [| "ocamlrun"; "rtc.byte" |]` from a
boot module, then asked twice, two seconds apart:

```ocaml
let ts = Tools.of_service "rtc" in
Tools.call (Tools.find ts "rtc_time") "{}";      (* "[10,45,3]" *)
Tools.call (Tools.find ts "rtc_ticks") "{}";     (* "4" *)
Mynos.sleep 2.0;
Tools.call (Tools.find ts "rtc_ticks") "{}"      (* "8" *)
```

Four interrupts in two seconds: the clock runs at 2 Hz. A program in
OCaml writes a client with `Ipc.Make (Protocol)` and `I.call`, as for any
service, if it shares the protocol module.

## 23.8 Starting a driver

**From `init.rc`.** A line `driver PROGRAM ARGS...` starts the program
with the `io` privilege; a program ending in `.byte` runs on `ocamlrun`.
`init.rc` and the programs it names are on the RAM disk, which is
read-only: adding a driver means adding it to `system/init.rc` and to the
`FILES` of `system/Makefile`, and building the RAM disk again (appendix
H). The order of the lines is the order of starting: a driver goes
before the services that use it (`ata.byte` before `fatfs.byte`). With
the clock's driver of 23.7 added, the start of `init.rc` would read:

```
driver consoled
start tmpfs.byte
start clipboard.byte
driver ata.byte
driver rtc.byte
start fatfs.byte
```

`init` supervises its drivers like its services (E.3): a driver that
ends with status 0 decided to (no such device) and is left alone; one
that crashes or is killed is started again after 0.3 s, up to five times
a minute. A driver should therefore end with `exit 0` when its device is
missing, as `ata` and `netd` do, and fail loudly otherwise.

**From a test boot.** While a driver is being written, rebuilding the
system's RAM disk for each try is slow. The tests of `tools/run-tests.sh`
boot a RAM disk of their own whose `init.byte` is a test program: as a
boot module, `ocamlrun` has the `io` privilege, so that program can
start the driver with `Mynos.spawn ~io:true` and talk to it at once
(`tests/net/net_test.ml` starts `netd` so).

**Not from `sh`.** The shell has no privilege and cannot give one; a
driver typed at the prompt fails at its first `outb`.

## 23.9 Known limits

- The `io` privilege is all or nothing: every port, every free
  interrupt line (port by port is mynos-37p).
- DMA only through the kernel's one 64 KB area below 16 MB
  (`mynos_dmaArea`, in C). No `mapPhysical` in OCaml, no PCI helpers.
- Interrupt lines 0–15 of the two 8259s only; no APIC, no MSI.

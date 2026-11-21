(* ata: the driver of the first ATA (IDE) disk, written in OCaml. It runs
   as an ordinary MyNOS process: it talks to the controller through the I/O
   ports (init gives it the io privilege: "driver ata.byte" in init.rc) and serves sectors to other
   processes over IPC, as the block service "ata0".

   The disk is the master of the primary channel (ports 0x1F0-0x1F7 and
   0x3F6), addressed with 28-bit LBA, in PIO mode, polling the status
   register: the controller's interrupts are turned off. The drive's
   cache is flushed half a second after the last write (a domain watches),
   and when asked (Block.Flush: init, before the power goes), not after
   every write: each flush made QEMU sync the disk's file on the host.

   Protocol: Block.Protocol ("block/1", typed IPC: mynos-lib/ocaml/block.mli). *)

(* ---- the controller ---- *)

let data = 0x1F0
let error = 0x1F1
let sector_count = 0x1F2
let lba_low = 0x1F3
let lba_mid = 0x1F4
let lba_high = 0x1F5
let drive = 0x1F6
let command = 0x1F7               (* written: command; read: status *)
let control = 0x3F6               (* written: control; read: alternate status *)

let st_err = 0x01 and st_drq = 0x08 and st_df = 0x20 and st_bsy = 0x80

let cmd_read = 0x20 and cmd_write = 0x30 and cmd_flush = 0xE7
and cmd_identify = 0xEC and cmd_write_multiple = 0xC5 and cmd_set_multiple = 0xC6

(* sectors written per data block (WRITE MULTIPLE), if the disk can: the
   disk takes a block, and is waited for, once for several sectors (QEMU
   writes each block to its file at once, and waiting for each of 32
   sectors made a write 25 times slower than a read). 1: one at a time *)
let multiple = ref 1

exception Device of string

(* the 400 ns the controller needs after a command: four status reads *)
let delay () = for _ = 1 to 4 do ignore (Mynos.inb control) done

let wait_not_busy () =
  let rec loop n =
    let s = Mynos.inb command in
    if s land st_bsy = 0 then s
    else if n = 0 then raise (Device "timeout (busy)")
    else loop (n - 1) in
  loop 10_000_000

(* wait until the controller wants data (DRQ), or fails *)
let wait_data () =
  let s = wait_not_busy () in
  if s land (st_err lor st_df) <> 0 then
    raise (Device (Printf.sprintf "error %02x" (Mynos.inb error)))
  else if s land st_drq = 0 then raise (Device "no data")

let select lba count =
  ignore (wait_not_busy ());
  Mynos.outb drive (0xE0 lor ((lba lsr 24) land 0x0F));
  Mynos.outb sector_count (count land 0xFF);
  Mynos.outb lba_low (lba land 0xFF);
  Mynos.outb lba_mid ((lba lsr 8) land 0xFF);
  Mynos.outb lba_high ((lba lsr 16) land 0xFF)

let read_sectors lba count =
  select lba count;
  Mynos.outb command cmd_read;
  delay ();
  String.concat ""
    (List.init count (fun _ -> wait_data (); Mynos.insw data 256))

let write_sectors lba count bytes =
  select lba count;
  let m = !multiple in
  Mynos.outb command (if m > 1 then cmd_write_multiple else cmd_write);
  delay ();
  let i = ref 0 in
  while !i < count do
    let k = min m (count - !i) in
    wait_data ();
    Mynos.outsw data (String.sub bytes (512 * !i) (512 * k));
    i := !i + k
  done;
  ignore (wait_not_busy ())

(* the drive's cache to the disk: when the drive is ready, its result
   checked *)
let flush_cache () =
  ignore (wait_not_busy ());
  Mynos.outb command cmd_flush;
  delay ();
  let s = wait_not_busy () in
  if s land (st_err lor st_df) <> 0 then
    raise (Device (Printf.sprintf "flush: error %02x" (Mynos.inb error)))

(* the ports belong to one domain at a time: the requests' and the
   flusher's. [dirty]: written since the last flush *)
let lock = Mutex.create ()
let dirty = ref false and last_write = ref 0.

let flush_now () =
  if !dirty then begin
    dirty := false;
    flush_cache ()
  end

(* half a second without writes: the cache flushed *)
let flusher () =
  while true do
    Mynos.sleep 0.2;
    Mutex.protect lock (fun () ->
        if !dirty && Mynos.uptime () -. !last_write >= 0.5 then
          try flush_now () with Device e -> Mynos.log ("ata: flush: " ^ e))
  done

(* the number of sectors, or None if there is no ATA disk *)
let identify () =
  Mynos.outb control 0x02;                         (* no interrupts *)
  Mynos.outb drive 0xA0;
  delay ();
  List.iter (fun p -> Mynos.outb p 0) [ sector_count; lba_low; lba_mid; lba_high ];
  Mynos.outb command cmd_identify;
  delay ();
  let s = Mynos.inb command in
  if s = 0 || s = 0xFF then None          (* no device; 0xFF: nothing on the bus *)
  else begin
    ignore (wait_not_busy ());
    if Mynos.inb lba_mid <> 0 || Mynos.inb lba_high <> 0 then None (* ATAPI... *)
    else begin
      wait_data ();
      let id = Mynos.insw data 256 in
      let word n = Char.code id.[2 * n] lor (Char.code id.[2 * n + 1] lsl 8) in
      (* the largest block WRITE MULTIPLE takes (word 47), up to 16 *)
      let most = min 16 (word 47 land 0xFF) in
      if most >= 2 then begin
        ignore (wait_not_busy ());
        Mynos.outb drive 0xE0;
        Mynos.outb sector_count most;
        Mynos.outb command cmd_set_multiple;
        delay ();
        let s = wait_not_busy () in
        if s land (st_err lor st_df) = 0 then multiple := most
      end;
      Some (word 60 lor (word 61 lsl 16))           (* LBA28 sectors *)
    end
  end

(* ---- the block service (typed IPC: Block.Protocol) ---- *)

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

let () =
  (* a driver: without the io privilege (started from sh, not by a driver
     line of init.rc) the first port access would end it *)
  (match Mynos.process_info (Mynos.getpid ()) with
   | Some { Mynos.io = false; _ } ->
     prerr_endline "ata: a driver: init starts it (a driver line of init.rc)";
     exit 1
   | _ -> ());
  match (try identify () with Device _ -> None) with
  | None -> Mynos.log "ata: no ATA disk on the primary channel"
  | Some sectors ->
    Mynos.log (Printf.sprintf "ata: disk of %d sectors (%d MB), service ata0"
                 sectors (sectors / 2048));
    if !multiple > 1 then
      Mynos.log (Printf.sprintf "ata: writes %d sectors at a time (WRITE MULTIPLE)" !multiple);
    ignore (Domain.spawn flusher);
    Block.serve "ata0" (handle sectors)

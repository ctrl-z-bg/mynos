(* ata: the driver of the first ATA (IDE) disk, written in OCaml. It runs
   as an ordinary MyNOS process: it talks to the controller through the I/O
   ports (MyNOS gives processes I/O privilege) and serves sectors to other
   processes over IPC, as the block service "ata0".

   The disk is the master of the primary channel (ports 0x1F0-0x1F7 and
   0x3F6), addressed with 28-bit LBA, in PIO mode, polling the status
   register: the controller's interrupts are turned off.

   Protocol: mynos-lib/include/mynos_block.h. *)

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
and cmd_identify = 0xEC

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
  Mynos.outb command cmd_write;
  delay ();
  for i = 0 to count - 1 do
    wait_data ();
    Mynos.outsw data (String.sub bytes (512 * i) 512)
  done;
  Mynos.outb command cmd_flush;
  delay ();
  ignore (wait_not_busy ())

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
      Some (word 60 lor (word 61 lsl 16))           (* LBA28 sectors *)
    end
  end

(* ---- the block service ---- *)

let ok = 0 and invalid = 1 and io_error = 2
let max_count = 32

let reply ch status value =
  let b = Bytes.create 8 in
  Bytes.set_int32_le b 0 (Int32.of_int status);
  Bytes.set_int32_le b 4 (Int32.of_int value);
  Mynos.send ch (Bytes.to_string b)

let serve sectors ch =
  let req = Mynos.recv ~timeout:1.0 ch in
  let int_at i = Int32.to_int (String.get_int32_le req i) in
  if String.length req <> 12 then reply ch invalid 0
  else begin
    let typ = int_at 0 and lba = int_at 4 and count = int_at 8 in
    let in_range =
      count >= 1 && count <= max_count && lba >= 0 && lba + count <= sectors in
    match typ with
    | 0 -> reply ch ok sectors
    | 1 when in_range ->
      (match read_sectors lba count with
       | bytes -> reply ch ok count; Mynos.send ch bytes
       | exception Device e ->
         Mynos.log ("ata: read: " ^ e); reply ch io_error 0)
    | 2 ->
      (* the data follows the request: take it before replying *)
      let bytes = Mynos.recv ~timeout:1.0 ch in
      if not in_range || String.length bytes <> 512 * count then
        reply ch invalid 0
      else (match write_sectors lba count bytes with
          | () -> reply ch ok count
          | exception Device e ->
            Mynos.log ("ata: write: " ^ e); reply ch io_error 0)
    | _ -> reply ch invalid 0
  end

let () =
  match (try identify () with Device _ -> None) with
  | None -> Mynos.log "ata: no ATA disk on the primary channel"
  | Some sectors ->
    let port = Mynos.register "ata0" in
    Mynos.log (Printf.sprintf "ata: disk of %d sectors (%d MB), service ata0"
                 sectors (sectors / 2048));
    while true do
      let ch = Mynos.listen port in
      (try serve sectors ch
       with Mynos.Error (fn, code) ->
         Mynos.log (Printf.sprintf "ata: %s: %s" fn (Mynos.error_name code)));
      (try Mynos.free_channel ch with Mynos.Error _ -> ())
    done

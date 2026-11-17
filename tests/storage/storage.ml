(* Storage test (mynos-rf4): init.byte starts the ATA driver (ata.byte, in
   OCaml) and reads and writes the QEMU disk through it, with module Block.
   tools/run-tests.sh prepares the disk: 2048 sectors, each starting with
   "MYNOS SECTOR n", and checks afterwards what was written. *)

let check what ok =
  Printf.printf "storage: %-38s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let label n = Printf.sprintf "MYNOS SECTOR %d\n" n

let sector_text n =
  let s = Bytes.make 512 '\000' in
  Bytes.blit_string (label n) 0 s 0 (String.length (label n));
  Bytes.to_string s

let rec device tries =
  match Block.connect () with
  | d -> d
  | exception Mynos.Error _ when tries > 0 -> Mynos.sleep 0.1; device (tries - 1)

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  ignore (Mynos.spawn "ocamlrun" [| "ocamlrun"; "ata.byte" |]);
  let d = device 50 in
  ok &&& check "disk size" (Block.sectors d = 2048);
  ok &&& check "read sector 0" (Block.read d 0 1 = sector_text 0);
  let many = Block.read d 100 40 in
  ok &&& check "read 40 sectors (two requests)"
    (List.for_all (fun i -> String.sub many (512 * i) 512 = sector_text (100 + i))
       (List.init 40 Fun.id));
  let mine = Bytes.make 512 '\000' in
  Bytes.blit_string "WRITTEN BY MYNOS" 0 mine 0 16;
  Block.write d 1000 (Bytes.to_string mine);
  ok &&& check "write a sector and read it back"
    (Block.read d 1000 1 = Bytes.to_string mine);
  let big = String.init (512 * 40) (fun i -> Char.chr (i mod 251)) in
  Block.write d 1500 big;
  ok &&& check "write 40 sectors and read them back" (Block.read d 1500 40 = big);
  ok &&& check "reading beyond the end fails"
    (match Block.read d 2047 2 with _ -> false | exception Failure _ -> true);
  (* typed IPC with the driver itself *)
  ok &&& check "typed call: Info" (Block.call d Block.Info = 2048);
  ok &&& check "typed call: Read" (Block.call d (Block.Read (7, 1)) = sector_text 7);
  ok &&& check "a refused request is a Remote_error"
    (match Block.call d (Block.Read (2047, 2)) with
     | _ -> false
     | exception Ipc.Remote_error ("ata0", m) -> print_endline m; true);
  (* raw messages: malformed, another protocol, garbage *)
  let raw msg =
    let port = Mynos.lookup "ata0" in
    let ch = Mynos.connect port in
    Mynos.send ch msg;
    let r = Mynos.recv ch in
    Mynos.free_channel ch;
    r in
  ok &&& check "the driver answers malformed messages"
    (List.for_all (fun m ->
         match Block.read_reply (raw m) Block.Info with
         | _ -> false | exception Ipc.Remote_error _ -> true)
        [ "\255\255"; "\014block/9\000"; String.make 300 '\128';
          Block.request_message (Block.Read (0, 1)) ^ "\000" ]);
  ok &&& check "and goes on serving" (Block.call d (Block.Read (9, 1)) = sector_text 9);
  print_endline (if !ok then "storage: all checks passed" else "storage: FAIL")

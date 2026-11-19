(* sector0: the first sector of the disk, through the driver ata0 *)
let () =
  let d = Block.connect () in
  Printf.printf "ata0: %d sectors of %d bytes\n" (Block.sectors d) Block.sector;
  let s = Block.call d (Block.Read (0, 1)) in
  Printf.printf "sector 0: %S..., ends with %02X %02X\n"
    (String.sub s 0 11) (Char.code s.[510]) (Char.code s.[511]);
  (match Block.call d (Block.Read (Block.sectors d, 1)) with
   | _ -> print_endline "past the end: read?!"
   | exception Ipc.Remote_error (service, m) -> Printf.printf "past the end: %s: %s\n" service m)

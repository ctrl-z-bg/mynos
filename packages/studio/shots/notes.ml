(* Twenty notes written to the disk and read back: Watch shows whom the
   program talked to (fatfs), and whom fatfs asked meanwhile (ata). *)

let () =
  let dir = "/disk/studio/notes" in
  (try Sys.mkdir dir 0o755 with Sys_error _ -> ());
  for i = 1 to 20 do
    let f = Printf.sprintf "%s/note%02d.txt" dir i in
    Out_channel.with_open_text f (fun oc -> Printf.fprintf oc "note %d\n" i);
    ignore (In_channel.with_open_text f In_channel.input_all)
  done;
  print_endline "20 notes written and read back"

(* files.ml: files from OCaml, with the standard library and with Fs *)
let () =
  (* the standard library: libmynos speaks fs/1 underneath *)
  Out_channel.with_open_text "/tmp/notes.txt" (fun oc ->
      output_string oc "first line\nsecond line\n");
  let text = In_channel.with_open_text "/tmp/notes.txt" In_channel.input_all in
  Printf.printf "read %d bytes\n" (String.length text);
  Sys.rename "/tmp/notes.txt" "/tmp/old.txt";
  Printf.printf "/tmp: %s\n" (String.concat " " (Array.to_list (Sys.readdir "/tmp")));
  Printf.printf "/: %d entries\n" (Array.length (Sys.readdir "/"));
  (match open_out "/hello.txt" with
   | _ -> ()
   | exception Sys_error e -> Printf.printf "error: %s\n" e);
  (* fs/1 itself: names inside the service, descriptors of the service *)
  let tmp = Fs.connect "tmpfs" in
  List.iter (fun (name, size) -> Printf.printf "tmpfs: %s, %d bytes\n" name size)
    (Fs.call tmp (Fs.List ""));
  let fd = Fs.call tmp (Fs.Open ("old.txt", 0)) in
  let first = Fs.call tmp (Fs.Read (fd, 5)) in
  Fs.call tmp (Fs.Close fd);
  Printf.printf "first 5 bytes: %S\n" first;
  Fs.call tmp (Fs.Remove "old.txt");
  match Fs.call tmp (Fs.Open ("old.txt", 0)) with
  | _ -> ()
  | exception Ipc.Remote_error (service, m) ->
    Printf.printf "%s: %s (error %d)\n" service m (Fs.error_of m)

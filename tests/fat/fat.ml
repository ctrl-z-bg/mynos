(* FAT test (mynos-rf4): init.byte starts the ATA driver and fatfs (both in
   OCaml), then uses /disk through the standard library only. The disk
   images are made by mkfs.fat and mtools (Makefile); tools/run-tests.sh
   checks them afterwards with fsck.fat and mtools. *)

let check what ok =
  Printf.printf "fat: %-44s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let read f = In_channel.with_open_bin f In_channel.input_all
let write f s = Out_channel.with_open_bin f (fun oc -> output_string oc s)

let rec wait_for path tries =
  if Sys.file_exists path || tries = 0 then ()
  else (Mynos.sleep 0.1; wait_for path (tries - 1))

let fails f = match f () with _ -> false | exception Sys_error _ -> true

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  List.iter (fun p -> ignore (Mynos.spawn ~io:(p = "ata.byte") "ocamlrun" [| "ocamlrun"; p |]))
    [ "ata.byte"; "fatfs.byte" ];
  wait_for "/disk" 100;
  ok &&& check "/disk is a directory" (Sys.is_directory "/disk");
  let root = Sys.readdir "/disk" in
  Array.sort compare root;
  ok &&& check "list the root (8.3 and long names)"
    (Array.to_list root = [ "Makefile"; "docs"; "hello.txt" ]);
  ok &&& check "read a file" (read "/disk/hello.txt" = "Hello from a FAT disk!\n");
  ok &&& check "read in a subdirectory, long name"
    (read "/disk/docs/A long file name.txt" = "Long names work.\n");
  ok &&& check "names are case-insensitive" (Sys.file_exists "/disk/HELLO.TXT");
  ok &&& check "read 100 KB across clusters"
    (read "/disk/docs/big.bin" = String.init 100_000 (fun i -> Char.chr (i mod 253)));
  (* writing *)
  write "/disk/new.ml" "let answer = 42\n";
  ok &&& check "create and read back" (read "/disk/new.ml" = "let answer = 42\n");
  Out_channel.with_open_gen [ Open_append; Open_wronly ] 0 "/disk/new.ml"
    (fun oc -> output_string oc "let more = 1\n");
  ok &&& check "append" (read "/disk/new.ml" = "let answer = 42\nlet more = 1\n");
  ok &&& check "O_EXCL: an existing file is not created again"
    (fails (fun () -> open_out_gen [ Open_creat; Open_excl; Open_wronly ] 0o644 "/disk/new.ml")
     && read "/disk/new.ml" = "let answer = 42\nlet more = 1\n");
  let big = String.init 70_000 (fun i -> Char.chr (i * 7 mod 256)) in
  write "/disk/big.dat" big;
  ok &&& check "write 70 KB and read it back" (read "/disk/big.dat" = big);
  write "/disk/big.dat" "short";
  ok &&& check "truncate on rewrite" (read "/disk/big.dat" = "short");
  Sys.mkdir "/disk/projects" 0o755;
  write "/disk/projects/A Longer Name Than Eight.txt" "nested\n";
  ok &&& check "mkdir, long name in it"
    (Sys.readdir "/disk/projects" = [| "A Longer Name Than Eight.txt" |]
     && read "/disk/projects/A Longer Name Than Eight.txt" = "nested\n");
  for i = 1 to 40 do write (Printf.sprintf "/disk/projects/file%02d.txt" i) "x" done;
  ok &&& check "a directory grows past one cluster"
    (Array.length (Sys.readdir "/disk/projects") = 41);
  for i = 1 to 40 do Sys.remove (Printf.sprintf "/disk/projects/file%02d.txt" i) done;
  Sys.remove "/disk/big.dat";
  ok &&& check "remove files" (not (Sys.file_exists "/disk/big.dat"));
  ok &&& check "rmdir of a non-empty directory fails"
    (fails (fun () -> Sys.rmdir "/disk/projects"));
  Sys.mkdir "/disk/empty" 0o755;
  Sys.rmdir "/disk/empty";
  ok &&& check "rmdir" (not (Sys.file_exists "/disk/empty"));
  ok &&& check "a missing file" (fails (fun () -> read "/disk/nothing"));
  (* a rename that changes only the case keeps the file *)
  Out_channel.with_open_bin "/disk/case.txt" (fun oc -> output_string oc "kept");
  Sys.rename "/disk/case.txt" "/disk/CASE.txt";
  ok &&& check "rename to the same name in other letters"
    (read "/disk/CASE.txt" = "kept" && Array.mem "CASE.txt" (Sys.readdir "/disk"));
  print_endline (if !ok then "fat: all checks passed" else "fat: FAIL")

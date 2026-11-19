(* fg.ml: a program in the foreground, ended by Ctrl-C *)
let () =
  let pid = Mynos.spawn "ocamlrun" [| "ocamlrun"; "worker.byte"; "forever" |] in
  Mynos.console_foreground pid;          (* Ctrl-C now ends it *)
  let st = Mynos.wait pid in
  Mynos.console_foreground 0;
  match st with
  | Mynos.Exited n -> Printf.printf "fg: exited with %d\n" n
  | Mynos.Signaled s -> Printf.printf "fg: killed (signal %d)\n" s

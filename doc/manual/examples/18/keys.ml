(* keys.ml: keys one by one, in OCaml, until q *)
let () =
  Mynos.console_mode ~canon:false ~echo:false ();
  print_endline "press keys, q to quit";
  let buf = Bytes.create 16 in
  let rec loop () =
    let n = Unix.read Unix.stdin buf 0 16 in
    let keys = Bytes.sub_string buf 0 n in
    Printf.printf "keys %S\n%!" keys;
    if n > 0 && not (String.contains keys 'q') then loop () in
  loop ();
  Mynos.console_mode ~canon:true ~echo:true ()

(* lower.ml: a client of "upper", in OCaml *)
let ask text =
  let ch = Mynos.connect (Mynos.lookup "upper") in
  Fun.protect ~finally:(fun () -> Mynos.free_channel ch) (fun () ->
      Mynos.send ch text;
      Mynos.recv ~timeout:2.0 ch)

let () =
  Mynos.sleep 1.0;                        (* let the service register *)
  match ask "hello from OCaml" with
  | answer -> print_endline answer
  | exception Mynos.Error (fn, code) ->
    Printf.printf "lower: %s: %s\n" fn (Mynos.error_name code)

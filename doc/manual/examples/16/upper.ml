(* upper.ml: the same service in OCaml *)
let () =
  let port = Mynos.register "upper" in
  while true do
    let ch = Mynos.listen port in
    (try
       let msg = Mynos.recv ~timeout:1.0 ch in
       Mynos.log (Printf.sprintf "upper: %d bytes from pid %d"
                    (String.length msg) (Mynos.channel_peer ch));
       Mynos.send ch (String.uppercase_ascii msg)
     with Mynos.Error (fn, code) ->
       Mynos.log (Printf.sprintf "upper: %s: %s" fn (Mynos.error_name code)));
    Mynos.free_channel ch
  done

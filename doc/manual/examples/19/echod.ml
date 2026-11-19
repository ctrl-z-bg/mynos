(* echod: a TCP echo server.  echod [PORT]  (7 by default)
   Each connection gets back what it sends, until it closes; one
   connection at a time. *)

let port = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 7

(* one connection: echo until the peer closes, or 30 s of silence *)
let serve n s =
  Net.call n (Net.Set_timeout (s, 30_000));
  let rec loop total =
    match Net.call n (Net.Recv (s, 4096)) with
    | "" -> total                                   (* the peer closed *)
    | data ->
      ignore (Net.call n (Net.Send (s, data)));
      loop (total + String.length data)
    | exception Ipc.Remote_error (_, "timeout") -> total in
  Fun.protect ~finally:(fun () -> Net.call n (Net.Close s))
    (fun () -> loop 0)

let () =
  let n = Net.connect () in
  let l = Net.call n (Net.Listen port) in
  Printf.printf "echod: listening on port %d\n%!" port;
  while true do
    let s, address, p = Net.call n (Net.Accept l) in
    match serve n s with
    | bytes -> Printf.printf "echod: %s:%d, %d bytes\n%!" address p bytes
    | exception Ipc.Remote_error (_, m) ->
      Printf.printf "echod: %s:%d: %s\n%!" address p m
  done

(* capture.ml: the console of another program. It serves console/1
   under a name of its own and starts a child with MYNOS_CONSOLE naming
   it: the child's output comes here, and its input is "" (the end). *)
let answer ch msg =
  (try Mynos.send ch msg with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let serve port lines =
  while true do
    let ch = Mynos.listen port in
    match Mynos.recv ~timeout:1.0 ch with
    | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ())
    | msg ->
      match Console.decode msg with
      | Error reply -> answer ch reply
      | Ok (Console.Protocol.Request r) ->
        let ok (type a) (r : a Console.request) (v : a) = answer ch (Console.reply r v) in
        (match r with
         | Console.Write s -> Mutex.protect (fst lines) (fun () -> Buffer.add_string (snd lines) s); ok r ()
         | Console.Read _ -> ok r ""                   (* no input: the end *)
         | Console.Mode _ -> ok r ()
         | Console.Keymap _ -> ok r Console.layout_us
         | Console.Foreground _ -> ok r ()
         | Console.Size -> ok r (80, 25))
  done

let () =
  let name = Printf.sprintf "cap%d" (Mynos.getpid ()) in
  let port = Mynos.register name in
  let lines = (Mutex.create (), Buffer.create 256) in
  ignore (Domain.spawn (fun () -> serve port lines));
  let env = Array.append (Mynos.environment ()) [| "MYNOS_CONSOLE=" ^ name |] in
  let pid = Mynos.spawn ~env "ocamlrun" [| "ocamlrun"; "worker.byte"; "0" |] in
  ignore (Mynos.wait pid);
  let child = Mutex.protect (fst lines) (fun () -> Buffer.contents (snd lines)) in
  Printf.printf "capture: the child wrote %S\n" child

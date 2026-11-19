(* procs.ml: starting programs, waiting for them, ending them *)
let show = function
  | Mynos.Exited n -> Printf.sprintf "exited with %d" n
  | Mynos.Signaled s -> Printf.sprintf "killed by signal %d" s

let start ?env args =
  Mynos.spawn ?env "ocamlrun" (Array.append [| "ocamlrun"; "worker.byte" |] args)

let () =
  (* one child, our environment *)
  let pid = start [| "3" |] in
  Printf.printf "procs: %d %s\n%!" pid (show (Mynos.wait pid));
  (* another environment: ours, with one variable more *)
  let env = Array.append (Mynos.environment ()) [| "GREETING=ciao" |] in
  let pid = start ~env [| "0" |] in
  Printf.printf "procs: %d %s\n%!" pid (show (Mynos.wait pid));
  (* two at once, collected in the order they end *)
  let a = start [| "5" |] and b = start [| "7" |] in
  for _ = 1 to 2 do
    let pid, st = Mynos.wait_any () in
    Printf.printf "procs: %s %d %s\n%!" (if pid = a then "a" else if pid = b then "b" else "?")
      pid (show st)
  done;
  (* one in the background, ended by us *)
  let bg = start [| "forever" |] in
  Mynos.sleep 0.5;
  (match Mynos.process_info bg with
   | Some { Mynos.alive = true; _ } -> Printf.printf "procs: %d is running\n%!" bg
   | _ -> ());
  Mynos.kill bg;
  Printf.printf "procs: %d %s\n%!" bg (show (Mynos.wait bg));
  (* a program that is not there *)
  (match Mynos.spawn "nothing" [| "nothing" |] with
   | _ -> ()
   | exception Mynos.Error (fn, code) ->
     Printf.printf "procs: %s: %s\n%!" fn (Mynos.error_name code));
  print_endline "procs: done"

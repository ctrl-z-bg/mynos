(* worker.ml: started by procs.ml *)
let () =
  let greeting = Option.value (Sys.getenv_opt "GREETING") ~default:"(none)" in
  Printf.printf "worker %d: GREETING=%s, args [%s]\n%!" (Mynos.getpid ()) greeting
    (String.concat " " (List.tl (Array.to_list Sys.argv)));
  match Sys.argv with
  | [| _; "forever" |] -> while true do Mynos.sleep 1.0 done
  | [| _; code |] -> exit (int_of_string code)
  | _ -> exit 0

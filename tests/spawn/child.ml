(* Started by init.byte (spawn.ml) through Mynos.spawn: prints its
   arguments and ends with an exit code the parent checks. *)

let () =
  let args = Array.to_list Sys.argv |> List.tl |> String.concat " " in
  Printf.printf "spawn child %d (parent %d): args [%s]\n%!"
    (Mynos.getpid ()) (Mynos.stats ()).Mynos.ppid args;
  match Sys.argv with
  | [| _; "crash" |] -> Mynos.send (-1) "" ; exit 0  (* an error *)
  | [| _; code |] -> exit (int_of_string code)
  | _ -> exit 3

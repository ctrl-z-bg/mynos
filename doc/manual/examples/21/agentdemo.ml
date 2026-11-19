(* agentdemo: a task for the agent, at the console.  agentdemo TASK *)
let () =
  let task = String.concat " " (List.tl (Array.to_list Sys.argv)) in
  let a = Agent.create ~services:[ "net" ] () in
  let emit = function
    | Agent.Task t -> Printf.printf "> %s\n%!" t
    | Said s -> Printf.printf "%s\n%!" s
    | Action a -> Printf.printf "  [%s]\n%!" a
    | Result { text; error } ->
      Printf.printf "  %s%s\n%!" (if error then "error: " else "") text
    | Note n -> Printf.printf "  (%s)\n%!" n in
  let confirm what =
    Printf.printf "Allow %s? [y/n/a] %!" what;
    match In_channel.input_line stdin with
    | Some "y" -> Agent.Yes
    | Some "a" -> Agent.All
    | _ -> Agent.No in
  exit (Agent.run a ~emit ~confirm task)

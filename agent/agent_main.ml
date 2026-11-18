(* agent: a task in natural language, carried out by a language model
   with tools (module Agent; doc/decisions/llm.md, step 4):

     agent TASK...
     agent -p PROFILE ...       another model profile (llm -l)
     agent -s net,llm ...       the typed services it may use (net)
     agent -y ...               no confirmations (careful)
     agent -n TURNS ...         at most so many model calls (20)
     agent -t FILE ...          the recording's file (/tmp/agent.trc)

   Tools: commands, files, OCaml programs (run_ocaml: type-checked, then
   run; build_ocaml: into a file, such as a window to start with &), the
   typed services (module Agent).
   What changes things is shown and done only once confirmed: y, n, or a
   (yes to all). The event recorder runs meanwhile: "trace calls FILE"
   shows what the agent, the model service and every other process did. *)

let usage () =
  prerr_endline "usage: agent [-p PROFILE] [-s SERVICE,...] [-y] [-n TURNS] [-t FILE] TASK...";
  exit 2

let say s = print_endline s; flush stdout

(* the answer: a key on the console, or a line when the input is a file *)
let confirm what =
  print_string ("  " ^ what ^ "\n  Do it? [y/N/a] "); flush stdout;
  let answer =
    if Sys.getenv_opt "MYNOS_STDIN" <> None then
      (match In_channel.input_line stdin with Some l -> String.trim l | None -> "")
    else begin
      Mynos.console_mode ~canon:false ~echo:false ();
      Fun.protect ~finally:(fun () -> Mynos.console_mode ~canon:true ~echo:true ())
        (fun () -> match input_char stdin with
           | c -> String.make 1 c | exception End_of_file -> "")
    end in
  let a = if answer = "" then 'n' else Char.lowercase_ascii answer.[0] in
  print_endline (String.make 1 a);
  match a with 'y' -> Agent.Yes | 'a' -> Agent.All | _ -> Agent.No

let emit = function
  | Agent.Task t -> say ("agent: " ^ t)
  | Said s -> say s
  | Action a -> say ("  " ^ a)
  | Result { text; error } ->
    let first = match String.index_opt text '\n' with
      | Some i -> String.sub text 0 i ^ " ..." | None -> text in
    say (Printf.sprintf "  -> %s%s" (if error then "error: " else "")
           (if String.length first > 100 then String.sub first 0 100 ^ "..." else first))
  | Note n -> say ("agent: " ^ n)

let () =
  let profile = ref "" and services = ref [ "net" ] and yes = ref false
  and max_turns = ref 20 and trace_file = ref "/tmp/agent.trc" in
  let rec args = function
    | "-p" :: p :: rest -> profile := p; args rest
    | "-s" :: s :: rest ->
      services := List.filter (fun s -> s <> "") (String.split_on_char ',' s); args rest
    | "-y" :: rest -> yes := true; args rest
    | "-n" :: n :: rest ->
      (match int_of_string_opt n with Some n when n > 0 -> max_turns := n | _ -> usage ());
      args rest
    | "-t" :: f :: rest -> trace_file := f; args rest
    | w :: _ when String.length w > 1 && w.[0] = '-' -> usage ()
    | words -> words in
  let task = String.concat " " (args (List.tl (Array.to_list Sys.argv))) in
  if String.trim task = "" then usage ();
  match Agent.create ~profile:!profile ~services:!services ~max_turns:!max_turns
          ~trace_file:!trace_file ~yes_to_all:!yes
          ~warn:(fun m -> prerr_endline ("agent: " ^ m)) () with
  | exception Failure m -> prerr_endline ("agent: " ^ m); exit 1
  | a ->
    let code = Agent.run a ~emit ~confirm task in
    let i, o = Agent.tokens a in
    say (Printf.sprintf "agent: %d tokens in, %d out" i o);
    exit code

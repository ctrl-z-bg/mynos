(* agent: a task in natural language, carried out by a language model
   with tools (doc/decisions/llm.md, step 4):

     agent TASK...
     agent -p PROFILE ...       another model profile (llm -l)
     agent -s net,llm ...       the typed services it may use (net)
     agent -y ...               no confirmations (careful)
     agent -n TURNS ...         at most so many model calls (20)
     agent -t FILE ...          the recording's file (/tmp/agent.trc)

   Tools: run_command (a line of sh, its output back), run_ocaml (a
   program, type-checked by ocamlc against MyNOS's libraries: the errors
   go back to the model; run once confirmed), read_file, write_file,
   list_directory, and every request of the services given, from their
   descriptions (module Tools). What changes things (commands,
   writes, requests not marked safe) is shown and run only once confirmed:
   y, n, or a (yes to all). The event recorder runs meanwhile: "trace
   calls FILE" shows what the agent, the model service and every other
   process did. *)

let usage () =
  prerr_endline "usage: agent [-p PROFILE] [-s SERVICE,...] [-y] [-n TURNS] [-t FILE] TASK...";
  exit 2

let profile = ref "" and services = ref [ "net" ] and yes_to_all = ref false
and max_turns = ref 20 and trace_file = ref "/tmp/agent.trc"

let say fmt = Printf.ksprintf (fun s -> print_endline s; flush stdout) fmt

(* ---- confirmation ---- *)

let confirm what =
  if !yes_to_all then (print_endline ("  " ^ what); true)
  else begin
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
    if a = 'a' then yes_to_all := true;
    a = 'y' || a = 'a'
  end

(* ---- the agent's own tools ---- *)

let max_result = 16384

let clip s =
  if String.length s <= max_result then s
  else String.sub s 0 max_result
       ^ Printf.sprintf "\n[... %d more bytes not shown]" (String.length s - max_result)

let schema props =
  Json.to_string (Json.Object [
      "type", Json.String "object";
      "properties", Json.Object (List.map (fun (n, d) ->
          (n, Json.Object [ "type", Json.String "string"; "description", Json.String d ]))
          props);
      "required", Json.Array (List.map (fun (n, _) -> Json.String n) props) ])

let own_tools = [
  { Llm.name = "run_command";
    description = "Run one command line in MyNOS sh (the user confirms it first): \
                   its exit status and its output (standard output and errors).";
    schema = schema [ "command", "one line for MyNOS sh" ] };
  { name = "run_ocaml";
    description = "Compile an OCaml 5 program with ocamlc, against MyNOS's libraries \
                   (Mynos: processes, IPC, files; Net: the network; Http; Json; Llm: \
                   language models; Ipc, Wire, Tools: typed services; and the \
                   standard library). If it does not type-check, the compiler's \
                   errors come back and nothing runs. If it does, the user confirms, \
                   then it runs: its exit status and output come back. Prefer it to \
                   run_command for anything a typed interface does better.";
    schema = schema [ "code", "the program: an OCaml compilation unit (let () = ...)" ] };
  { name = "ocaml_signature";
    description = "The signature of an OCaml module of MyNOS or of the standard \
                   library (its types and functions), as the toplevel shows it: \
                   Mynos, Net, Http, Json, Llm, Ipc, Wire, Tools, Block, List...";
    schema = schema [ "module", "the module's name, such as Net" ] };
  { name = "read_file"; description = "The contents of a file.";
    schema = schema [ "path", "the file's path" ] };
  { name = "write_file";
    description = "Write a file (created, or replaced): the user confirms it first.";
    schema = schema [ "path", "the file's path"; "content", "its new contents" ] };
  { name = "list_directory";
    description = "The entries of a directory, with sizes; directories end with /.";
    schema = schema [ "path", "the directory's path" ] } ]

let arg input name =
  match Json.(member name (of_string input)) with
  | Json.String s -> s
  | _ -> failwith ("missing argument " ^ name)
  | exception Json.Error m -> failwith ("arguments: " ^ m)

let counter = ref 0

let temp ext =
  incr counter;
  Printf.sprintf "/tmp/.agent-%d-%d%s" (Mynos.getpid ()) !counter ext

(* a bytecode program run with its input from an empty file and its
   output (and its children's) into a file of /tmp: (exit status, output) *)
let capture ?(input = "") argv =
  let out = temp ".out" in
  let inp = out ^ ".in" in
  Out_channel.with_open_bin inp (fun oc -> output_string oc input);
  Out_channel.with_open_bin out (fun _ -> ());
  let env = Array.of_list (
      List.filter (fun kv ->
          not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                 [ "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR"; "OCAMLLIB" ]))
        (Array.to_list (Mynos.environment ()))
      @ [ "MYNOS_STDIN=" ^ inp; "MYNOS_STDOUT=>>" ^ out; "MYNOS_STDERR=>>" ^ out;
          "OCAMLLIB=/" ]) in
  let status =
    match Mynos.spawn ~env "ocamlrun" (Array.of_list ("ocamlrun" :: argv)) with
    | pid -> (match Mynos.wait pid with
        | Mynos.Exited n -> n
        | Mynos.Signaled s -> 128 + s)
    | exception Mynos.Error (_, code) ->
      failwith ("cannot start ocamlrun: " ^ Mynos.error_name code) in
  let output = try In_channel.with_open_bin out In_channel.input_all with Sys_error _ -> "" in
  (try Sys.remove out with Sys_error _ -> ());
  (try Sys.remove inp with Sys_error _ -> ());
  (status, output)

(* a command line, run by sh *)
let run_command command =
  let status, output = capture [ "/sh.byte"; "-c"; command ] in
  Printf.sprintf "exit status %d\n%s" status (clip output)

(* a module's signature, as the toplevel shows it *)
let ocaml_signature m =
  if m = "" || not (String.for_all (fun c ->
      match c with 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' | '.' -> true | _ -> false) m)
  then failwith "a module's name, such as Net or Llm"
  else
    let _, output = capture ~input:("#show_module " ^ m ^ ";;\n") [ "/shell.byte" ] in
    (* from the signature on: the toplevel's banner and prompts, out *)
    let lines = String.split_on_char '\n' output in
    let rec from = function
      | l :: _ as ls when String.starts_with ~prefix:"# module" l
                         || String.starts_with ~prefix:"module" l
                         || String.starts_with ~prefix:"Unbound" l
                         || String.starts_with ~prefix:"# Unbound" l -> ls
      | _ :: rest -> from rest
      | [] -> lines in
    let lines = List.filter (fun l -> String.trim l <> "#" && String.trim l <> "")
        (from lines) in
    clip (String.concat "\n" (List.map (fun l ->
        if String.starts_with ~prefix:"# " l then String.sub l 2 (String.length l - 2) else l)
        lines))

(* an OCaml program: compiled (the type checker's word first), then run if
   the user agrees: (result, is an error) *)
let run_ocaml code =
  let src = temp ".ml" in
  let exe = Filename.chop_suffix src ".ml" ^ ".byte" in
  Out_channel.with_open_bin src (fun oc -> output_string oc code);
  let cleanup () =
    List.iter (fun f -> try Sys.remove f with Sys_error _ -> ())
      [ src; exe; Filename.chop_suffix src ".ml" ^ ".cmi";
        Filename.chop_suffix src ".ml" ^ ".cmo" ] in
  Fun.protect ~finally:cleanup (fun () ->
      say "  compile (%d lines of OCaml)" (List.length (String.split_on_char '\n' code));
      match capture [ "/ocamlc.byte"; "-use-prims"; "/primitives"; "mynos.cma";
                      "-o"; exe; src ] with
      | 0, warnings ->
        let lines = String.split_on_char '\n' code in
        let shown = List.filteri (fun i _ -> i < 12) lines in
        if confirm ("run this OCaml program:\n    "
                    ^ String.concat "\n    " shown
                    ^ (if List.length lines > 12 then "\n    ..." else "")) then
          let status, output = capture [ exe ] in
          (Printf.sprintf "%sexit status %d\n%s"
             (if String.trim warnings = "" then "" else "compiler warnings:\n" ^ warnings ^ "\n")
             status (clip output), false)
        else ("It compiles, but the user did not allow running it.", true)
      | _, errors -> ("It does not compile:\n" ^ clip errors, true))

let list_directory path =
  let names = List.sort compare (Array.to_list (Sys.readdir path)) in
  String.concat "\n" (List.map (fun n ->
      let full = Filename.concat path n in
      if (try Sys.is_directory full with Sys_error _ -> false) then n ^ "/"
      else match In_channel.with_open_bin full In_channel.length with
        | len -> Printf.sprintf "%s\t%Ld bytes" n len
        | exception Sys_error _ -> n) names)

(* a tool call: (result, is an error) *)
let execute service_tools name input =
  match name with
  | "run_command" ->
    let c = arg input "command" in
    if confirm ("run: " ^ c) then (run_command c, false)
    else ("The user did not allow this command.", true)
  | "run_ocaml" -> run_ocaml (arg input "code")
  | "ocaml_signature" ->
    let m = arg input "module" in
    say "  signature of %s" m;
    (ocaml_signature m, false)
  | "read_file" ->
    let p = arg input "path" in
    say "  read %s" p;
    (clip (In_channel.with_open_bin p In_channel.input_all), false)
  | "write_file" ->
    let p = arg input "path" and content = arg input "content" in
    if confirm (Printf.sprintf "write %s (%d bytes)" p (String.length content)) then begin
      Out_channel.with_open_bin p (fun oc -> output_string oc content);
      (Printf.sprintf "%d bytes written to %s" (String.length content) p, false)
    end else ("The user did not allow writing this file.", true)
  | "list_directory" ->
    let p = arg input "path" in
    say "  list %s" p;
    (list_directory p, false)
  | _ ->
    match Tools.find service_tools name with
    | exception Not_found -> ("No tool " ^ name, true)
    | t ->
      if t.request.safe || confirm (Printf.sprintf "%s %s" name input) then begin
        if t.request.safe then say "  %s %s" name input;
        (clip (Tools.call t input), false)
      end else ("The user did not allow this request.", true)

let execute service_tools name input =
  match execute service_tools name input with
  | r -> r
  | exception (Failure m | Sys_error m | Invalid_argument m) -> (m, true)
  | exception Ipc.Remote_error (s, m) -> (s ^ ": " ^ m, true)
  | exception Mynos.Error (f, code) -> (f ^ ": " ^ Mynos.error_name code, true)

(* ---- the model's context ---- *)

let system_prompt services =
  String.concat "\n" [
    "You are an agent inside MyNOS, a small microkernel operating system \
     written in C and OCaml, running on i386. You carry out the user's \
     task with your tools, step by step: look before you change things, \
     check what your commands did. When the task is done (or cannot be \
     done), answer with a short final report and no tool call. Answer in \
     the user's language.";
    "";
    "run_command runs one line of MyNOS sh: words with 'quotes' and \
     \"quotes\", $VAR, NAME=value, commands joined by ; && ||, redirections \
     < > >>, pipes |, * and ? in file names. There is no arithmetic, no \
     if/for/while, no command substitution. Built in: cd pwd echo cat ls \
     (ls -l) cp mv rm mkdir rmdir touch export unset env which free; \
     ifconfig, ping HOST, host NAME. Programs: fetch [-i] [-o FILE] [-H \
     'Name: value'] [-d DATA] URL (HTTP and HTTPS), ocamlc, llm QUESTION, \
     trace COMMAND. Each command runs in a new sh: cd does not carry over \
     to the next one.";
    "Files: / is the RAM disk (read-only), /tmp is in memory, /disk is the \
     FAT disk (kept across reboots). Paths are up to 63 characters in a \
     directory.";
    "run_ocaml compiles OCaml 5 against MyNOS's libraries: the compiler \
     checks your program's types before anything runs, so prefer it when a \
     typed interface helps (Net.call n (Net.Resolve \"example.com\"), \
     Http.get, Json, Llm.ask...). ocaml_signature shows a module's \
     interface: look before you write.";
    "Besides, your tools include the requests of these MyNOS services, \
     described by the services themselves: " ^ String.concat ", " services ^ ".";
    "The current directory: " ^ Sys.getcwd () ]

(* ---- the loop ---- *)

let () =
  let rec args = function
    | "-p" :: p :: rest -> profile := p; args rest
    | "-s" :: s :: rest ->
      services := List.filter (fun s -> s <> "") (String.split_on_char ',' s); args rest
    | "-y" :: rest -> yes_to_all := true; args rest
    | "-n" :: n :: rest ->
      (match int_of_string_opt n with Some n when n > 0 -> max_turns := n | _ -> usage ());
      args rest
    | "-t" :: f :: rest -> trace_file := f; args rest
    | w :: _ when String.length w > 1 && w.[0] = '-' -> usage ()
    | words -> words in
  let task = String.concat " " (args (List.tl (Array.to_list Sys.argv))) in
  if String.trim task = "" then usage ();
  let l = try Llm.connect () with Mynos.Error _ ->
    prerr_endline "agent: no language model service (llmd)"; exit 1 in
  let service_tools = List.concat_map (fun s ->
      match Tools.of_service s with
      | ts -> ts
      | exception e ->
        prerr_endline (Printf.sprintf "agent: service %s: %s" s (Printexc.to_string e)); [])
      !services in
  let tools = own_tools @ List.map (fun t -> t.Tools.tool) service_tools in
  (* the recorder, read after every step so that its buffer does not fill *)
  let raw = Buffer.create 65536 in
  let recording = (try Tracer.start (); true with _ -> false) in
  let drain () = if recording then Buffer.add_string raw (Tracer.read ()) in
  let system = system_prompt !services in
  let tokens_in = ref 0 and tokens_out = ref 0 in
  let rec turn n messages =
    if n > !max_turns then (say "agent: stopped after %d model calls" !max_turns; 1)
    else
      match Llm.call l (Llm.Chat { Llm.chat with profile = !profile; system;
                                                 messages; tools }) with
      | exception Ipc.Remote_error (_, m) -> say "agent: %s" m; 1
      | a ->
        drain ();
        tokens_in := !tokens_in + a.input_tokens;
        tokens_out := !tokens_out + a.output_tokens;
        (match Llm.text a with "" -> () | t -> say "%s" (String.trim t));
        let calls = List.filter_map (function
            | Llm.Tool_call { id; name; input } -> Some (id, name, input)
            | _ -> None) a.content in
        match a.stop, calls with
        | Llm.Tool_use, _ :: _ ->
          let results = List.map (fun (id, name, input) ->
              let content, error = execute service_tools name input in
              drain ();
              let first = match String.index_opt content '\n' with
                | Some i -> String.sub content 0 i ^ " ..." | None -> content in
              say "  -> %s%s" (if error then "error: " else "")
                (if String.length first > 100 then String.sub first 0 100 ^ "..." else first);
              Llm.Tool_result { id; content; error })
              calls in
          turn (n + 1) (messages @ [ { Llm.role = Assistant; content = a.content };
                                     { role = User; content = results } ])
        | Llm.Max_tokens, _ -> say "agent: the answer was cut (max_tokens)"; 1
        | Llm.Refusal, _ -> say "agent: the model declined"; 1
        | _ -> 0 in
  say "agent: %s" task;
  let code = turn 1 [ Llm.user task ] in
  say "agent: %d tokens in, %d out" !tokens_in !tokens_out;
  if recording then begin
    Tracer.stop ();
    drain ();
    match Tracer.save !trace_file ~raw:(Buffer.contents raw) (Tracer.info ()) with
    | () -> say "agent: recording in %s (trace calls %s)" !trace_file !trace_file
    | exception Sys_error e -> say "agent: recording not saved: %s" e
  end;
  exit code

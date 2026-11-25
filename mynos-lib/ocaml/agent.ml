(* The agent: a task carried out by a language model with tools (see
   agent.mli; doc/decisions/llm.md, section 9). Shared by the agent
   command and the agent window. *)

type event =
  | Task of string
  | Said of string
  | Action of string
  | Result of { text : string; error : bool }
  | Note of string

type answer = Yes | No | All

(* ---- the agent's own tools ---- *)

let max_result = 16384

let clip s =
  if String.length s <= max_result then s
  else String.sub s 0 max_result
       ^ Printf.sprintf "\n[... %d more bytes not shown]" (String.length s - max_result)

let string_schema props =
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
    schema = string_schema [ "command", "one line for MyNOS sh" ] };
  { name = "run_ocaml";
    description = "Compile an OCaml 5 program with ocamlc, against MyNOS's libraries \
                   (Mynos: processes, IPC, files; Net: the network; Http; Json; Llm: \
                   language models; Ipc, Wire, Tools: typed services; the \
                   standard library; and, linked when the program names them, \
                   Unix, Thread, Str, Num and Big_int, Graphics). If it does not type-check, the compiler's \
                   errors come back and nothing runs. If it does, the user confirms, \
                   then it runs: its exit status and output come back. Prefer it to \
                   run_command for anything a typed interface does better. It waits \
                   for the program's end and keeps its output: not for programs that \
                   keep running (a window, an animation, a service): build_ocaml.";
    schema = string_schema [ "code", "the program: an OCaml compilation unit (let () = ...)" ] };
  { name = "build_ocaml";
    description = "Compile an OCaml 5 program, against MyNOS's libraries as run_ocaml \
                   does (also Gfx, Display, Gui: windows; or OCaml's Graphics), \
                   into a program file, \
                   without running it; its source is kept beside it (.ml). The \
                   compiler's errors come back if it does not type-check. For \
                   programs that keep running: start a window or a service with \
                   run_command \"PROGRAM &\" (it returns at once); a program for \
                   the terminal (escape sequences, keys) is for the user to run.";
    schema = string_schema [ "code", "the program: an OCaml compilation unit (let () = ...)";
                      "output", "the program's file, ending in .byte, such as \
                                 /disk/life.byte" ] };
  { name = "ocaml_signature";
    description = "The signature of an OCaml module of MyNOS or of the standard \
                   library (its types and functions), as the toplevel shows it: \
                   Mynos, Net, Http, Json, Llm, Ipc, Wire, Tools, Block, Gfx, \
                   Display, Gui, Graphics, Str, Num, List...";
    schema = string_schema [ "module", "the module's name, such as Net" ] };
  { name = "read_file"; description = "The contents of a file.";
    schema = string_schema [ "path", "the file's path" ] };
  { name = "write_file";
    description = "Write a file (created, or replaced): the user confirms it first.";
    schema = string_schema [ "path", "the file's path"; "content", "its new contents" ] };
  { name = "list_directory";
    description = "The entries of a directory, with sizes; directories end with /.";
    schema = string_schema [ "path", "the directory's path" ] } ]

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

(* the libraries a program names, for ocamlc inside MyNOS, beside
   mynos.cma: unix, threads and str are always linked once given (their
   units are "force link"), so only those the source mentions *)
let ocamlc_libraries code =
  let ident c = match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '\'' -> true | _ -> false in
  let n = String.length code in
  let mentions m =
    let k = String.length m in
    let rec from i =
      i + k <= n
      && ((String.sub code i k = m
           && (i = 0 || not (ident code.[i - 1]))
           && (i + k = n || not (ident code.[i + k])))
          || from (i + 1)) in
    from 0 in
  let any = List.exists mentions in
  let threads = any [ "Thread"; "Event" ] in
  "-noautolink" :: "mynos.cma"
  :: List.concat [
    (if threads || any [ "Unix"; "UnixLabels" ] then [ "unix.cma" ] else []);
    (if threads then [ "threads.cma" ] else []);
    (if mentions "Str" then [ "str.cma" ] else []);
    (if any [ "Num"; "Big_int"; "Ratio"; "Nat"; "Arith_status" ] then [ "nums.cma" ] else []);
    (if mentions "Graphics" then [ "graphics.cma" ] else []) ]

(* an OCaml program: compiled (the type checker's word first), then run if
   the user agrees: (result, is an error) *)
let run_ocaml ~emit ~confirm code =
  let src = temp ".ml" in
  let exe = Filename.chop_suffix src ".ml" ^ ".byte" in
  Out_channel.with_open_bin src (fun oc -> output_string oc code);
  let cleanup () =
    List.iter (fun f -> try Sys.remove f with Sys_error _ -> ())
      [ src; exe; Filename.chop_suffix src ".ml" ^ ".cmi";
        Filename.chop_suffix src ".ml" ^ ".cmo" ] in
  Fun.protect ~finally:cleanup (fun () ->
      emit (Action (Printf.sprintf "compile (%d lines of OCaml)"
                      (List.length (String.split_on_char '\n' code))));
      match capture ([ "/ocamlc.byte"; "-use-prims"; "/primitives" ]
                     @ ocamlc_libraries code @ [ "-o"; exe; src ]) with
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

(* a program into a file: compiled (the type checker's word), not run *)
let build_ocaml ~emit ~confirm code output =
  if not (Filename.check_suffix output ".byte") then
    ("The output must end in .byte, such as /disk/life.byte.", true)
  else begin
    let base = Filename.chop_suffix output ".byte" in
    let src = base ^ ".ml" in
    let lines = List.length (String.split_on_char '\n' code) in
    if not (confirm (Printf.sprintf "build %s (%d lines of OCaml, source in %s)"
                       output lines src)) then
      ("The user did not allow building it.", true)
    else begin
      Out_channel.with_open_bin src (fun oc -> output_string oc code);
      emit (Action (Printf.sprintf "compile %s" src));
      let result = capture ([ "/ocamlc.byte"; "-use-prims"; "/primitives" ]
                            @ ocamlc_libraries code @ [ "-o"; output; src ]) in
      List.iter (fun f -> try Sys.remove f with Sys_error _ -> ())
        [ base ^ ".cmi"; base ^ ".cmo" ];
      match result with
      | 0, warnings ->
        let size = try In_channel.with_open_bin output In_channel.length with _ -> 0L in
        (Printf.sprintf "%sBuilt %s (%Ld bytes), source in %s. Start it with \
                         run_command: \"%s &\" if it keeps running (a window, a \
                         service), \"%s\" if it ends."
           (if String.trim warnings = "" then "" else "compiler warnings:\n" ^ clip warnings ^ "\n")
           output size src output output, false)
      | _, errors -> ("It does not compile:\n" ^ clip errors, true)
    end
  end

let list_directory path =
  let names = List.sort compare (Array.to_list (Sys.readdir path)) in
  String.concat "\n" (List.map (fun n ->
      let full = Filename.concat path n in
      if (try Sys.is_directory full with Sys_error _ -> false) then n ^ "/"
      else match In_channel.with_open_bin full In_channel.length with
        | len -> Printf.sprintf "%s\t%Ld bytes" n len
        | exception Sys_error _ -> n) names)

(* ---- the tools of installed packages ---- *)

(* /disk/pkg/NAME/tool.json: {"name", "description", "parameters": {NAME:
   DESCRIPTION...}, "command": [WORD...] where "{NAME}" is replaced by an
   argument, "safe": true if it changes nothing (run without asking) *)
type package_tool = { ptool : Llm.tool; command : string list; safe : bool }

let package_tools ?(warn = prerr_endline) () =
  let root = "/disk/pkg" in
  (try Array.to_list (Sys.readdir root) with Sys_error _ -> [])
  |> List.sort compare
  |> List.filter_map (fun pkg ->
      let f = Filename.concat (Filename.concat root pkg) "tool.json" in
      if not (Sys.file_exists f && Sys.file_exists (Filename.concat (Filename.concat root pkg) "installed"))
      then None
      else
        match Json.of_string (In_channel.with_open_bin f In_channel.input_all) with
        | j ->
          (try
             let str k = Json.(member k j |> to_string_value) in
             let params = match Json.member "parameters" j with
               | Json.Object l -> List.map (fun (k, v) -> (k, Json.to_string_value v)) l
               | _ -> [] in
             Some { ptool = { Llm.name = str "name"; description = str "description";
                              schema = string_schema params };
                    command = Json.(member "command" j |> to_list |> List.map to_string_value);
                    safe = (match Json.member "safe" j with Json.Bool b -> b | _ -> false) }
           with Json.Error m | Failure m -> warn (Printf.sprintf "package %s: tool.json: %s" pkg m); None)
        | exception (Json.Error m | Sys_error m) ->
          warn (Printf.sprintf "package %s: tool.json: %s" pkg m); None)

(* a word for sh, in single quotes *)
let quote w = "'" ^ String.concat "'\\''" (String.split_on_char '\'' w) ^ "'"

(* every [pat] in [s], replaced by [by] *)
let replace_all s pat by =
  let b = Buffer.create (String.length s) and n = String.length pat in
  let i = ref 0 in
  while !i < String.length s do
    if !i + n <= String.length s && String.sub s !i n = pat then (Buffer.add_string b by; i := !i + n)
    else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

let run_package_tool ~emit ~confirm t input =
  let params = match Json.(member "properties" (of_string t.ptool.Llm.schema)) with
    | Json.Object l -> List.map fst l | _ -> [] in
  let line = String.concat " " (List.map (fun w ->
      quote (List.fold_left (fun w k -> replace_all w ("{" ^ k ^ "}") (arg input k)) w params))
      t.command) in
  if t.safe then begin emit (Action line); (run_command line, false) end
  else if confirm ("run: " ^ line) then (run_command line, false)
  else ("The user did not allow this command.", true)

(* a tool of the program's (Agent.create ~extra) *)
type extra = {
  tool : Llm.tool;
  run : emit:(event -> unit) -> confirm:(string -> bool) -> string -> string * bool;
}

(* a tool call: (result, is an error) *)
let execute ~emit ~confirm ?(package_tools = []) ?(extra = []) service_tools name input =
  match List.find_opt (fun t -> t.tool.Llm.name = name) extra with
  | Some t -> t.run ~emit ~confirm input
  | None ->
  match List.find_opt (fun t -> t.ptool.Llm.name = name) package_tools with
  | Some t -> run_package_tool ~emit ~confirm t input
  | None ->
  match name with
  | "run_command" ->
    let c = arg input "command" in
    if confirm ("run: " ^ c) then (run_command c, false)
    else ("The user did not allow this command.", true)
  | "run_ocaml" -> run_ocaml ~emit ~confirm (arg input "code")
  | "build_ocaml" -> build_ocaml ~emit ~confirm (arg input "code") (arg input "output")
  | "ocaml_signature" ->
    let m = arg input "module" in
    emit (Action ("signature of " ^ m));
    (ocaml_signature m, false)
  | "read_file" ->
    let p = arg input "path" in
    emit (Action ("read " ^ p));
    (clip (In_channel.with_open_bin p In_channel.input_all), false)
  | "write_file" ->
    let p = arg input "path" and content = arg input "content" in
    if confirm (Printf.sprintf "write %s (%d bytes)" p (String.length content)) then begin
      Out_channel.with_open_bin p (fun oc -> output_string oc content);
      (Printf.sprintf "%d bytes written to %s" (String.length content) p, false)
    end else ("The user did not allow writing this file.", true)
  | "list_directory" ->
    let p = arg input "path" in
    emit (Action ("list " ^ p));
    (list_directory p, false)
  | _ ->
    match Tools.find service_tools name with
    | exception Not_found -> ("No tool " ^ name, true)
    | t ->
      if t.request.safe || confirm (Printf.sprintf "%s %s" name input) then begin
        if t.request.safe then emit (Action (name ^ " " ^ input));
        (clip (Tools.call t input), false)
      end else ("The user did not allow this request.", true)

let execute ~emit ~confirm ?package_tools ?extra service_tools name input =
  match execute ~emit ~confirm ?package_tools ?extra service_tools name input with
  | r -> r
  | exception (Failure m | Sys_error m | Invalid_argument m) -> (m, true)
  | exception Ipc.Remote_error (s, m) -> (s ^ ": " ^ m, true)
  | exception Mynos.Error (f, code) -> (f ^ ": " ^ Mynos.error_name code, true)

(* ---- the model's context ---- *)

let system_prompt services =
  String.concat "\n" [
    "You are an agent inside MyNOS, a small microkernel operating system \
     written in C and OCaml, running on " ^ Mynos.machine () ^ ". You carry out the user's \
     task with your tools, step by step: look before you change things, \
     check what your commands did. When the task is done (or cannot be \
     done), answer with a short final report and no tool call. Answer in \
     the user's language.";
    "";
    "run_command runs one line of MyNOS sh: words with 'quotes' and \
     \"quotes\", $VAR, NAME=value, commands joined by ; && ||, redirections \
     < > >>, pipes |, * and ? in file names; PROGRAM & starts a program \
     in the background and returns at once (a service, which never ends: \
     its pid in $!). There is no arithmetic, no if/for/while, no command \
     substitution. Built in: cd pwd echo cat ls \
     (ls -l) cp mv rm mkdir rmdir touch export unset env which free; \
     ifconfig, ping HOST, host NAME; ps (the processes, and the services \
     each one registered); kill PID or kill SERVICE ends a process. Programs: fetch [-i] [-o FILE] [-H \
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
    "Programs that keep running are built with build_ocaml into a file. \
     A window: Gui.run ~title ~tick:0.1 width height state (fun ui state -> \
     ... next state) calls its function at every event and every tick; \
     draw with Gfx on ui.Gui.g (Gfx.fill g x y w h colour, Gfx.line, \
     Gfx.rect, Gfx.text g x y text colour; colours 0xRRGGBB), widgets \
     with Gui.button, Gui.label...; check Gui and Gfx with ocaml_signature \
     first. Start a window with run_command \"/disk/prog.byte &\": it \
     appears in the graphical session (gui). A program for the terminal \
     writes VT100 escape sequences: \\027[2J clears, \\027[ROW;COLH moves \
     the cursor (from 1;1), \\027[?25l hides it, \\027[31m colours, \
     \\027[?1049h and \\027[?1049l enter and leave the alternate screen; \
     Mynos.console_mode ~canon:false ~echo:false ~vmin:0 ~vtime:1 () reads \
     keys one by one without waiting; Mynos.sleep seconds. Its output is \
     the screen, so the user runs it (run_command would keep its output).";
    "Besides, your tools include the requests of these MyNOS services, \
     described by the services themselves: " ^ String.concat ", " services ^ ".";
    "The current directory: " ^ Sys.getcwd () ]

(* ---- a session ---- *)

type t = {
  llm : Llm.t;
  profile : string;
  services : string list;
  service_tools : Tools.t list;
  package_tools : package_tool list;
  extra : extra list;
  record : bool;
  tools : Llm.tool list;
  system : string;
  max_turns : int;
  trace_file : string;
  mutable yes_to_all : bool;
  mutable messages : Llm.message list;
  mutable tokens_in : int;
  mutable tokens_out : int;
}

let create ?(profile = "") ?(services = [ "net" ]) ?(max_turns = 20)
    ?(trace_file = "/tmp/agent.trc") ?(yes_to_all = false) ?(warn = prerr_endline)
    ?system ?(record = true) ?(extra = []) () =
  let llm = try Llm.connect () with Mynos.Error _ ->
    failwith "no language model service (llmd)" in
  let service_tools = List.concat_map (fun s ->
      match Tools.of_service s with
      | ts -> ts
      | exception e -> warn (Printf.sprintf "service %s: %s" s (Printexc.to_string e)); [])
      services in
  let package_tools = package_tools ~warn () in
  { llm; profile; services; service_tools; package_tools; extra; record;
    tools = List.map (fun t -> t.tool) extra @ own_tools @ List.map (fun t -> t.ptool) package_tools
            @ List.map (fun t -> t.Tools.tool) service_tools;
    system = (match system with Some s -> s | None -> system_prompt services)
             ^ (if package_tools = [] then "" else
                  "\nThe installed packages add these tools: "
                  ^ String.concat ", " (List.map (fun t -> t.ptool.Llm.name) package_tools) ^ "."); max_turns; trace_file; yes_to_all;
    messages = []; tokens_in = 0; tokens_out = 0 }

let tokens a = (a.tokens_in, a.tokens_out)
let trace_file a = a.trace_file
let set_yes_to_all a b = a.yes_to_all <- b
let forget a = a.messages <- []

let run a ~emit ~confirm task =
  (* what changes things: asked, unless yes to all *)
  let confirm what =
    if a.yes_to_all then (emit (Action what); true)
    else match confirm what with
      | Yes -> true
      | All -> a.yes_to_all <- true; true
      | No -> false in
  (* the recorder, read after every step so that its buffer does not fill *)
  let raw = Buffer.create 65536 in
  let recording =
    if not a.record then false else
    match Tracer.start () with
    | () -> true
    | exception Tracer.Busy ->
      emit (Note "not recorded: another program is recording"); false
    | exception _ -> false in
  let drain () = if recording then Buffer.add_string raw (Tracer.read ()) in
  let rec turn n messages =
    if n > a.max_turns then begin
      emit (Note (Printf.sprintf "stopped after %d model calls" a.max_turns));
      (messages, 1)
    end else begin
      if recording then Tracer.mark (Printf.sprintf "model call %d" n);
      match Llm.call a.llm (Llm.Chat { Llm.chat with profile = a.profile; system = a.system;
                                                     messages; tools = a.tools }) with
      | exception Ipc.Remote_error (_, m) -> emit (Note m); (messages, 1)
      | exception Mynos.Error _ -> emit (Note "the language model service is not answering");
        (messages, 1)
      | r ->
        drain ();
        a.tokens_in <- a.tokens_in + r.input_tokens;
        a.tokens_out <- a.tokens_out + r.output_tokens;
        (match Llm.text r with "" -> () | t -> emit (Said (String.trim t)));
        let calls = List.filter_map (function
            | Llm.Tool_call { id; name; input } -> Some (id, name, input)
            | _ -> None) r.content in
        let messages = messages @ [ { Llm.role = Assistant; content = r.content } ] in
        match r.stop, calls with
        | Llm.Tool_use, _ :: _ ->
          let results = List.map (fun (id, name, input) ->
              if recording then begin
                (* the tool and the start of its input: what the step is *)
                let arg = match Json.of_string input with
                  | Json.Object ((_, Json.String s) :: _) -> s
                  | _ | exception _ -> "" in
                let arg = String.map (fun c -> if c < ' ' then ' ' else c) arg in
                Tracer.mark (name ^ (if arg = "" then "" else ": " ^ arg))
              end;
              let content, error = execute ~emit ~confirm ~package_tools:a.package_tools ~extra:a.extra
                  a.service_tools name input in
              drain ();
              emit (Result { text = content; error });
              Llm.Tool_result { id; content; error })
              calls in
          turn (n + 1) (messages @ [ { Llm.role = User; content = results } ])
        | Llm.Max_tokens, _ -> emit (Note "the answer was cut (max_tokens)"); (messages, 1)
        | Llm.Refusal, _ -> emit (Note "the model declined"); (messages, 1)
        | _ -> (messages, 0)
    end in
  emit (Task task);
  let messages, code = turn 1 (a.messages @ [ Llm.user task ]) in
  (* a conversation ends with the model's answer: a refused or cut turn is
     not kept *)
  if code = 0 then a.messages <- messages;
  if recording then begin
    Tracer.stop ();
    drain ();
    let info = Tracer.info () in
    Tracer.free ();
    match Tracer.save a.trace_file ~raw:(Buffer.contents raw) info with
    | () -> emit (Note (Printf.sprintf "recording in %s (trace calls %s)" a.trace_file a.trace_file))
    | exception Sys_error e -> emit (Note ("recording not saved: " ^ e))
  end;
  code

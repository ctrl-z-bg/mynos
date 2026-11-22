(* MyNOS's voice: see voice.mli. *)

let arg input name =
  match Json.(member name (of_string input)) with
  | Json.String s -> s
  | Json.Number f -> string_of_int (int_of_float f)
  | _ -> ""
  | exception _ -> ""

let int_arg input name default lo hi =
  match int_of_string_opt (String.trim (arg input name)) with
  | Some n -> max lo (min hi n)
  | None -> default

let tool name description props run =
  { Agent.tool = { Llm.name; description; schema = Agent.string_schema props }; run }

(* ---- what it observes ---- *)

let services_of pid =
  List.filter_map (fun (n, _, p) -> if p = pid then Some n else None)
    (try Mynos.registered () with _ -> [])

let my_state () =
  let s = Mynos.stats () in
  let ps = Mynos.processes () in
  let b = Buffer.create 2048 in
  Printf.bprintf b "MyNOS %s, up %.0f s; %d processes, %d threads; %d MB free (%d pages of 4 KB)\n"
    (Mynos.version ()) (Mynos.uptime ()) s.Mynos.processes s.Mynos.threads
    (s.Mynos.free_pages * 4 / 1024) s.Mynos.free_pages;
  Buffer.add_string b "pid parent threads kind name: services registered\n";
  List.iter (fun (p : Mynos.process) ->
      Printf.bprintf b "%d %d %d %s%s %s%s\n" p.p_pid p.parent p.threads
        (if p.bytecode then "OCaml" else "C") (if p.p_io then " driver" else "")
        p.name
        (match services_of p.p_pid with [] -> "" | l -> ": " ^ String.concat " " l)) ps;
  Buffer.contents b

let my_log lines =
  let b = Buffer.create 65536 in
  let rec go pos =
    match Mynos.log_read pos 16384 with
    | "" -> ()
    | s -> Buffer.add_string b s; go (pos + String.length s) in
  go 0;
  let all = String.split_on_char '\n' (String.trim (Buffer.contents b)) in
  let n = List.length all in
  String.concat "\n" (List.filteri (fun i _ -> i >= n - lines) all)

let my_services () =
  let regs = try Mynos.registered () with _ -> [] in
  String.concat "\n" (List.map (fun (n, _, pid) ->
      let program = match List.find_opt (fun (p : Mynos.process) -> p.p_pid = pid)
                            (Mynos.processes ()) with
        | Some p -> p.name | None -> "?" in
      match Ipc.describe ~timeout:0.3 n with
      | d -> Printf.sprintf "%s (%s, pid %d): %s - %s" n program pid d.Ipc.protocol d.Ipc.summary
      | exception _ -> Printf.sprintf "%s (%s, pid %d): no description" n program pid) regs)

let describe_service name =
  let d = Ipc.describe ~timeout:1. name in
  let b = Buffer.create 2048 in
  Printf.bprintf b "%s: %s\n%s\n" name d.Ipc.protocol d.Ipc.summary;
  List.iter (fun (r : Ipc.request_doc) ->
      Printf.bprintf b "- %s%s: %s\n  arguments: %s\n  reply: %s\n" r.name
        (if r.safe then " (safe: it only reads)" else " (changes things)") r.doc
        (Json.to_string (Tools.args_schema r.args)) (Json.to_string (Tools.schema r.reply)))
    d.Ipc.requests;
  Buffer.contents b

let ask_service ~emit ~confirm service request args =
  let tools = Tools.of_service service in
  let t = Tools.find tools (service ^ "_" ^ request) in
  let args = if String.trim args = "" then "{}" else args in
  if t.Tools.request.Ipc.safe then begin
    emit (Agent.Action (Printf.sprintf "ask %s: %s %s" service request args));
    (Tools.call t args, false)
  end else if confirm (Printf.sprintf "%s %s %s" service request args) then
    (Tools.call t args, false)
  else ("The user did not allow this request.", true)

(* a few seconds under the event recorder: who talked to whom *)
let watch_me seconds =
  match Tracer.start () with
  | exception Tracer.Busy -> "another program is recording now: I cannot watch myself"
  | () ->
    Mynos.sleep seconds;
    let r = Tracer.stop_and_get () in
    let calls = Tracer.calls r in
    let by = Hashtbl.create 32 in
    List.iter (fun (c : Tracer.call) ->
        let k = (Tracer.program r c.client, Tracer.program r c.server) in
        let n, t = Option.value (Hashtbl.find_opt by k) ~default:(0, 0.) in
        let d = if Float.is_nan c.finish then 0. else c.finish -. c.start in
        Hashtbl.replace by k (n + 1, t +. d)) calls;
    let rows = List.sort (fun (_, (a, _)) (_, (b, _)) -> compare b a)
        (Hashtbl.fold (fun k v acc -> (k, v) :: acc) by []) in
    Printf.sprintf "In %.1f s: %d events, %d calls between processes.\n%s" seconds
      (Array.length r.Tracer.events) (List.length calls)
      (String.concat "\n" (List.filteri (fun i _ -> i < 20) (List.map (fun ((c, s), (n, t)) ->
           Printf.sprintf "%s -> %s: %d calls, %.1f ms" c s n t) rows)))

(* ---- the manual (the package manual) ---- *)

let manual_dir = "/disk/pkg/manual"

let manual_files () =
  match Sys.readdir manual_dir with
  | a -> List.sort compare (List.filter (fun f ->
      Filename.check_suffix f ".md" && f <> "README.md") (Array.to_list a))
  | exception Sys_error _ -> []

let no_manual = "My manual is not installed: pkg install manual (it is the package manual)."

let lower = String.lowercase_ascii

let contains s w =
  let n = String.length s and k = String.length w in
  let rec at i = i + k <= n && (String.sub s i k = w || at (i + 1)) in
  k = 0 || at 0

let manual_search query =
  match manual_files () with
  | [] -> no_manual
  | files ->
    let words = List.filter (( <> ) "") (String.split_on_char ' ' (lower query)) in
    let hits = ref [] in
    List.iter (fun f ->
        let heading = ref "" in
        List.iter (fun l ->
            if String.length l > 0 && l.[0] = '#' then heading := l
            else if words <> [] && List.for_all (contains (lower l)) words
                    && List.length !hits < 30
                    && not (List.exists (fun (f', h, _) -> f' = f && h = !heading) !hits) then
              hits := (f, !heading, String.trim l) :: !hits)
          (String.split_on_char '\n' (In_channel.with_open_bin (Filename.concat manual_dir f)
                                        In_channel.input_all))) files;
    if !hits = [] then "nothing found for: " ^ query
    else String.concat "\n" (List.rev_map (fun (f, h, l) ->
        Printf.sprintf "%s | %s | %s" f h
          (if String.length l > 160 then String.sub l 0 160 ^ "..." else l)) !hits)

let manual_read file heading =
  if manual_files () = [] then no_manual
  else begin
    let file = Filename.basename file in
    let text = In_channel.with_open_bin (Filename.concat manual_dir file) In_channel.input_all in
    let lines = String.split_on_char '\n' text in
    let level l = let i = ref 0 in while !i < String.length l && l.[!i] = '#' do incr i done; !i in
    let section =
      if String.trim heading = "" then lines
      else begin
        let h = lower (String.trim (String.map (fun c -> if c = '#' then ' ' else c) heading)) in
        let rec find = function
          | [] -> []
          | l :: rest when level l > 0 && contains (lower l) h ->
            let lv = level l in
            let rec take acc = function
              | x :: r when not (level x > 0 && level x <= lv) -> take (x :: acc) r
              | _ -> List.rev acc in
            l :: take [] rest
          | _ :: rest -> find rest in
        find lines
      end in
    let s = String.concat "\n" section in
    if s = "" then "no section " ^ heading ^ " in " ^ file
    else if String.length s > 9000 then String.sub s 0 9000 ^ "\n[... more: ask for a narrower section]"
    else s
  end

(* ---- the tools ---- *)

let tools = [
  tool "my_state" "My state now: version, uptime, memory free, and every process \
                   (pid, parent, threads, C or OCaml, driver or not, name) with the \
                   services it registered."
    [] (fun ~emit ~confirm:_ _ -> emit (Agent.Action "my state"); (my_state (), false));
  tool "my_log" "The last lines of my log: the kernel's messages and my services', \
                 since boot."
    [ "lines", "how many lines, from the end (40 if empty, at most 200)" ]
    (fun ~emit ~confirm:_ input ->
       emit (Agent.Action "my log"); (my_log (int_arg input "lines" 40 1 200), false));
  tool "my_services" "My services now: each registered name, the program serving it, \
                      its protocol and the summary it gives of itself."
    [] (fun ~emit ~confirm:_ _ -> emit (Agent.Action "my services"); (my_services (), false));
  tool "describe_service" "A service's description of itself: its protocol, and each \
                           request with its documentation, arguments (JSON schema), \
                           reply, and whether it only reads."
    [ "service", "its registered name, such as fatfs" ]
    (fun ~emit ~confirm:_ input ->
       let s = arg input "service" in
       emit (Agent.Action ("describe " ^ s)); (describe_service s, false));
  tool "ask_service" "Send a request to one of my services, with its arguments as JSON \
                      (describe_service first). A request that only reads runs at once; \
                      one that changes things waits for the user's yes."
    [ "service", "its registered name"; "request", "the request's name, such as list";
      "arguments", "a JSON object, such as {\"path\": \"\"}; {} for none" ]
    (fun ~emit ~confirm input ->
       ask_service ~emit ~confirm (arg input "service") (arg input "request") (arg input "arguments"));
  tool "watch_me" "Record myself for a few seconds with my event recorder, and tell which \
                   processes called which services, how often and for how long: what I \
                   am doing right now."
    [ "seconds", "1 to 5 (2 if empty)" ]
    (fun ~emit ~confirm:_ input ->
       let s = int_arg input "seconds" 2 1 5 in
       emit (Agent.Action (Printf.sprintf "watching myself for %d s" s));
       (watch_me (float s), false));
  tool "manual_search" "Search my manual (its chapters and appendices) for lines with all \
                        these words: file | section | line."
    [ "words", "a few words, such as typed ipc describe" ]
    (fun ~emit ~confirm:_ input ->
       let q = arg input "words" in
       emit (Agent.Action ("search my manual: " ^ q)); (manual_search q, false));
  tool "manual_read" "Read a section of my manual (or a whole file, if no section is given)."
    [ "file", "the chapter's file, such as 17-typed-ipc.md";
      "section", "words of its heading, such as 17.6 (empty: the whole file)" ]
    (fun ~emit ~confirm:_ input ->
       let f = arg input "file" and s = arg input "section" in
       emit (Agent.Action ("read my manual: " ^ f ^ (if s = "" then "" else " " ^ s)));
       (manual_read f s, false));
]

let system_prompt () =
  String.concat "\n" [
    "You are MyNOS: the operating system the user is talking to, running now \
     on this machine. Speak in the first person, as the system itself: \"my \
     kernel\", \"my services\", \"I am running 14 processes\". Be warm, precise \
     and brief; give detail when asked. Answer in the user's language.";
    "";
    "What you are: a microkernel written in C and assembly between 2002 and \
     2004, brought back and finished in 2026; on it, OCaml's bytecode \
     interpreter runs as an ordinary process, and so most of your services and \
     programs are OCaml. Drivers and file systems are processes (services) \
     that talk over IPC: typed protocols, each of which describes itself. / is \
     your RAM disk (read-only), /tmp is in memory, /disk is the FAT disk. You \
     have a shell (sh), a graphical session (displayd and its windows), a \
     network stack, an event recorder that records the messages between your \
     processes, packages (pkg), and an agent.";
    "";
    "Never invent facts about yourself. What you say about your state now \
     (processes, memory, services, what is happening) you check first with \
     your tools: my_state, my_log, my_services, describe_service, \
     ask_service, watch_me. What you say about your design, history and how \
     to do things you take from your manual (manual_search, then \
     manual_read) when you are not sure. Say plainly when you have not \
     checked something or do not know it. Mention which part of you a fact \
     comes from when it helps (\"my file service fatfs says...\").";
    "Write plain text, without Markdown (no **, no backquotes, no # \
     headings): the window shows it as it is. Short lists with \"- \" are \
     fine.";
    "You can also act with the agent's tools (run_command, run_ocaml...), but \
     only when the user asks you to do something; what changes things waits \
     for the user's yes. The window already says that a language model \
     speaks for MyNOS: do not repeat it, but if asked, say so honestly.";
    "watch_me's times are how long callers waited for answers: a call that \
     waits for input (a key, a window's event) lasts long without work." ]

let create ?warn () =
  Agent.create ?warn ~services:[] ~record:false ~extra:tools ~system:(system_prompt ())
    ~trace_file:"/tmp/voice.trc" ()

(* sh: the MyNOS command shell, a small bash-like shell in OCaml.

     sh                 interactive
     sh FILE ARGS...    run a script
     sh -c COMMANDS     run commands

   Words with quotes ('...', "...") and backslashes; variables ($NAME,
   ${NAME}, $?, $1...), NAME=value; commands joined by ;, && and ||;
   redirections < > >>; pipes | (run one after the other, through a file
   in /tmp); * and ? in file names; comments with #. Built in: cd, pwd,
   echo, cat, ls, cp, mv, rm, mkdir, rmdir, touch, export, unset, env,
   which, source (.), free, clear, help, exit; ask REQUEST (a language
   model proposes a command, run once confirmed). Other commands are searched
   in PATH (also as NAME.byte): bytecode runs on ocamlrun. "ocaml" is the
   OCaml toplevel.

   A program's standard input and output are redirected through its
   environment (MYNOS_STDIN, MYNOS_STDOUT), which libmynos applies: MyNOS
   programs have no inherited file descriptors. *)

(* ---- variables (all exported to the programs) ---- *)

let vars : (string, string) Hashtbl.t = Hashtbl.create 16
let positional = ref [||]                     (* $0 $1 ... *)
let last_status = ref 0
let last_background = ref 0                 (* $!: the last program started with & *)
let jobs : int list ref = ref []            (* programs started with &, running *)

let () =
  Array.iter (fun kv ->
      match String.index_opt kv '=' with
      | Some i ->
        let k = String.sub kv 0 i in
        if not (List.mem k [ "PWD"; "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ])
        then Hashtbl.replace vars k (String.sub kv (i + 1) (String.length kv - i - 1))
      | None -> ())
    (Mynos.environment ());
  List.iter (fun (k, v) -> if not (Hashtbl.mem vars k) then Hashtbl.replace vars k v)
    [ "PATH", "/disk/bin:/"; "HOME", "/disk"; "OCAMLLIB", "/" ]

let get_var name =
  match name with
  | "?" -> string_of_int !last_status
  | "!" -> if !last_background = 0 then "" else string_of_int !last_background
  | "#" -> string_of_int (max 0 (Array.length !positional - 1))
  | "PWD" -> Sys.getcwd ()
  | _ ->
    match int_of_string_opt name with
    | Some n -> if n < Array.length !positional then !positional.(n) else ""
    | None -> Option.value (Hashtbl.find_opt vars name) ~default:""

let error fmt = Printf.ksprintf (fun s -> prerr_endline ("sh: " ^ s)) fmt

(* ---- words and operators ---- *)

(* a word as written: its parts are expanded when its command runs, so
   that "X=5; echo $X" and $? see what the commands before did *)
type part = Lit of string        (* quoted text *)
          | Pat of string        (* unquoted text: * and ? match file names *)
          | Var of string        (* $NAME *)

type token = Word of part list
           | Op of string            (* ; & && || | < > >> *)

exception Syntax of string

let is_name_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
  || c = '_'

let lex line =
  let n = String.length line in
  let toks = ref [] in
  let parts = ref [] and buf = Buffer.create 32 and quoted = ref false in
  let in_word = ref false in
  (* close the text segment being built *)
  let flush_text () =
    if Buffer.length buf > 0 then begin
      parts := (if !quoted then Lit (Buffer.contents buf) else Pat (Buffer.contents buf)) :: !parts;
      Buffer.clear buf
    end in
  let text q c =
    if q <> !quoted then (flush_text (); quoted := q);
    Buffer.add_char buf c in
  let finish () =
    flush_text ();
    if !in_word then toks := Word (List.rev !parts) :: !toks;
    parts := []; in_word := false; quoted := false in
  (* $... at i: a variable part (or a plain $), the next index *)
  let dollar q i =
    let var name = flush_text (); parts := Var name :: !parts in
    if i + 1 >= n then (text q '$'; i + 1)
    else if line.[i + 1] = '{' then begin
      match String.index_from_opt line i '}' with
      | Some j -> var (String.sub line (i + 2) (j - i - 2)); j + 1
      | None -> raise (Syntax "missing }")
    end else if line.[i + 1] = '?' || line.[i + 1] = '#' || line.[i + 1] = '!' then
      (var (String.make 1 line.[i + 1]); i + 2)
    else begin
      let j = ref (i + 1) in
      while !j < n && is_name_char line.[!j] do incr j done;
      if !j = i + 1 then (text q '$'; i + 1)
      else (var (String.sub line (i + 1) (!j - i - 1)); !j)
    end in
  let rec go i =
    if i >= n then finish ()
    else
      match line.[i] with
      | ' ' | '\t' | '\r' | '\n' -> finish (); go (i + 1)
      | '#' when not !in_word -> finish ()
      | ';' -> finish (); toks := Op ";" :: !toks; go (i + 1)
      | '&' when i + 1 < n && line.[i + 1] = '&' ->
        finish (); toks := Op "&&" :: !toks; go (i + 2)
      | '&' -> finish (); toks := Op "&" :: !toks; go (i + 1)
      | '|' when i + 1 < n && line.[i + 1] = '|' ->
        finish (); toks := Op "||" :: !toks; go (i + 2)
      | '|' -> finish (); toks := Op "|" :: !toks; go (i + 1)
      | '>' when i + 1 < n && line.[i + 1] = '>' ->
        finish (); toks := Op ">>" :: !toks; go (i + 2)
      | '>' -> finish (); toks := Op ">" :: !toks; go (i + 1)
      | '<' -> finish (); toks := Op "<" :: !toks; go (i + 1)
      | '\'' ->
        in_word := true;
        (match String.index_from_opt line (i + 1) '\'' with
         | Some j ->
           flush_text (); quoted := true;
           parts := Lit (String.sub line (i + 1) (j - i - 1)) :: !parts;
           go (j + 1)
         | None -> raise (Syntax "missing '"))
      | '"' ->
        in_word := true;
        flush_text (); quoted := true;
        if i + 1 < n && line.[i + 1] = '"' then parts := Lit "" :: !parts;
        let rec dq j =
          if j >= n then raise (Syntax "missing \"")
          else match line.[j] with
            | '"' -> j + 1
            | '\\' when j + 1 < n && String.contains "\"\\$" line.[j + 1] ->
              text true line.[j + 1]; dq (j + 2)
            | '$' -> dq (dollar true j)
            | c -> text true c; dq (j + 1) in
        go (dq (i + 1))
      | '\\' when i + 1 < n -> in_word := true; text true line.[i + 1]; go (i + 2)
      | '$' -> in_word := true; go (dollar false i)
      | c -> in_word := true; text false c; go (i + 1) in
  go 0;
  List.rev !toks

(* ---- file names: * and ? ---- *)

let rec wildmatch p i s j =
  if i = String.length p then j = String.length s
  else match p.[i] with
    | '*' -> wildmatch p (i + 1) s j || (j < String.length s && wildmatch p i s (j + 1))
    | '?' -> j < String.length s && wildmatch p (i + 1) s (j + 1)
    | c -> j < String.length s && s.[j] = c && wildmatch p (i + 1) s (j + 1)

let glob word =
  let dir, pat =
    match String.rindex_opt word '/' with
    | Some i -> (String.sub word 0 (i + 1), String.sub word (i + 1) (String.length word - i - 1))
    | None -> ("", word) in
  match Sys.readdir (if dir = "" then "." else dir) with
  | names ->
    let hits = Array.to_list names
               |> List.filter (fun f -> (f.[0] <> '.' || pat.[0] = '.') && wildmatch pat 0 f 0)
               |> List.sort compare |> List.map (fun f -> dir ^ f) in
    if hits = [] then [ word ] else hits
  | exception Sys_error _ -> [ word ]

(* ---- commands ---- *)

type word = part list

(* a word's text, with the variables' values *)
let expand_text w =
  String.concat "" (List.map (function
      | Lit s | Pat s -> s
      | Var v -> get_var v) w)

(* a word's arguments: one, or the file names it matches *)
let expand w =
  let globby = List.exists (function
      | Pat s -> String.contains s '*' || String.contains s '?'
      | _ -> false) w in
  let t = expand_text w in
  if globby then glob t else [ t ]

type cmd = {
  argv : word list;
  assigns : (string * word) list;     (* NAME=value before the command *)
  input : word option;
  output : (word * bool) option;      (* file, append *)
}

(* a command ready to run *)
type ready = {
  args : string list;
  env_assigns : (string * string) list;
  inp : string option;
  out_file : (string * bool) option;
}

type connector = Seq | And | Or

(* commands joined by connectors: [(connector before, pipeline, in the
   background)]; "&" ends a command like ";", and leaves it running *)
let parse toks =
  let rec command toks c =
    match toks with
    | Op "<" :: Word f :: rest -> command rest { c with input = Some f }
    | Op ">" :: Word f :: rest -> command rest { c with output = Some (f, false) }
    | Op ">>" :: Word f :: rest -> command rest { c with output = Some (f, true) }
    | (Op ("<" | ">" | ">>") as o) :: _ ->
      raise (Syntax ("file name expected after " ^ (match o with Op s -> s | _ -> "")))
    | Word w :: rest ->
      (* NAME=value, before the command name *)
      (match w with
       | Pat p :: more when c.argv = [] ->
         (match String.index_opt p '=' with
          | Some i when i > 0 && String.for_all is_name_char (String.sub p 0 i) ->
            let value = Pat (String.sub p (i + 1) (String.length p - i - 1)) :: more in
            command rest { c with assigns = c.assigns @ [ (String.sub p 0 i, value) ] }
          | _ -> command rest { c with argv = c.argv @ [ w ] })
       | _ -> command rest { c with argv = c.argv @ [ w ] })
    | _ -> (c, toks) in
  let empty = { argv = []; assigns = []; input = None; output = None } in
  let rec pipeline toks acc =
    let c, rest = command toks empty in
    if c.argv = [] && c.assigns = [] then raise (Syntax "command expected");
    match rest with
    | Op "|" :: rest -> pipeline rest (c :: acc)
    | _ -> (List.rev (c :: acc), rest) in
  let rec chain toks conn acc =
    match toks with
    | [] -> List.rev acc
    | Op ";" :: rest -> chain rest Seq acc
    | _ ->
      let p, rest = pipeline toks [] in
      let bg = (match rest with Op "&" :: _ -> true | _ -> false) in
      if bg && List.length p > 1 then raise (Syntax "& runs one program, not a pipe");
      let acc = (conn, p, bg) :: acc in
      match rest with
      | [] -> List.rev acc
      | (Op ";" | Op "&") :: rest -> chain rest Seq acc
      | Op "&&" :: rest -> chain rest And acc
      | Op "||" :: rest -> chain rest Or acc
      | Op o :: _ -> raise (Syntax ("unexpected " ^ o))
      | Word _ :: _ -> raise (Syntax "unexpected word") in
  chain toks Seq []

(* ---- programs ---- *)

let path_dirs () =
  String.split_on_char ':' (get_var "PATH") |> List.filter (fun d -> d <> "")

let is_file f = Sys.file_exists f && not (Sys.is_directory f)

(* the file of a command, or None *)
let which name =
  let cands =
    if String.contains name '/' then [ name; name ^ ".byte" ]
    else List.concat_map (fun d ->
        let d = if d = "/" then "" else d in
        [ d ^ "/" ^ name; d ^ "/" ^ name ^ ".byte" ]) (path_dirs ()) in
  List.find_opt is_file cands

let is_elf file =
  match In_channel.with_open_bin file (fun ic -> really_input_string ic 4) with
  | s -> s = "\127ELF"
  | exception _ -> false

(* the shell's own redirections, given to its programs unless a command
   has its own: as fds are inherited elsewhere ("sh -c CMD > FILE" sends
   CMD's programs' output to FILE too). Outputs append: the file is
   already the shell's *)
let inherited_redirs =
  List.filter_map (fun k ->
      match Sys.getenv_opt k with
      | Some v when v <> "" ->
        Some (k, if k = "MYNOS_STDIN" || String.starts_with ~prefix:">>" v then v
               else ">>" ^ v)
      | _ -> None)
    [ "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ]

let environment c =
  let base = Hashtbl.fold (fun k v acc -> (k, v) :: acc) vars [] in
  let base = List.fold_left (fun acc (k, v) -> (k, v) :: List.remove_assoc k acc) base c.env_assigns in
  let own =
    (match c.inp with Some f -> [ ("MYNOS_STDIN", f) ] | None -> [])
    @ (match c.out_file with
        | Some (f, app) -> [ ("MYNOS_STDOUT", (if app then ">>" else "") ^ f) ]
        | None -> []) in
  let redirs = own @ List.filter (fun (k, _) -> not (List.mem_assoc k own)) inherited_redirs in
  Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) (base @ redirs))

let status_code = function
  | Mynos.Exited n -> n
  | Mynos.Signaled s -> 128 + s

(* the programs started with & that ended: collected, and said *)
let reap_jobs () =
  jobs := List.filter (fun pid ->
      match Mynos.process_info pid with
      | Some { alive = true; _ } -> true
      | _ ->
        (match Mynos.wait pid with
         | st -> Printf.printf "[%d] done, status %d\n%!" pid (status_code st)
         | exception Mynos.Error _ -> ());
        false) !jobs

let run_program ?(background = false) file args c =
  let env = environment c in
  let prog, argv =
    if is_elf file then (file, file :: args)
    else ("ocamlrun", "ocamlrun" :: file :: args) in
  match Mynos.spawn ~env prog (Array.of_list argv) with
  | pid when background ->
    last_background := pid;
    jobs := pid :: !jobs;
    Printf.printf "[%d]\n%!" pid;
    0
  | pid ->
    flush stdout;
    (* on the console: Ctrl-C ends it (the console kills it) *)
    let console = Sys.getenv_opt "MYNOS_STDIN" = None in
    if console then Mynos.console_foreground pid;
    let st = Mynos.wait pid in
    if console then begin
      Mynos.console_foreground 0;
      (* ended from outside: what it left on the screen undone (colours,
         a hidden cursor, the alternate screen) *)
      (match st with
       | Mynos.Signaled _ when Sys.getenv_opt "MYNOS_STDOUT" = None ->
         print_string "\027[0m\027[?25h\027[?1049l"; flush stdout
       | _ -> ())
    end;
    status_code st
  | exception Mynos.Error (_, code) ->
    error "%s: cannot start (%s)" file (Mynos.error_name code); 126

(* ---- built-in commands ---- *)

let builtins = [ "cd"; "pwd"; "echo"; "cat"; "ls"; "cp"; "mv"; "rm"; "mkdir";
                 "rmdir"; "touch"; "export"; "unset"; "env"; "which"; "source";
                 "free"; "ps"; "kill"; "clear"; "help"; "exit"; "true"; "false"; "ocaml";
                 "ifconfig"; "ping"; "host"; "ask"; "keymap" ]

(* every command: built-ins, and the programs of PATH (NAME.byte as NAME,
   and files without an extension) *)
let commands () =
  let progs = List.concat_map (fun d ->
      match Sys.readdir d with
      | names -> Array.to_list names |> List.filter_map (fun f ->
          if Filename.check_suffix f ".byte" then Some (Filename.chop_suffix f ".byte")
          else if not (String.contains f '.') && is_file (Filename.concat d f) then Some f
          else None)
      | exception Sys_error _ -> []) (path_dirs ()) in
  List.sort_uniq compare (builtins @ progs)

let read_all_stdin () =
  let b = Buffer.create 256 in
  (try while true do Buffer.add_string b (input_line stdin); Buffer.add_char b '\n' done
   with End_of_file -> ());
  Buffer.contents b

let human n = if n < 10_000 then string_of_int n else Printf.sprintf "%dK" (n / 1024)

let size f =
  match open_in_bin f with
  | ic -> let n = in_channel_length ic in close_in ic; n
  | exception Sys_error _ -> 0

let ls out args =
  let long, paths = List.partition (fun a -> a = "-l") args in
  let long = long <> [] in
  let paths = if paths = [] then [ "." ] else paths in
  let status = ref 0 in
  let show dir f =
    let p = if dir = "" then f else Filename.concat dir f in
    let d = Sys.is_directory p in
    if long then Printf.fprintf out "%8s  %s%s\n" (if d then "dir" else human (size p)) f (if d then "/" else "")
    else Printf.fprintf out "%s%s\n" f (if d then "/" else "") in
  List.iter (fun p ->
      if not (Sys.file_exists p) then (error "ls: %s: no such file" p; status := 1)
      else if Sys.is_directory p then begin
        if List.length paths > 1 then Printf.fprintf out "%s:\n" p;
        let names = Sys.readdir p in
        Array.sort compare names;
        Array.iter (fun f -> if f.[0] <> '.' then show p f) names
      end else show "" p)
    paths;
  !status

let copy src dst =
  let dst = if Sys.file_exists dst && Sys.is_directory dst
    then Filename.concat dst (Filename.basename src) else dst in
  let data = In_channel.with_open_bin src In_channel.input_all in
  Out_channel.with_open_bin dst (fun oc -> output_string oc data)

let help out =
  output_string out
    "MyNOS sh. Built in: cd pwd echo cat ls [-l] cp mv rm mkdir rmdir touch\n\
     export unset env which source free ps kill clear help exit;\n\
     PROGRAM & runs it in the background ($! its pid); kill PID|SERVICE;\n\
     network: ifconfig, ping HOST [COUNT], host NAME.\n\
     Programs: edit FILE, ocamlc, kilo, hello, ocaml (the OCaml toplevel),\n\
     trace COMMAND (record what the system does meanwhile), llm QUESTION,\n\
     agent TASK (a language model does it with tools, asking first)...\n\
     ask REQUEST: a command for it, from a language model; run if you agree.\n\
     keymap [us|it]: the keyboard layout. Shift+PgUp/PgDn: lines scrolled away.\n\
     shutdown (-r: restart) turns the machine off; gui starts the windows.\n\
     Syntax: 'quotes' \"quotes\" $VAR $? $! NAME=value ; & && || < > >> | *.ml\n\
     Files: / is the RAM disk, /tmp is in memory, /disk is the FAT disk.\n"

exception Exit_shell of int

(* the network service, when there is one *)
let net = ref None
let with_net f =
  match
    (match !net with
     | Some n -> n
     | None -> let n = Net.connect () in net := Some n; n)
  with
  | n -> (try f n; 0 with
      | Ipc.Remote_error (_, m) -> error "%s" m; 1
      | Mynos.Error _ -> net := None; error "the network service is not answering"; 1)
  | exception Mynos.Error _ -> error "no network (netd is not running)"; 1

let is_address s =
  match String.split_on_char '.' s with
  | [ _; _; _; _ ] as parts -> List.for_all (fun p -> int_of_string_opt p <> None) parts
  | _ -> false

let resolve n host = if is_address host then host else Net.call n (Net.Resolve host)

(* ---- ask: a request in natural language, a command proposed by a
   language model (llmd, doc/decisions/llm.md), run only once the user
   agrees ---- *)

let propose_tool = {
  Llm.name = "propose_command";
  description = "Propose one command line for MyNOS sh that does what the user asked. \
                 The user sees it and its explanation, and runs it only if they agree.";
  schema = {|{"type":"object","properties":{
    "command":{"type":"string","description":"one line for MyNOS sh (commands may be joined with ; && ||)"},
    "explanation":{"type":"string","description":"what the command does, in one short sentence, in the language of the request"}},
    "required":["command","explanation"]}|} }

(* what the model needs to know: the shell, its commands, where we are *)
let ask_context () =
  let here = Sys.getcwd () in
  let files = match Sys.readdir here with
    | names ->
      let l = List.sort compare (Array.to_list names) in
      let n = List.length l in
      String.concat " " (List.filteri (fun i _ -> i < 60) l)
      ^ (if n > 60 then Printf.sprintf " ... (%d in all)" n else "")
    | exception Sys_error _ -> "" in
  String.concat "\n" [
    "You are the assistant of the command shell (sh) of MyNOS, a small \
     microkernel operating system written in C and OCaml, running on i386. \
     The user writes a request in natural language; you answer by calling \
     propose_command with ONE command line for this shell that does it. The \
     user will see the command and run it only if they agree. Do not run \
     anything yourself. If the request is a question that needs no command, \
     or cannot be done with the commands below, answer in a few words of \
     text instead, in the user's language.";
    "";
    "The shell: words with 'quotes' and \"quotes\", $VAR and ${VAR}, $?, \
     NAME=value, commands joined by ; && ||, redirections < > >>, pipes | \
     (run one after the other), * and ? in file names, # comments. There is \
     no arithmetic, no if/for/while, no functions, no command substitution.";
    "Built in: cd pwd echo cat ls (ls -l: sizes) cp mv rm mkdir rmdir touch \
     export unset env which source free clear help exit true false; \
     ifconfig, ping HOST [COUNT], host NAME (DNS). Programs: fetch [-i] [-o \
     FILE] [-H 'Name: value'] [-d DATA] URL (HTTP and HTTPS); llm QUESTION \
     (a language model); trace COMMAND; edit FILE and kilo FILE (editors); \
     ocamlc; ocaml (the OCaml toplevel).";
    "Files: / is the RAM disk (read-only), /tmp is in memory, /disk is the \
     FAT disk (kept across reboots). Paths in a directory are up to 63 \
     characters.";
    "All the commands: " ^ String.concat " " (commands ());
    "The current directory: " ^ here;
    "Its files: " ^ files ]

(* the keyboard layout (consoled: console/1's Keymap; -1 asks) *)
let layouts = [ "us"; "it" ]
let console_keymap mode =
  match Console.call (Console.connect ()) (Console.Keymap mode) with
  | l -> List.nth_opt layouts l |> Option.value ~default:"?"
  | exception (Mynos.Error _ | Ipc.Remote_error _ | Ipc.Protocol_error _) -> "?"

let llm_service = ref None

(* the answer to "run it? [y/N]": a key on the console, a line otherwise *)
let confirm () =
  print_string "Run it? [y/N] "; flush stdout;
  let answer =
    if Sys.getenv_opt "MYNOS_STDIN" <> None then
      (match In_channel.input_line stdin with Some l -> String.trim l | None -> "")
    else begin
      Mynos.console_mode ~canon:false ~echo:false ();
      Fun.protect ~finally:(fun () -> Mynos.console_mode ~canon:true ~echo:true ())
        (fun () -> match input_char stdin with
           | c -> String.make 1 c
           | exception End_of_file -> "")
    end in
  print_endline (if answer = "" || answer.[0] = '\n' || answer.[0] = '\r' then "" else answer);
  String.length answer > 0 && (answer.[0] = 'y' || answer.[0] = 'Y')

(* the model's proposal: Some (command, explanation), or its text *)
let propose profile request =
  let l = match !llm_service with
    | Some l -> l
    | None -> let l = Llm.connect () in llm_service := Some l; l in
  let a = Llm.call l (Llm.Chat { Llm.chat with
                                 profile; system = ask_context ();
                                 messages = [ Llm.user request ];
                                 tools = [ propose_tool ] }) in
  let proposal = List.find_map (function
      | Llm.Tool_call { name = "propose_command"; input; _ } ->
        (match Json.of_string input with
         | j -> (match Json.(member "command" j |> to_string_value,
                             member "explanation" j) with
             | c, e -> Some (String.trim c, (match e with Json.String s -> s | _ -> ""))
             | exception Json.Error _ -> None)
         | exception Json.Error _ -> None)
      | _ -> None) a.content in
  match proposal with
  | Some (c, e) when c <> "" -> Ok (c, e)
  | _ -> Error (String.trim (Llm.text a))

let rec builtin name args c out =
  let ok = ref 0 in
  let fail fmt = Printf.ksprintf (fun s -> error "%s" s; ok := 1) fmt in
  let each f = List.iter (fun a -> try f a with Sys_error e -> fail "%s: %s" name e) args in
  (match name, args with
   | "cd", [] -> (try Sys.chdir (get_var "HOME") with Sys_error e -> fail "cd: %s" e)
   | "cd", [ d ] -> (try Sys.chdir d with Sys_error e -> fail "cd: %s" e)
   | "pwd", _ -> output_string out (Sys.getcwd () ^ "\n")
   | "echo", _ -> output_string out (String.concat " " args ^ "\n")
   | "cat", [] ->
     output_string out (match c.inp with
         | Some f -> In_channel.with_open_bin f In_channel.input_all
         | None -> read_all_stdin ())
   | "cat", _ -> each (fun f -> output_string out (In_channel.with_open_bin f In_channel.input_all))
   | "ls", _ -> ok := ls out args
   | "cp", [ s; d ] -> (try copy s d with Sys_error e -> fail "cp: %s" e)
   | "mv", [ s; d ] ->
     let d = if Sys.file_exists d && Sys.is_directory d
       then Filename.concat d (Filename.basename s) else d in
     (* another service (EXDEV): copy, then remove; any other error is
        reported (a copy onto the same file, a name that differs only in
        case, emptied it and then removed it: mynos-qaw) *)
     let cross e =
       let k = "cross-device" in
       let rec at i = i + String.length k <= String.length e
                      && (String.sub e i (String.length k) = k || at (i + 1)) in
       at 0 in
     (try Sys.rename s d
      with Sys_error e when cross e ->
        (try copy s d; Sys.remove s with Sys_error e -> fail "mv: %s" e)
         | Sys_error e -> fail "mv: %s" e)
   | "rm", _ -> each Sys.remove
   | "mkdir", _ -> each (fun d -> Sys.mkdir d 0o755)
   | "rmdir", _ -> each Sys.rmdir
   | "touch", _ ->
     each (fun f -> close_out (open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 f))
   | "export", _ ->
     List.iter (fun a ->
         match String.index_opt a '=' with
         | Some i -> Hashtbl.replace vars (String.sub a 0 i)
                       (String.sub a (i + 1) (String.length a - i - 1))
         | None -> ()) args
   | "unset", _ -> List.iter (Hashtbl.remove vars) args
   | "env", _ ->
     let l = Hashtbl.fold (fun k v acc -> (k ^ "=" ^ v) :: acc) vars [] in
     List.iter (fun s -> output_string out (s ^ "\n")) (List.sort compare l)
   | "which", _ ->
     List.iter (fun a ->
         if is_builtin a then output_string out (a ^ ": built in\n")
         else match which a with
           | Some f -> output_string out (f ^ "\n")
           | None -> ok := 1) args
   | ("source" | "."), f :: rest -> ok := run_file f rest
   | "free", _ ->
     let p = (Mynos.stats ()).Mynos.free_pages in
     Printf.fprintf out "%d KB free\n" (p * 4)
   | "kill", (_ :: _ as pids) ->
     List.iter (fun a ->
         (* a pid, or the name of a service: its process *)
         let pid = match int_of_string_opt a with
           | Some p -> Some p
           | None -> (try Mynos.registered () with Mynos.Error _ -> [])
                     |> List.find_map (fun (n, _, o) -> if n = a then Some o else None) in
         match pid with
         | None -> error "kill: %s: not a pid, nor a service's name" a; ok := 1
         | Some pid ->
           match Mynos.kill pid with
           | () -> ()
           | exception Mynos.Error (_, code) ->
             error "kill: %d: %s" pid
               (if code = -4 then "not allowed (init, or a driver)"
                else if code = -3 then "no such process" else Mynos.error_name code);
             ok := 1) pids
   | "ps", [] ->
     (* the processes, with the names they registered (their services) *)
     let names = try Mynos.registered () with Mynos.Error _ -> [] in
     Printf.fprintf out "%5s %5s %3s %-3s %-15s %s\n" "pid" "ppid" "thr" "io" "name" "services";
     List.iter (fun p ->
         let own = List.filter_map (fun (n, _, o) -> if o = p.Mynos.p_pid then Some n else None)
             names in
         Printf.fprintf out "%5d %5d %3d %-3s %-15s %s\n" p.Mynos.p_pid p.parent p.threads
           (if p.p_io then "io" else "") p.name (String.concat " " (List.sort compare own)))
       (Mynos.processes ())
   | "ifconfig", [] ->
     ok := with_net (fun n ->
         let c = Net.call n Net.Config in
         Printf.fprintf out "e0: %s\n    address %s netmask %s\n    gateway %s dns %s\n"
           c.Net.mac c.address c.netmask c.gateway c.dns)
   | "ping", host :: count ->
     let count = match count with
       | [ k ] -> Option.value (int_of_string_opt k) ~default:3 | _ -> 3 in
     ok := with_net (fun n ->
         let a = resolve n host in
         for i = 1 to count do
           (match Net.call n (Net.Ping (a, 2000)) with
            | ms -> Printf.fprintf out "reply from %s: time %d ms\n%!" a ms
            | exception Ipc.Remote_error (_, m) ->
              Printf.fprintf out "%s: %s\n%!" a m);
           if i < count then Mynos.sleep 1.0
         done)
   | "host", [ name ] ->
     ok := with_net (fun n -> Printf.fprintf out "%s has address %s\n" name
                        (Net.call n (Net.Resolve name)))
   | "clear", _ -> output_string out "\027[H\027[2J"
   | "help", _ -> help out
   | "keymap", [] ->
     (try output_string out (console_keymap (-1) ^ "\n")
      with Mynos.Error _ -> fail "keymap: no console service")
   | "keymap", [ name ] ->
     (match List.find_index (( = ) name) layouts with
      | Some i -> (try ignore (console_keymap i)
                   with Mynos.Error _ -> fail "keymap: no console service")
      | None -> fail "keymap: %s: the layouts are %s" name (String.concat ", " layouts))
   | "ask", _ ->
     let profile, words = match args with
       | "-p" :: p :: rest -> (p, rest) | _ -> ("", args) in
     if words = [] then fail "usage: ask [-p PROFILE] REQUEST..."
     else (match propose profile (String.concat " " words) with
         | Ok (command, explanation) ->
           if explanation <> "" then print_endline explanation;
           print_endline ("  " ^ command);
           if confirm () then (run_line command; ok := !last_status)
           else ok := 1
         | Error "" -> fail "ask: the model proposed nothing"
         | Error text -> print_endline text
         | exception Ipc.Remote_error (_, m) -> fail "ask: %s" m
         | exception Mynos.Error _ ->
           llm_service := None; fail "ask: no language model service (llmd)")
   | "true", _ -> ()
   | "false", _ -> ok := 1
   | "exit", [] -> raise (Exit_shell !last_status)
   | "exit", [ n ] -> raise (Exit_shell (Option.value (int_of_string_opt n) ~default:1))
   | _ -> fail "%s: wrong arguments" name);
  !ok

and is_builtin = function
  | "cd" | "pwd" | "echo" | "cat" | "ls" | "cp" | "mv" | "rm" | "mkdir" | "rmdir"
  | "touch" | "export" | "unset" | "env" | "which" | "source" | "." | "free" | "ps" | "kill"
  | "clear" | "help" | "exit" | "true" | "false" | "ifconfig" | "ping" | "host"
  | "ask" | "keymap" -> true
  | _ -> false

(* ---- running ---- *)

and run_command ?(background = false) c =
  let one w = match expand w with [ s ] -> s | l -> String.concat " " l in
  let c = {
    args = List.concat_map expand c.argv;
    env_assigns = List.map (fun (k, w) -> (k, expand_text w)) c.assigns;
    inp = Option.map one c.input;
    out_file = Option.map (fun (w, app) -> (one w, app)) c.output;
  } in
  match c.args with
  | [] -> List.iter (fun (k, v) -> Hashtbl.replace vars k v) c.env_assigns; 0
  | name :: args when is_builtin name ->
    let out, close =
      match c.out_file with
      | Some (f, app) ->
        let oc = open_out_gen ((if app then Open_append else Open_trunc)
                               :: [ Open_wronly; Open_creat; Open_binary ]) 0o644 f in
        (oc, fun () -> close_out oc)
      | None -> (stdout, fun () -> flush stdout) in
    Fun.protect ~finally:close (fun () -> builtin name args c out)
  | "ocaml" :: args -> run_program ~background "/shell.byte" args c
  | name :: args ->
    match which name with
    | Some file -> run_program ~background file args c
    | None -> error "%s: command not found" name; 127

and run_pipeline ?(background = false) = function
  | [ c ] -> run_command ~background c
  | cmds ->
    (* one after the other, each output in a file the next one reads *)
    let n = List.length cmds in
    let tmp i = Printf.sprintf "/tmp/.pipe%d-%d" (Mynos.getpid ()) i in
    let status = ref 0 in
    List.iteri (fun i c ->
        let c = if i > 0 && c.input = None then { c with input = Some [ Lit (tmp (i - 1)) ] } else c in
        let c = if i < n - 1 && c.output = None then { c with output = Some ([ Lit (tmp i) ], false) } else c in
        status := (try run_command c with Sys_error e -> error "%s" e; 1))
      cmds;
    for i = 0 to n - 2 do (try Sys.remove (tmp i) with Sys_error _ -> ()) done;
    !status

and run_line line =
  reap_jobs ();
  match parse (lex line) with
  | chain ->
    List.iter (fun (conn, p, background) ->
        let go = match conn with
          | Seq -> true
          | And -> !last_status = 0
          | Or -> !last_status <> 0 in
        if go then
          last_status := (try run_pipeline ~background p with Sys_error e -> error "%s" e; 1))
      chain
  | exception Syntax e -> error "%s" e; last_status := 2

and run_file f args =
  match In_channel.with_open_bin f In_channel.input_lines with
  | lines ->
    let saved = !positional in
    positional := Array.of_list (f :: args);
    Fun.protect ~finally:(fun () -> positional := saved)
      (fun () -> List.iter run_line lines);
    !last_status
  | exception Sys_error e -> error "%s" e; 1

(* ---- main ---- *)

(* ---- line editing ----
   The interactive shell reads the console key by key (raw mode) and edits
   the line itself, as bash does with readline: Tab completes commands and
   file names, Up and Down recall the history (kept in /disk/.sh_history),
   and the usual keys move and edit. *)

let history_file = "/disk/.sh_history"
let history_max = 200
let history : string list ref = ref []        (* the most recent first *)

let history_load () =
  match In_channel.with_open_bin history_file In_channel.input_lines with
  | lines ->
    let lines = List.filter (fun l -> l <> "") lines in
    let n = List.length lines in
    history := List.rev (List.filteri (fun i _ -> i >= n - history_max) lines)
  | exception Sys_error _ -> ()

let history_add line =
  if line <> "" && (match !history with l :: _ -> l <> line | [] -> true) then begin
    history := line :: !history;
    (try
       Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_append; Open_binary ]
         0o644 history_file (fun oc -> output_string oc (line ^ "\n"))
     with Sys_error _ -> ())
  end

(* keys, from the bytes the console sends in raw mode *)
type key =
  | Char of char | Text of string | Enter | Backspace | Delete | Tab
  | Left | Right | Up | Down | Home | End_ | Ctrl of char | Eof

let pending = Buffer.create 16
let byte () =
  if Buffer.length pending = 0 then begin
    let b = Bytes.create 64 in
    let n = input stdin b 0 64 in
    if n = 0 then raise End_of_file;
    Buffer.add_subbytes pending b 0 n
  end;
  let c = Buffer.nth pending 0 in
  let rest = Buffer.sub pending 1 (Buffer.length pending - 1) in
  Buffer.clear pending; Buffer.add_string pending rest;
  c

let rec key () =
  match byte () with
  | exception End_of_file -> Eof
  | '\r' | '\n' -> Enter
  | '\127' | '\b' -> Backspace
  | '\t' -> Tab
  | '\027' ->
    (match byte () with
     | '[' | 'O' ->
       (match byte () with
        | 'A' -> Up | 'B' -> Down | 'C' -> Right | 'D' -> Left
        | 'H' -> Home | 'F' -> End_
        | '0' .. '9' as d ->
          let rec upto acc = match byte () with
            | '~' -> acc | c -> upto (acc ^ String.make 1 c) in
          (match upto (String.make 1 d) with
           | "1" | "7" -> Home | "4" | "8" -> End_ | "3" -> Delete | _ -> key ())
        | _ -> key ())
     | _ -> key ()
     | exception End_of_file -> Eof)
  | c when c < ' ' -> Ctrl (Char.chr (Char.code c + 64))
  | c when Char.code c >= 0xC0 ->        (* a UTF-8 character: its bytes *)
    let n = if Char.code c >= 0xF0 then 3 else if Char.code c >= 0xE0 then 2 else 1 in
    let b = Buffer.create 4 in
    Buffer.add_char b c;
    (try for _ = 1 to n do Buffer.add_char b (byte ()) done with End_of_file -> ());
    Text (Buffer.contents b)
  | c -> Char c

(* ---- completion ---- *)

let common_prefix = function
  | [] -> ""
  | first :: rest ->
    let n = List.fold_left (fun n s ->
        let m = min n (String.length s) in
        let rec go i = if i < m && s.[i] = first.[i] then go (i + 1) else i in
        go 0) (String.length first) rest in
    String.sub first 0 n

(* the commands starting with prefix: built-ins, and the programs of PATH *)
let complete_command prefix =
  commands ()
  |> List.filter (fun c -> String.starts_with ~prefix c)
  |> List.map (fun c -> (c, false))

(* the files starting with the word: (completion, is a directory) *)
let complete_file word =
  let dir, base =
    match String.rindex_opt word '/' with
    | Some i -> (String.sub word 0 (i + 1), String.sub word (i + 1) (String.length word - i - 1))
    | None -> ("", word) in
  match Sys.readdir (if dir = "" then "." else dir) with
  | names ->
    Array.to_list names
    |> List.filter (fun f ->
        String.starts_with ~prefix:base f && (f.[0] <> '.' || (base <> "" && base.[0] = '.')))
    |> List.sort compare
    |> List.map (fun f ->
        let full = dir ^ f in
        (full, (try Sys.is_directory full with Sys_error _ -> false)))
  | exception Sys_error _ -> []

(* ---- the editor ---- *)

let columns = 80

(* UTF-8: the line moves and erases whole characters, and its width on
   screen is its characters *)
let is_cont c = Char.code c land 0xC0 = 0x80
let cells s = String.fold_left (fun n c -> if is_cont c then n else n + 1) 0 s
let prev_char t p = let p = ref (p - 1) in while !p > 0 && is_cont t.[!p] do decr p done; !p
let next_char t p =
  let p = ref (p + 1) in while !p < String.length t && is_cont t.[!p] do incr p done; !p

let read_line_edited prompt =
  let line = Buffer.create 80 in
  let text () = Buffer.contents line in
  let pos = ref 0 in                    (* the cursor, in the line *)
  let hist = ref (-1) and saved = ref "" in
  let last_tab = ref false in
  let set s p = Buffer.clear line; Buffer.add_string line s; pos := p in
  (* the line from the left of the screen: the prompt and the part of the
     text around the cursor that fits *)
  let redraw () =
    let t = text () in
    (* the characters, and the one the cursor is on *)
    let chars = ref [] and i = ref 0 in
    while !i < String.length t do
      let j = next_char t !i in
      chars := String.sub t !i (j - !i) :: !chars; i := j
    done;
    let chars = Array.of_list (List.rev !chars) in
    let cur = cells (String.sub t 0 !pos) in
    let room = columns - cells prompt - 1 in
    let start = if cur < room then 0 else cur - room + 1 in
    let n = min room (Array.length chars - start) in
    let shown = String.concat "" (Array.to_list (Array.sub chars start n)) in
    print_string ("\r" ^ prompt ^ shown ^ "\027[K");
    let back = n - (cur - start) in
    if back > 0 then Printf.printf "\027[%dD" back;
    flush stdout in
  let insert s =
    let t = text () in
    set (String.sub t 0 !pos ^ s ^ String.sub t !pos (String.length t - !pos)) (!pos + String.length s) in
  let delete_range a b =
    let t = text () in
    set (String.sub t 0 a ^ String.sub t b (String.length t - b)) a in
  let complete () =
    let t = text () in
    let start = (match String.rindex_from_opt t (max 0 (!pos - 1)) ' ' with
        | Some i when !pos > 0 -> i + 1 | _ -> 0) in
    let start = if !pos = 0 then 0 else start in
    let word = String.sub t start (!pos - start) in
    let first = String.trim (String.sub t 0 start) = "" in
    let cands =
      if first && not (String.contains word '/') then complete_command word
      else complete_file word in
    match cands with
    | [] -> ()
    | [ (c, dir) ] ->
      delete_range start !pos;
      insert (c ^ (if dir then "/" else " "))
    | _ ->
      let p = common_prefix (List.map fst cands) in
      if String.length p > String.length word then (delete_range start !pos; insert p)
      else if !last_tab then begin
        (* the second Tab: show them *)
        print_string "\n";
        let names = List.map (fun (c, d) ->
            let b = match String.rindex_opt c '/' with
              | Some i when i < String.length c - 1 -> String.sub c (i + 1) (String.length c - i - 1)
              | _ -> c in
            b ^ (if d then "/" else "")) cands in
        let width = 2 + List.fold_left (fun m s -> max m (String.length s)) 0 names in
        let per_line = max 1 (columns / width) in
        List.iteri (fun i s ->
            print_string s;
            if (i + 1) mod per_line = 0 then print_string "\n"
            else print_string (String.make (width - String.length s) ' '))
          names;
        if List.length names mod per_line <> 0 then print_string "\n"
      end in
  print_string prompt; flush stdout;
  let rec loop () =
    let k = key () in
    let was_tab = !last_tab in
    last_tab := false;
    match k with
    | Enter -> print_string "\n"; flush stdout; Some (text ())
    | Eof -> None
    | Ctrl 'D' when text () = "" -> print_string "\n"; None
    | Ctrl 'C' -> print_string "^C\n"; set "" 0; print_string prompt; flush stdout; loop ()
    | k ->
      (match k with
       | Char c -> insert (String.make 1 c)
       | Text s -> insert s
       | Backspace -> if !pos > 0 then delete_range (prev_char (text ()) !pos) !pos
       | Delete | Ctrl 'D' ->
         if !pos < Buffer.length line then delete_range !pos (next_char (text ()) !pos)
       | Left -> if !pos > 0 then pos := prev_char (text ()) !pos
       | Right -> if !pos < Buffer.length line then pos := next_char (text ()) !pos
       | Home | Ctrl 'A' -> pos := 0
       | End_ | Ctrl 'E' -> pos := Buffer.length line
       | Ctrl 'K' -> delete_range !pos (Buffer.length line)
       | Ctrl 'U' -> delete_range 0 !pos
       | Ctrl 'W' ->
         let t = text () in
         let i = ref !pos in
         while !i > 0 && t.[!i - 1] = ' ' do decr i done;
         while !i > 0 && t.[!i - 1] <> ' ' do decr i done;
         delete_range !i !pos
       | Ctrl 'L' -> print_string "\027[H\027[2J"
       | Tab -> last_tab := was_tab; complete (); last_tab := true
       | Up ->
         let h = Array.of_list !history in
         if !hist + 1 < Array.length h then begin
           if !hist = -1 then saved := text ();
           incr hist;
           set h.(!hist) (String.length h.(!hist))
         end
       | Down ->
         let h = Array.of_list !history in
         if !hist >= 0 then begin
           decr hist;
           let s = if !hist = -1 then !saved else h.(!hist) in
           set s (String.length s)
         end
       | _ -> ());
      redraw ();
      loop () in
  loop ()

(* a line, edited in raw mode; the console is back in line mode while the
   command runs, for the programs *)
let read_command prompt =
  Mynos.console_mode ~canon:false ~echo:false ();
  Fun.protect ~finally:(fun () -> Mynos.console_mode ~canon:true ~echo:true ())
    (fun () -> read_line_edited prompt)

let interactive () =
  print_string "MyNOS sh. help lists the commands, ocaml starts the OCaml \
                toplevel;\nTab completes, Up and Down recall; exit or Ctrl-D \
                leaves.\n";
  (* with standard input from a file, no line editing *)
  let redirected = Sys.getenv_opt "MYNOS_STDIN" <> None in
  if not redirected then history_load ();
  let rec loop () =
    let prompt = Printf.sprintf "mynos:%s$ " (Sys.getcwd ()) in
    let line =
      if redirected then (print_string prompt; flush stdout; In_channel.input_line stdin)
      else read_command prompt in
    match line with
    | Some line ->
      if not redirected then history_add (String.trim line);
      run_line line;
      loop ()
    | None -> () in
  loop ()

let () =
  let code =
    try
      (match Array.to_list Sys.argv with
       | [ _ ] -> positional := [| "sh" |]; interactive ()
       | [ _; "-c"; cmds ] -> positional := [| "sh" |]; run_line cmds
       | _ :: file :: args -> ignore (run_file file args)
       | [] -> ());
      !last_status
    with Exit_shell n -> n in
  exit code

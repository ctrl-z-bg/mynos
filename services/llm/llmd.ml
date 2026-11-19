(* llmd: language models as a service (doc/decisions/llm.md). Protocol
   "llm/1" (mynos-lib/ocaml/llm.ml), registered as "llm".

     llmd.byte [CONFIG]          CONFIG: /disk/llm.env by default

   The configuration is a .env file of profiles (llm.env.example at the
   root of MyNOS's sources), read again at every request. Each profile
   speaks one of two HTTP APIs: "anthropic" (Claude's Messages API) or
   "openai" (Chat Completions: OpenAI, vLLM, Ollama, llama.cpp...). The
   requests go out through Http (and netd, with TLS for https://); keys and
   URLs stay here. A few domains serve requests at once: an answer takes
   seconds. *)

let config_path =
  if Array.length Sys.argv > 1 then Sys.argv.(1) else "/disk/llm.env"

(* to the kernel log, as the other services: not to the screen *)
let log fmt = Printf.ksprintf (fun s -> Mynos.log ("llmd: " ^ s)) fmt

(* --- the configuration --- *)

type profile = {
  name : string;
  api : string;                 (* "anthropic" | "openai" *)
  model : string;
  key : string;
  url : string;                 (* the API's base, with /v1, no final / *)
  max_tokens : int;
  effort : string;              (* "": the model's default *)
  fallbacks : string;           (* "": none *)
}

(* NAME=value lines: "#" comments, "export " allowed, values in quotes or
   not (then a " #" ends them), ${NAME} replaced by an earlier value *)
let parse_env text =
  let vars = ref [] in
  let expand v =
    let b = Buffer.create (String.length v) in
    let n = String.length v in
    let rec go i =
      if i >= n then ()
      else if v.[i] = '$' && i + 1 < n && v.[i + 1] = '{' then
        match String.index_from_opt v i '}' with
        | Some j ->
          let name = String.sub v (i + 2) (j - i - 2) in
          Buffer.add_string b
            (Option.value (List.assoc_opt name !vars) ~default:"");
          go (j + 1)
        | None -> Buffer.add_char b v.[i]; go (i + 1)
      else (Buffer.add_char b v.[i]; go (i + 1)) in
    go 0; Buffer.contents b in
  let value raw =
    let raw = String.trim raw in
    let n = String.length raw in
    if n >= 2 && raw.[0] = '\'' && raw.[n - 1] = '\'' then String.sub raw 1 (n - 2)
    else if n >= 2 && raw.[0] = '"' && raw.[n - 1] = '"' then expand (String.sub raw 1 (n - 2))
    else
      let cut = ref n in
      for i = n - 1 downto 1 do
        if raw.[i] = '#' && (raw.[i - 1] = ' ' || raw.[i - 1] = '\t') then cut := i
      done;
      expand (String.trim (String.sub raw 0 !cut)) in
  List.iter (fun line ->
      let line = String.trim line in
      let line =
        if String.length line > 7 && String.sub line 0 7 = "export " then
          String.trim (String.sub line 7 (String.length line - 7)) else line in
      if line <> "" && line.[0] <> '#' then
        match String.index_opt line '=' with
        | Some i ->
          let name = String.trim (String.sub line 0 i) in
          let v = value (String.sub line (i + 1) (String.length line - i - 1)) in
          vars := (name, v) :: List.remove_assoc name !vars
        | None -> ())
    (String.split_on_char '\n' text);
  List.rev !vars

let fields = [ "API"; "MODEL"; "KEY"; "URL"; "MAX_TOKENS"; "EFFORT"; "FALLBACKS" ]

(* the profiles, the default first *)
let profiles_of vars =
  let prefix = "LLM_" in
  let names = ref [] in
  List.iter (fun (k, _) ->
      let lk = String.length k in
      if lk > 4 && String.sub k 0 4 = prefix then
        List.iter (fun f ->
            let lf = String.length f in
            if lk > 4 + lf + 1 && String.sub k (lk - lf - 1) (lf + 1) = "_" ^ f then
              let name = String.sub k 4 (lk - 4 - lf - 1) in
              if not (List.mem name !names) then names := name :: !names)
          fields)
    vars;
  let get name f = Option.value (List.assoc_opt ("LLM_" ^ name ^ "_" ^ f) vars) ~default:"" in
  let profile name =
    let api = String.lowercase_ascii (get name "API") in
    if api <> "anthropic" && api <> "openai" then
      failwith (Printf.sprintf "%s: LLM_%s_API must be anthropic or openai, not %S"
                  config_path name api);
    let model = get name "MODEL" in
    if model = "" then failwith (Printf.sprintf "%s: LLM_%s_MODEL is missing" config_path name);
    let url = match get name "URL" with
      | "" -> if api = "anthropic" then "https://api.anthropic.com/v1"
        else "https://api.openai.com/v1"
      | u -> u in
    let url =
      if String.length url > 0 && url.[String.length url - 1] = '/'
      then String.sub url 0 (String.length url - 1) else url in
    let max_tokens = match int_of_string_opt (get name "MAX_TOKENS") with
      | Some n when n > 0 -> n | _ -> 16000 in
    { name = String.lowercase_ascii name; api; model; key = get name "KEY"; url;
      max_tokens; effort = get name "EFFORT"; fallbacks = get name "FALLBACKS" } in
  let all = List.rev_map profile !names in
  let default = String.lowercase_ascii
      (Option.value (List.assoc_opt "LLM_DEFAULT" vars) ~default:"") in
  match List.partition (fun p -> p.name = default) all with
  | [ d ], rest -> d :: rest
  | _ -> all

let no_config () =
  failwith ("no model configured: write " ^ config_path
            ^ " (see llm.env.example in MyNOS's sources)")

let load () =
  match In_channel.with_open_bin config_path In_channel.input_all with
  | exception Sys_error _ -> no_config ()
  | text -> match profiles_of (parse_env text) with
    | [] -> no_config ()
    | ps -> ps

(* --- JSON helpers --- *)

let field k = function
  | Json.Object l -> Option.value (List.assoc_opt k l) ~default:Json.Null
  | _ -> Json.Null

let str = function Json.String s -> s | _ -> ""
let num = function Json.Number f -> int_of_float f | _ -> 0
let list = function Json.Array l -> l | _ -> []

(* a tool call's input: a JSON object, "{}" if the model wrote nothing *)
let json_input s =
  if String.trim s = "" then Json.Object []
  else match Json.of_string s with
    | v -> v
    | exception Json.Error _ -> failwith ("a tool call's input is not JSON: " ^ s)

let post p ~headers body =
  let url = p.url ^ (if p.api = "anthropic" then "/messages" else "/chat/completions") in
  let r =
    try Http.request ~meth:"POST" ~timeout:300000
          ~headers:(("content-type", "application/json") :: headers)
          ~body:(Json.to_string body) url
    with Http.Error m -> failwith (Printf.sprintf "%s: %s" p.name m) in
  let json = try Some (Json.of_string r.Http.body) with Json.Error _ -> None in
  if r.status <> 200 then begin
    let detail = match json with
      | Some j ->
        let e = field "error" j in
        (match e with
         | Json.String s -> s
         | _ ->
           let ty = str (field "type" e) and m = str (field "message" e) in
           if ty <> "" then ty ^ ": " ^ m else if m <> "" then m else r.body)
      | None -> r.body in
    failwith (Printf.sprintf "%s: %d %s" p.name r.status
                (if String.length detail > 500 then String.sub detail 0 500 else detail))
  end;
  match json with
  | Some j -> j
  | None -> failwith (p.name ^ ": the answer is not JSON")

(* --- Claude's Messages API --- *)

let anthropic p (c : Llm.chat) : Llm.answer =
  let block = function
    | Llm.Text "" -> None
    | Llm.Text s -> Some (Json.Object [ "type", String "text"; "text", String s ])
    | Tool_call { id; name; input } ->
      Some (Json.Object [ "type", String "tool_use"; "id", String id;
                          "name", String name; "input", json_input input ])
    | Tool_result { id; content; error } ->
      Some (Json.Object [ "type", String "tool_result"; "tool_use_id", String id;
                          "content", String content; "is_error", Bool error ])
    | Opaque j -> Some (Json.of_string j) in
  let message (m : Llm.message) =
    Json.Object [ "role", String (if m.role = Assistant then "assistant" else "user");
                  "content", Array (List.filter_map block m.content) ] in
  let tool (t : Llm.tool) =
    Json.Object [ "name", String t.name; "description", String t.description;
                  "input_schema", Json.of_string t.schema ] in
  let max_tokens = if c.max_tokens > 0 then c.max_tokens else p.max_tokens in
  let body = Json.Object (List.concat [
      [ "model", Json.String p.model; "max_tokens", Number (float max_tokens) ];
      (if c.system = "" then [] else [ "system", Json.String c.system ]);
      [ "messages", Array (List.map message c.messages) ];
      (if c.tools = [] then [] else [ "tools", Array (List.map tool c.tools) ]);
      (if p.effort = "" then []
       else [ "output_config", Object [ "effort", String p.effort ] ]);
      (if p.fallbacks = "" then [] else [ "fallbacks", String p.fallbacks ]);
      (* the prompt so far cached, for the next request of a conversation
         (an agent's loop): prompts shorter than the model's minimum are
         simply not cached *)
      [ "cache_control", Object [ "type", String "ephemeral" ] ] ]) in
  let headers = List.concat [
      (if p.key = "" then [] else [ "x-api-key", p.key ]);
      [ "anthropic-version", "2026-10-21" ];
      (if p.fallbacks = "" then []
       else [ "anthropic-beta", "server-side-fallback-2026-07-01" ]) ] in
  let j = post p ~headers body in
  let content = List.map (fun b ->
      match str (field "type" b) with
      | "text" -> Llm.Text (str (field "text" b))
      | "tool_use" ->
        Tool_call { id = str (field "id" b); name = str (field "name" b);
                    input = Json.to_string (field "input" b) }
      | _ -> Opaque (Json.to_string b))
      (list (field "content" j)) in
  let stop = match str (field "stop_reason" j) with
    | "end_turn" | "stop_sequence" -> Llm.End
    | "tool_use" -> Tool_use
    | "max_tokens" -> Max_tokens
    | "refusal" -> Refusal
    | s -> Other s in
  let usage = field "usage" j in
  (* the whole prompt: the tokens read from the cache and written to it
     are counted apart from input_tokens *)
  { content; stop; model = str (field "model" j);
    input_tokens = num (field "input_tokens" usage)
                   + num (field "cache_creation_input_tokens" usage)
                   + num (field "cache_read_input_tokens" usage);
    output_tokens = num (field "output_tokens" usage) }

(* --- the Chat Completions API (OpenAI, vLLM, Ollama...) --- *)

let openai p (c : Llm.chat) : Llm.answer =
  let texts blocks =
    String.concat "" (List.filter_map (function Llm.Text s -> Some s | _ -> None) blocks) in
  let message (m : Llm.message) =
    match m.role with
    | User ->
      (* tool results first: they answer the assistant message before *)
      let results = List.filter_map (function
          | Llm.Tool_result { id; content; error } ->
            Some (Json.Object [ "role", String "tool"; "tool_call_id", String id;
                                "content", String (if error then "error: " ^ content
                                                   else content) ])
          | _ -> None) m.content in
      results @ (match texts m.content with
          | "" -> []
          | t -> [ Json.Object [ "role", String "user"; "content", String t ] ])
    | Assistant ->
      let calls = List.filter_map (function
          | Llm.Tool_call { id; name; input } ->
            Some (Json.Object [ "id", String id; "type", String "function";
                                "function", Object [ "name", String name;
                                                     "arguments", String input ] ])
          | _ -> None) m.content in
      [ Json.Object (List.concat [
            [ "role", Json.String "assistant" ];
            [ "content", (match texts m.content with "" -> Json.Null | t -> String t) ];
            (if calls = [] then [] else [ "tool_calls", Array calls ]) ]) ] in
  let tool (t : Llm.tool) =
    Json.Object [ "type", String "function";
                  "function", Object [ "name", String t.name;
                                       "description", String t.description;
                                       "parameters", Json.of_string t.schema ] ] in
  let max_tokens = if c.max_tokens > 0 then c.max_tokens else p.max_tokens in
  (* OpenAI's newer models refuse max_tokens; the other servers know it *)
  let limit = if p.url = "https://api.openai.com/v1" then "max_completion_tokens"
    else "max_tokens" in
  let body = Json.Object (List.concat [
      [ "model", Json.String p.model ];
      [ "messages", Array ((if c.system = "" then []
                            else [ Json.Object [ "role", String "system";
                                                 "content", String c.system ] ])
                           @ List.concat_map message c.messages) ];
      (if c.tools = [] then [] else [ "tools", Array (List.map tool c.tools) ]);
      [ limit, Number (float max_tokens) ] ]) in
  let headers = if p.key = "" then [] else [ "authorization", "Bearer " ^ p.key ] in
  let j = post p ~headers body in
  let choice = match list (field "choices" j) with
    | c :: _ -> c | [] -> failwith (p.name ^ ": an answer without choices") in
  let m = field "message" choice in
  let text = match str (field "content" m) with "" -> [] | t -> [ Llm.Text t ] in
  let calls = List.mapi (fun i call ->
      let f = field "function" call in
      Llm.Tool_call { id = (match str (field "id" call) with
          | "" -> Printf.sprintf "call_%d" i | id -> id);
          name = str (field "name" f);
          input = (match field "arguments" f with
              | Json.String s -> s
              | Json.Null -> "{}"
              | v -> Json.to_string v) })
      (list (field "tool_calls" m)) in
  let stop = match str (field "finish_reason" choice) with
    | "stop" -> Llm.End
    | "tool_calls" -> Tool_use
    | "length" -> Max_tokens
    | "content_filter" -> Refusal
    | s -> if calls <> [] then Tool_use else Other s in
  let usage = field "usage" j in
  { content = text @ calls; stop; model = str (field "model" j);
    input_tokens = num (field "prompt_tokens" usage);
    output_tokens = num (field "completion_tokens" usage) }

(* --- the service --- *)

let chat (c : Llm.chat) =
  let ps = load () in
  let p = match c.profile with
    | "" -> List.hd ps
    | name ->
      match List.find_opt (fun p -> p.name = String.lowercase_ascii name) ps with
      | Some p -> p
      | None ->
        failwith (Printf.sprintf "no profile %S (there are: %s)" name
                    (String.concat ", " (List.map (fun p -> p.name) ps))) in
  if p.api = "anthropic" then anthropic p c else openai p c

let handler = { Llm.handle = fun (type a) _caller (r : a Llm.request) : a ->
    match r with
    | Llm.Profiles -> List.map (fun p -> (p.name, p.api, p.model)) (load ())
    | Llm.Chat c -> chat c }

(* connections are served by a few domains at once: the main domain
   accepts them and queues them for the workers (as httpd) *)
let workers = 4
let queue = Queue.create ()
let lock = Mutex.create ()
let nonempty = Condition.create ()

let serve ch =
  match Mynos.recv ~timeout:5.0 ch with
  | exception Mynos.Error _ -> ()
  | msg ->
    let caller =
      match Mynos.channel_peer ch with
      | exception Mynos.Error _ -> Ipc.nobody
      | pid ->
        match Mynos.process_info pid with
        | Some i -> { Ipc.pid; io = i.Mynos.io }
        | None -> { Ipc.pid; io = false } in
    (try Mynos.send ch (Llm.answer ~caller handler msg) with Mynos.Error _ -> ())

let worker () =
  while true do
    Mutex.lock lock;
    while Queue.is_empty queue do Condition.wait nonempty lock done;
    let ch = Queue.pop queue in
    Mutex.unlock lock;
    serve ch;
    (try Mynos.free_channel ch with Mynos.Error _ -> ())
  done

let () =
  let port = Mynos.register "llm" in
  (match load () with
   | ps -> log "%d profile(s) in %s: %s" (List.length ps) config_path
             (String.concat ", " (List.map (fun p -> p.name ^ " (" ^ p.model ^ ")") ps))
   | exception Failure m -> log "%s" m);
  for _ = 1 to workers do ignore (Domain.spawn worker) done;
  while true do
    match Mynos.listen port with
    | ch ->
      Mutex.lock lock;
      Queue.push ch queue;
      Condition.signal nonempty;
      Mutex.unlock lock
    | exception Mynos.Error (f, code) -> log "listen: %s %d" f code
  done

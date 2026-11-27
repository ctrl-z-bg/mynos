(* A page's scripts (M6): run in jsd, the DOM reached through Ariadne's
   own service, dom/1, which answers jsd's __dom calls with Dom_api's
   operations on the page's tree. Scripts run once the page is parsed and
   its style sheets fetched, before the cascade: in document order, the
   inline ones and those fetched (src); then DOMContentLoaded, load, and
   the timers due within the first second. Nothing else touches the tree
   meanwhile (the page is not shown yet), so no lock is needed on it.
   ARIADNE_NOJS (set to anything) turns scripts off. *)

type _ request = Call : string * string list -> string list request

let call_args = Wire.(pair (field "op" string) (field "args" (list string)))

module Protocol = struct
  let id = "dom/1"
  let summary = "A page's DOM for its scripts (Ariadne's, for jsd's __dom): an operation and its arguments."
  let requests = Ipc.[
      request 0 "call" "A DOM operation (Dom_api: document, query, getAttr, insert...) and its arguments: \
                        its answer (nodes as handle, type, name triples)."
        call_args Wire.(list string) ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with Call (op, args) -> Wire.write w Wire.int 0; Wire.write w call_args (op, args)
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let op, args = Wire.read r call_args in Request (Call (op, args))
    | n -> raise (Wire.Error (Printf.sprintf "dom: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function Call _ -> Wire.(list string)
end

module S = Ipc.Make (Protocol)

let enabled = Sys.getenv_opt "ARIADNE_NOJS" = None

(* the pages with scripts, by session (a page loading and the one shown
   both have one: the first argument of every call says whose); the
   service, started once *)
let sessions : (int, Dom_api.t) Hashtbl.t = Hashtbl.create 8
let lock = Mutex.create ()
let next_sid = ref 0
let service = lazy (
  let name = Printf.sprintf "ariadne-dom.%d" (Mynos.getpid ()) in
  let handler = { S.handle = fun (type a) _caller (r : a request) : a ->
      match r with
      | Call (op, sid :: args) ->
        (match Mutex.protect lock (fun () -> Hashtbl.find_opt sessions (int_of_string sid)) with
         | Some t -> Dom_api.call t op args
         | None -> failwith "no such page"
         | exception Failure _ -> failwith "no such page")
      | Call (_, []) -> failwith "no page" } in
  ignore (Thread.create (fun () -> S.serve name handler) ());
  (* registered by the thread: a moment to be there *)
  Thread.delay 0.05;
  name)

(* JavaScript's types for <script> (and none: JavaScript) *)
let is_js s =
  match String.lowercase_ascii (String.trim (Option.value (Dom.attr s "type") ~default:"")) with
  | "" | "text/javascript" | "application/javascript" | "application/ecmascript" | "text/ecmascript"
  | "application/x-javascript" | "text/jscript" -> true
  | _ -> false

type report = { ran : int; failed : int; console : string; ms : float; changed : bool }

(* a page's scripts, kept while it is shown: their context, its tree *)
type session = {
  cx : Js.context;
  dom : Dom_api.t;
  sid : int;
  mutable pending : int;                   (* timers waiting *)
  log : string -> unit;
  out : Buffer.t;                          (* console, errors *)
}

let eval s ~name code =
  match Js.eval ~name s.cx code with
  | r ->
    Buffer.add_string s.out r.Js.console;
    if not r.ok then begin
      Buffer.add_string s.out ("error: " ^ r.value ^ "\n");
      s.log (Printf.sprintf "script %s: %s" name (List.hd (String.split_on_char '\n' r.value)))
    end;
    Some r
  | exception e -> s.log ("script " ^ name ^ ": " ^ Printexc.to_string e); None

(* an event at a node (click, input, submit, change): whether its default
   action is still to happen (no preventDefault) *)
let event s (n : Dom.node) typ =
  let h = Dom_api.handle s.dom n in
  match eval s ~name:typ (Printf.sprintf "__event(%S, %d, %S, %S)" h (Dom_api.node_type n) (Dom_api.node_name n) typ) with
  | Some r when r.ok -> r.value <> "false"
  | _ -> true

(* the timers due within [ms] *)
let tick s ms =
  match eval s ~name:"timers" (Printf.sprintf "__runTimers(%d)" ms) with
  | Some r when r.ok -> s.pending <- Option.value (int_of_string_opt r.value) ~default:0
  | _ -> s.pending <- 0

(* the scripts changed the tree since asked last *)
let changed s = let c = s.dom.changed in s.dom.changed <- false; c

let close s =
  Js.destroy s.cx;
  Mutex.protect lock (fun () -> Hashtbl.remove sessions s.sid)

(* the page's scripts run; [fetch] gives a script's text by its URL *)
let run ~(log : string -> unit) ~url ~base ~width ~height ~(fetch : string -> string option)
    ?(cookies_get = fun _ -> "") ?(cookies_set = fun _ _ -> ()) (doc : Dom.node) =
  let trace fmt = Printf.ksprintf log fmt in
  let t0 = Unix.gettimeofday () in
  let scripts = ref [] in
  Dom.iter (fun n -> if Dom.is_html n "script" && is_js n then scripts := n :: !scripts) doc;
  let scripts = List.rev !scripts in
  if not enabled || scripts = [] then None
  else
    match Js.connect () with
    | exception _ -> trace "scripts: no jsd"; None
    | js ->
      let name = Lazy.force service in
      let t = Dom_api.create ~cookies:((fun () -> cookies_get url), cookies_set url) doc in
      let sid = Mutex.protect lock (fun () -> incr next_sid; Hashtbl.replace sessions !next_sid t; !next_sid) in
      let cx = Js.create ~js ~dom:name () in
      let s = { cx; dom = t; sid; pending = 0; log; out = Buffer.create 256 } in
      let ran = ref 0 and failed = ref 0 in
      let run_one ~name code =
        match eval s ~name code with Some r when not r.ok -> incr failed | _ -> () in
      run_one ~name:"url.js" Js_prelude.url_polyfill;
      run_one ~name:"prelude.js" Js_prelude.source;
      let quote x = "\"" ^ String.concat "\\\"" (String.split_on_char '"' x) ^ "\"" in
      run_one ~name:"init" (Printf.sprintf "__init(%s, %d, %d, %d)" (quote url) width height sid);
      List.iteri (fun i sc ->
          let code, name = match Dom.attr sc "src" with
            | Some src when String.trim src <> "" ->
              let u = Url.resolve base (String.trim src) in
              (fetch u, u)
            | _ -> (Some (Dom.text_content sc), Printf.sprintf "%s#script%d" url (i + 1)) in
          match code with
          | Some code -> incr ran; run_one ~name code
          | None -> trace "script %s: not fetched" name) scripts;
      run_one ~name:"after" "__afterScripts()";
      tick s 1000;
      (* with scripts on, noscript's content is not shown *)
      let noscripts = ref [] in
      Dom.iter (fun n -> if Dom.is_html n "noscript" then noscripts := n :: !noscripts) doc;
      List.iter Dom.remove !noscripts;
      let ms = (Unix.gettimeofday () -. t0) *. 1000. in
      trace "scripts: %d run, %d failed, %.0f ms%s" !ran !failed ms (if t.changed then ", the page changed" else "");
      let report = { ran = !ran; failed = !failed; console = Buffer.contents s.out; ms; changed = t.changed } in
      t.changed <- false;
      Some (report, s)

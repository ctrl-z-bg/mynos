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

(* the page whose scripts run now; the service, started once *)
let current : Dom_api.t option ref = ref None
let lock = Mutex.create ()
let service = lazy (
  let name = Printf.sprintf "ariadne-dom.%d" (Mynos.getpid ()) in
  let handler = { S.handle = fun (type a) _caller (r : a request) : a ->
      match r with
      | Call (op, args) ->
        match Mutex.protect lock (fun () -> !current) with
        | Some t -> Dom_api.call t op args
        | None -> failwith "no page" } in
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

(* the page's scripts run; [fetch] gives a script's text by its URL *)
let run ~(log : string -> unit) ~url ~base ~width ~height ~(fetch : string -> string option) (doc : Dom.node) =
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
      let t = Dom_api.create doc in
      Mutex.protect lock (fun () -> current := Some t);
      let console = Buffer.create 256 in
      let ran = ref 0 and failed = ref 0 in
      Fun.protect ~finally:(fun () -> Mutex.protect lock (fun () -> current := None)) (fun () ->
          let cx = Js.create ~js ~dom:name () in
          Fun.protect ~finally:(fun () -> Js.destroy cx) (fun () ->
              let eval ~name code =
                let r = Js.eval ~name cx code in
                Buffer.add_string console r.Js.console;
                if not r.ok then begin
                  incr failed;
                  Buffer.add_string console ("error: " ^ r.value ^ "\n");
                  trace "script %s: %s" name (List.hd (String.split_on_char '\n' r.value))
                end;
                r in
              ignore (eval ~name:"url.js" Js_prelude.url_polyfill);
              ignore (eval ~name:"prelude.js" Js_prelude.source);
              let quote s = "\"" ^ String.concat "\\\"" (String.split_on_char '"' s) ^ "\"" in
              ignore (eval ~name:"init" (Printf.sprintf "__init(%s, %d, %d)" (quote url) width height));
              List.iteri (fun i s ->
                  let code, name = match Dom.attr s "src" with
                    | Some src when String.trim src <> "" ->
                      let u = Url.resolve base (String.trim src) in
                      (fetch u, u)
                    | _ -> (Some (Dom.text_content s), Printf.sprintf "%s#script%d" url (i + 1)) in
                  match code with
                  | Some code -> incr ran; ignore (eval ~name code)
                  | None -> trace "script %s: not fetched" name) scripts;
              ignore (eval ~name:"after" "__afterScripts()");
              ignore (eval ~name:"timers" "__runTimers(1000)")));
      (* with scripts on, noscript's content is not shown *)
      let noscripts = ref [] in
      Dom.iter (fun n -> if Dom.is_html n "noscript" then noscripts := n :: !noscripts) doc;
      List.iter Dom.remove !noscripts;
      let ms = (Unix.gettimeofday () -. t0) *. 1000. in
      trace "scripts: %d run, %d failed, %.0f ms%s" !ran !failed ms (if t.changed then ", the page changed" else "");
      Some { ran = !ran; failed = !failed; console = Buffer.contents console; ms; changed = t.changed }

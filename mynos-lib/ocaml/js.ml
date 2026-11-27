(* JavaScript over typed IPC: see js.mli. The service is jsd
   (services/js/jsd.c), which follows the case numbers below. *)

type _ request =
  | Create : string -> int request
  | Eval : int * string * string -> (bool * string * string) request
  | Destroy : int -> unit request

let context_f = Wire.(field "context" int)
let dom_f = Wire.(field "dom" string)
let eval_args = Wire.(triple (field "context" int) (field "code" string) (field "name" string))
let eval_reply = Wire.(triple (field "ok" bool) (field "value" string) (field "console" string))

module Protocol = struct
  let id = "js/1"
  let summary =
    "JavaScript (jsd, in C: QuickJS-ng): contexts of their own, code run in them, console; \
     for Ariadne and any program."
  let requests = Ipc.[
      request 0 "create"
        "A JavaScript context of its own (a page's): its globals, console; its memory and run time limited. \
         dom: the service (dom/1) its __dom(op, ...args) calls, or \"\": none."
        dom_f context_f;
      request 1 "eval"
        "Run code (a script; name: its file, for the stack) in the context: whether it ended without an \
         exception, its value (or the exception, with the stack), and what console printed."
        eval_args eval_reply;
      request 2 "destroy" "Free a context." context_f Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Create d -> case 0; Wire.write w dom_f d
    | Eval (c, code, name) -> case 1; Wire.write w eval_args (c, code, name)
    | Destroy c -> case 2; Wire.write w context_f c

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Create (Wire.read r dom_f))
    | 1 -> let c, code, name = Wire.read r eval_args in Request (Eval (c, code, name))
    | 2 -> Request (Destroy (Wire.read r context_f))
    | n -> raise (Wire.Error (Printf.sprintf "js: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Create _ -> context_f
    | Eval _ -> eval_reply
    | Destroy _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect () = I.connect "js"
let call = I.call

type context = { js : t; id : int }

let create ?js ?(dom = "") () =
  let js = match js with Some j -> j | None -> connect () in
  { js; id = call js (Create dom) }

type result = { ok : bool; value : string; console : string }

let eval ?(name = "") c code =
  let ok, value, console = call c.js (Eval (c.id, code, name)) in
  { ok; value; console }

let destroy c = try call c.js (Destroy c.id) with Ipc.Remote_error _ -> ()

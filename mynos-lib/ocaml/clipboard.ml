(* The clipboard over typed IPC: see clipboard.mli. The service is
   services/clipboard/clipboard_service.ml. *)

type _ request =
  | Get : string request
  | Set : string -> unit request

module Protocol = struct
  let id = "clipboard/1"
  let summary = "The clipboard: the text copied last, for any program to paste."
  let requests = Ipc.[
      request ~safe:true 0 "get" "The text copied last (\"\": none yet)." Wire.unit Wire.string;
      request 1 "set" "Copy a text (up to 1 MB): what get gives from now on."
        Wire.(field "text" string) Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with
    | Get -> Wire.write w Wire.int 0
    | Set s -> Wire.write w Wire.int 1; Wire.write w Wire.string s
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Get
    | 1 -> Request (Set (Wire.read r Wire.string))
    | n -> raise (Wire.Error (Printf.sprintf "clipboard: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Get -> Wire.string
    | Set _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
let serve = I.serve

let call r = I.call (I.connect "clipboard") r

let get () = try call Get with _ -> ""
let set s = try call (Set s) with _ -> ()

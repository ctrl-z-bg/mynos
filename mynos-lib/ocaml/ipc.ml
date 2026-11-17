(* Typed IPC: see ipc.mli. *)

exception Remote_error of string * string
exception Protocol_error of string

type caller = { pid : int; io : bool }

let nobody = { pid = -1; io = false }

type request_doc = {
  case : int;
  name : string;
  doc : string;
  args : Wire.shape;
  reply : Wire.shape;
  safe : bool;
}

let request ?(safe = false) case name doc args reply =
  { case; name; doc; args = Wire.shape args; reply = Wire.shape reply; safe }

type description = {
  protocol : string;
  summary : string;
  requests : request_doc list;
}

let request_doc_codec =
  Wire.(conv
          (fun r -> ((r.case, r.name, r.doc), (r.args, r.reply, r.safe)))
          (fun ((case, name, doc), (args, reply, safe)) ->
             { case; name; doc; args; reply; safe })
          (pair (triple int string string) (triple shape_codec shape_codec bool)))

let description_codec =
  Wire.(conv (fun d -> (d.protocol, d.summary, d.requests))
          (fun (protocol, summary, requests) -> { protocol; summary; requests })
          (triple string string (list request_doc_codec)))

(* the request "describe": a protocol of its own, with nothing after its
   id; the reply, Ok description *)
let describe_id = "describe"

let describe ?(timeout = 1.0) name =
  let ch = Mynos.connect (Mynos.lookup name) in
  let answer =
    Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with Mynos.Error _ -> ())
      (fun () ->
         Mynos.send ch (Wire.to_string Wire.string describe_id);
         Mynos.recv ~timeout ch) in
  match Wire.of_string (Wire.result description_codec Wire.string) answer with
  | Ok d -> d
  | Error m -> raise (Remote_error (name, m))
  | exception Wire.Error e -> raise (Protocol_error (Printf.sprintf "%s: %s" name e))

module type PROTOCOL = sig
  val id : string
  val summary : string
  val requests : request_doc list
  type 'a request
  type packed = Request : 'a request -> packed
  val write_request : Wire.writer -> 'a request -> unit
  val read_request : Wire.reader -> packed
  val reply : 'a request -> 'a Wire.t
end

module Make (P : PROTOCOL) = struct
  type client = { name : string; port : int }

  let connect name = { name; port = Mynos.lookup name }
  let service c = c.name

  let request_message req =
    let w = Wire.writer () in
    Wire.write w Wire.string P.id;
    P.write_request w req;
    Wire.contents w

  (* every reply: Ok value or Error message *)
  let reply_codec req = Wire.result (P.reply req) Wire.string

  let read_reply_of name msg req =
    match Wire.of_string (reply_codec req) msg with
    | Ok v -> v
    | Error m -> raise (Remote_error (name, m))
    | exception Wire.Error e ->
      raise (Protocol_error (Printf.sprintf "%s: %s" name e))

  let read_reply msg req = read_reply_of "" msg req

  let call c req =
    let msg = request_message req in
    let ch = Mynos.connect c.port in
    let answer =
      Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with Mynos.Error _ -> ())
        (fun () -> Mynos.send ch msg; Mynos.recv ch) in
    read_reply_of c.name answer req

  type handler = { handle : 'a. caller -> 'a P.request -> 'a }

  let error m = Wire.to_string (Wire.result Wire.unit Wire.string) (Error m)

  let message = function
    | Failure m | Invalid_argument m | Sys_error m -> m
    | e -> Printexc.to_string e

  let answer ?(caller = nobody) h msg =
    match
      let r = Wire.reader msg in
      let id = Wire.read r Wire.string in
      if id = describe_id && Wire.at_end r then
        Ok (Wire.to_string (Wire.result description_codec Wire.string)
              (Ok { protocol = P.id; summary = P.summary; requests = P.requests }))
      else if id <> P.id then Error (Printf.sprintf "protocol %S, expected %S" id P.id)
      else match P.read_request r with
        | P.Request req ->
          if not (Wire.at_end r) then Error "bytes left over in the request"
          else Ok (match h.handle caller req with
              | v ->
                (try Wire.to_string (reply_codec req) (Ok v)
                 with e -> error ("cannot encode the reply: " ^ message e))
              | exception e -> error (message e))
    with
    | Ok reply -> reply
    | Error m -> error m
    | exception Wire.Error m -> error ("malformed request: " ^ m)

  let serve_port port h =
    while true do
      let ch = Mynos.listen port in
      (try
         (* a client that connects and sends nothing must not stop us *)
         let msg = Mynos.recv ~timeout:1.0 ch in
         let caller =
           let pid = Mynos.channel_peer ch in
           match Mynos.process_info pid with
           | Some i -> { pid; io = i.Mynos.io }
           | None -> { pid; io = false } in
         Mynos.send ch (answer ~caller h msg)
       with Mynos.Error (fn, code) ->
         Mynos.log (Printf.sprintf "%s: %s: %s" P.id fn (Mynos.error_name code)));
      (try Mynos.free_channel ch with Mynos.Error _ -> ())
    done;
    assert false

  let serve name h = serve_port (Mynos.register name) h
end

(* Typed IPC: see ipc.mli. *)

exception Remote_error of string * string
exception Protocol_error of string

module type PROTOCOL = sig
  val id : string
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

  type handler = { handle : 'a. 'a P.request -> 'a }

  let error m = Wire.to_string (Wire.result Wire.unit Wire.string) (Error m)

  let message = function
    | Failure m | Invalid_argument m | Sys_error m -> m
    | e -> Printexc.to_string e

  let answer h msg =
    match
      let r = Wire.reader msg in
      let id = Wire.read r Wire.string in
      if id <> P.id then Error (Printf.sprintf "protocol %S, expected %S" id P.id)
      else match P.read_request r with
        | P.Request req ->
          if not (Wire.at_end r) then Error "bytes left over in the request"
          else Ok (match h.handle req with
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
         Mynos.send ch (answer h msg)
       with Mynos.Error (fn, code) ->
         Mynos.log (Printf.sprintf "%s: %s: %s" P.id fn (Mynos.error_name code)));
      (try Mynos.free_channel ch with Mynos.Error _ -> ())
    done;
    assert false

  let serve name h = serve_port (Mynos.register name) h
end

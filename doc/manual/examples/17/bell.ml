(* bell.ml: a service that answers later, "bell/1".

     bell             serve, forever
     bell wait        wait for the next ring, print its message
     bell ring TEXT   ring: every waiting client gets TEXT *)

type _ request =
  | Wait : string request            (* the message of the next ring *)
  | Ring : string -> int request     (* how many were waiting *)

module Protocol = struct
  let id = "bell/1"
  let summary = "Clients wait for a ring; a ring wakes them all."
  let requests = Ipc.[
      request 0 "wait" "Wait for the next ring: its message." Wire.unit Wire.string;
      request 1 "ring" "Ring: how many clients were waiting."
        Wire.(field "message" string) Wire.int ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with
    | Wait -> Wire.write w Wire.int 0; Wire.write w Wire.unit ()
    | Ring s -> Wire.write w Wire.int 1; Wire.write w Wire.string s
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Wire.read r Wire.unit; Request Wait
    | 1 -> Request (Ring (Wire.read r Wire.string))
    | n -> raise (Wire.Error (Printf.sprintf "bell: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Wait -> Wire.string
    | Ring _ -> Wire.int
end

module Bell = Ipc.Make (Protocol)

(* send a reply and close the channel; a client that has gone is no error *)
let answer ch msg =
  (try Mynos.send ch msg with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let waiting = ref []                  (* channels of clients in Wait *)

let handle (type a) ch (r : a request) =
  match r with
  | Wait -> waiting := ch :: !waiting                 (* no answer yet *)
  | Ring text ->
    let n = List.length !waiting in
    List.iter (fun w -> answer w (Bell.reply Wait text)) (List.rev !waiting);
    waiting := [];
    answer ch (Bell.reply r n)

let serve () =
  let port = Mynos.register "bell" in
  while true do
    let ch = Mynos.listen port in
    match Mynos.recv ~timeout:1.0 ch with
    | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ())
    | msg ->
      match Bell.decode msg with
      | Error reply -> answer ch reply          (* "describe", or an error *)
      | Ok (Protocol.Request r) -> handle ch r
  done

let () =
  match Sys.argv with
  | [| _ |] -> serve ()
  | [| _; "wait" |] -> print_endline (Bell.call (Bell.connect "bell") Wait)
  | [| _; "ring"; text |] ->
    Printf.printf "%d were waiting\n" (Bell.call (Bell.connect "bell") (Ring text))
  | _ -> prerr_endline "usage: bell [wait | ring TEXT]"; exit 2

(* kv.ml: a typed service, "kv/1": a table of strings in memory.

     kv                 serve, forever
     kv set KEY VALUE   ask the service
     kv get KEY
     kv keys *)

type _ request =
  | Set : string * string -> unit request
  | Get : string -> string option request
  | Keys : string list request

module Protocol = struct
  let id = "kv/1"
  let summary = "A table of strings, kept in memory."

  let key = Wire.(field "key" string)
  let set_args = Wire.(pair key (field "value" string))

  let requests = Ipc.[
      request 0 "set" "Give a key a value (keys sys.* only from drivers)."
        set_args Wire.unit;
      request ~safe:true 1 "get" "The value of a key, if it has one."
        key Wire.(option string);
      request ~safe:true 2 "keys" "Every key, in order." Wire.unit Wire.(list string) ]

  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Set (k, v) -> Wire.write w Wire.int 0; Wire.write w set_args (k, v)
    | Get k -> Wire.write w Wire.int 1; Wire.write w key k
    | Keys -> Wire.write w Wire.int 2; Wire.write w Wire.unit ()

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let k, v = Wire.read r set_args in Request (Set (k, v))
    | 1 -> Request (Get (Wire.read r key))
    | 2 -> Wire.read r Wire.unit; Request Keys
    | n -> raise (Wire.Error (Printf.sprintf "kv: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Set _ -> Wire.unit
    | Get _ -> Wire.(option string)
    | Keys -> Wire.(list string)
end

module Kv = Ipc.Make (Protocol)

let table : (string, string) Hashtbl.t = Hashtbl.create 16

let handle : type a. Ipc.caller -> a request -> a = fun caller r ->
  match r with
  | Set (k, v) ->
    if k = "" then invalid_arg "invalid: an empty key";
    if String.starts_with ~prefix:"sys." k && not caller.Ipc.io then
      failwith "denied: sys.* keys are for drivers";
    Hashtbl.replace table k v
  | Get k -> Hashtbl.find_opt table k
  | Keys -> List.sort compare (Hashtbl.fold (fun k _ l -> k :: l) table [])

let () =
  match Sys.argv with
  | [| _ |] -> Kv.serve "kv" { Kv.handle = handle }
  | [| _; "set"; k; v |] -> Kv.call (Kv.connect "kv") (Set (k, v))
  | [| _; "get"; k |] ->
    print_endline (Option.value ~default:"(none)" (Kv.call (Kv.connect "kv") (Get k)))
  | [| _; "keys" |] -> List.iter print_endline (Kv.call (Kv.connect "kv") Keys)
  | _ -> prerr_endline "usage: kv [set KEY VALUE | get KEY | keys]"; exit 2

(* registry/1, the protocol of the name registry: see registry.mli. *)

type _ request =
  | Register : string -> int request
  | Lookup : string -> int request
  | List : (string * int * int) list request

let name = Wire.(field "name" string)
let entries = Wire.(list (triple (field "name" string) (field "port" int) (field "owner" int)))

module Protocol = struct
  let id = "registry/1"
  let summary =
    "The names of the services (the registry, in C since 2002): a name gives a \
     port to connect to. The registry itself answers at a well-known port."
  let requests = Ipc.[
      request 0 "register"
        "Register a name: a new port, the caller's; the name is the caller's while \
         it runs." name Wire.int;
      request ~safe:true 1 "lookup" "The port of a name." name Wire.int;
      request ~safe:true 2 "list" "Every name, with its port and the process that \
                                  registered it." Wire.unit entries ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Register n -> Wire.write w Wire.int 0; Wire.write w name n
    | Lookup n -> Wire.write w Wire.int 1; Wire.write w name n
    | List -> Wire.write w Wire.int 2; Wire.write w Wire.unit ()

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Register (Wire.read r name))
    | 1 -> Request (Lookup (Wire.read r name))
    | 2 -> Wire.read r Wire.unit; Request List
    | n -> raise (Wire.Error (Printf.sprintf "registry: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Register _ -> Wire.int
    | Lookup _ -> Wire.int
    | List -> entries
end

module I = Ipc.Make (Protocol)

let call r = I.call (I.connect "registry") r

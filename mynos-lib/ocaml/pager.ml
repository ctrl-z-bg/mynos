(* The external pager's client and kernel calls: see pager.mli. The
   service is services/pager/pagerd.ml. *)

type mapping = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type stats = { regions : int; given : int; refused : int }

type _ request =
  | Map : string * int * int -> (int * int) request
  | Unmap : int -> unit request
  | Stats : stats request

let stats_wire =
  Wire.conv (fun s -> (s.regions, s.given, s.refused))
    (fun (regions, given, refused) -> { regions; given; refused })
    Wire.(triple (field "regions" int) (field "given" int) (field "refused" int))

let map_reply = Wire.(pair (field "page" int) (field "length" int))

module Protocol = struct
  let id = "pager/1"
  let summary = "Files mapped into a process's memory, each page read from \
                 the file when the process first touches it."
  let requests = Ipc.[
      request 0 "map"
        "Map a file (from offset, a multiple of 4096, length bytes; 0: to its \
         end) into the caller's memory, read-only: its first page's number, \
         and its length."
        Wire.(triple (field "path" string) (field "offset" int) (field "length" int))
        map_reply;
      request 1 "unmap" "Forget a mapping of the caller's, by its first page."
        Wire.(field "page" int) Wire.unit;
      request ~safe:true 2 "stats" "Mappings open, pages given and refused."
        Wire.unit stats_wire ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with
    | Map (p, o, l) -> Wire.write w Wire.int 0; Wire.write w Wire.string p;
      Wire.write w Wire.int o; Wire.write w Wire.int l
    | Unmap p -> Wire.write w Wire.int 1; Wire.write w Wire.int p
    | Stats -> Wire.write w Wire.int 2
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let p = Wire.read r Wire.string in let o = Wire.read r Wire.int in
      Request (Map (p, o, Wire.read r Wire.int))
    | 1 -> Request (Unmap (Wire.read r Wire.int))
    | 2 -> Request Stats
    | n -> raise (Wire.Error (Printf.sprintf "pager: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Map _ -> map_reply
    | Unmap _ -> Wire.unit
    | Stats -> stats_wire
end

module I = Ipc.Make (Protocol)

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
let serve = I.serve

let call r =
  match I.connect "pager" with
  | c -> I.call c r
  | exception _ -> failwith "pager: no pager service (pagerd)"

external bytes_at : int -> int -> mapping = "caml_mynos_pager_bytes"
external unmap_pages : int -> int -> unit = "caml_mynos_pager_unmap"

(* a mapping's first page and size, by its bytes' address *)
let mappings : (mapping * int) list ref = ref []

let map_file ?(offset = 0) ?(length = 0) path =
  let page, size = call (Map (path, offset, length)) in
  let m = bytes_at page ((size + 4095) / 4096) in
  let m = Bigarray.Array1.sub m 0 size in
  mappings := (m, page) :: !mappings;
  m

let unmap m =
  match List.assq_opt m !mappings with
  | None -> invalid_arg "Pager.unmap: not a mapping of Pager.map_file"
  | Some page ->
    mappings := List.filter (fun (x, _) -> x != m) !mappings;
    unmap_pages page ((Bigarray.Array1.dim m + 4095) / 4096);
    (try call (Unmap page) with _ -> ())

let stats () = call Stats

type fault = { pid : int; page : int; token : int; write : bool }

external register : unit -> int = "caml_mynos_pager_register"
external region_raw : int -> int -> int -> bool -> int = "caml_mynos_pager_region"
let region ~pid ~pages ~token ~writable = region_raw pid pages token writable
external wait_raw : int -> int * int * int * bool = "caml_mynos_pager_wait"
let wait sem = let pid, page, token, write = wait_raw sem in { pid; page; token; write }
external supply_raw : int -> int -> string option -> unit = "caml_mynos_pager_supply"
let supply f data = supply_raw f.pid f.page (Some data)
let refuse f = supply_raw f.pid f.page None

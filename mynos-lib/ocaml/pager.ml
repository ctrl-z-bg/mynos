(* The external pager's client and kernel calls: see pager.mli. The
   service is services/pager/pagerd.ml; libmynos speaks the same protocol
   for C's mmap of a file (mynos-lib/src/fileio.c). *)

type mapping = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type mode = Read_only | Shared | Private

type stats = {
  regions : int; given : int; refused : int; resident : int; budget : int;
  swapped_out : int; swapped_in : int; written : int;
}

type _ request =
  | Map : string * int * int * mode -> (int * int) request
  | Unmap : int -> unit request
  | Stats : stats request
  | Alloc : int -> int request
  | Sync : int -> unit request
  | Budget : int -> unit request

let mode_wire =
  Wire.conv (function Read_only -> 0 | Shared -> 1 | Private -> 2)
    (function 1 -> Shared | 2 -> Private | _ -> Read_only) Wire.int

let stats_wire =
  Wire.conv
    (fun s -> ((s.regions, s.given, s.refused), (s.resident, s.budget, s.swapped_out),
               (s.swapped_in, s.written)))
    (fun ((regions, given, refused), (resident, budget, swapped_out), (swapped_in, written)) ->
       { regions; given; refused; resident; budget; swapped_out; swapped_in; written })
    Wire.(triple
            (triple (field "regions" int) (field "given" int) (field "refused" int))
            (triple (field "resident" int) (field "budget" int) (field "swapped_out" int))
            (pair (field "swapped_in" int) (field "written" int)))

let map_reply = Wire.(pair (field "page" int) (field "length" int))

module Protocol = struct
  let id = "pager/1"
  let summary = "Memory from the external pager: files mapped into a process's memory, \
                 and memory that may go to the disk, each page provided when first touched."
  let requests = Ipc.[
      request 0 "map"
        "Map a file (from offset, a multiple of 4096, length bytes; 0: to its end) into \
         the caller's memory; mode 0 read-only, 1 shared (changes to the file), 2 \
         private: the first page's number, and the length."
        Wire.(pair (triple (field "path" string) (field "offset" int) (field "length" int))
                (field "mode" mode_wire))
        map_reply;
      request 1 "unmap" "Forget a mapping of the caller's, by its first page (a shared \
                         one's changes written first)."
        Wire.(field "page" int) Wire.unit;
      request ~safe:true 2 "stats" "Mappings, pages given and refused, in memory, the \
                                    budget, swapped out and in, written back."
        Wire.unit stats_wire;
      request 3 "alloc" "Memory of so many pages, zeros, which may go to the swap: the \
                         first page's number."
        Wire.(field "pages" int) Wire.int;
      request 4 "sync" "A shared mapping's changes written to its file now."
        Wire.(field "page" int) Wire.unit;
      request 5 "budget" "At most so many pages in memory (at least 4)."
        Wire.(field "pages" int) Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with
    | Map (p, o, l, m) -> Wire.write w Wire.int 0; Wire.write w Wire.string p;
      Wire.write w Wire.int o; Wire.write w Wire.int l; Wire.write w mode_wire m
    | Unmap p -> Wire.write w Wire.int 1; Wire.write w Wire.int p
    | Stats -> Wire.write w Wire.int 2
    | Alloc n -> Wire.write w Wire.int 3; Wire.write w Wire.int n
    | Sync p -> Wire.write w Wire.int 4; Wire.write w Wire.int p
    | Budget n -> Wire.write w Wire.int 5; Wire.write w Wire.int n
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let p = Wire.read r Wire.string in let o = Wire.read r Wire.int in
      let l = Wire.read r Wire.int in Request (Map (p, o, l, Wire.read r mode_wire))
    | 1 -> Request (Unmap (Wire.read r Wire.int))
    | 2 -> Request Stats
    | 3 -> Request (Alloc (Wire.read r Wire.int))
    | 4 -> Request (Sync (Wire.read r Wire.int))
    | 5 -> Request (Budget (Wire.read r Wire.int))
    | n -> raise (Wire.Error (Printf.sprintf "pager: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Map _ -> map_reply
    | Unmap _ -> Wire.unit
    | Stats -> stats_wire
    | Alloc _ -> Wire.int
    | Sync _ -> Wire.unit
    | Budget _ -> Wire.unit
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

(* a mapping's first page, by its bytes (physically) *)
let mappings : (mapping * int) list ref = ref []

let remember page size =
  let m = Bigarray.Array1.sub (bytes_at page ((size + 4095) / 4096)) 0 size in
  mappings := (m, page) :: !mappings;
  m

let map_file ?(offset = 0) ?(length = 0) ?(mode = Read_only) path =
  let page, size = call (Map (path, offset, length, mode)) in
  remember page size

let alloc pages =
  if pages <= 0 then invalid_arg "Pager.alloc";
  remember (call (Alloc pages)) (pages * 4096)

let page_of fn m =
  match List.assq_opt m !mappings with
  | Some page -> page
  | None -> invalid_arg ("Pager." ^ fn ^ ": not a mapping of Pager's")

let sync m = call (Sync (page_of "sync" m))

let unmap m =
  let page = page_of "unmap" m in
  (* pagerd first: a shared mapping's pages, written back while there *)
  (try call (Unmap page) with _ -> ());
  mappings := List.filter (fun (x, _) -> x != m) !mappings;
  unmap_pages page ((Bigarray.Array1.dim m + 4095) / 4096)

let set_budget n = call (Budget n)
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
external query_raw : int -> int -> int = "caml_mynos_pager_query"
let query ~pid ~page = query_raw pid page
external evict_raw : int -> int -> int -> bool -> string = "caml_mynos_pager_evict"
let evict ~pid ~page ~token ~writable = evict_raw pid page token writable
external copy_raw : int -> int -> string = "caml_mynos_pager_copy"
let copy ~pid ~page = copy_raw pid page

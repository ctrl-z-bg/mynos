(* fs/1, the protocol of the file services: see fs.mli. *)

type _ request =
  | Open : string * int -> int request
  | Close : int -> unit request
  | Read : int * int -> string request
  | Write : int * string -> int request
  | Seek : int * int * int -> int request
  | List : string -> (string * int) list request
  | Remove : string -> unit request
  | Mkdir : string -> unit request
  | Rmdir : string -> unit request
  | Rename : string * string -> unit request

let o_write = 1 and o_creat = 2 and o_trunc = 4 and o_append = 8
and o_excl = 16
let io_max = 16384

let ok = 0 and not_found = 1 and too_many = 2 and denied = 3 and not_open = 4
and invalid = 5 and read_only = 6 and no_space = 7 and is_dir = 8
and not_empty = 9 and exists = 10 and not_dir = 11

let error_names = [| "ok"; "not_found"; "too_many"; "denied"; "not_open"; "invalid";
                     "read_only"; "no_space"; "is_dir"; "not_empty"; "exists"; "not_dir" |]

let error_name code =
  if code >= 0 && code < Array.length error_names then error_names.(code) else "invalid"

let fail code = failwith (error_name code)

let error_of message =
  let word = match String.index_opt message ':' with
    | Some i -> String.sub message 0 i | None -> message in
  let rec find i =
    if i >= Array.length error_names then invalid
    else if error_names.(i) = word then i else find (i + 1) in
  find 0

let path = Wire.(field "path" string)
let fd = Wire.(field "fd" int)
let open_args = Wire.(pair path (field "flags" int))
let read_args = Wire.(pair fd (field "max" int))
let write_args = Wire.(pair fd (field "data" string))
let seek_args = Wire.(triple fd (field "offset" int) (field "whence" int))
let rename_args = Wire.(pair (field "from" string) (field "to" string))
let entries = Wire.(list (pair (field "name" string) (field "size" int)))

module Protocol = struct
  let id = "fs/1"
  let summary =
    "Files: open, read, write, list and change the files of a file service \
     (memrofs: /, read-only; tmpfs: /tmp; fatfs: /disk). Paths are inside the \
     service: \"docs/a.txt\", no leading slash. Errors start with a name: \
     not_found, denied, read_only, is_dir, exists, not_empty..."
  let requests = Ipc.[
      request 0 "open"
        "Open a file: its descriptor. flags: 1 write, 2 create, 4 truncate, 8 \
         append (0: read)." open_args Wire.int;
      request ~safe:true 1 "close" "Close a descriptor." fd Wire.unit;
      request ~safe:true 2 "read" "Up to max bytes (16384 at most) from the position: \
                                  \"\" at the end." read_args Wire.string;
      request 3 "write" "Write data (16384 bytes at most) at the position: how many."
        write_args Wire.int;
      request ~safe:true 4 "seek" "Move the position: whence 0 from the start, 1 from \
                                  here, 2 from the end. The new position." seek_args Wire.int;
      request ~safe:true 5 "list" "A directory's entries: names and sizes (-1: a \
                                  directory)." path entries;
      request 6 "remove" "Remove a file." path Wire.unit;
      request 7 "mkdir" "Make a directory." path Wire.unit;
      request 8 "rmdir" "Remove an empty directory." path Wire.unit;
      request 9 "rename" "Rename a file (one of the new name is replaced)." rename_args
        Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Open (p, f) -> case 0; Wire.write w open_args (p, f)
    | Close d -> case 1; Wire.write w fd d
    | Read (d, n) -> case 2; Wire.write w read_args (d, n)
    | Write (d, s) -> case 3; Wire.write w write_args (d, s)
    | Seek (d, o, wh) -> case 4; Wire.write w seek_args (d, o, wh)
    | List p -> case 5; Wire.write w path p
    | Remove p -> case 6; Wire.write w path p
    | Mkdir p -> case 7; Wire.write w path p
    | Rmdir p -> case 8; Wire.write w path p
    | Rename (a, b) -> case 9; Wire.write w rename_args (a, b)

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let p, f = Wire.read r open_args in Request (Open (p, f))
    | 1 -> Request (Close (Wire.read r fd))
    | 2 -> let d, n = Wire.read r read_args in Request (Read (d, n))
    | 3 -> let d, s = Wire.read r write_args in Request (Write (d, s))
    | 4 -> let d, o, wh = Wire.read r seek_args in Request (Seek (d, o, wh))
    | 5 -> Request (List (Wire.read r path))
    | 6 -> Request (Remove (Wire.read r path))
    | 7 -> Request (Mkdir (Wire.read r path))
    | 8 -> Request (Rmdir (Wire.read r path))
    | 9 -> let a, b = Wire.read r rename_args in Request (Rename (a, b))
    | n -> raise (Wire.Error (Printf.sprintf "fs: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Open _ -> Wire.int
    | Close _ -> Wire.unit
    | Read _ -> Wire.string
    | Write _ -> Wire.int
    | Seek _ -> Wire.int
    | List _ -> entries
    | Remove _ -> Wire.unit
    | Mkdir _ -> Wire.unit
    | Rmdir _ -> Wire.unit
    | Rename _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type client = I.client
let connect service = I.connect service
let call = I.call

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
let serve name h = I.serve name h

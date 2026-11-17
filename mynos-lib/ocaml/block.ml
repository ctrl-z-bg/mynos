(* Block devices over typed IPC: see block.mli. *)

let sector = 512
let max_count = 32

type _ request =
  | Info : int request
  | Read : int * int -> string request
  | Write : int * string -> unit request

module Protocol = struct
  let id = "block/1"
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Info -> Wire.write w Wire.int 0
    | Read (lba, count) ->
      Wire.write w Wire.int 1; Wire.write w Wire.(pair int int) (lba, count)
    | Write (lba, bytes) ->
      Wire.write w Wire.int 2; Wire.write w Wire.(pair int string) (lba, bytes)

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Info
    | 1 -> let lba, count = Wire.read r Wire.(pair int int) in
      Request (Read (lba, count))
    | 2 -> let lba, bytes = Wire.read r Wire.(pair int string) in
      Request (Write (lba, bytes))
    | n -> raise (Wire.Error (Printf.sprintf "block: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Info -> Wire.int
    | Read _ -> Wire.string
    | Write _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type t = { client : I.client; size : int }

let call d r = I.call d.client r

let connect ?(service = "ata0") () =
  let client = I.connect service in
  { client; size = I.call client Info }

let sectors d = d.size

(* the convenience functions keep the old errors: Failure *)
let checked f =
  try f () with Ipc.Remote_error (s, m) -> failwith (Printf.sprintf "Block: %s: %s" s m)

let read d lba count =
  let buf = Buffer.create (count * sector) in
  let rec go lba count =
    if count > 0 then begin
      let n = min count max_count in
      Buffer.add_string buf (checked (fun () -> call d (Read (lba, n))));
      go (lba + n) (count - n)
    end in
  go lba count;
  Buffer.contents buf

let write d lba bytes =
  if String.length bytes mod sector <> 0 then
    invalid_arg "Block.write: not a whole number of sectors";
  let rec go lba off =
    if off < String.length bytes then begin
      let n = min ((String.length bytes - off) / sector) max_count in
      checked (fun () -> call d (Write (lba, String.sub bytes off (n * sector))));
      go (lba + n) (off + n * sector)
    end in
  go lba 0

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }

let serve = I.serve
let answer = I.answer
let request_message = I.request_message
let read_reply = I.read_reply

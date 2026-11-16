(* tmpfs: a writable filesystem in memory, the first MyNOS service written
   in OCaml. Programs see it as /tmp (the file functions of libmynos route
   /tmp/NAME here as NAME). One flat directory; the files are lost when the
   machine stops.

   Protocol: mynos-lib/include/mynos_fs.h, one connection per request. A
   request is 84 bytes: type, client, fd, arg1, arg2 (little-endian int32)
   and a 64-byte name; a reply is 8 bytes: status and value. READ replies
   are followed by the data, WRITE requests by the data, LIST replies by
   the name. *)

(* request types, open flags, statuses: as in mynos_fs.h *)
let fs_open = 0 and fs_close = 1 and fs_read = 2 and fs_lseek = 3
and fs_list = 4 and fs_write = 5 and fs_unlink = 6

let o_write = 1 and o_creat = 2 and o_trunc = 4 and o_append = 8

let ok = 0 and not_found = 1 and too_many = 2 and denied = 3
and not_open = 4 and invalid = 5 and readonly = 6

let name_max = 64
let io_max = 16384
let max_open = 1000

(* a file: its contents are data[0 .. size) *)
type file = { mutable data : Bytes.t; mutable size : int }

(* an open file: its owner, its access and position *)
type desc = {
  client : int;
  file : file;
  writable : bool;
  append : bool;
  mutable pos : int;
}

let files : (string, file) Hashtbl.t = Hashtbl.create 16
let descs : (int, desc) Hashtbl.t = Hashtbl.create 16
let next_fd = ref 3

type request = {
  typ : int;
  client : int;
  fd : int;
  arg1 : int;
  arg2 : int;
  name : string;
}

let parse s =
  let int_at i = Int32.to_int (String.get_int32_le s i) in
  let raw = String.sub s 20 name_max in
  let name =
    match String.index_opt raw '\000' with
    | Some n -> String.sub raw 0 n
    | None -> raw in
  { typ = int_at 0; client = int_at 4; fd = int_at 8; arg1 = int_at 12;
    arg2 = int_at 16; name }

let reply ch status value =
  let b = Bytes.create 8 in
  Bytes.set_int32_le b 0 (Int32.of_int status);
  Bytes.set_int32_le b 4 (Int32.of_int value);
  Mynos.send ch (Bytes.to_string b)

(* a name in the flat directory *)
let valid_name n =
  n <> "" && String.length n < name_max && not (String.contains n '/')

(* the open file fd of client, or the status to reply *)
let owned r =
  match Hashtbl.find_opt descs r.fd with
  | None -> Error not_open
  | Some d when d.client <> r.client -> Error denied
  | Some d -> Ok d

let new_fd () =
  let rec find n tries =
    if tries > max_open then None
    else if Hashtbl.mem descs n then find (if n >= max_open then 3 else n + 1) (tries + 1)
    else Some n in
  match find !next_fd 0 with
  | Some n -> next_fd := (if n >= max_open then 3 else n + 1); Some n
  | None -> None

let do_open ch r =
  let writable = r.arg1 land o_write <> 0 in
  if not (valid_name r.name) then reply ch invalid (-1)
  else begin
    let file =
      match Hashtbl.find_opt files r.name with
      | Some f ->
        if writable && r.arg1 land o_trunc <> 0 then f.size <- 0;
        Some f
      | None when r.arg1 land o_creat <> 0 ->
        let f = { data = Bytes.create 256; size = 0 } in
        Hashtbl.replace files r.name f;
        Some f
      | None -> None in
    match file, new_fd () with
    | None, _ -> reply ch not_found (-1)
    | Some _, None -> reply ch too_many (-1)
    | Some file, Some fd ->
      Hashtbl.replace descs fd
        { client = r.client; file; writable;
          append = r.arg1 land o_append <> 0; pos = 0 };
      reply ch ok fd
  end

let do_close ch r =
  match owned r with
  | Error st -> reply ch st 0
  | Ok _ -> Hashtbl.remove descs r.fd; reply ch ok 0

let do_read ch r =
  match owned r with
  | Error st -> reply ch st 0
  | Ok d ->
    let n = max 0 (min (min r.arg1 io_max) (d.file.size - d.pos)) in
    reply ch ok n;
    if n > 0 then begin
      Mynos.send ch (Bytes.sub_string d.file.data d.pos n);
      d.pos <- d.pos + n
    end

let do_write ch r =
  (* the data follows the request: take it before replying *)
  let data = Mynos.recv ~timeout:1.0 ch in
  match owned r with
  | Error st -> reply ch st 0
  | Ok d when not d.writable -> reply ch readonly 0
  | Ok d ->
    let f = d.file in
    if d.append then d.pos <- f.size;
    let n = String.length data in
    let needed = d.pos + n in
    if needed > Bytes.length f.data then begin
      let bigger = Bytes.make (max needed (2 * Bytes.length f.data)) '\000' in
      Bytes.blit f.data 0 bigger 0 f.size;
      f.data <- bigger
    end;
    if d.pos > f.size then Bytes.fill f.data f.size (d.pos - f.size) '\000';
    Bytes.blit_string data 0 f.data d.pos n;
    d.pos <- needed;
    if needed > f.size then f.size <- needed;
    reply ch ok n

let do_lseek ch r =
  match owned r with
  | Error st -> reply ch st (-1)
  | Ok d ->
    let base =
      match r.arg2 with
      | 0 -> Some 0
      | 1 -> Some d.pos
      | 2 -> Some d.file.size
      | _ -> None in
    match base with
    | Some b when b + r.arg1 >= 0 ->
      d.pos <- b + r.arg1;
      reply ch ok d.pos
    | _ -> reply ch invalid (-1)

let do_list ch r =
  if r.name <> "" then reply ch not_found (-1) else (* one flat directory *)
  let names = Hashtbl.fold (fun n _ acc -> n :: acc) files [] in
  match List.nth_opt (List.sort compare names) r.arg1 with
  | Some n when r.arg1 >= 0 ->
    reply ch ok (Hashtbl.find files n).size;
    Mynos.send ch (n ^ "\000")
  | _ -> reply ch not_found (-1)

let do_unlink ch r =
  (* files still open stay readable through their descriptors *)
  if Hashtbl.mem files r.name then begin
    Hashtbl.remove files r.name;
    reply ch ok 0
  end else reply ch not_found (-1)

let serve ch =
  let msg = Mynos.recv ~timeout:1.0 ch in
  if String.length msg <> 20 + name_max then reply ch invalid (-1)
  else begin
    let r = parse msg in
    if r.typ = fs_open then do_open ch r
    else if r.typ = fs_close then do_close ch r
    else if r.typ = fs_read then do_read ch r
    else if r.typ = fs_write then do_write ch r
    else if r.typ = fs_lseek then do_lseek ch r
    else if r.typ = fs_list then do_list ch r
    else if r.typ = fs_unlink then do_unlink ch r
    else reply ch invalid (-1)
  end

let () =
  let port = Mynos.register "tmpfs" in
  Mynos.log (Printf.sprintf "tmpfs: service on port %d" port);
  while true do
    let ch = Mynos.listen port in
    (try serve ch
     with Mynos.Error (fn, code) ->
       Mynos.log (Printf.sprintf "tmpfs: %s: %s" fn (Mynos.error_name code)));
    (try Mynos.free_channel ch with Mynos.Error _ -> ())
  done

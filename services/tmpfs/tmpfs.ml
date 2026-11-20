(* tmpfs: a writable filesystem in memory, the first MyNOS service written
   in OCaml. Programs see it as /tmp (the file functions of libmynos route
   /tmp/NAME here as NAME). One flat directory; the files are lost when the
   machine stops.

   Protocol: fs/1 (module Fs, mynos-lib/include/mynos_fs.h), typed IPC:
   the caller of a request is the owner of the descriptors it opens. *)

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

(* a name in the flat directory *)
let valid_name n =
  n <> "" && String.length n < 64 && not (String.contains n '/')

(* the open file fd of the caller *)
let owned me fd =
  match Hashtbl.find_opt descs fd with
  | None -> Fs.fail Fs.not_open
  | Some d when d.client <> me -> Fs.fail Fs.denied
  | Some d -> d

let new_fd () =
  let rec find n tries =
    if tries > max_open then None
    else if Hashtbl.mem descs n then find (if n >= max_open then 3 else n + 1) (tries + 1)
    else Some n in
  match find !next_fd 0 with
  | Some n -> next_fd := (if n >= max_open then 3 else n + 1); Some n
  | None -> None

let do_open me name flags =
  let writable = flags land Fs.o_write <> 0 in
  if not (valid_name name) then Fs.fail (if name = "" then Fs.is_dir else Fs.invalid);
  let file =
    match Hashtbl.find_opt files name with
    | Some _ when flags land Fs.o_creat <> 0 && flags land Fs.o_excl <> 0 ->
      Fs.fail Fs.exists
    | Some f ->
      if writable && flags land Fs.o_trunc <> 0 then f.size <- 0;
      Some f
    | None when flags land Fs.o_creat <> 0 ->
      let f = { data = Bytes.create 256; size = 0 } in
      Hashtbl.replace files name f;
      Some f
    | None -> None in
  match file, new_fd () with
  | None, _ -> Fs.fail Fs.not_found
  | Some _, None -> Fs.fail Fs.too_many
  | Some file, Some fd ->
    Hashtbl.replace descs fd
      { client = me; file; writable; append = flags land Fs.o_append <> 0; pos = 0 };
    fd

let do_read d max =
  let n = Stdlib.max 0 (min (min max Fs.io_max) (d.file.size - d.pos)) in
  let s = Bytes.sub_string d.file.data d.pos n in
  d.pos <- d.pos + n;
  s

let do_write d data =
  if not d.writable then Fs.fail Fs.read_only;
  let f = d.file in
  if d.append then d.pos <- f.size;
  let n = String.length data in
  let needed = d.pos + n in
  if needed > Bytes.length f.data then begin
    let bigger = Bytes.make (Stdlib.max needed (2 * Bytes.length f.data)) '\000' in
    Bytes.blit f.data 0 bigger 0 f.size;
    f.data <- bigger
  end;
  if d.pos > f.size then Bytes.fill f.data f.size (d.pos - f.size) '\000';
  Bytes.blit_string data 0 f.data d.pos n;
  d.pos <- needed;
  if needed > f.size then f.size <- needed;
  n

let do_seek d offset whence =
  let base = match whence with
    | 0 -> 0 | 1 -> d.pos | 2 -> d.file.size | _ -> Fs.fail Fs.invalid in
  if base + offset < 0 then Fs.fail Fs.invalid;
  d.pos <- base + offset;
  d.pos

let handle = { Fs.handle = fun (type a) (caller : Ipc.caller) (r : a Fs.request) : a ->
    let me = caller.Ipc.pid in
    match r with
    | Fs.Open (name, flags) -> do_open me name flags
    | Fs.Close fd -> ignore (owned me fd); Hashtbl.remove descs fd
    | Fs.Read (fd, max) -> do_read (owned me fd) max
    | Fs.Write (fd, data) -> do_write (owned me fd) data
    | Fs.Seek (fd, offset, whence) -> do_seek (owned me fd) offset whence
    | Fs.List "" ->                               (* one flat directory *)
      List.sort compare (Hashtbl.fold (fun n f acc -> (n, f.size) :: acc) files [])
    | Fs.List _ -> Fs.fail Fs.not_found
    | Fs.Remove name ->
      (* files still open stay readable through their descriptors *)
      if not (Hashtbl.mem files name) then Fs.fail Fs.not_found;
      Hashtbl.remove files name
    | Fs.Rename (name, target) ->
      (match Hashtbl.find_opt files name with
       | None -> Fs.fail Fs.not_found
       | Some _ when not (valid_name target) -> Fs.fail Fs.invalid
       | Some f ->
         Hashtbl.remove files name;
         Hashtbl.replace files target f)          (* replaces an existing one *)
    | Fs.Mkdir _ | Fs.Rmdir _ -> Fs.fail Fs.invalid   (* flat *)
  }

let () =
  Mynos.log "tmpfs: service fs/1, as tmpfs";
  Fs.serve "tmpfs" handle

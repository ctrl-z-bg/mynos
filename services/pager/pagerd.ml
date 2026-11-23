(* pagerd: the external pager (mynos-vzp; appendix B.14), registered as
   "pager" (protocol pager/1, module Pager). It provides the pages of
   regions of other processes' memory: files mapped (read-only, shared or
   private) and memory of its own (alloc), each page when it is first
   touched. init starts it as a driver: becoming the pager needs the io
   privilege.

   It keeps at most a budget of its pages in memory, all regions
   together. Past it, a page is taken back (Pager.evict), chosen by the
   clock: the pages in the order they were given, a page used since the
   last look gets a second chance. A page taken back goes where it can be
   read again: memory of alloc and a private mapping's changed pages to
   the swap (/disk/swap, slots of 4 KB), a shared mapping's changed pages
   to their file; a page as the file has it, nowhere.

   Two threads: the service (map, alloc, sync, unmap, stats, budget) and
   the pages. A page is named by its token: each region has a range of
   them, so a child that fork copied a region into is answered too. A
   region lasts until its owner unmaps it or ends. *)

type mode = Pager.mode

type kind =
  | File of { fd : Unix.file_descr; path : string; offset : int; length : int; mode : mode }
  | Anon

type region = {
  owner : int;
  page : int;               (* its first page in the owner *)
  token : int;              (* its first token *)
  pages : int;
  kind : kind;
}

let lock = Mutex.create ()
let regions : region list ref = ref []

(* the pages in memory, in the clock's order: (pid, page, token) *)
let ring : (int * int * int) Queue.t = Queue.create ()
let budget = ref 2048
let given = ref 0 and refused = ref 0
let swapped_out = ref 0 and swapped_in = ref 0 and written = ref 0

(* ---- tokens: 2^20 of them, in ranges (start, count), first fit ---- *)

let free = ref [ (1, (1 lsl 20) - 1) ]

let take n =
  let rec go acc = function
    | [] -> None
    | (s, c) :: rest when c >= n ->
      free := List.rev_append acc (if c = n then rest else (s + n, c - n) :: rest);
      Some s
    | r :: rest -> go (r :: acc) rest in
  go [] !free

let give_back s n =
  let rec merge = function
    | (a, c) :: (b, d) :: rest when a + c = b -> merge ((a, c + d) :: rest)
    | r :: rest -> r :: merge rest
    | [] -> [] in
  free := merge (List.sort compare ((s, n) :: !free))

(* ---- the swap: /disk/swap, a slot of 4 KB for each page kept there ---- *)

let swap_path = "/disk/swap"
let swap_fd = ref None
let in_swap : (int, int) Hashtbl.t = Hashtbl.create 64     (* token -> slot *)
let free_slots = ref [] and next_slot = ref 0

let swap () =
  match !swap_fd with
  | Some fd -> fd
  | None ->
    let fd = Unix.openfile swap_path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
    swap_fd := Some fd; fd

let write_at fd pos data =
  ignore (Unix.lseek fd pos Unix.SEEK_SET);
  let n = String.length data in
  let rec go o = if o < n then go (o + Unix.write_substring fd data o (n - o)) in
  go 0

let read_at fd pos n =
  ignore (Unix.lseek fd pos Unix.SEEK_SET);
  let b = Bytes.create n in
  let rec go o = if o < n then match Unix.read fd b o (n - o) with 0 -> o | k -> go (o + k) else o in
  Bytes.sub_string b 0 (go 0)

let to_swap token data =
  let slot = match Hashtbl.find_opt in_swap token with
    | Some s -> s
    | None -> (match !free_slots with
        | s :: rest -> free_slots := rest; s
        | [] -> let s = !next_slot in incr next_slot; s) in
  write_at (swap ()) (slot * 4096) data;
  Hashtbl.replace in_swap token slot;
  incr swapped_out

let from_swap token =
  match Hashtbl.find_opt in_swap token with
  | None -> None
  | Some slot ->
    incr swapped_in;
    Some (read_at (swap ()) (slot * 4096) 4096)

let forget_swap token =
  match Hashtbl.find_opt in_swap token with
  | Some slot -> Hashtbl.remove in_swap token; free_slots := slot :: !free_slots
  | None -> ()

(* ---- regions ---- *)

let region_of token =
  List.find_opt (fun r -> token >= r.token && token < r.token + r.pages) !regions

let writable r = match r.kind with Anon -> true | File f -> f.mode <> Pager.Read_only

(* a file's page: where it starts in the file, and how many bytes of it
   the mapping has *)
let file_span r token =
  match r.kind with
  | File f ->
    let pos = f.offset + (token - r.token) * 4096 in
    (pos, max 0 (min 4096 (f.offset + f.length - pos)))
  | Anon -> (0, 0)

(* a shared mapping's page, written back to its file *)
let write_back r token data =
  match r.kind with
  | File { fd; mode = Pager.Shared; _ } ->
    let pos, n = file_span r token in
    if n > 0 then (write_at fd pos (String.sub data 0 n); incr written)
  | _ -> ()

(* the clock: the next page to take back, out of memory *)
let rec evict_one () =
  match Queue.take_opt ring with
  | None -> ()
  | Some (pid, page, token) ->
    let q = try Pager.query ~pid ~page with Mynos.Error _ -> 0 in
    if q = 0 then evict_one ()                 (* gone (unmapped, ended, shared by fork) *)
    else if q land 2 <> 0 then begin           (* used: a second chance *)
      Queue.add (pid, page, token) ring;
      evict_one ()
    end else
      match region_of token with
      | None -> ()
      | Some r ->
        (match Pager.evict ~pid ~page ~token ~writable:(writable r) with
         | data ->
           (* to the swap only if changed since it was last there (a page
              never written reads as zeros, or as the file has it) *)
           (match r.kind with
            | Anon -> if q land 4 <> 0 then to_swap token data
            | File { mode = Pager.Private; _ } -> if q land 4 <> 0 then to_swap token data
            | File { mode = Pager.Shared; _ } -> if q land 4 <> 0 then write_back r token data
            | File _ -> ())
         | exception Mynos.Error _ -> ())

let make_room () =
  while Queue.length ring >= !budget && not (Queue.is_empty ring) do evict_one () done

(* a region gone: its pages out of the clock, its swap slots free *)
let drop_region r =
  regions := List.filter (fun x -> x != r) !regions;
  (match r.kind with File f -> (try Unix.close f.fd with _ -> ()) | Anon -> ());
  let keep = Queue.create () in
  Queue.iter (fun ((_, _, t) as e) -> if t < r.token || t >= r.token + r.pages then Queue.add e keep) ring;
  Queue.clear ring;
  Queue.transfer keep ring;
  for t = r.token to r.token + r.pages - 1 do forget_swap t done;
  give_back r.token r.pages

(* the regions of processes that have ended *)
let forget_dead () =
  let alive = List.map (fun p -> p.Mynos.p_pid) (Mynos.processes ()) in
  List.iter (fun r -> if not (List.mem r.owner alive) then drop_region r) !regions

let new_region (caller : Ipc.caller) pages kind =
  forget_dead ();
  match take pages with
  | None -> failwith "too many pages mapped"
  | Some token ->
    let w = match kind with Anon -> true | File f -> f.mode <> Pager.Read_only in
    match Pager.region ~pid:caller.pid ~pages ~token ~writable:w with
    | page ->
      regions := { owner = caller.pid; page; token; pages; kind } :: !regions;
      page
    | exception e -> give_back token pages; raise e

(* ---- the service ---- *)

let map caller path offset length mode =
  if offset < 0 || offset land 4095 <> 0 then failwith "the offset is not a multiple of 4096";
  let flags = if mode = Pager.Shared then [ Unix.O_RDWR ] else [ Unix.O_RDONLY ] in
  let fd = try Unix.openfile path flags 0 with Unix.Unix_error (e, _, _) -> failwith (Unix.error_message e) in
  let size = (Unix.fstat fd).Unix.st_size in
  let length = if length <= 0 then size - offset else min length (size - offset) in
  if length <= 0 then (Unix.close fd; failwith "nothing to map there");
  let pages = (length + 4095) / 4096 in
  Mutex.protect lock (fun () ->
      match new_region caller pages (File { fd; path; offset; length; mode }) with
      | page -> (page, length)
      | exception e -> Unix.close fd; raise e)

let find_region (caller : Ipc.caller) page =
  match List.find_opt (fun r -> r.owner = caller.pid && r.page = page) !regions with
  | Some r -> r
  | None -> failwith "no such mapping"

(* a region's pages in memory that its owner changed: written back *)
let sync_region r =
  match r.kind with
  | File { mode = Pager.Shared; _ } ->
    Queue.iter (fun (pid, page, token) ->
        if pid = r.owner && token >= r.token && token < r.token + r.pages then
          let q = try Pager.query ~pid ~page with Mynos.Error _ -> 0 in
          if q land 4 <> 0 then
            (try write_back r token (Pager.copy ~pid ~page) with Mynos.Error _ -> ())) ring
  | _ -> ()

let unmap caller page =
  Mutex.protect lock (fun () ->
      let r = find_region caller page in
      sync_region r;
      drop_region r)

(* ---- the pages ---- *)

let page_for r token =
  match r.kind with
  | Anon -> (match from_swap token with Some d -> Some d | None -> Some "")
  | File { fd; mode; _ } ->
    match (if mode = Pager.Private then from_swap token else None) with
    | Some d -> Some d
    | None ->
      let pos, n = file_span r token in
      (try Some (read_at fd pos n) with _ -> None)

let serve_pages sem =
  while true do
    let f = Pager.wait sem in
    Mutex.protect lock (fun () ->
        match region_of f.Pager.token with
        | None -> (try Pager.refuse f with Mynos.Error _ -> ()); incr refused
        | Some r ->
          make_room ();
          match page_for r f.token with
          | Some d ->
            (match Pager.supply f d with
             | () -> incr given; Queue.add (f.pid, f.page, f.token) ring
             | exception Mynos.Error _ -> ())       (* that process has ended meanwhile *)
          | None -> (try Pager.refuse f with Mynos.Error _ -> ()); incr refused)
  done

let () =
  let sem = Pager.register () in
  ignore (Thread.create serve_pages sem);
  Pager.serve "pager"
    { Pager.handle = fun (type a) caller (r : a Pager.request) : a ->
          match r with
          | Pager.Map (path, offset, length, mode) -> map caller path offset length mode
          | Pager.Alloc pages ->
            if pages <= 0 then failwith "no pages";
            Mutex.protect lock (fun () -> new_region caller pages Anon)
          | Pager.Sync page -> Mutex.protect lock (fun () -> sync_region (find_region caller page))
          | Pager.Unmap page -> unmap caller page
          | Pager.Budget n -> Mutex.protect lock (fun () -> budget := max 4 n; make_room ())
          | Pager.Stats ->
            Mutex.protect lock (fun () ->
                { Pager.regions = List.length !regions; given = !given; refused = !refused;
                  resident = Queue.length ring; budget = !budget;
                  swapped_out = !swapped_out; swapped_in = !swapped_in; written = !written }) }

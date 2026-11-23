(* pagerd: the external pager (mynos-vzp; appendix B.14), registered as
   "pager" (protocol pager/1, module Pager). It maps files into the memory
   of the processes that ask: the kernel gives each mapping's pages to
   pagerd, and the first touch of a page becomes a request here, answered
   with that page read from the file. init starts it as a driver: becoming
   the pager needs the io privilege.

   Two threads: the service (map, unmap, stats) and the pages. A page is
   named by its token: each mapping has a range of them, so a child that
   fork copied a mapping into is answered too. A mapping lasts until its
   owner unmaps it or ends. *)

type mapping = {
  owner : int;
  page : int;               (* its first page in the owner *)
  token : int;              (* its first token *)
  pages : int;
  path : string;
  offset : int;
  length : int;
  ic : in_channel;
}

let lock = Mutex.create ()
let maps : mapping list ref = ref []
let given = ref 0
let refused = ref 0

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

let drop m =
  maps := List.filter (fun x -> x != m) !maps;
  close_in_noerr m.ic;
  give_back m.token m.pages

(* the mappings of processes that have ended *)
let forget_dead () =
  let alive = List.map (fun p -> p.Mynos.p_pid) (Mynos.processes ()) in
  List.iter (fun m -> if not (List.mem m.owner alive) then drop m) !maps

(* ---- the service ---- *)

let map (caller : Ipc.caller) path offset length =
  if offset < 0 || offset land 4095 <> 0 then failwith "the offset is not a multiple of 4096";
  let ic = try open_in_bin path with Sys_error e -> failwith e in
  let size = in_channel_length ic in
  let length = if length <= 0 then size - offset else min length (size - offset) in
  if length <= 0 then (close_in ic; failwith "nothing to map there");
  let pages = (length + 4095) / 4096 in
  Mutex.protect lock (fun () ->
      forget_dead ();
      match take pages with
      | None -> close_in ic; failwith "too many pages mapped"
      | Some token ->
        match Pager.region ~pid:caller.pid ~pages ~token ~writable:false with
        | page ->
          maps := { owner = caller.pid; page; token; pages; path; offset; length; ic } :: !maps;
          (page, length)
        | exception e -> close_in ic; give_back token pages; raise e)

let unmap (caller : Ipc.caller) page =
  Mutex.protect lock (fun () ->
      match List.find_opt (fun m -> m.owner = caller.pid && m.page = page) !maps with
      | Some m -> drop m
      | None -> failwith "no such mapping")

(* ---- the pages ---- *)

let serve_pages sem =
  while true do
    let f = Pager.wait sem in
    let data =
      Mutex.protect lock (fun () ->
          match List.find_opt (fun m -> f.Pager.token >= m.token
                                        && f.token < m.token + m.pages) !maps with
          | None -> None
          | Some m ->
            let pos = m.offset + (f.token - m.token) * 4096 in
            let n = min 4096 (m.offset + m.length - pos) in
            (try seek_in m.ic pos; Some (really_input_string m.ic n) with _ -> None)) in
    (try
       match data with
       | Some d -> Pager.supply f d; incr given
       | None -> Pager.refuse f; incr refused
     with Mynos.Error _ -> ())          (* that process has ended meanwhile *)
  done

let () =
  let sem = Pager.register () in
  ignore (Thread.create serve_pages sem);
  Pager.serve "pager"
    { Pager.handle = fun (type a) caller (r : a Pager.request) : a ->
          match r with
          | Pager.Map (path, offset, length) -> map caller path offset length
          | Pager.Unmap page -> unmap caller page
          | Pager.Stats ->
            Mutex.protect lock (fun () ->
                { Pager.regions = List.length !maps; given = !given; refused = !refused }) }

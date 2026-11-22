(* Run and watch: the program runs under the event recorder (module
   Tracer, one recording at a time); when it ends, whom it talked to. Its
   calls by service (how many, how long in all), the calls those services
   made meanwhile (nested), the slowest; the recording kept in a file,
   which Recordings replays. *)

type line = { text : string; strong : bool }

let file () = Printf.sprintf "/tmp/studio%d.trc" (Mynos.getpid ())

let start () = try Tracer.start (); Ok () with Tracer.Busy -> Error "another program is recording"

let ms f = if Float.is_nan f then "?" else Printf.sprintf "%.1f ms" f

(* the summary of a recording: [pid] the program's *)
let summary r pid =
  let calls = Tracer.calls r in
  let mine = List.filter (fun (c : Tracer.call) -> c.client = pid) calls in
  let dur (c : Tracer.call) = if Float.is_nan c.finish then 0. else c.finish -. c.start in
  (* by server: calls and time *)
  let by = Hashtbl.create 16 in
  let add tbl key c =
    let n, t = Option.value (Hashtbl.find_opt tbl key) ~default:(0, 0.) in
    Hashtbl.replace tbl key (n + 1, t +. dur c) in
  List.iter (fun (c : Tracer.call) -> add by (Tracer.program r c.server) c) mine;
  (* what those servers asked of others meanwhile: nested calls *)
  let servers = List.sort_uniq compare (List.map (fun (c : Tracer.call) -> c.server) mine) in
  let nested = Hashtbl.create 16 in
  List.iter (fun (c : Tracer.call) ->
      if List.mem c.client servers && c.depth > 0 then
        add nested (Tracer.program r c.client ^ " -> " ^ Tracer.program r c.server) c) calls;
  let rows tbl =
    List.sort (fun (_, (_, a)) (_, (_, b)) -> compare b a)
      (Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []) in
  let total = List.fold_left (fun a c -> a +. dur c) 0. mine in
  let head = { text = Printf.sprintf "%s: %d calls, %s waiting for services%s"
                   (Tracer.program r pid) (List.length mine) (ms total)
                   (if r.Tracer.dropped > 0 then Printf.sprintf " (%d events lost)" r.Tracer.dropped else "");
               strong = true } in
  let services = List.map (fun (k, (n, t)) ->
      { text = Printf.sprintf "  %-12s %5d calls  %s" k n (ms t); strong = false }) (rows by) in
  let nest = List.map (fun (k, (n, t)) ->
      { text = Printf.sprintf "    %-22s %5d calls  %s" k n (ms t); strong = false }) (rows nested) in
  let slow = List.filteri (fun i _ -> i < 5)
      (List.sort (fun a b -> compare (dur b) (dur a)) mine) in
  [ head; { text = "Whom it talked to:"; strong = true } ] @ services
  @ (if nest = [] then [] else { text = "What they asked of others meanwhile:"; strong = true } :: nest)
  @ (if slow = [] then [] else { text = "The slowest calls:"; strong = true }
                               :: List.map (fun (c : Tracer.call) ->
                                   { text = Printf.sprintf "  %s  %s %s"
                                         (ms (dur c)) (Tracer.program r c.server) c.request;
                                     strong = false }) slow)

(* the recording stopped and kept: its summary *)
let finish pid =
  match Tracer.stop_and_save (file ()) with
  | r -> summary r pid
  | exception e -> [ { text = "the recording: " ^ Printexc.to_string e; strong = true } ]

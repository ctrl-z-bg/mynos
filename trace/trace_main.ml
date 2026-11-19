(* trace: the event recorder's command (doc/decisions/tracer.md).

     trace COMMAND...              run it (sh -c), record, print the calls
     trace -o FILE COMMAND...      and save the recording in FILE
     trace -s SECONDS [-o FILE]    record the whole system for a while
     trace show FILE               the events of a recording
     trace calls FILE              its calls, nested, with their durations
     trace json FILE OUT           for Perfetto (ui.perfetto.dev)

   A recording is kept in memory and written at the end, so that the
   recorder's own writes are not in it. Default file: /tmp/last.trace. *)

let usage () =
  prerr_string
    "usage: trace [-o FILE] COMMAND...   run a command and record it\n\
    \       trace -s SECONDS [-o FILE]   record the whole system\n\
    \       trace show FILE | calls FILE | json FILE OUT.json\n";
  exit 2

(* record: start, [at_start], then read the kernel's buffer often until
   [finished] *)
let record ~at_start finished =
  let buf = Buffer.create 65536 in
  (try Tracer.start () with Tracer.Busy ->
     prerr_endline "trace: another program is recording (one recording at a time)";
     exit 1);
  at_start ();
  let rec loop () =
    Buffer.add_string buf (Tracer.read ());
    if not (finished ()) then (Mynos.sleep 0.05; loop ()) in
  loop ();
  Tracer.stop ();
  Buffer.add_string buf (Tracer.read ());
  let i = Tracer.info () in
  Tracer.free ();
  (Buffer.contents buf, i)

let finish file (raw, info) ~show =
  (try Tracer.save file ~raw info
   with Sys_error e -> Printf.eprintf "trace: %s\n" e);
  let r = Tracer.of_raw ~raw info in
  if show then begin
    print_string "\n";
    Tracer.print_calls stdout r
  end;
  Printf.printf "recording: %s (%d events%s); trace show/calls/json %s\n%!"
    file (Array.length r.Tracer.events)
    (if r.dropped > 0 then Printf.sprintf ", %d lost" r.dropped else "") file

(* the command, under sh; a domain waits for it while this one records *)
let run file command =
  let cmd = String.concat " " command in
  let finished = Atomic.make false in
  let waiter = ref None in
  let result = record
      ~at_start:(fun () ->
          let pid = Mynos.spawn ~env:(Mynos.environment ()) "ocamlrun"
              [| "ocamlrun"; "/sh.byte"; "-c"; cmd |] in
          waiter := Some (Domain.spawn (fun () ->
              ignore (Mynos.wait pid);
              Atomic.set finished true)))
      (fun () -> Atomic.get finished) in
  Option.iter Domain.join !waiter;
  finish file result ~show:true

let system file seconds =
  let until = Mynos.uptime () +. seconds in
  finish file (record ~at_start:ignore (fun () -> Mynos.uptime () >= until)) ~show:false

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  match args with
  | [ "show"; f ] -> Tracer.print_events stdout (Tracer.load f)
  | [ "calls"; f ] -> Tracer.print_calls stdout (Tracer.load f)
  | [ "json"; f; out ] ->
    Out_channel.with_open_bin out (fun oc -> output_string oc (Tracer.to_json (Tracer.load f)));
    Printf.printf "%s: open it in ui.perfetto.dev\n" out
  | "-s" :: secs :: rest ->
    let file = (match rest with [ "-o"; f ] -> f | [] -> "/tmp/last.trace" | _ -> usage ()) in
    (match float_of_string_opt secs with
     | Some s when s > 0. -> system file s
     | _ -> usage ())
  | "-o" :: file :: (_ :: _ as command) -> run file command
  | (c :: _ as command) when c <> "-o" && c <> "-s" -> run "/tmp/last.trace" command
  | _ -> usage ()

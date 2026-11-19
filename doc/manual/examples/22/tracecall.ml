(* tracecall: read a file under the event recorder, then print the
   calls it made.  tracecall FILE *)

let () =
  if Array.length Sys.argv <> 2 then (prerr_endline "usage: tracecall FILE"; exit 2);
  let file = Sys.argv.(1) in
  (match Tracer.start () with
   | () -> ()
   | exception Tracer.Busy ->
     prerr_endline "tracecall: another program is recording"; exit 1);
  Tracer.mark ("open " ^ file);
  let text =
    try In_channel.with_open_bin file In_channel.input_all
    with Sys_error e -> Tracer.free (); prerr_endline e; exit 1 in
  Tracer.mark "read";
  let r = Tracer.stop_and_get () in
  Printf.printf "%s: %d bytes, %d events recorded\n"
    file (String.length text) (Array.length r.Tracer.events);
  Tracer.print_calls stdout r

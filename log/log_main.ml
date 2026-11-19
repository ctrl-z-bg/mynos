(* log: the kernel's log, its messages and the services' (Mynos.log)
   since boot: the last 64 KB of them, kept by the kernel.

     log          print it
     log -f       print it, then follow it (Ctrl-C ends) *)

let chunk = 16384

let () =
  let follow = match Sys.argv with
    | [| _ |] -> false
    | [| _; "-f" |] -> true
    | _ -> prerr_endline "usage: log [-f]"; exit 2 in
  (* the oldest position still kept: the kernel keeps 64 KB *)
  let pos = ref (max 0 (Mynos.log_position () - 65536)) in
  let rec drain () =
    let s = Mynos.log_read !pos chunk in
    if s <> "" then begin
      print_string s;
      flush stdout;
      pos := !pos + String.length s;
      drain ()
    end in
  drain ();
  if follow then
    while true do Mynos.sleep 0.3; drain () done

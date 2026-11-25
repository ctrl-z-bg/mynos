(* ticks: where the processor's time goes, process by process (the
   measurements of doc/decisions/ocaml-native.md).
     ticks save FILE   each live process's CPU ticks (10 ms), into FILE
     ticks diff FILE   the ticks each process took since FILE was saved,
                       most first, with its share of the time that passed *)

let snapshot () =
  List.filter_map (fun (p : Mynos.process) ->
      match Mynos.process_stats p.p_pid with
      | s -> Some (p.p_pid, p.name, p.bytecode, s.cpu_ticks)
      | exception Mynos.Error _ -> None)
    (Mynos.processes ())

let clock () = (Mynos.process_stats 0).clock_ticks
let idle () = (Mynos.process_stats 0).cpu_ticks

let save file =
  Out_channel.with_open_text file (fun oc ->
      Printf.fprintf oc "clock %d %d\n" (clock ()) (idle ());
      List.iter (fun (pid, name, _, t) -> Printf.fprintf oc "%d %s %d\n" pid name t)
        (snapshot ()))

let diff file =
  let before = Hashtbl.create 64 and c0 = ref 0 and i0 = ref 0 in
  In_channel.with_open_text file (fun ic ->
      try while true do
          match String.split_on_char ' ' (input_line ic) with
          | [ "clock"; c; i ] -> c0 := int_of_string c; i0 := int_of_string i
          | [ pid; _; t ] -> Hashtbl.replace before (int_of_string pid) (int_of_string t)
          | _ -> ()
        done with End_of_file -> ());
  let elapsed = clock () - !c0 and idle = idle () - !i0 in
  let rows = List.filter_map (fun (pid, name, byte, t) ->
      let d = t - Option.value (Hashtbl.find_opt before pid) ~default:0 in
      if d > 0 then Some (d, pid, name, byte) else None) (snapshot ()) in
  Printf.printf "ticks: %d elapsed, %d idle (%d%%)\n" elapsed idle
    (if elapsed > 0 then 100 * idle / elapsed else 0);
  List.iter (fun (d, pid, name, byte) ->
      Printf.printf "ticks: %6d %3d%%  %-14s pid %d%s\n" d
        (if elapsed > 0 then 100 * d / elapsed else 0) name pid
        (if byte then "  (bytecode)" else ""))
    (List.sort (fun (a, _, _, _) (b, _, _, _) -> compare b a) rows)

let () =
  match Sys.argv with
  | [| _; "save"; f |] -> save f
  | [| _; "diff"; f |] -> diff f
  | _ -> prerr_endline "usage: ticks save FILE | ticks diff FILE"; exit 2

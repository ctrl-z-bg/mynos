(* init: the first program of MyNOS, started by ocamlrun from the RAM disk
   (init.byte). It reads init.rc and starts what it lists:

     start PROGRAM ARGS...     start it and leave it running (services)
     respawn PROGRAM ARGS...   start it, and again whenever it ends (the
                               shell)

   A bytecode program (.byte) runs on ocamlrun. Then init waits for its
   children: it restarts the ones marked respawn, logs the others' end.
   Its messages go to the kernel log (Mynos.log). *)

type entry = { respawn : bool; argv : string list }

let log fmt = Printf.ksprintf (fun s -> Mynos.log ("init: " ^ s)) fmt

let parse_line line =
  let words =
    String.split_on_char ' ' (String.trim line)
    |> List.filter (fun w -> w <> "") in
  match words with
  | [] -> None
  | w :: _ when w.[0] = '#' -> None
  | "start" :: (_ :: _ as argv) -> Some { respawn = false; argv }
  | "respawn" :: (_ :: _ as argv) -> Some { respawn = true; argv }
  | _ -> log "init.rc: cannot read %S" line; None

let read_config file =
  match In_channel.with_open_text file In_channel.input_lines with
  | lines -> List.filter_map parse_line lines
  | exception Sys_error e -> log "%s" e; []

let describe e = String.concat " " e.argv

(* start an entry: its pid, or None *)
let start e =
  let argv =
    match e.argv with
    | prog :: _ when Filename.check_suffix prog ".byte" -> "ocamlrun" :: e.argv
    | argv -> argv in
  match Mynos.spawn (List.hd argv) (Array.of_list argv) with
  | pid -> log "started %s (pid %d)" (describe e) pid; Some pid
  | exception Mynos.Error (_, code) ->
    log "cannot start %s: %s" (describe e) (Mynos.error_name code); None

let status_text = function
  | Mynos.Exited n -> Printf.sprintf "exit code %d" n
  | Mynos.Signaled s -> Printf.sprintf "signal %d" s

let () =
  let running = Hashtbl.create 8 in            (* pid -> entry *)
  let launch e =
    match start e with
    | Some pid -> Hashtbl.replace running pid (e, Mynos.uptime ())
    | None -> () in
  List.iter launch (read_config "init.rc");
  while Hashtbl.length running > 0 do
    let pid, status = Mynos.wait_any () in
    match Hashtbl.find_opt running pid with
    | None -> ()
    | Some (e, started) ->
      Hashtbl.remove running pid;
      log "%s (pid %d) ended: %s" (describe e) pid (status_text status);
      if e.respawn then begin
        (* a program that keeps failing at once must not take the CPU *)
        if Mynos.uptime () -. started < 1.0 then Mynos.sleep 1.0;
        launch e
      end
  done;
  log "nothing left to run"

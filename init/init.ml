(* init: the first program of MyNOS, started by ocamlrun from the RAM disk
   (init.byte). It reads init.rc and starts what it lists:

     start PROGRAM ARGS...     start it and leave it running (services):
                               restarted if it crashes or is killed
     driver PROGRAM ARGS...    the same, with the io privilege (port I/O,
                               IRQs: doc/decisions/identity-and-permissions.md)
     respawn PROGRAM ARGS...   start it, and again whenever it ends (the
                               shell)

   A bytecode program (.byte) runs on ocamlrun. Then init waits for its
   children: it restarts the ones marked respawn whenever they end, and
   services that crash or are killed (not more than 5 times a minute).
   Its messages go to the kernel log (Mynos.log). *)

type entry = { respawn : bool; io : bool; argv : string list }

let log fmt = Printf.ksprintf (fun s -> Mynos.log ("init: " ^ s)) fmt

let parse_line line =
  let words =
    String.split_on_char ' ' (String.trim line)
    |> List.filter (fun w -> w <> "") in
  match words with
  | [] -> None
  | w :: _ when w.[0] = '#' -> None
  | "start" :: (_ :: _ as argv) -> Some { respawn = false; io = false; argv }
  | "driver" :: (_ :: _ as argv) -> Some { respawn = false; io = true; argv }
  | "respawn" :: (_ :: _ as argv) -> Some { respawn = true; io = false; argv }
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
  match Mynos.spawn ~io:e.io (List.hd argv) (Array.of_list argv) with
  | pid -> log "started %s (pid %d)" (describe e) pid; Some pid
  | exception Mynos.Error (_, code) ->
    log "cannot start %s: %s" (describe e) (Mynos.error_name code); None

let status_text = function
  | Mynos.Exited n -> Printf.sprintf "exit code %d" n
  | Mynos.Signaled s -> Printf.sprintf "signal %d" s

(* ---- the power (Power, "power/1"): any process may ask ---- *)

let power_off () =
  (* the graphical session first: the text console is back *)
  (match Mynos.lookup "display" with
   | _ -> (try Display.call (Display.connect ()) Display.Stop with _ -> ())
   | exception Mynos.Error _ -> ());
  Mynos.sleep 0.3

let shutdown () =
  log "shutting down";
  power_off ();
  print_endline "\nMyNOS: turning the machine off.";
  (* ACPI's PM1a control, sleep state 5: QEMU's PIIX4 (0x604), older QEMU
     and Bochs (0xB004), VirtualBox (0x4004) *)
  Mynos.outw 0x604 0x2000;
  Mynos.outw 0xB004 0x2000;
  Mynos.outw 0x4004 0x3400;
  Mynos.sleep 1.0;
  print_endline "MyNOS: the machine did not turn itself off; it can be turned off now.";
  while true do Mynos.sleep 3600. done

let reboot () =
  log "restarting";
  power_off ();
  print_endline "\nMyNOS: restarting.";
  (* the keyboard controller's reset line; else the reset control
     register (PCI's 0xCF9: a hard reset), which AArch64's kernel answers
     with PSCI's SYSTEM_RESET *)
  for _ = 1 to 100 do
    if Mynos.inb 0x64 land 2 = 0 then Mynos.outb 0x64 0xFE
  done;
  Mynos.outb 0xCF9 0x06;
  Mynos.sleep 1.0;
  log "the machine did not restart"

let power_service () =
  Power.serve { Power.handle = fun (type a) caller (r : a Power.request) : a ->
      (* the reply first: then act, from another domain *)
      let act = match r with Power.Shutdown -> shutdown | Power.Reboot -> reboot in
      log "%s asked by pid %d" (match r with Power.Shutdown -> "shutdown" | Power.Reboot -> "reboot")
        caller.Ipc.pid;
      ignore (Domain.spawn (fun () ->
          Mynos.sleep 0.2;
          (* the disk's cache, written before the power goes *)
          List.iter (fun service ->
              try Block.flush (Block.connect ~service ()) with _ -> ())
            [ "ata0"; "vblk0" ];
          act ()));
      match r with Power.Shutdown -> () | Power.Reboot -> () }

let () =
  ignore (Domain.spawn power_service);
  let running = Hashtbl.create 8 in            (* pid -> entry *)
  let restarts = Hashtbl.create 8 in           (* a service -> when it was restarted *)
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
      end else if status <> Mynos.Exited 0 then begin
        (* a service that crashed or was killed comes back (one that
           ended by itself, exit 0, decided to: httpd without a network),
           five times a minute at most; its clients find it again by name *)
        let now = Mynos.uptime () in
        let recent = List.filter (fun t -> now -. t < 60.)
            (Option.value (Hashtbl.find_opt restarts (describe e)) ~default:[]) in
        if List.length recent >= 5 then
          log "%s: not restarted, it ended 5 times in a minute" (describe e)
        else begin
          Hashtbl.replace restarts (describe e) (now :: recent);
          Mynos.sleep 0.3;
          log "restarting %s" (describe e);
          launch e
        end
      end
  done;
  log "nothing left to run"

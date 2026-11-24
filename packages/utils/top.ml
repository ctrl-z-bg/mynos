(* top [-b] [-n N] [-d SECS]: the processes, the busiest first, as they
   run: the share of the processor each one had in the last interval, its
   memory (its pages in memory), its threads, its page faults a second,
   and above them the processor's load and the memory in use. On the
   console it draws the table again every SECS seconds (1) until q; with
   -b, or when its output goes to a file, it prints N tables (1) one
   after the other.

   The numbers are the kernel's (system call 38, Mynos.process_stats),
   as sysmonitor's: a process's CPU is the clock's ticks that found it
   running, so a share over one second is good to a few per cent; its
   memory counts pages it shares (copy-on-write after a fork) as its own. *)

open Util

type row = { pid : int; pname : string; cpu : float; mem_kb : int;
             threads : int; faults : float }

(* one sample: the clock, the idle ticks, each process's ticks and faults *)
let sample () =
  let k = Mynos.process_stats 0 in
  let procs = List.filter_map (fun (p : Mynos.process) ->
      if p.p_pid = 0 then None
      else match Mynos.process_stats p.p_pid with
        | s -> Some (p, s)
        | exception Mynos.Error _ -> None) (Mynos.processes ()) in
  (k, procs)

(* the rows between two samples, the busiest first *)
let rows ((k0 : Mynos.process_stats), before) ((k1 : Mynos.process_stats), now) =
  let dt = max 1 (k1.clock_ticks - k0.clock_ticks) in
  let faults (s : Mynos.process_stats) = s.faults_alloc + s.faults_cow in
  let rs = List.map (fun ((p : Mynos.process), (s : Mynos.process_stats)) ->
      let c0, f0 = match List.find_opt (fun ((q : Mynos.process), _) -> q.p_pid = p.p_pid) before with
        | Some (_, (b : Mynos.process_stats)) -> (b.cpu_ticks, faults b)
        | None -> (s.cpu_ticks, faults s) in
      { pid = p.p_pid; pname = p.name;
        cpu = 100. *. float (s.cpu_ticks - c0) /. float dt;
        mem_kb = s.resident * 4; threads = s.s_threads;
        faults = float (faults s - f0) *. 100. /. float dt }) now in
  let busy = max 0. (100. -. 100. *. float (k1.cpu_ticks - k0.cpu_ticks) /. float dt) in
  (busy, List.sort (fun a b -> compare (b.cpu, b.mem_kb, a.pid) (a.cpu, a.mem_kb, b.pid)) rs)

let table ?(max_rows = max_int) (k : Mynos.process_stats) busy rs =
  let up = k.clock_ticks / 100 in
  let total = k.resident * 4 and free = (Mynos.stats ()).free_pages * 4 in
  let b = Buffer.create 4096 in
  Printf.bprintf b "up %d:%02d:%02d, %d processes, %d threads; CPU %.0f%% busy; memory %d of %d MB in use\n\n"
    (up / 3600) (up / 60 mod 60) (up mod 60) (List.length rs)
    (List.fold_left (fun n r -> n + r.threads) 0 rs) busy
    ((total - free) / 1024) (total / 1024);
  Printf.bprintf b "%5s %5s %9s %4s %7s  %s\n" "PID" "%CPU" "MEM KB" "THR" "FLT/s" "NAME";
  List.iteri (fun i r ->
      if i < max_rows then
        Printf.bprintf b "%5d %5.1f %9d %4d %7.0f  %s\n" r.pid r.cpu r.mem_kb r.threads r.faults r.pname) rs;
  Buffer.contents b

(* a key within [secs] seconds, on the console in raw mode: VTIME tenths *)
let key secs =
  let buf = Bytes.create 16 in
  let deadline = Mynos.uptime () +. secs in
  let rec go () =
    let left = deadline -. Mynos.uptime () in
    if left <= 0. then None
    else begin
      Mynos.console_mode ~canon:false ~echo:false ~vmin:0
        ~vtime:(max 1 (min 255 (int_of_float (left *. 10.)))) ();
      match input stdin buf 0 16 with
      | 0 -> go ()
      | n -> Some (Bytes.sub_string buf 0 n)
    end in
  go ()

let main () =
  let set, operands = parse ~flags:"b" ~valued:"nd" ~usage:"[-b] [-n N] [-d SECS]" "top" in
  if operands <> [] then usage "[-b] [-n N] [-d SECS]";
  let delay = match value set 'd' with
    | None -> 1.
    | Some v -> match float_of_string_opt v with
      | Some d when d >= 0.1 -> d
      | _ -> die "-d: seconds, at least 0.1: %s" v in
  let redirected = Sys.getenv_opt "MYNOS_STDOUT" <> None in
  if flag set 'b' || redirected then begin
    let rounds = int_value set 'n' 1 in
    let prev = ref (sample ()) in
    for i = 1 to rounds do
      Mynos.sleep delay;
      let now = sample () in
      let busy, rs = rows !prev now in
      if i > 1 then print_newline ();
      print_string (table (fst now) busy rs);
      flush stdout;
      prev := now
    done
  end else begin
    let rounds = int_value set 'n' max_int in
    let cols, lines = Console.size () in
    ignore cols;
    let restore () =
      (try Mynos.console_mode ~canon:true ~echo:true () with _ -> ());
      print_string "\027[?25h"; flush stdout in
    Fun.protect ~finally:restore (fun () ->
        print_string "\027[?25l"; flush stdout;
        let prev = ref (sample ()) in
        let rec loop i =
          if i <= rounds then
            match key delay with
            | Some k when String.contains k 'q' || String.contains k '\003' -> ()
            | _ ->
              let now = sample () in
              let busy, rs = rows !prev now in
              prev := now;
              print_string ("\027[H\027[2J" ^ table ~max_rows:(max 1 (lines - 4)) (fst now) busy rs
                            ^ "q quits");
              flush stdout;
              loop (i + 1) in
        loop 1);
    print_newline ()
  end

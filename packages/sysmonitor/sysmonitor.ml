(* sysmonitor: the system at work, in a window, once a second: the
   processor's load and the memory in use (with their last two minutes in
   graphs), the file systems' space, and a table of the processes: CPU,
   memory, threads, page faults a second, the services each one serves.
   A row clicked is selected; "End process" ends it (a second click
   confirms). The numbers are the kernel's (system call 38,
   Mynos.process_stats): CPU in ticks of 10 ms, memory in pages of 4 KB. *)

let history = 120                               (* samples kept: 2 minutes *)

(* the processors (x86-64 has several, mynos-btq.5): the kernel's idle
   time is theirs together, a process's CPU time can be more than one
   processor's. 1 where the kernel does not tell (sched_getaffinity). *)
let processors = max 1 (Domain.recommended_domain_count ())

type row = {
  pid : int;
  name : string;
  cpu : float;                                  (* % of one processor *)
  mem_kb : int;
  threads : int;
  faults : float;                               (* a second *)
  services : string;
}

type sort = By_cpu | By_mem | By_pid | By_name | By_faults

type state = {
  mutable prev : (int * (int * int)) list;      (* pid -> cpu ticks, faults *)
  mutable prev_idle : int;
  mutable prev_clock : int;
  mutable rows : row list;
  mutable busy : float;
  mutable cpu_hist : float array;               (* 0..100, oldest first *)
  mutable mem_hist : float array;
  mutable mem_used_kb : int;
  mutable mem_total_kb : int;
  mutable uptime : int;                         (* seconds *)
  mutable disks : (string * int * int) list;    (* where, size KB, free KB *)
  mutable disks_at : float;
  mutable sort : sort;
  mutable selected : int option;
  mutable confirm : int option;                 (* the pid a click will end *)
  mutable message : string;
  mutable next : float;
  mutable unsupported : bool;
}

let push a v = Array.append (Array.sub a 1 (Array.length a - 1)) [| v |]

let mounts = [ "memrofs", "/"; "tmpfs", "/tmp"; "fatfs", "/disk" ]

let sample st =
  let k = Mynos.process_stats 0 in
  let clock = k.Mynos.clock_ticks in
  let dt = max 1 (clock - st.prev_clock) in
  let first = st.prev_clock = 0 in
  let services = try Mynos.registered () with _ -> [] in
  let now = List.filter_map (fun p ->
      let pid = p.Mynos.p_pid in
      if pid = 0 then None
      else match Mynos.process_stats pid with
        | s -> Some (p, s)
        | exception Mynos.Error _ -> None) (Mynos.processes ()) in
  st.rows <- List.map (fun ((p : Mynos.process), (s : Mynos.process_stats)) ->
      let pid = p.p_pid in
      let faults = s.faults_alloc + s.faults_cow in
      let cpu0, faults0 = match List.assoc_opt pid st.prev with
        | Some x -> x | None -> (s.cpu_ticks, faults) in
      { pid; name = p.name;
        cpu = 100. *. float (s.cpu_ticks - cpu0) /. float dt;
        mem_kb = s.resident * 4; threads = s.s_threads;
        faults = float (faults - faults0) *. 100. /. float dt;
        services = String.concat " " (List.sort compare (List.filter_map
            (fun (n, _, o) -> if o = pid then Some n else None) services)) }) now;
  st.prev <- List.map (fun ((p : Mynos.process), (s : Mynos.process_stats)) ->
      (p.p_pid, (s.cpu_ticks, s.faults_alloc + s.faults_cow))) now;
  let idle = k.cpu_ticks in
  st.busy <- if first then 0. else
      min 100. (max 0. (100. -. 100. *. float (idle - st.prev_idle)
                                 /. float (dt * processors)));
  st.prev_idle <- idle;
  st.prev_clock <- clock;
  st.uptime <- clock / 100;
  st.mem_total_kb <- k.resident * 4;
  st.mem_used_kb <- st.mem_total_kb - (Mynos.stats ()).Mynos.free_pages * 4;
  if not first then begin
    st.cpu_hist <- push st.cpu_hist st.busy;
    st.mem_hist <- push st.mem_hist
        (100. *. float st.mem_used_kb /. float (max 1 st.mem_total_kb))
  end;
  if Unix.gettimeofday () >= st.disks_at then begin
    st.disks_at <- Unix.gettimeofday () +. 5.;
    st.disks <- List.filter_map (fun (service, at) ->
        match Fs.call (Fs.connect service) Fs.Space with
        | size, free -> Some (at, size, free)
        | exception _ -> None) mounts
  end

let mb kb = if kb >= 10240 then Printf.sprintf "%d MB" (kb / 1024)
  else Printf.sprintf "%.1f MB" (float kb /. 1024.)

let sorted st =
  let cmp = match st.sort with
    | By_cpu -> (fun a b -> compare (b.cpu, b.mem_kb) (a.cpu, a.mem_kb))
    | By_mem -> (fun a b -> compare b.mem_kb a.mem_kb)
    | By_pid -> (fun a b -> compare a.pid b.pid)
    | By_name -> (fun a b -> compare a.name b.name)
    | By_faults -> (fun a b -> compare b.faults a.faults) in
  List.stable_sort cmp st.rows

let graph ui x y w h title value colour hist =
  Gui.panel ui x y w h;
  Gui.label ~bold:true ui (x + 10) (y + 6) title;
  let v = Printf.sprintf "%.0f%%" value in
  Gui.label ~colour:colour ~bold:true ui (x + w - 10 - Gfx.cells v * Gfx.char_w) (y + 6) v;
  let gx = x + 10 and gy = y + 28 and gw = w - 20 and gh = h - 36 in
  Gfx.fill ui.Gui.g gx gy gw gh 0xF4F7FA;
  List.iter (fun f -> let ly = gy + gh - int_of_float (f *. float gh) in
              Gfx.fill ui.Gui.g gx ly gw 1 0xE1E7ED) [ 0.25; 0.5; 0.75 ];
  let n = Array.length hist in
  let px i = gx + i * (gw - 1) / (n - 1) and py v = gy + gh - 1 - int_of_float (v /. 100. *. float (gh - 1)) in
  Array.iteri (fun i v ->
      let bh = gy + gh - py v in
      if i > 0 then begin
        let x0 = px (i - 1) and x1 = px i in
        Gfx.fill ui.Gui.g x0 (py v) (max 1 (x1 - x0)) bh (Gfx.mix colour 0xFFFFFF 0.7);
        Gfx.line ui.Gui.g x0 (py hist.(i - 1)) x1 (py v) colour
      end) hist;
  Gfx.rect ui.Gui.g gx gy gw gh 0xC8D2DC

let columns = [ (* title, x offset, sort *)
  ("PID", 0, By_pid); ("Name", 56, By_name); ("CPU", 196, By_cpu);
  ("Memory", 256, By_mem); ("Thr", 344, By_cpu); ("Faults/s", 392, By_faults);
  ("Services", 480, By_name) ]

let frame ui st =
  let w = Gui.width ui and h = Gui.height ui in
  if not st.unsupported && Unix.gettimeofday () >= st.next then begin
    st.next <- Unix.gettimeofday () +. 1.;
    (try sample st
     with Mynos.Error _ ->
       st.unsupported <- true;
       st.message <- "This MyNOS does not give the processes' statistics \
                      (system call 38): a newer one is needed.")
  end;
  Gfx.fill ui.Gui.g 0 0 w h Gui.background;
  let up = Printf.sprintf "%d:%02d:%02d" (st.uptime / 3600) (st.uptime / 60 mod 60) (st.uptime mod 60) in
  let threads = List.fold_left (fun n r -> n + r.threads) 0 st.rows in
  Gui.label ~bold:true ui 12 10
    (Printf.sprintf "Up %s   %d processes, %d threads   CPU %.0f%%%s   Memory %s of %s"
       up (List.length st.rows) threads st.busy
       (if processors > 1 then Printf.sprintf " of %d processors" processors else "")
       (mb st.mem_used_kb) (mb st.mem_total_kb));
  let gw = (w - 36) / 2 in
  graph ui 12 34 gw 120
    (if processors > 1 then Printf.sprintf "Processors (%d)" processors else "Processor")
    st.busy 0x2D6CA2 st.cpu_hist;
  graph ui (24 + gw) 34 gw 120
    (Printf.sprintf "Memory, %s of %s" (mb st.mem_used_kb) (mb st.mem_total_kb))
    (100. *. float st.mem_used_kb /. float (max 1 st.mem_total_kb)) 0x3C9A5F st.mem_hist;
  (* the file systems *)
  let dy = 164 in
  ignore (List.fold_left (fun x (at, size, free) ->
      let used = max 0 (size - free) in
      let s = Printf.sprintf "%s  %s of %s" at (mb used) (mb size) in
      Gui.label ~colour:Gui.muted ui x dy s;
      let bx = x and by = dy + 20 and bw = 150 in
      Gfx.fill ui.Gui.g bx by bw 6 0xE1E7ED;
      if size > 0 then Gfx.fill ui.Gui.g bx by (bw * used / size) 6 0xD9822B;
      x + max 190 ((Gfx.cells s + 3) * Gfx.char_w)) 12 st.disks);
  (* the processes *)
  let ty = 198 in
  Gui.panel ui 12 ty (w - 24) (h - ty - 50);
  List.iter (fun (title, dx, sort) ->
      let x = 22 + dx in
      let tw = Gfx.cells title * Gfx.char_w in
      let over = Gui.hovered ui x (ty + 6) (tw + 8) 20 in
      Gui.label ~bold:true ~colour:(if sort = st.sort && title <> "Thr" && title <> "Services"
                                    then Gui.accent else Gui.foreground) ui x (ty + 8) title;
      if over && ui.Gui.clicked && title <> "Thr" && title <> "Services" then st.sort <- sort)
    columns;
  Gui.scroll ui 1 16 (ty + 30) (w - 32) (h - ty - 84) (fun top ->
      List.iteri (fun i r ->
          let y = top + i * 22 in
          let selected = st.selected = Some r.pid in
          let over = Gui.hovered ui 16 y (w - 48) 22 in
          if selected then Gfx.fill ui.Gui.g 16 y (w - 48) 22 Gui.accent
          else if over then Gfx.fill ui.Gui.g 16 y (w - 48) 22 0xDCE6EF;
          if over && ui.Gui.clicked then (st.selected <- Some r.pid; st.confirm <- None);
          let c = if selected then 0xFFFFFF else Gui.foreground in
          let cell dx s = ignore (Gfx.text ui.Gui.g (22 + dx) (y + 3) s c) in
          cell 0 (string_of_int r.pid);
          cell 56 r.name;
          cell 196 (Printf.sprintf "%5.1f" r.cpu);
          cell 256 (mb r.mem_kb);
          cell 344 (string_of_int r.threads);
          cell 392 (Printf.sprintf "%.0f" r.faults);
          ignore (Gfx.text ~max:(max 4 ((w - 520) / Gfx.char_w)) ui.Gui.g (22 + 480) (y + 3)
                    r.services (if selected then 0xFFFFFF else Gui.muted)))
        (sorted st);
      List.length st.rows * 22);
  (* the selected process *)
  let by = h - 40 in
  (match st.selected with
   | Some pid when List.exists (fun r -> r.pid = pid) st.rows ->
     let r = List.find (fun r -> r.pid = pid) st.rows in
     let label = if st.confirm = Some pid then "Really end it?" else "End process" in
     if Gui.button ui 12 by 150 label then begin
       if st.confirm = Some pid then begin
         (try Mynos.kill pid; st.message <- Printf.sprintf "%s (%d) ended." r.name pid
          with Mynos.Error (_, e) ->
            st.message <- Printf.sprintf "%s (%d): %s" r.name pid (Mynos.error_name e));
         st.confirm <- None; st.selected <- None
       end else begin
         st.confirm <- Some pid;
         st.message <- Printf.sprintf "%s (%d): a second click ends it%s." r.name pid
             (if r.services <> "" then ", and the services it serves" else "")
       end
     end
   | _ -> st.selected <- None);
  Gui.label ~colour:Gui.muted ui 176 (by + 5) st.message;
  st

let () =
  let st = { prev = []; prev_idle = 0; prev_clock = 0; rows = []; busy = 0.;
             cpu_hist = Array.make history 0.; mem_hist = Array.make history 0.;
             mem_used_kb = 0; mem_total_kb = 0; uptime = 0; disks = []; disks_at = 0.;
             sort = By_cpu; selected = None; confirm = None; message = "";
             next = 0.; unsupported = false } in
  Gui.run ~title:"System monitor" ~tick:1.0 ~resizable:(640, 440) 780 560 st frame

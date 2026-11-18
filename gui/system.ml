(* The System window (doc/decisions/gui.md): MyNOS's architecture as it
   is now, from the bottom: the hardware, the microkernel, the drivers
   (processes with the io privilege), the services (processes that
   registered a name, and the boot modules), the programs. The boxes are
   the live processes (Mynos.processes, Mynos.registered, every second):
   a new one appears outlined, one that ends fades away.

   A recording (doc/decisions/tracer.md) is replayed on it, step by step
   (Prev, Next, Play, Next mark): each call is an arrow from its client
   down into the kernel, through IPC, and up into its server, and its
   reply comes back; an interrupt is an arrow from a device to its driver;
   a mark is a phase a program labelled. Processes of the recording that
   have ended are drawn as ghosts. The step, or the box clicked, is
   explained at the bottom.

     system [FILE] *)

type layer = Programs | Services | Drivers

type node = {
  key : int;                  (* its box: the pid; a ghost's, -pid-1 *)
  pid : int;
  name : string;
  layer : layer;
  names : string list;        (* the names it registered *)
  threads : int;
  parent : int;
  alive : bool;
  born : float;               (* uptime when first seen (0: at the start) *)
  died : float;               (* uptime when it ended (infinity: alive) *)
  lang : string;              (* "OCaml" (bytecode, on ocamlrun), "C"; "": unknown *)
}

type step = Call of Tracer.call | Mark of Tracer.event | Irq of Tracer.event

type selection = Nothing | Box of int | Kernel | Device of int

type st = {
  mutable nodes : (int, node) Hashtbl.t;
  mutable last_poll : float;
  mutable registered : (string * int * int) list;
  mutable stats : Mynos.stats option;
  mutable r : Tracer.recording option;
  mutable file : string;
  mutable steps : step array;
  mutable step : int;               (* -1: before the first *)
  mutable playing : bool;
  mutable last_play : float;
  mutable sel : selection;
  mutable field : string;
  mutable message : string;
  mutable recording : bool;
}

let lock = Mutex.create ()
let finished : (string, string) result option ref = ref None

let width = 1000 and height = 700

(* ---- the hardware ---- *)

type device = { d_name : string; d_what : string; drivers : string list; irqs : int list }

let devices = [|
  { d_name = "CPU"; d_what = "i386: runs the kernel and every process, \
                              switching between their threads"; drivers = []; irqs = [] };
  { d_name = "Memory"; d_what = "RAM: the kernel gives pages to processes; \
                                 a window's pixels are pages shared with displayd";
    drivers = []; irqs = [] };
  { d_name = "Timer"; d_what = "the PIT, 100 times a second: the scheduler's \
                                clock (IRQ 0, the kernel's own)"; drivers = []; irqs = [ 0 ] };
  { d_name = "Keyboard"; d_what = "PS/2 keyboard: IRQ 1, read by consoled";
    drivers = [ "consoled"; "keyboardd" ]; irqs = [ 1 ] };
  { d_name = "Mouse"; d_what = "PS/2 mouse (and vmmouse): IRQ 12, read by displayd";
    drivers = [ "displayd" ]; irqs = [ 12 ] };
  { d_name = "Serial"; d_what = "COM1, the kernel's log; COM2, a terminal (IRQ 3, consoled)";
    drivers = [ "consoled"; "seriald" ]; irqs = [ 3; 4 ] };
  { d_name = "Disk"; d_what = "ATA disk: its blocks, read and written by ata (polled)";
    drivers = [ "ata" ]; irqs = [ 14; 15 ] };
  { d_name = "Network"; d_what = "NE2000 card: IRQ 9, netd (lwIP, TLS)";
    drivers = [ "netd" ]; irqs = [ 9 ] };
  { d_name = "Video"; d_what = "VGA text, and the Bochs graphics mode with its frame \
                               buffer, mapped by displayd"; drivers = [ "displayd" ]; irqs = [] };
|]

let device_of_irq irq driver =
  let found = ref (-1) in
  Array.iteri (fun i d ->
      if !found < 0 && List.mem irq d.irqs && (d.drivers = [] || List.mem driver d.drivers)
      then found := i) devices;
  if !found >= 0 then !found
  else begin
    Array.iteri (fun i d -> if !found < 0 && List.mem driver d.drivers then found := i) devices;
    !found
  end

(* ---- the live processes ---- *)

let display_name pid name = if pid = 1 then "init" else name

(* drivers: started with the io privilege (init's "driver"); services:
   they registered a name, or the kernel started them (boot modules), or
   init did (its "start"; sh, which init restarts, is a program) *)
let classify ~io ~parent ~names ~name =
  if io && parent > 1 then Drivers
  else if io && parent = 1 && name <> "sh" then Drivers
  else if names <> [] || parent = 0 || (parent = 1 && name <> "sh") then Services
  else Programs

let known_driver = [ "consoled"; "ata"; "netd"; "displayd"; "keyboardd"; "seriald" ]

let poll st =
  let now = Mynos.uptime () in
  let first = Hashtbl.length st.nodes = 0 in
  st.stats <- (try Some (Mynos.stats ()) with _ -> None);
  st.registered <- (try Mynos.registered () with _ -> st.registered);
  let live = try Mynos.processes () with _ -> [] in
  let seen = Hashtbl.create 32 in
  List.iter (fun (p : Mynos.process) ->
      if p.p_pid <> 0 then begin
        Hashtbl.replace seen p.p_pid ();
        let names = List.sort compare (List.filter_map (fun (n, _, o) ->
            if o = p.p_pid then Some n else None) st.registered) in
        let old = Hashtbl.find_opt st.nodes p.p_pid in
        Hashtbl.replace st.nodes p.p_pid
          { key = p.p_pid; pid = p.p_pid; name = display_name p.p_pid p.name;
            layer = classify ~io:p.p_io ~parent:p.parent ~names ~name:p.name; names;
            threads = p.threads; parent = p.parent; alive = true;
            born = (match old with Some o -> o.born | None -> if first then 0. else now);
            died = infinity; lang = if p.bytecode then "OCaml" else "C" }
      end) live;
  (* the ones that ended: fading, then gone *)
  Hashtbl.filter_map_inplace (fun pid n ->
      if Hashtbl.mem seen pid then Some n
      else if n.alive then Some { n with alive = false; died = now }
      else if now -. n.died > 3. then None
      else Some n) st.nodes;
  st.last_poll <- now

(* ---- a recording ---- *)

let is_gui r pid = Tracer.program r pid = "displayd"

let load st file =
  match Tracer.load file with
  | r ->
    let calls = List.filter (fun (c : Tracer.call) ->
        not (is_gui r c.client || is_gui r c.server)) (Tracer.calls r) in
    let others = List.filter_map (fun (e : Tracer.event) ->
        match e.kind with
        | Tracer.Mark -> Some (e.time, Mark e)
        | Tracer.Irq when e.arg <> 12 -> Some (e.time, Irq e)
        | _ -> None) (Array.to_list r.events) in
    let all = List.map (fun (c : Tracer.call) -> (c.start, Call c)) calls @ others in
    st.steps <- Array.of_list (List.map snd (List.stable_sort (fun (a, _) (b, _) ->
        compare a b) all));
    st.r <- Some r;
    st.file <- file;
    st.step <- -1;
    st.playing <- false;
    st.sel <- Nothing;
    st.message <- Printf.sprintf "%s: %d steps" (Filename.basename file) (Array.length st.steps)
  | exception (Sys_error e | Failure e) -> st.message <- e
  | exception e -> st.message <- Printexc.to_string e

let counter = ref 0
let record st command =
  incr counter;
  let file = Printf.sprintf "/tmp/sys-%d-%d.trc" (Mynos.getpid ()) !counter in
  let out = file ^ ".out" in
  st.recording <- true;
  st.message <- "recording: " ^ command;
  ignore (Domain.spawn (fun () ->
      let result =
        try
          Out_channel.with_open_bin out (fun _ -> ());
          let env = Array.append
              (Array.of_list (List.filter (fun kv ->
                   not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                          [ "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ]))
                   (Array.to_list (Mynos.environment ()))))
              [| "MYNOS_STDIN=" ^ out; "MYNOS_STDOUT=>>" ^ out; "MYNOS_STDERR=>>" ^ out |] in
          let pid = Mynos.spawn ~env "ocamlrun"
              [| "ocamlrun"; "/trace.byte"; "-o"; file; command |] in
          ignore (Mynos.wait pid);
          (try Sys.remove out with Sys_error _ -> ());
          Ok file
        with
        | Mynos.Error (f, code) -> Error (f ^ ": " ^ Mynos.error_name code)
        | Sys_error e -> Error e in
      Mutex.lock lock;
      finished := Some result;
      Mutex.unlock lock))

(* a process of the recording is a live one if it has the same pid and
   the same program (a recording of an earlier boot has the same pids for
   other processes): its box's key; otherwise a ghost's *)
let live_match st r pid =
  match Hashtbl.find_opt st.nodes pid with
  | Some n -> n.alive && n.name = display_name pid (Tracer.program r pid)
  | None -> false

let key_of st pid =
  match st.r with
  | Some r when pid > 0 && not (live_match st r pid) -> - pid - 1
  | _ -> pid

(* the processes of the recording that are not live: ghosts, in the layer
   the recording shows (a known driver; a service, if it served calls) *)
let ghosts st =
  match st.r with
  | None -> []
  | Some r ->
    let pids = Hashtbl.create 16 and served = Hashtbl.create 16 in
    Array.iter (function
        | Call c ->
          Hashtbl.replace pids c.client (); Hashtbl.replace pids c.server ();
          Hashtbl.replace served c.server ()
        | Mark e | Irq e -> Hashtbl.replace pids e.pid ()) st.steps;
    Hashtbl.fold (fun pid () acc ->
        if pid <= 0 || live_match st r pid then acc
        else
          let name = display_name pid (Tracer.program r pid) in
          let layer = if List.mem name known_driver then Drivers
            else if Hashtbl.mem served pid then Services else Programs in
          { key = - pid - 1; pid; name; layer; names = []; threads = 0; parent = -1;
            alive = false; born = 0.; died = neg_infinity; lang = "" } :: acc) pids []

(* ---- layout ---- *)

let left = 112 and right = width - 10
let box_h = 52

(* the rows, from the top: programs (two lines), services, drivers *)
let row_y = function Programs -> 76 | Services -> 206 | Drivers -> 268
let row_lines = function Programs -> 2 | _ -> 1
let row_name = function Programs -> "Programs" | Services -> "Services" | Drivers -> "Drivers"

let kernel_y = 348 and kernel_h = 100
let hw_y = 470 and hw_h = 44
let bar_y = 524
let detail_y = 540

(* each node's box: (x, y, w, h) *)
let layout nodes =
  let pos = Hashtbl.create 32 in
  List.iter (fun layer ->
      let ns = List.sort (fun a b -> compare a.pid b.pid)
          (List.filter (fun n -> n.layer = layer) nodes) in
      let n = List.length ns in
      if n > 0 then begin
        let lines = row_lines layer in
        let per_line = max 1 ((n + lines - 1) / lines) in
        let avail = right - left in
        let w = min 132 ((avail - 8 * (per_line - 1)) / per_line) in
        let h = box_h in
        List.iteri (fun i node ->
            let line = i / per_line and col = i mod per_line in
            Hashtbl.replace pos node.key
              (left + col * (w + 8), row_y layer + line * (h + 8), w, h)) ns
      end) [ Programs; Services; Drivers ];
  pos

let device_box i =
  let n = Array.length devices in
  let w = (right - left - 6 * (n - 1)) / n in
  (left + i * (w + 6), hw_y, w, hw_h)

(* the kernel's parts *)
let kernel_parts = [| "Processes"; "IPC: ports, channels"; "Memory";
                      "Timer, scheduler"; "Recorder" |]
let kernel_part i =
  let n = Array.length kernel_parts in
  let w = (right - left - 16 - 6 * (n - 1)) / n in
  (left + 8 + i * (w + 6), kernel_y + 48, w, 46)

(* ---- drawing ---- *)

let colours = function
  | Programs -> (0xE3F1E6, 0x3E8E5E)
  | Services -> (0xDCEAF7, 0x2D6CA2)
  | Drivers -> (0xFBE3D0, 0xB5651D)

let thick_line g x0 y0 x1 y1 c =
  Gfx.line g x0 y0 x1 y1 c;
  if x0 = x1 then Gfx.line g (x0 + 1) y0 (x1 + 1) y1 c
  else Gfx.line g x0 (y0 + 1) x1 (y1 + 1) c

(* an arrow along a path of points; its head at the end *)
let arrow g points c =
  let rec go = function
    | (x0, y0) :: ((x1, y1) :: _ as rest) -> thick_line g x0 y0 x1 y1 c; go rest
    | _ -> () in
  go points;
  match List.rev points with
  | (x1, y1) :: (x0, y0) :: _ ->
    let dx = compare x1 x0 and dy = compare y1 y0 in
    for k = 0 to 5 do
      if dy <> 0 then Gfx.fill g (x1 - k) (y1 - dy * (6 - k)) (2 * k + 1) 1 c
      else Gfx.fill g (x1 - dx * (6 - k)) (y1 - k) 1 (2 * k + 1) c
    done
  | _ -> ()

let ms t = if t >= 1. then Printf.sprintf "%.2f ms" t else Printf.sprintf "%.0f us" (t *. 1000.)

let () =
  let st = { nodes = Hashtbl.create 32; last_poll = -10.; registered = []; stats = None;
             r = None; file = ""; steps = [||]; step = -1; playing = false; last_play = 0.;
             sel = Nothing; field = ""; message = ""; recording = false } in
  if Array.length Sys.argv > 1 then (st.field <- Sys.argv.(1); load st Sys.argv.(1));
  Gui.run ~title:"System" ~tick:0.25 width height () (fun ui () ->
      let g = ui.Gui.g in
      let now = Mynos.uptime () in
      if now -. st.last_poll >= 1. then poll st;
      Mutex.lock lock;
      let done_ = !finished in
      finished := None;
      Mutex.unlock lock;
      (match done_ with
       | Some (Ok f) -> st.recording <- false; st.field <- f; load st f
       | Some (Error e) -> st.recording <- false; st.message <- e
       | None -> ());
      (* playing: a step every 0.6 s *)
      if st.playing && now -. st.last_play >= 0.6 then begin
        st.last_play <- now;
        if st.step + 1 < Array.length st.steps then st.step <- st.step + 1
        else st.playing <- false
      end;
      let live = Hashtbl.fold (fun _ n acc -> n :: acc) st.nodes [] in
      let nodes = live @ ghosts st in
      let pos = layout nodes in
      let node_of key = List.find_opt (fun n -> n.key = key) nodes in
      (* the header *)
      Gfx.fill g 0 0 width 34 0x1B3A57;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 12 9 "MyNOS, now";
      let info = match st.stats with
        | Some s -> Printf.sprintf "%d processes, %d threads, %d MB free, up %.0f s"
                      s.Mynos.processes s.threads (s.free_pages / 256) now
        | None -> "" in
      ignore (Gfx.text g (width - 12 - 8 * Gfx.cells info) 9 info 0xB8C7D3);
      (* the toolbar *)
      let ty = 42 in
      st.field <- Gui.text_field ui 3 8 (ty + 2) 300 st.field;
      if Gui.button ui 314 ty 60 "Open" && String.trim st.field <> "" then
        load st (String.trim st.field);
      if Gui.button ui 380 ty 76 (if st.recording then "..." else "Record")
      && not st.recording && String.trim st.field <> "" then record st (String.trim st.field);
      if st.r <> None then begin
        let n = Array.length st.steps in
        if Gui.button ui 470 ty 56 "Prev" && st.step >= 0 then st.step <- st.step - 1;
        if Gui.button ui 532 ty 56 "Next" && st.step + 1 < n then st.step <- st.step + 1;
        if Gui.button ui 594 ty 64 (if st.playing then "Pause" else "Play") then begin
          st.playing <- not st.playing; st.last_play <- 0.;
          if st.playing && st.step + 1 >= n then st.step <- -1
        end;
        if Gui.button ui 664 ty 96 "Next mark" then begin
          let k = ref (st.step + 1) in
          while !k < n && (match st.steps.(!k) with Mark _ -> false | _ -> true) do incr k done;
          if !k < n then st.step <- !k
        end;
        if Gui.button ui 766 ty 56 "Live" then begin
          st.r <- None; st.steps <- [||]; st.step <- -1; st.playing <- false; st.file <- "";
          st.message <- ""
        end;
        ignore (Gfx.text g 830 (ty + 5) (Printf.sprintf "step %d / %d" (st.step + 1) n) Gui.muted)
      end else
        ignore (Gfx.text ~max:62 g 470 (ty + 5)
                  (if st.message <> "" then st.message
                   else "Live. Open a recording, or Record a command, to replay it.") Gui.muted);
      (* a click on nothing: the step again *)
      (let _, py = ui.press in
       if ui.clicked && py >= 72 && py < bar_y - 4 then st.sel <- Nothing);
      (* the rows' names, and the kernel and the hardware *)
      List.iter (fun l ->
          Gui.label ~colour:Gui.muted ~bold:true ui 12 (row_y l + 18) (row_name l))
        [ Programs; Services; Drivers ];
      Gui.label ~colour:Gui.muted ~bold:true ui 12 (kernel_y + 38) "Kernel";
      Gui.label ~colour:Gui.muted ~bold:true ui 12 (hw_y + 14) "Hardware";
      let current = if st.step >= 0 && st.step < Array.length st.steps
        then Some st.steps.(st.step) else None in
      let ipc_on = match current with Some (Call _) -> true | _ -> false in
      (* each driver's wires to its devices, under the kernel: drivers
         reach the hardware themselves (the io privilege) *)
      let k = ref 0 in
      Array.iteri (fun i d ->
          let x, y, w, _ = device_box i in
          List.iter (fun n ->
              if n.layer = Drivers && List.mem n.name d.drivers && n.alive then
                match Hashtbl.find_opt pos n.key with
                | Some (bx, by, bw, bh) ->
                  incr k;
                  let x0 = bx + 14 + (!k mod 4) * 8 - (if bw < 40 then 10 else 0)
                  and x1 = x + w / 2 and yb = y - 6 - (!k mod 3) * 4 in
                  ignore bw;
                  Gfx.fill g x0 (by + bh) 2 (yb - by - bh) 0xD08A50;
                  Gfx.fill g (min x0 x1) yb (abs (x1 - x0) + 2) 2 0xD08A50;
                  Gfx.fill g x1 yb 2 (y - yb) 0xD08A50
                | None -> ()) nodes)
        devices;
      Gfx.fill g left kernel_y (right - left) kernel_h 0x24313C;
      ignore (Gfx.text ~bold:true g (left + 10) (kernel_y + 5)
                "MyNOS microkernel (C): every message between processes passes through it"
                0xFFFFFF);
      (* the messages' lane *)
      Gfx.fill g (left + 8) (kernel_y + 26) (right - left - 16) 16 0x2E3D49;
      Array.iteri (fun i part ->
          let x, y, w, h = kernel_part i in
          let on = (i = 1 && ipc_on) || (i = 4 && st.r <> None) in
          Gfx.fill g x y w h (if on then 0xF29B38 else 0x34434F);
          ignore (Gfx.text ~max:((w - 8) / 8) g (x + 6) (y + 6) part 0xFFFFFF);
          let value = match i, st.stats with
            | 0, Some s -> Printf.sprintf "%d, %d threads" s.Mynos.processes s.threads
            | 2, Some s -> Printf.sprintf "%d MB free" (s.Mynos.free_pages / 256)
            | 3, _ -> "100 Hz"
            | 4, _ -> if st.r <> None then "replaying" else "idle"
            | _ -> "" in
          ignore (Gfx.text ~max:((w - 8) / 8) g (x + 6) (y + 24) value 0xB8C7D3))
        kernel_parts;
      if ui.clicked && Gui.hovered ui left kernel_y (right - left) kernel_h then st.sel <- Kernel;
      (* the hardware, and each driver's line to its devices *)
      Array.iteri (fun i d ->
          let x, y, w, h = device_box i in
          Gfx.fill g x y w h 0xE9ECEF;
          Gfx.rect g x y w h 0x8A949C;
          ignore (Gfx.text ~bold:true ~max:((w - 8) / 8) g (x + 6) (y + 14) d.d_name 0x3A444C);
          if ui.clicked && Gui.hovered ui x y w h then st.sel <- Device i)
        devices;
      (* the boxes *)
      List.iter (fun n ->
          match Hashtbl.find_opt pos n.key with
          | None -> ()
          | Some (x, y, w, h) ->
            let fill, border = colours n.layer in
            let ghost = not n.alive && n.died = neg_infinity in
            let fading = not n.alive && not ghost in
            let fill = if ghost || fading then 0xF1F2F3 else fill in
            let border = if ghost || fading then 0xB0B6BB else border in
            Gfx.fill g x y w h fill;
            Gfx.rect g x y w h border;
            if n.alive && now -. n.born < 6. && n.born > 0. then begin
              Gfx.rect g (x - 2) (y - 2) (w + 4) (h + 4) 0xF29B38;
              Gfx.rect g (x - 3) (y - 3) (w + 6) (h + 6) 0xF29B38
            end;
            if st.sel = Box n.key then Gfx.rect g (x + 1) (y + 1) (w - 2) (h - 2) 0x1A2228;
            let text_c = if ghost || fading then Gui.muted else Gui.foreground in
            let cols = (w - 10) / 8 in
            ignore (Gfx.text ~bold:true ~max:cols g (x + 6) (y + 4) n.name text_c);
            ignore (Gfx.text ~max:cols g (x + 6) (y + 20)
                      (if ghost then Printf.sprintf "pid %d, ended" n.pid
                       else Printf.sprintf "pid %d \xc2\xb7 %d thr" n.pid n.threads) Gui.muted);
            (* the language: a tag at the bottom right *)
            let tag_w = if n.lang = "" then 0 else 8 * String.length n.lang + 6 in
            if n.lang <> "" && w > 70 then begin
              let tx = x + w - tag_w - 3 and ty = y + h - 18 in
              Gfx.fill g tx ty tag_w 15 (if n.lang = "OCaml" then 0xE8762C else 0x5A6670);
              ignore (Gfx.text g (tx + 3) (ty - 1) n.lang 0xFFFFFF)
            end;
            if n.names <> [] then
              ignore (Gfx.text ~max:((w - 12 - tag_w) / 8) g (x + 6) (y + 35)
                        (String.concat " " n.names) border);
            if ui.clicked && Gui.hovered ui x y w h then st.sel <- Box n.key)
        nodes;
      (* the step: its arrows *)
      let centre pid = match Hashtbl.find_opt pos (key_of st pid) with
        | Some (x, y, w, h) -> Some (x + w / 2, y + h)
        | None -> None in
      (match current with
       | Some (Call c) ->
         (match centre c.client, centre c.server with
          | Some (cx, cy), Some (sx, sy) ->
            let lane = kernel_y + 30 in
            arrow g [ (cx - 4, cy); (cx - 4, lane); (sx - 4, lane); (sx - 4, sy + 1) ] 0xD9534F;
            if c.reply <> "" then
              arrow g [ (sx + 4, sy); (sx + 4, lane + 6); (cx + 4, lane + 6); (cx + 4, cy + 1) ]
                0x3E8E5E;
            let label = c.request in
            let lx = min (right - 8 * min 50 (Gfx.cells label) - 8) (max left (min cx sx)) in
            Gfx.fill g lx (kernel_y - 24) (8 * min 50 (Gfx.cells label) + 8) 20 0xFFFFFF;
            ignore (Gfx.text ~max:50 g (lx + 4) (kernel_y - 22) label 0xD9534F)
          | _ -> ())
       | Some (Irq e) ->
         let d = device_of_irq e.arg (match st.r with Some r -> Tracer.program r e.pid | None -> "") in
         (match centre e.pid with
          | Some (bx, by) when d >= 0 ->
            let x, y, w, _ = device_box d in
            arrow g [ (x + w / 2, y); (x + w / 2, by + 20); (bx, by + 20); (bx, by + 1) ] 0x7B4FA0
          | _ -> ())
       | Some (Mark e) ->
         (match Hashtbl.find_opt pos (key_of st e.pid) with
          | Some (x, y, w, h) ->
            Gfx.rect g (x - 2) (y - 2) (w + 4) (h + 4) 0xF29B38;
            let label = "# " ^ e.data in
            let lx = min (right - 8 * min 60 (Gfx.cells label) - 8) x in
            Gfx.fill g lx (y + h + 4) (8 * min 60 (Gfx.cells label) + 8) 18 0xFFF4E0;
            ignore (Gfx.text ~max:60 g (lx + 4) (y + h + 5) label 0x8A4B08)
          | None -> ())
       | None -> ());
      (* the progress of the replay: click to go there *)
      if st.r <> None && Array.length st.steps > 0 then begin
        let n = Array.length st.steps in
        Gfx.fill g left bar_y (right - left) 8 0xE3E8EC;
        Array.iteri (fun i s -> match s with
            | Mark _ -> Gfx.fill g (left + i * (right - left) / n) (bar_y - 2) 2 12 0xF29B38
            | _ -> ()) st.steps;
        if st.step >= 0 then
          Gfx.fill g left bar_y ((st.step + 1) * (right - left) / n) 8 0x2D6CA2;
        let px, py = ui.press in
        if ui.clicked && py >= bar_y - 4 && py < bar_y + 12 && px >= left && px < right then
          st.step <- min (n - 1) ((px - left) * n / (right - left))
      end;
      (* the detail: the selection, or the step *)
      Gui.panel ui 8 detail_y (width - 16) (height - detail_y - 8);
      let line k ?(bold = false) ?(colour = Gui.foreground) s =
        ignore (Gfx.text ~bold ~max:120 g 18 (detail_y + 8 + k * 19) s colour) in
      let name_of pid = match node_of (key_of st pid) with
        | Some n -> Printf.sprintf "%s(%d)" n.name pid
        | None -> (match st.r with Some r -> Tracer.name r pid | None -> string_of_int pid) in
      (match st.sel, current with
       | Box key, _ ->
         (match node_of key with
          | Some n ->
            let pid = n.pid in
            line 0 ~bold:true (Printf.sprintf "%s, pid %d%s" n.name n.pid
                                 (if n.alive then "" else " (ended)"));
            line 1 (match n.layer with
                | Drivers -> "A driver: a process with the io privilege, which talks to the \
                              hardware itself (ports, interrupts)."
                | Services -> "A service: it serves requests from other processes over IPC \
                               (its names are in the registry)."
                | Programs -> "A program: it asks the services for what it needs.");
            if n.lang <> "" then
              line 6 ~colour:Gui.muted
                (if n.lang = "OCaml" then
                   "Written in OCaml: bytecode, run by ocamlrun (the OCaml 5.5 runtime, in C, \
                    with musl)."
                 else "Written in C: native i386 code, with musl and libmynos.");
            if n.parent >= 0 then
              line 2 ~colour:Gui.muted (Printf.sprintf "started by %s; %d threads"
                                          (if n.parent = 0 then "the kernel (a boot module)"
                                           else name_of n.parent) n.threads);
            let names = List.filter_map (fun (nm, port, o) ->
                if o = pid then Some (Printf.sprintf "%s (port %d)" nm port) else None)
                st.registered in
            if names <> [] then line 3 ~colour:Gui.muted ("registered: " ^ String.concat ", " names);
            let children = List.filter_map (fun c ->
                if c.parent = pid then Some (Printf.sprintf "%s(%d)" c.name c.pid) else None) nodes in
            if children <> [] then line 4 ~colour:Gui.muted ("started: " ^ String.concat ", " children);
            (match st.r with
             | Some _ ->
               let as_client = ref 0 and as_server = ref 0 in
               Array.iter (function
                   | Call c -> if c.client = pid then incr as_client;
                     if c.server = pid then incr as_server
                   | _ -> ()) st.steps;
               line 5 ~colour:Gui.muted (Printf.sprintf "in the recording: %d calls made, %d served"
                                           !as_client !as_server)
             | None -> ())
          | None -> st.sel <- Nothing)
       | Kernel, _ ->
         line 0 ~bold:true "The microkernel";
         line 1 "Processes and threads, their memory, the timer and the scheduler, and IPC: ports, \
                 and channels that carry messages.";
         line 2 ~colour:Gui.muted "Everything else runs as processes: files, the console, the \
                                   disk, the network, the display. A message from one to another";
         line 3 ~colour:Gui.muted "is copied (or its pages lent) by the kernel; the recorder sees \
                                   each one, which is how a recording is made."
       | Device i, _ ->
         let d = devices.(i) in
         line 0 ~bold:true d.d_name;
         line 1 d.d_what;
         if d.drivers <> [] then
           line 2 ~colour:Gui.muted ("drivers: " ^ String.concat ", " d.drivers)
       | Nothing, Some (Call c) ->
         line 0 ~bold:true (Printf.sprintf "%s \xe2\x86\x92 %s   %s" (name_of c.client)
                              (name_of c.server) c.request);
         line 1 ("reply: " ^ (if c.reply = "" then "(none in the recording)" else c.reply));
         let took = if Float.is_nan c.finish then "not finished" else ms (c.finish -. c.start) in
         line 2 ~colour:Gui.muted (Printf.sprintf "at %s, took %s%s" (ms c.start) took
                                     (if Float.is_nan c.server_start || Float.is_nan c.server_finish
                                      then ""
                                      else Printf.sprintf "; the server worked %s"
                                          (ms (c.server_finish -. c.server_start))));
         line 3 ~colour:Gui.muted
           "Red: the request, from the client into the kernel and up to the server; green: \
            the reply, back.";
         if c.depth > 0 then
           line 4 ~colour:Gui.muted (Printf.sprintf "%s made it while serving another call."
                                       (name_of c.client))
       | Nothing, Some (Mark e) ->
         line 0 ~bold:true (Printf.sprintf "%s: %s" (name_of e.pid) e.data);
         line 1 ~colour:Gui.muted (Printf.sprintf "at %s: a mark, a phase the program labelled. \
                                                  Next mark jumps to the next one." (ms e.time))
       | Nothing, Some (Irq e) ->
         let drv = match st.r with Some r -> Tracer.program r e.pid | None -> "" in
         let d = device_of_irq e.arg drv in
         line 0 ~bold:true (Printf.sprintf "IRQ %d \xe2\x86\x92 %s" e.arg (name_of e.pid));
         line 1 (Printf.sprintf "%s: an interrupt, which the kernel turns into a wake-up of \
                                 the driver's thread."
                   (if d >= 0 then devices.(d).d_name else "a device"));
         line 2 ~colour:Gui.muted (Printf.sprintf "at %s" (ms e.time))
       | Nothing, None ->
         line 0 ~bold:true "MyNOS as it is now: every box is a process, updated every second.";
         line 1 ~colour:Gui.muted "Drivers (orange) reach the hardware; services (blue) serve \
                                   requests; programs (green) ask. All talk through the kernel.";
         line 2 ~colour:Gui.muted "A new process appears outlined; one that ends fades away. \
                                   Click a box, the kernel or a device for what it is.";
         line 4 ~colour:Gui.muted "Each box says what it is written in: OCaml (bytecode, on \
                                   ocamlrun) or C (native).";
         line 3 ~colour:Gui.muted "A recording (the field: a file to Open, or a command to \
                                   Record) is replayed here step by step."))

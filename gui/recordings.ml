(* The recordings window (doc/decisions/gui.md, phase 4): a recording of
   the event recorder (doc/decisions/tracer.md), seen as

   - a timeline: a lane per process, each call a box on its client's lane
     (waiting) and on its server's (serving), the marks as lines across;
     the wheel zooms where the pointer is, a drag moves along;
   - the calls: the list of trace calls, nested, with the marks between;

   and, under either, the call selected: who, what, the reply, the times,
   the first bytes of both messages. The field opens a file, or records a
   command (trace -o, in a domain: the window keeps drawing).

     recordings [FILE]       (/tmp/agent.trc, or /tmp/last.trace) *)

type view = Timeline | Calls

type row = Mark_row of Tracer.event | Call_row of int

type st = {
  mutable file : string;
  mutable r : Tracer.recording option;
  mutable all : Tracer.call array;
  mutable shown : Tracer.call array;    (* without the display's, if hidden *)
  mutable rows : row array;             (* the calls view: calls and marks *)
  mutable marks : Tracer.event array;
  mutable lanes : int array;            (* pids, in order *)
  mutable total : float;                (* the recording's length, ms *)
  mutable t0 : float;                   (* the time span seen *)
  mutable t1 : float;
  mutable sel : int;                    (* in shown; -1: none *)
  mutable view : view;
  mutable field : string;
  mutable message : string;
  mutable hide_gui : bool;
  mutable drag : (float * float) option;
  mutable recording : bool;
}

let lock = Mutex.create ()
let finished : (string, string) result option ref = ref None   (* from the domain *)

let width = 940 and height = 640

(* ---- a recording ---- *)

let is_gui r pid = Tracer.program r pid = "displayd"

let select st =
  match st.r with
  | None -> ()
  | Some r ->
    st.shown <- Array.of_list (List.filter (fun (c : Tracer.call) ->
        not (st.hide_gui && (is_gui r c.client || is_gui r c.server)))
        (Array.to_list st.all));
    let pids = Hashtbl.create 16 in
    Array.iter (fun (c : Tracer.call) ->
        Hashtbl.replace pids c.client (); Hashtbl.replace pids c.server ()) st.shown;
    Array.iter (fun (e : Tracer.event) -> Hashtbl.replace pids e.pid ()) st.marks;
    st.lanes <- Array.of_list (List.sort compare (Hashtbl.fold (fun p () l -> p :: l) pids []));
    (* the calls view: marks before the calls they precede *)
    let rows = ref [] and ms = ref (Array.to_list st.marks) in
    Array.iteri (fun i (c : Tracer.call) ->
        let rec before () = match !ms with
          | m :: rest when m.Tracer.time <= c.start -> rows := Mark_row m :: !rows; ms := rest; before ()
          | _ -> () in
        before ();
        rows := Call_row i :: !rows) st.shown;
    List.iter (fun m -> rows := Mark_row m :: !rows) !ms;
    st.rows <- Array.of_list (List.rev !rows);
    st.sel <- -1

let load st file =
  match Tracer.load file with
  | r ->
    st.file <- file;
    st.r <- Some r;
    st.all <- Array.of_list (Tracer.calls r);
    st.marks <- Array.of_list (List.filter (fun (e : Tracer.event) -> e.kind = Tracer.Mark)
                                 (Array.to_list r.events));
    let n = Array.length r.events in
    st.total <- (if n = 0 then 1. else max 0.001 r.events.(n - 1).time);
    st.t0 <- 0.; st.t1 <- st.total;
    select st;
    st.message <- Printf.sprintf "%d calls, %d marks, %.1f ms%s" (Array.length st.all)
        (Array.length st.marks) st.total
        (if r.dropped > 0 then Printf.sprintf ", %d events lost" r.dropped else "")
  | exception (Sys_error e | Failure e) -> st.message <- e
  | exception e -> st.message <- Printexc.to_string e

(* a command, recorded by trace in a domain of its own *)
let counter = ref 0
let record st command =
  incr counter;
  let file = Printf.sprintf "/tmp/rec-%d-%d.trc" (Mynos.getpid ()) !counter in
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

(* ---- drawing ---- *)

let palette = [| 0x2D6CA2; 0x3E8E5E; 0xB5651D; 0x7B4FA0; 0xA23B5A; 0x2A8A8A; 0x8A7A2A; 0x5A6670 |]
let colour_of r pid =
  let n = Tracer.program r pid in
  palette.(Hashtbl.hash n mod Array.length palette)

let ms_text t =
  if t >= 100. then Printf.sprintf "%.0f ms" t
  else if t >= 1. then Printf.sprintf "%.2f ms" t
  else Printf.sprintf "%.0f us" (t *. 1000.)

(* a step of 1, 2 or 5 times a power of ten: about n ticks over the span *)
let tick_step span n =
  let raw = span /. float n in
  let p = 10. ** floor (log10 raw) in
  List.find (fun s -> s >= raw) [ p; 2. *. p; 5. *. p; 10. *. p ]

let hex s =
  let b = Buffer.create 100 in
  String.iteri (fun i c -> if i < 24 then Printf.bprintf b "%02x " (Char.code c)) s;
  Buffer.add_string b " ";
  String.iteri (fun i c -> if i < 24 then
                   Buffer.add_char b (if c >= ' ' && c < '\127' then c else '.')) s;
  Buffer.contents b

let main_y = 76 and main_h = 384
let detail_y = 468

let label_w = 160
let plot_x = 8 + label_w
let plot_w = width - 16 - label_w - 14
let lane_h = 24

let timeline ui st r =
  let g = ui.Gui.g in
  let span = st.t1 -. st.t0 in
  let t_of x = st.t0 +. float (x - plot_x) /. float plot_w *. span in
  let over_plot = ui.mx >= plot_x && ui.mx < plot_x + plot_w
                  && ui.my >= main_y && ui.my < main_y + main_h in
  (* the wheel: zoom where the pointer is *)
  if over_plot && ui.wheel <> 0 then begin
    let at = t_of ui.mx in
    let k = if ui.wheel < 0 then 0.8 ** float (- ui.wheel) else 1.25 ** float ui.wheel in
    let span' = Float.min st.total (Float.max 0.005 (span *. k)) in
    let t0 = at -. (at -. st.t0) *. span' /. span in
    let t0 = Float.max 0. (Float.min (st.total -. span') t0) in
    st.t0 <- t0; st.t1 <- t0 +. span';
    ui.wheel <- 0
  end;
  (* a drag: along the time *)
  let px, py = ui.press in
  (match st.drag with
   | None when ui.buttons land 1 <> 0 && px >= plot_x && px < plot_x + plot_w
               && py >= main_y + 40 && py < main_y + main_h ->
     st.drag <- Some (st.t0, st.t1)
   | Some (a, b) when ui.buttons land 1 <> 0 ->
     let dt = float (px - ui.mx) /. float plot_w *. (b -. a) in
     let dt = Float.max (-. a) (Float.min (st.total -. b) dt) in
     st.t0 <- a +. dt; st.t1 <- b +. dt
   | Some _ -> st.drag <- None
   | None -> ());
  let span = st.t1 -. st.t0 in
  let x_of t = plot_x + int_of_float ((t -. st.t0) /. span *. float plot_w) in
  (* the axis *)
  Gfx.fill g 8 main_y (width - 16) 20 0xE9EEF2;
  let step = tick_step span 8 in
  let t = ref (Float.of_int (int_of_float (st.t0 /. step)) *. step) in
  while !t <= st.t1 do
    if !t >= st.t0 then begin
      let x = x_of !t in
      Gfx.fill g x (main_y + 14) 1 6 0x9AA5AF;
      ignore (Gfx.text g (x + 3) (main_y + 2) (ms_text !t) Gui.muted)
    end;
    t := !t +. step
  done;
  (* the marks' band: their labels *)
  let marks_y = main_y + 20 in
  Gfx.fill g 8 marks_y (width - 16) 20 0xFFF4E0;
  ignore (Gfx.text g 12 (marks_y + 2) "marks" Gui.muted);
  (* the marks whose labels show: each from its line to the next label's *)
  let labelled x_of =
    let last_end = ref 0 and out = ref [] in
    Array.iteri (fun k (m : Tracer.event) ->
        if m.time >= st.t0 && m.time <= st.t1 then begin
          let x = x_of m.time in
          if x > !last_end then begin
            let n = min (Gfx.cells m.data) ((plot_x + plot_w - x - 6) / 8) in
            last_end := x + 6 + 8 * n;
            out := (k, x, !last_end) :: !out
          end
        end) st.marks;
    List.rev !out in
  (* a click on one: its step, to the next mark *)
  if ui.clicked && abs (px - ui.mx) < 4 && py >= marks_y && py < marks_y + 20 then
    (match List.find_opt (fun (_, x0, x1) -> px >= x0 - 3 && px < x1) (labelled x_of) with
     | Some (k, _, _) ->
       let a = st.marks.(k).time in
       let b = if k + 1 < Array.length st.marks then st.marks.(k + 1).time else st.total in
       let margin = (b -. a) *. 0.03 +. 0.01 in
       st.t0 <- Float.max 0. (a -. margin);
       st.t1 <- Float.min st.total (b +. margin)
     | None -> ());
  let span = st.t1 -. st.t0 in
  let x_of t = plot_x + int_of_float ((t -. st.t0) /. span *. float plot_w) in
  Array.iter (fun (m : Tracer.event) ->
      if m.time >= st.t0 && m.time <= st.t1 then
        Gfx.fill g (x_of m.time) marks_y 2 20 0xF29B38) st.marks;
  List.iter (fun (k, x, _) ->
      ignore (Gfx.text ~max:((plot_x + plot_w - x - 6) / 8) g (x + 5) (marks_y + 2)
                st.marks.(k).data 0x8A4B08))
    (labelled x_of);
  (* the lanes *)
  let lanes_y = marks_y + 20 in
  let lanes_h = main_y + main_h - lanes_y in
  let lane_of = Hashtbl.create 16 in
  Array.iteri (fun i p -> Hashtbl.replace lane_of p i) st.lanes;
  let clicked = ui.clicked && abs (px - ui.mx) < 4 && abs (py - ui.my) < 4 in
  Gui.scroll ui 1 8 lanes_y (width - 16) lanes_h (fun top ->
      Array.iteri (fun i pid ->
          let y = top + i * lane_h in
          Gfx.fill g 8 y (width - 30) lane_h (if i mod 2 = 0 then 0xFFFFFF else 0xF5F7F9);
          ignore (Gfx.text ~max:((label_w - 8) / 8) g 12 (y + 4) (Tracer.name r pid) Gui.foreground))
        st.lanes;
      (* the marks, across *)
      Array.iter (fun (m : Tracer.event) ->
          if m.time >= st.t0 && m.time <= st.t1 then
            Gfx.fill g (x_of m.time) top 1 (Array.length st.lanes * lane_h) 0xF7C98B) st.marks;
      let hit = ref (-1) in
      let box i lane a b colour inner =
        if b >= st.t0 && a <= st.t1 then begin
          let x0 = max plot_x (x_of a) and x1 = min (plot_x + plot_w) (x_of b) in
          let w = max 1 (x1 - x0) in
          let y = top + lane * lane_h + (if inner then 4 else 7) in
          let h = if inner then lane_h - 8 else lane_h - 14 in
          Gfx.fill g x0 y w h colour;
          if i = st.sel then Gfx.rect g (x0 - 1) (y - 1) (w + 2) (h + 2) 0xF29B38;
          if clicked && px >= x0 - 1 && px <= x0 + w && py >= y && py < y + h then hit := i
        end in
      Array.iteri (fun i (c : Tracer.call) ->
          let finish = if Float.is_nan c.finish then st.total else c.finish in
          (match Hashtbl.find_opt lane_of c.client with
           | Some l -> box i l c.start finish 0xC9D6E3 false
           | None -> ());
          if not (Float.is_nan c.server_start) then
            match Hashtbl.find_opt lane_of c.server with
            | Some l ->
              let sf = if Float.is_nan c.server_finish then finish else c.server_finish in
              box i l c.server_start sf (colour_of r c.server) true
            | None -> ())
        st.shown;
      (* the selected call: a line from its client to its server *)
      if st.sel >= 0 && st.sel < Array.length st.shown then begin
        let c = st.shown.(st.sel) in
        match Hashtbl.find_opt lane_of c.client, Hashtbl.find_opt lane_of c.server with
        | Some a, Some b when c.start >= st.t0 && c.start <= st.t1 ->
          let x = x_of c.start in
          let ya = top + a * lane_h + lane_h / 2 and yb = top + b * lane_h + lane_h / 2 in
          Gfx.fill g x (min ya yb) 2 (abs (yb - ya)) 0xF29B38
        | _ -> ()
      end;
      if !hit >= 0 then st.sel <- !hit;
      Array.length st.lanes * lane_h)

let calls_view ui st r =
  let g = ui.Gui.g in
  let row_h = 22 in
  Gui.scroll ui 2 8 main_y (width - 16) main_h (fun top ->
      let first = max 0 ((main_y - top) / row_h) in
      let last = min (Array.length st.rows - 1) ((main_y + main_h - top) / row_h) in
      for k = first to last do
        let y = top + k * row_h in
        match st.rows.(k) with
        | Mark_row m ->
          Gfx.fill g 8 y (width - 30) row_h 0xFFF4E0;
          ignore (Gfx.text ~max:110 g 12 (y + 3)
                    (Printf.sprintf "%9.3f            # %s: %s" m.time (Tracer.name r m.pid) m.data)
                    0x8A4B08)
        | Call_row i ->
          let c = st.shown.(i) in
          let took = if Float.is_nan c.finish then "?" else Printf.sprintf "%.3f" (c.finish -. c.start) in
          let label = Printf.sprintf "%9.3f %9s  %s%s -> %s  %s%s" c.start took
              (String.make (2 * c.depth) ' ') (Tracer.name r c.client) (Tracer.name r c.server)
              c.request (if c.reply = "" then "" else "  =>  " ^ c.reply) in
          if Gui.list_item ui 8 y (width - 30) ~selected:(i = st.sel) label then begin
            st.sel <- i;
            (* the timeline, around it *)
            let finish = if Float.is_nan c.finish then st.total else c.finish in
            let span = Float.max 0.5 ((finish -. c.start) *. 4.) in
            let t0 = Float.max 0. (c.start -. span /. 4.) in
            st.t0 <- t0; st.t1 <- Float.min st.total (t0 +. span)
          end
      done;
      Array.length st.rows * row_h)

let detail ui st r =
  let g = ui.Gui.g in
  Gui.panel ui 8 detail_y (width - 16) (height - detail_y - 8);
  let line k ?(bold = false) ?(colour = Gui.foreground) s =
    ignore (Gui.text ~bold ~max:112 ui 18 (detail_y + 8 + k * 19) s colour) in
  if st.sel >= 0 && st.sel < Array.length st.shown then begin
    let c = st.shown.(st.sel) in
    line 0 ~bold:true (Printf.sprintf "%s \xe2\x86\x92 %s   %s" (Tracer.name r c.client)
                         (Tracer.name r c.server) c.request);
    line 1 ("reply: " ^ (if c.reply = "" then "(none in the recording)" else c.reply));
    let took = if Float.is_nan c.finish then "not finished" else ms_text (c.finish -. c.start) in
    let served =
      if Float.is_nan c.server_start || Float.is_nan c.server_finish then ""
      else Printf.sprintf "; waited %s for the server, which worked %s (thread %d)"
          (ms_text (c.server_start -. c.start)) (ms_text (c.server_finish -. c.server_start))
          c.server_tid in
    line 2 ~colour:Gui.muted (Printf.sprintf "at %s, took %s%s" (ms_text c.start) took served);
    line 3 ~colour:Gui.muted (Printf.sprintf "request, %d bytes:  %s" c.request_size (hex c.request_bytes));
    if c.reply_size > 0 then
      line 4 ~colour:Gui.muted (Printf.sprintf "reply, %d bytes:    %s" c.reply_size (hex c.reply_bytes));
    if c.depth > 0 then line 5 ~colour:Gui.muted
        (Printf.sprintf "made while %s was serving a call (depth %d)" (Tracer.name r c.client) c.depth)
  end else begin
    line 0 ~bold:true "Click a call for its details.";
    line 1 ~colour:Gui.muted
      "Timeline: a lane per process; light boxes: a client waiting, dark ones: a server serving.";
    line 2 ~colour:Gui.muted
      "The wheel zooms where the pointer is; drag to move along; Whole shows it all.";
    line 3 ~colour:Gui.muted
      "Orange lines: marks, the phases a program labelled (the agent's steps): click one for its step.";
    line 4 ~colour:Gui.muted
      "The field opens a recording (Open), or runs a command and records it (Record)."
  end

let () =
  let st = { file = ""; r = None; all = [||]; shown = [||]; rows = [||]; marks = [||];
             lanes = [||]; total = 1.; t0 = 0.; t1 = 1.; sel = -1; view = Timeline;
             field = ""; message = ""; hide_gui = true; drag = None; recording = false } in
  let initial =
    if Array.length Sys.argv > 1 then Some Sys.argv.(1)
    else List.find_opt Sys.file_exists [ "/tmp/agent.trc"; "/tmp/last.trace" ] in
  (match initial with
   | Some f -> st.field <- f; load st f
   | None -> st.message <- "No recording yet: type a command and Record, or a file and Open.");
  Gui.run ~title:"Recordings" ~tick:0.5 width height () (fun ui () ->
      let g = ui.Gui.g in
      (* a recording made meanwhile *)
      Mutex.lock lock;
      let done_ = !finished in
      finished := None;
      Mutex.unlock lock;
      (match done_ with
       | Some (Ok f) -> st.recording <- false; st.field <- f; load st f
       | Some (Error e) -> st.recording <- false; st.message <- e
       | None -> ());
      (* the header *)
      Gfx.fill g 0 0 width 34 0x1B3A57;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 12 9
        (if st.file = "" then "Recordings" else Filename.basename st.file);
      let m = st.message in
      ignore (Gfx.text g (width - 12 - 8 * Gfx.cells m) 9 m 0xB8C7D3);
      (* the toolbar *)
      let ty = 42 in
      if Gui.button ui 8 ty 90 (if st.view = Timeline then "[Timeline]" else "Timeline") then
        st.view <- Timeline;
      if Gui.button ui 104 ty 70 (if st.view = Calls then "[Calls]" else "Calls") then
        st.view <- Calls;
      if Gui.button ui 180 ty 60 "Whole" then (st.t0 <- 0.; st.t1 <- st.total);
      if Gui.button ui 246 ty 140 (if st.hide_gui then "GUI: hidden" else "GUI: shown") then begin
        st.hide_gui <- not st.hide_gui; select st
      end;
      st.field <- Gui.text_field ui 3 392 (ty + 2) 314 st.field;
      if Gui.button ui 712 ty 60 "Files" then
        Gui.open_file_picker ~title:"Open a recording"
          ~dir:(if st.field <> "" && st.field.[0] = '/' then String.trim st.field else "/tmp")
          ~filter:(fun n -> Filename.check_suffix n ".trc" || Filename.check_suffix n ".trace") 9;
      if Gui.button ui 778 ty 66 "Open" && st.field <> "" then load st (String.trim st.field);
      if Gui.button ui 850 ty 82 (if st.recording then "..." else "Record")
      && not st.recording && String.trim st.field <> "" then record st (String.trim st.field);
      (match st.r with
       | None -> Gui.panel ui 8 main_y (width - 16) main_h
       | Some r ->
         (match st.view with
          | Timeline -> timeline ui st r
          | Calls -> calls_view ui st r);
         detail ui st r);
      if st.r = None then
        ignore (Gui.paragraph ui 24 (main_y + 16) (width - 48)
                  "No recording open. A recording is made by trace COMMAND (or by the agent, \
                   /tmp/agent.trc); here, type a command in the field and press Record, \
                   or a file's path and Open (Files: choose one).");
      (* the file picker, over the rest *)
      match Gui.file_picker ui 9 with
      | Some (Gui.Picked f) -> st.field <- f; load st f
      | Some Gui.Cancelled | None -> ())

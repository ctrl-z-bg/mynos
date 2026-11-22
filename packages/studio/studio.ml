(* MyNOS Studio (doc/decisions/studio.md): an editor that is a citizen of
   the system it programs.

     studio [FILE...]

   - files in tabs (module Textarea: OCaml coloured), Open, New, Save;
   - Build: the ocamlc inside MyNOS, its errors marked in the text and
     listed (Problems); Run: the program, its console in the Output pane;
   - Watch: run under the event recorder, then whom it talked to;
   - Service: a service of one's own from a template; Run as service,
     Restart; the Services window shows it;
   - completion from the running system: after "Sound." the requests the
     sound service describes;
   - the agent pane: MyNOS's agent given Studio's own service (ide/1,
     studio<pid>): its requests are the agent's tools; a change it
     proposes waits for Allow, shown as lines removed and added.

   Keys: Ctrl-S save, Ctrl-B build, Ctrl-R run, Ctrl-O open, Ctrl-F the
   find field; in the completion list Up, Down, Enter or Tab, Escape. *)

let width = 1000 and height = 690
let bar = 34 and tabs_h = 24 and status_h = 22

(* ---- the files: tabs, shared with the service's domain ---- *)

type tab = { path : string; area : Textarea.t; mutable errors : Build.error list }

let lock = Mutex.create ()
let tabs : tab list ref = ref []
let current = ref 0
let message = ref ""

let is_ocaml p = Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli"

(* Studio's files: in a folder of their own, unless a path says otherwise *)
let home = "/disk/studio"
let make_home () = try Sys.mkdir home 0o755 with Sys_error _ -> ()

let absolute p = if Filename.is_relative p then Filename.concat home p else p

let find_tab path = List.find_index (fun t -> t.path = path) !tabs

(* a file in a tab (read from the disk, or new): its index *)
let open_tab path =
  let path = absolute path in
  match find_tab path with
  | Some i -> current := i; i
  | None ->
    let s = try In_channel.with_open_bin path In_channel.input_all with Sys_error _ -> "" in
    let area = if is_ocaml path then Textarea.create ~tab:2 ~numbers:true ~highlight:Textarea.ocaml s
      else Textarea.create ~numbers:true s in
    tabs := !tabs @ [ { path; area; errors = [] } ];
    current := List.length !tabs - 1;
    !current

let tab_at i = List.nth_opt !tabs i
let shown () = tab_at !current

let save_tab t =
  match Out_channel.with_open_bin t.path (fun oc -> output_string oc (Textarea.text t.area)) with
  | () -> Textarea.set_modified t.area false; message := "saved " ^ t.path; Ok ()
  | exception Sys_error e -> message := e; Error e

let close_tab i =
  tabs := List.filteri (fun j _ -> j <> i) !tabs;
  current := max 0 (min !current (List.length !tabs - 1))

let set_errors t errors =
  t.errors <- errors;
  Textarea.set_marks t.area (Build.marks errors)

let error_lines t =
  String.concat "\n" (List.map (fun (e : Build.error) ->
      Printf.sprintf "%s:%d: %s" t.path e.line e.text) t.errors)

(* ---- the service: ide/1, studio<pid> ---- *)

let service_name () = Printf.sprintf "studio%d" (Mynos.getpid ())

let numbered t first last =
  let n = Textarea.lines t.area in
  let last = if last <= 0 then n else min n last in
  let b = Buffer.create 1024 in
  for l = max 1 first to last do
    Buffer.add_string b (Printf.sprintf "%d| %s\n" l (Textarea.line t.area l))
  done;
  Buffer.contents b

(* a file's build, from the service (it waits) or the window: the text
   saved first, so that the compiler sees what Studio shows *)
let build_and_mark path =
  Mutex.protect lock (fun () ->
      match find_tab path with
      | Some i -> (match tab_at i with Some t when Textarea.modified t.area -> ignore (save_tab t) | _ -> ())
      | None -> ());
  let messages, errors = Build.run path in
  Mutex.protect lock (fun () ->
      let t = List.nth !tabs (open_tab path) in
      set_errors t errors);
  messages

let handle : type a. a Ide_proto.request -> a = fun r ->
  let with_tab f path = Mutex.protect lock (fun () ->
      let i = open_tab path in f (List.nth !tabs i)) in
  match r with
  | Ide_proto.Files ->
    Mutex.protect lock (fun () ->
        let order = match shown () with
          | Some s -> s :: List.filter (fun t -> t != s) !tabs | None -> !tabs in
        String.concat "\n" (List.map (fun t ->
            t.path ^ (if Textarea.modified t.area then " *" else "")) order))
  | Ide_proto.Read (f, a, b) -> with_tab (fun t -> numbered t a b) f
  | Ide_proto.Replace (f, a, b, text) ->
    with_tab (fun t -> Textarea.replace_lines t.area a b text; Textarea.goto t.area (max 1 a) 1) f
  | Ide_proto.Open f -> with_tab (fun _ -> ()) f
  | Ide_proto.Save f ->
    with_tab (fun t -> match save_tab t with Ok () -> () | Error e -> failwith e) f
  | Ide_proto.Build f -> build_and_mark (absolute f)
  | Ide_proto.Errors f -> with_tab error_lines f
  | Ide_proto.Goto (f, l) -> with_tab (fun t -> Textarea.goto t.area l 1) f
  | Ide_proto.Find (f, text) ->
    with_tab (fun t ->
        let b = Buffer.create 256 in
        for l = 1 to Textarea.lines t.area do
          let s = Textarea.line t.area l in
          let k = String.length text in
          let rec has i = i + k <= String.length s && (String.sub s i k = text || has (i + 1)) in
          if k > 0 && has 0 then Buffer.add_string b (Printf.sprintf "%d| %s\n" l s)
        done;
        Buffer.contents b) f

let start_service () =
  ignore (Domain.spawn (fun () ->
      Ide_proto.I.serve (service_name ())
        { Ide_proto.I.handle = fun (type a) _ (r : a Ide_proto.request) : a -> handle r }))

(* ---- the agent pane ---- *)

type said = You of string | Agent_said of string | Did of string | Result of string * bool
          | Note of string

let conversation : said list ref = ref []         (* newest last *)
let agent : Agent.t option ref = ref None
let working = ref false
let asking : (string * Agent.answer option ref) option ref = ref None
let answered = Condition.create ()

(* a change the agent proposes to Studio's text: the lines it replaces and
   the lines it brings, for Allow or Deny *)
let preview action =
  let svc = service_name () ^ "_replace " in
  if not (String.starts_with ~prefix:svc action) then None
  else
    match Json.of_string (String.sub action (String.length svc) (String.length action - String.length svc)) with
    | j ->
      let f = Json.to_string_value (Json.member "file" j)
      and a = Json.to_int (Json.member "first" j) and b = Json.to_int (Json.member "last" j)
      and text = Json.to_string_value (Json.member "text" j) in
      let old = match find_tab (absolute f) with
        | Some i -> List.init (max 0 (b - a + 1)) (fun k -> Textarea.line (List.nth !tabs i).area (a + k))
        | None -> [] in
      Some (Printf.sprintf "%s, lines %d to %d" (Filename.basename f) a b,
            old, String.split_on_char '\n' text)
    | exception _ -> None

let confirm action =
  Mutex.protect lock (fun () ->
      let answer = ref None in
      asking := Some (action, answer);
      while !answer = None do Condition.wait answered lock done;
      asking := None;
      Option.get !answer)

let send task =
  let a = match !agent with
    | Some a -> Some a
    | None ->
      (match Agent.create ~services:[ service_name () ] () with
       | a -> agent := Some a; Some a
       | exception Failure m ->
         conversation := !conversation @ [ Note ("no agent: " ^ m) ]; None) in
  match a with
  | None -> ()
  | Some a ->
    let context = match shown () with
      | Some t ->
        let l, _ = Textarea.cursor t.area in
        Printf.sprintf "[In MyNOS Studio: the file shown is %s, the cursor on line %d. \
                        Read and change files with the %s tools (read, replace, build, \
                        errors); a replace shows in Studio and waits for the user.] "
          t.path l (service_name ())
      | None -> "[In MyNOS Studio, no file open.] " in
    conversation := !conversation @ [ You task ];
    working := true;
    let emit e = Mutex.protect lock (fun () ->
        conversation := !conversation @ [ (match e with
            | Agent.Task _ -> Note ""
            | Agent.Said s -> Agent_said s
            | Agent.Action s -> Did s
            | Agent.Result { text; error } ->
              Result ((if String.length text > 600 then String.sub text 0 600 ^ "..." else text), error)
            | Agent.Note s -> Note s) ]) in
    ignore (Domain.spawn (fun () ->
        (try ignore (Agent.run a ~emit ~confirm (context ^ task))
         with e -> emit (Agent.Note ("stopped: " ^ Printexc.to_string e)));
        Mutex.protect lock (fun () -> working := false)))

(* ---- jobs: a build, then maybe a run ---- *)

type after = Show | Run_it | Watch_it | Serve_it
type job = Building of int * string * string * after   (* the compiler, the file, its output *)

let job : job option ref = ref None
let watching : int option ref = ref None
let watch_lines : Watch.line list ref = ref []
let service_pid = ref 0

(* the agent's question was scrolled into view *)
let ask_shown = ref false

(* Complete.read_count when the completion list was made *)
let lists_read = ref 0

type pane = Output | Problems | Watched
let pane = ref Output

let alive pid = pid > 0 && (match Mynos.process_info pid with
    | Some i -> i.Mynos.alive | None -> false | exception Mynos.Error _ -> false)

let start_build after =
  match shown () with
  | None -> message := "no file"
  | Some t ->
    if Textarea.modified t.area then ignore (save_tab t);
    let out = Printf.sprintf "/tmp/studio-build-%d.txt" (Mynos.getpid ()) in
    (match Build.spawn t.path out with
     | pid -> job := Some (Building (pid, t.path, out, after)); message := "building " ^ t.path
     | exception Mynos.Error _ -> message := "cannot start ocamlc")

let poll_job () =
  match !job with
  | Some (Building (pid, path, out, after)) when not (alive pid) ->
    job := None;
    let messages = try In_channel.with_open_bin out In_channel.input_all with Sys_error _ -> "" in
    let errors = Build.parse path messages in
    (match find_tab path with Some i -> set_errors (List.nth !tabs i) errors | None -> ());
    let failed = List.exists (fun (e : Build.error) -> e.is_error) errors
                 || (errors = [] && String.trim messages <> "" && not (Sys.file_exists (Build.target path))) in
    if failed then begin
      message := Printf.sprintf "%s: %d problem%s" (Filename.basename path) (List.length errors)
          (if List.length errors = 1 then "" else "s");
      pane := Problems
    end else begin
      message := "built " ^ Build.target path
                 ^ (if errors <> [] then Printf.sprintf " (%d warnings)" (List.length errors) else "");
      let target = Build.target path in
      match after with
      | Show -> if errors <> [] then pane := Problems
      | Run_it -> ignore (Runner.run target); pane := Output
      | Watch_it ->
        (match Watch.start () with
         | Ok () -> watching := Some (Runner.run target); pane := Output;
           message := "running under the recorder: it ends, or Stop"
         | Error m -> message := m)
      | Serve_it ->
        if alive !service_pid then (try Mynos.kill !service_pid with Mynos.Error _ -> ());
        service_pid := Runner.run target; pane := Output;
        message := "running as a service: the Services window shows it"
    end
  | _ -> ()

let poll_watch () =
  match !watching with
  | Some pid when not (alive pid) ->
    watching := None;
    watch_lines := Watch.finish pid;
    pane := Watched;
    message := "recorded: Watch shows whom it talked to"
  | _ -> ()

(* ---- the window ---- *)

type ui_state = {
  mutable find : string;
  mutable typed : string;             (* the agent's field *)
  mutable line : string;              (* the Output pane's input *)
  mutable naming : (bool * string) option;   (* New (false) or New service (true): a name *)
  mutable popup : (string * Complete.answer * int) option;
}

let wrap per s =
  List.concat_map (fun para ->
      let rec go acc s =
        if String.length s <= per then List.rev (s :: acc)
        else
          let cut = match String.rindex_from_opt s per ' ' with Some i when i > 0 -> i | _ -> per in
          go (String.sub s 0 cut :: acc)
            (String.trim (String.sub s cut (String.length s - cut))) in
      go [] para) (String.split_on_char '\n' s)

let draw_popup ui (word, answer, sel) =
  let g = ui.Gui.g in
  let cx, cy = match shown () with Some t -> Textarea.cursor_xy t.area | None -> (0, 0) in
  let x = min cx (Gui.width ui - 470) and y = cy + Gfx.char_h + 2 in
  match answer with
  | Complete.Not_running service ->
    let m = Printf.sprintf "%s: not running (no service %s now)" word service in
    Gfx.fill g x y (Gfx.char_w * String.length m + 16) 24 0xFFF4E0;
    Gfx.rect g x y (Gfx.char_w * String.length m + 16) 24 0xE0B070;
    ignore (Gfx.text g (x + 8) (y + 4) m 0x8A5A00)
  | Complete.Reading m ->
    let m = Printf.sprintf "%s: reading its interface..." m in
    Gfx.fill g x y (Gfx.char_w * String.length m + 16) 24 0xFFFFFF;
    Gfx.rect g x y (Gfx.char_w * String.length m + 16) 24 Gui.accent;
    ignore (Gfx.text g (x + 8) (y + 4) m Gui.muted)
  | Complete.Items (source, all) ->
    (* eight at a time, the selected one among them *)
    let top = max 0 (sel - 7) in
    let items = List.filteri (fun i _ -> i >= top && i < top + 8) all in
    let w = 520 and h = 24 + 20 * List.length items + 54 in
    let x = max 0 (min x (Gui.width ui - w - 6)) in
    Gfx.fill g (x + 4) (y + 4) w h 0x8090A0;
    Gfx.fill g x y w h 0xFFFFFF;
    Gfx.rect g x y w h Gui.accent;
    let more = if List.length all > 8 then Printf.sprintf "  %d/%d" (sel + 1) (List.length all) else "" in
    ignore (Gfx.text ~max:((w - 16) / Gfx.char_w) g (x + 8) (y + 4) ("from " ^ source ^ more) Gui.muted);
    List.iteri (fun i (it : Complete.item) ->
        let ry = y + 24 + i * 20 in
        if top + i = sel then Gfx.fill g (x + 1) ry (w - 2) 20 0xDCE6EF;
        (* a service's requests in green, the interface's values in blue *)
        ignore (Gfx.text ~bold:true g (x + 8) (ry + 2) it.constructor
                  (if it.request then 0x2E7D32 else 0x1F5F99));
        ignore (Gfx.text ~max:((w - 30) / Gfx.char_w - String.length it.constructor - 2) g
                  (x + 16 + Gfx.char_w * String.length it.constructor) (ry + 2)
                  (": " ^ it.signature) Gui.foreground)) items;
    (match List.nth_opt all sel with
     | Some it ->
       let dy = y + 24 + 20 * List.length items + 4 in
       List.iteri (fun i l -> if i < 2 then ignore (Gfx.text g (x + 8) (dy + i * 18) l Gui.muted))
         (wrap ((w - 16) / Gfx.char_w)
            ((if it.request then "request" ^ (if it.safe then " (safe): " else ": ") else "") ^ it.doc))
     | None -> ())
  | Complete.Nothing -> ()

let () =
  start_service ();
  Runner.start_service ();
  make_home ();
  List.iter (fun f -> ignore (open_tab f)) (List.tl (Array.to_list Sys.argv));
  if !tabs = [] then begin
    (* a first program, to build and run at once *)
    let hello = Filename.concat home "hello.ml" in
    if not (Sys.file_exists hello) then
      (try Out_channel.with_open_bin hello (fun oc ->
           output_string oc "(* Build, then Run: its output comes below. *)\n\n\
                             let () =\n  print_endline \"Hello from MyNOS Studio!\"\n")
       with Sys_error _ -> ());
    ignore (open_tab hello)
  end;
  current := 0;
  let us = { find = ""; typed = ""; line = ""; naming = None; popup = None } in
  let first = ref true in
  Gui.run ~title:"MyNOS Studio" ~tick:0.2 ~resizable:(720, 460)
    ~unsaved:(fun () -> List.exists (fun t -> Textarea.modified t.area) !tabs)
    width height () (fun ui () ->
      Mutex.protect lock @@ fun () ->
      let width = Gui.width ui and height = Gui.height ui in
      let g = ui.Gui.g in
      if !first then begin first := false; ui.Gui.field <- 1 end;
      poll_job (); poll_watch ();
      let agent_w = if width >= 860 then 300 else 0 in
      let pane_h = max 120 (height / 4) in
      let ed_x = 0 and ed_y = bar + tabs_h in
      let ed_w = width - agent_w and ed_h = height - ed_y - pane_h - status_h in
      (* the keys of Studio, before the text's *)
      List.iter (function
          | "\019" -> (match shown () with Some t -> ignore (save_tab t) | None -> ())
          | "\002" -> start_build Show
          | "\018" -> start_build Run_it
          | "\015" -> Gui.open_file_picker ~title:"A file" ~dir:home 1
          | "\006" -> ui.Gui.field <- 5
          | _ -> ()) ui.Gui.keys;
      (* the completion list takes its keys first *)
      (match us.popup with
       | Some (word, (Complete.Items (_, items) as ans), sel) when ui.Gui.field = 1 ->
         let n = List.length items in
         let accept = ref None and close = ref false and sel = ref sel in
         ui.Gui.keys <- List.filter (fun k ->
             match k with
             | "\027[A" -> sel := max 0 (!sel - 1); false
             | "\027[B" -> sel := min (n - 1) (!sel + 1); false
             | "\r" | "\n" | "\t" -> accept := List.nth_opt items !sel; false
             | "\027" -> close := true; false
             | _ -> true) ui.Gui.keys;
         (match !accept, shown () with
          | Some it, Some t ->
            let typed = match String.rindex_opt word '.' with
              | Some i -> String.length word - i - 1 | None -> 0 in
            let c = it.Complete.constructor in
            if typed <= String.length c then
              Textarea.insert t.area (String.sub c typed (String.length c - typed));
            us.popup <- None
          | _ -> if !close then us.popup <- None else us.popup <- Some (word, ans, !sel))
       | Some _ when List.mem "\027" ui.Gui.keys -> us.popup <- None
       | _ -> ());
      (* the bar *)
      Gfx.fill g 0 0 width bar 0x1B3A57;
      let bx = ref 6 in
      let button label w = let x = !bx in bx := !bx + w + 4; Gui.button ui x 4 w label in
      if button "Open" 52 then Gui.open_file_picker ~title:"A file" ~dir:home 1;
      if button "New" 44 then begin us.naming <- Some (false, Filename.concat home "new.ml"); ui.Gui.field <- 4 end;
      if button "Save" 50 then (match shown () with Some t -> ignore (save_tab t) | None -> ());
      if button "Build" 56 then start_build Show;
      if button "Run" 44 then start_build Run_it;
      if button "Watch" 56 then start_build Watch_it;
      if button "Stop" 48 then begin
        Runner.stop ();
        (match !watching with
         | Some pid -> watching := None; watch_lines := Watch.finish pid; pane := Watched;
           message := "stopped and recorded: Watch shows whom it talked to"
         | None -> message := "stopped")
      end;
      bx := !bx + 8;
      if button "New service" 104 then begin us.naming <- Some (true, "myservice"); ui.Gui.field <- 4 end;
      if button (if alive !service_pid then "Restart" else "Run as service") 124 then start_build Serve_it;
      if button "Services" 76 then Gui.spawn "/services.byte";
      (* the tabs *)
      Gfx.fill g 0 bar width tabs_h 0xDDE3E9;
      let tx = ref 4 in
      List.iteri (fun i t ->
          let label = Filename.basename t.path ^ (if Textarea.modified t.area then " *" else "") in
          let w = Gfx.char_w * String.length label + 30 in
          if !tx + w < ed_w then begin
            let sel = i = !current in
            Gfx.fill g !tx (bar + 2) w (tabs_h - 2) (if sel then 0xFFFFFF else 0xC9D2DB);
            ignore (Gfx.text ~bold:sel g (!tx + 8) (bar + 5) label Gui.foreground);
            if Gui.hovered ui !tx bar (w - 18) tabs_h && ui.Gui.clicked then begin
              current := i; us.popup <- None; ui.Gui.field <- 1 end;
            ignore (Gfx.text g (!tx + w - 16) (bar + 5) "x" Gui.muted);
            if Gui.hovered ui (!tx + w - 18) bar 18 tabs_h && ui.Gui.clicked then close_tab i;
            tx := !tx + w + 3
          end) !tabs;
      (* the find field, at the tabs' right *)
      let enter id = ui.Gui.field = id && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      let fx = ed_w - 210 in
      let go = enter 5 in
      us.find <- Gui.text_field ui 5 fx (bar + 1) 150 us.find;
      if (Gui.button ~h:22 ui (fx + 154) (bar + 1) 50 "Find" || go) && us.find <> "" then
        (match shown () with
         | Some t -> if not (Textarea.find t.area us.find) then message := "not found: " ^ us.find
         | None -> ());
      (* the text *)
      (match shown () with
       | Some t ->
         (* again when an interface has been read since the list was made
            (it said "reading") *)
         let read_now = Atomic.get Complete.read_count in
         let reading = us.popup <> None && read_now <> !lists_read in
         let typed_now = ui.Gui.field = 1 && (ui.Gui.keys <> [] || reading) in
         if typed_now then lists_read := read_now;
         Textarea.frame ui 1 t.area ed_x ed_y ed_w ed_h;
         if typed_now then begin
           let w = Textarea.word_before_cursor t.area in
           us.popup <- (if String.contains w '.' then
                          match Complete.for_word ~dir:(Filename.dirname t.path) w with
                          | Complete.Nothing -> None
                          | Complete.Items (_, []) -> None
                          | a -> Some (w, a, 0)
                        else None)
         end
       | None ->
         Gfx.fill g ed_x ed_y ed_w ed_h 0xFFFFFF;
         ignore (Gui.paragraph ~colour:Gui.muted ui 20 (ed_y + 20) (ed_w - 40)
                   "No file open: Open one, or New service."));
      (* the panes: Output, Problems, Watch *)
      let py = ed_y + ed_h in
      Gfx.fill g 0 py ed_w pane_h Gui.panel_colour;
      let pb label p x =
        let sel = !pane = p in
        if Gui.button ~h:22 ui x (py + 3) 90 ((if sel then "> " else "") ^ label) then pane := p in
      pb "Output" Output 6; pb "Problems" Problems 100; pb "Watch" Watched 194;
      let state =
        if alive !Runner.child then (if !watching <> None then "running, recorded" else "running")
        else "" in
      ignore (Gfx.text g 296 (py + 6) state Gui.accent);
      let ch = Gfx.char_h + 2 in
      let box_y = py + 28 and box_h = pane_h - 30 in
      (match !pane with
       | Output ->
         let lines = String.split_on_char '\n' (Runner.text ()) in
         let rows = max 1 ((box_h - 28) / ch) in
         let n = List.length lines in
         let shown_lines = List.filteri (fun i _ -> i >= n - rows) lines in
         Gfx.fill g 6 box_y (ed_w - 12) (box_h - 26) 0x10151C;
         List.iteri (fun i l ->
             ignore (Gfx.text ~max:((ed_w - 24) / Gfx.char_w) g 10 (box_y + 2 + i * ch) l 0xD8DEE4))
           shown_lines;
         let go = enter 3 in
         us.line <- Gui.text_field ui 3 6 (box_y + box_h - 24) (ed_w - 80) us.line;
         if (Gui.button ~h:22 ui (ed_w - 70) (box_y + box_h - 24) 64 "Send" || go) then begin
           Runner.type_line us.line; us.line <- "" end
       | Problems ->
         (match shown () with
          | Some t when t.errors <> [] ->
            Gui.scroll ui 7 6 box_y (ed_w - 12) box_h (fun top ->
                List.iteri (fun i (e : Build.error) ->
                    let label = Printf.sprintf "line %d: %s" e.line e.text in
                    if Gui.list_item ui 8 (top + i * 22) (ed_w - 30) ~selected:false label then begin
                      Textarea.goto t.area e.line (e.first + 1); ui.Gui.field <- 1 end) t.errors;
                22 * List.length t.errors)
          | _ -> ignore (Gfx.text g 10 box_y "No problems: Build to compile the file." Gui.muted))
       | Watched ->
         if !watch_lines = [] then
           ignore (Gfx.text g 10 box_y "Watch runs the program under the event recorder: \
                                         when it ends, whom it talked to." Gui.muted)
         else begin
           Gui.scroll ui 8 6 box_y (ed_w - 140) box_h (fun top ->
               List.iteri (fun i (l : Watch.line) ->
                   ignore (Gfx.text ~bold:l.strong g 10 (top + 2 + i * ch) l.text Gui.foreground))
                 !watch_lines;
               4 + ch * List.length !watch_lines);
           if Gui.button ~h:22 ui (ed_w - 128) box_y 122 "Recordings" then
             Gui.spawn ~args:[ Watch.file () ] "/recordings.byte"
         end);
      (* the agent pane *)
      if agent_w > 0 then begin
        let ax = width - agent_w in
        Gfx.fill g ax bar agent_w (height - bar - status_h) 0xF7F9FB;
        Gfx.fill g ax bar 1 (height - bar - status_h) 0xC9D2DB;
        Gui.label ~bold:true ui (ax + 10) (bar + 4) "Agent";
        Gui.label ~colour:Gui.muted ui (ax + 64) (bar + 4)
          (if !working then "working..." else "on " ^ service_name ());
        let per = (agent_w - 30) / Gfx.char_w in
        let conv_h = height - bar - status_h - 110 in
        Gui.scroll ~colour:0xFFFFFF ui 9 (ax + 6) (bar + 26) (agent_w - 12) conv_h (fun top ->
            let y = ref (top + 4) in
            let put colour bold s =
              List.iter (fun l ->
                  ignore (Gfx.text ~bold g (ax + 12) !y l colour); y := !y + 18) (wrap per s) in
            List.iter (function
                | You s -> put Gui.accent true s; y := !y + 4
                | Agent_said s -> put Gui.foreground false s; y := !y + 4
                | Did s -> put 0x1F5F99 false ("> " ^ s)
                | Result (s, err) -> put (if err then 0xC62828 else Gui.muted) false s; y := !y + 4
                | Note s -> if s <> "" then put Gui.muted false s) !conversation;
            (* a change waiting for Allow: the lines it removes, and adds *)
            (match !asking with
             | Some (action, _) ->
               (match preview action with
                | Some (what, old, nw) ->
                  put Gui.foreground true ("Change " ^ what ^ "?");
                  List.iter (fun l -> put 0xC62828 false ("- " ^ l)) old;
                  List.iter (fun l -> put 0x2E7D32 false ("+ " ^ l)) nw
                | None -> put Gui.foreground true ("Allow: " ^ action ^ "?"))
             | None -> ());
            !y - top + 8);
        if !working && !asking = None then Gui.scroll_to_end ui 9;
        (* a question: shown once at the end (the change it proposes) *)
        (match !asking with
         | Some _ when not !ask_shown -> Gui.scroll_to_end ui 9; ask_shown := true
         | None -> ask_shown := false
         | Some _ -> ());
        let fy = bar + 26 + conv_h + 8 in
        (match !asking with
         | Some (_, answer) ->
           let reply a = answer := Some a; Condition.broadcast answered in
           if Gui.button ui (ax + 8) fy 80 "Allow" then reply Agent.Yes;
           if Gui.button ui (ax + 94) fy 70 "Deny" then reply Agent.No;
           if Gui.button ui (ax + 170) fy 90 "Allow all" then reply Agent.All
         | None ->
           let go = enter 2 in
           us.typed <- Gui.text_field ui 2 (ax + 8) fy (agent_w - 16) us.typed;
           if (Gui.button ui (ax + agent_w - 88) (fy + 28) 80 "Ask" || go)
              && us.typed <> "" && not !working then begin
             (* the agent's work runs in a domain of its own, which takes the
                lock to report and to ask *)
             let task = us.typed in
             us.typed <- "";
             send task
           end)
      end;
      (* the status line *)
      let sy = height - status_h in
      Gfx.fill g 0 sy width status_h 0x1B3A57;
      (match shown () with
       | Some t ->
         let l, c = Textarea.cursor t.area in
         let where = Printf.sprintf "%s  line %d, column %d" t.path l c in
         ignore (Gfx.text g 8 (sy + 3) where 0xE8EEF2);
         let m = match Textarea.mark_at_cursor t.area with Some m -> m.Textarea.message | None -> !message in
         ignore (Gfx.text ~max:((width - 32 - Gfx.char_w * String.length where) / Gfx.char_w) g
                   (24 + Gfx.char_w * String.length where) (sy + 3) m 0xF2B866)
       | None -> ignore (Gfx.text g 8 (sy + 3) !message 0xE8EEF2));
      (* New / New service: a name *)
      (match us.naming with
       | Some (service, name) ->
         let px = width / 2 - 240 in
         Gui.panel ui px 80 480 112;
         Gui.label ~bold:true ui (px + 14) 90
           (if service then "A new service: its name (small letters)" else "A new file: its path");
         let name = Gui.text_field ui 4 (px + 14) 116 452 name in
         let ok = Gui.button ui (px + 300) 152 80 "Create" || enter 4 in
         if ok && name <> "" then begin
           us.naming <- None; ui.Gui.field <- 1;
           if not service then ignore (open_tab name)
           else begin
             make_home ();
             let path = Printf.sprintf "%s/%s.ml" home name in
             if not (Sys.file_exists path) then
               Out_channel.with_open_bin path (fun oc -> output_string oc (Template.service name));
             ignore (open_tab path);
             message := "a service: Run as service starts it"
           end
         end else if Gui.button ui (px + 386) 152 80 "Cancel" then begin
           us.naming <- None; ui.Gui.field <- 1 end
         else us.naming <- Some (service, name)
       | None -> ());
      (* the completion list, over everything *)
      (match us.popup with Some p when ui.Gui.field = 1 -> draw_popup ui p | _ -> ());
      (match Gui.file_picker ui 1 with
       | Some (Gui.Picked p) -> ignore (open_tab p); ui.Gui.field <- 1
       | Some Gui.Cancelled | None -> ());
      ())

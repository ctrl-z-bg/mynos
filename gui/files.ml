(* Files: a file manager (doc/decisions/gui.md). On the left, the places
   (/, /tmp, /disk) and which service serves the one shown: a file in
   MyNOS is what a process gives over IPC. In the middle, the entries;
   a click chooses, a second click (or Open, or Enter) opens: a directory
   is entered, a program (.byte) started, a recording (.trc) shown in
   Recordings, a text or an image (.pgm) viewed here. New folder, rename,
   delete (asked first), copy or cut then paste (between services, a copy
   then a removal, as sh's mv does). / is the RAM disk: read-only.

     files [DIR] *)

type mode =
  | Browse
  | Naming of [ `Folder | `Rename of string ] * string   (* the name typed *)
  | Deleting of string
  | Viewing of string * [ `Text of string list | `Image of Gfx.mask | `Binary ]

type st = {
  mutable dir : string;
  mutable listing : Gui.entry list;
  mutable chosen : string option;
  mutable mode : mode;
  mutable clip : (string * bool) option;      (* a path, and whether it is cut *)
  mutable message : string;
  mutable services : (string * int * int) list;
  mutable procs : Mynos.process list;
  mutable last_poll : float;
}

let width = 860 and height = 560
let side_w = 176
let list_x = side_w + 8 and list_y = 76
let list_w = width - side_w - 16 and list_h = 380

let refresh st = st.listing <- Gui.entries st.dir
let go st dir = st.dir <- dir; st.chosen <- None; st.mode <- Browse; refresh st

(* ---- what serves a place ---- *)

let places = [ "/", "memrofs"; "/tmp", "tmpfs"; "/disk", "fatfs" ]

let place_of dir =
  List.fold_left (fun acc (p, s) ->
      if p <> "/" && (dir = p || String.starts_with ~prefix:(p ^ "/") dir) then (p, s) else acc)
    ("/", "memrofs") places

let served st dir =
  let place, service = place_of dir in
  let who name = match List.find_opt (fun (n, _, _) -> n = name) st.services with
    | Some (_, _, pid) ->
      (match List.find_opt (fun p -> p.Mynos.p_pid = pid) st.procs with
       | Some p -> Printf.sprintf "%s (pid %d, %s)" name pid (if p.bytecode then "OCaml" else "C")
       | None -> Printf.sprintf "%s (pid %d)" name pid)
    | None -> name ^ " (not running)" in
  match place with
  | "/tmp" -> "/tmp: in memory, lost at shutdown. Served by " ^ who service ^ "."
  | "/disk" -> "/disk: the FAT disk, kept across boots. Served by " ^ who service
               ^ "; its blocks come from " ^ who "ata0" ^ "."
  | _ -> "/: the RAM disk, read-only, loaded at boot. Served by " ^ who service ^ "."

(* ---- opening ---- *)

let has ext n = Filename.check_suffix (String.lowercase_ascii n) ext

let printable s =
  String.for_all (fun c -> c >= ' ' || c = '\n' || c = '\t' || c = '\r' || Char.code c >= 128) s

let view st path =
  let name = Filename.basename path in
  if has ".pgm" name then
    match Gfx.load_mask path with
    | m -> st.mode <- Viewing (path, `Image m)
    | exception _ -> st.message <- name ^ ": not a PGM image"
  else
    match In_channel.with_open_bin path (fun ic ->
        really_input_string ic (min 65536 (Int64.to_int (In_channel.length ic)))) with
    | s when printable s ->
      st.mode <- Viewing (path, `Text (String.split_on_char '\n' s))
    | _ -> st.mode <- Viewing (path, `Binary)
    | exception Sys_error e -> st.message <- e

let open_entry st (e : Gui.entry) =
  let path = Gui.join st.dir e.name in
  if e.is_dir then go st path
  else if has ".byte" e.name then begin
    Gui.spawn path;
    st.message <- "started " ^ path
  end else if has ".trc" e.name || has ".trace" e.name then begin
    Gui.spawn ~args:[ path ] "/recordings.byte";
    st.message <- "opened in Recordings: " ^ path
  end else view st path

(* ---- changing things ---- *)

let attempt st f = try f () with
  | Sys_error e -> st.message <- e
  | Failure e -> st.message <- e

let copy_file src dst =
  let data = In_channel.with_open_bin src In_channel.input_all in
  Out_channel.with_open_bin dst (fun oc -> output_string oc data)

let paste st =
  match st.clip with
  | None -> st.message <- "nothing to paste: Copy or Cut a file first"
  | Some (src, cut) ->
    let dst = Gui.join st.dir (Filename.basename src) in
    if src = dst then st.message <- "it is already here"
    else attempt st (fun () ->
        if Sys.is_directory src then failwith "folders are not copied (yet)";
        if cut then begin
          (try Sys.rename src dst
           with Sys_error _ -> copy_file src dst; Sys.remove src);   (* another service *)
          st.clip <- None;
          st.message <- "moved to " ^ dst
        end else begin
          copy_file src dst;
          st.message <- "copied to " ^ dst
        end;
        refresh st;
        st.chosen <- Some (Filename.basename dst))

(* ---- the window ---- *)

let () =
  let start = if Array.length Sys.argv > 1 then Sys.argv.(1) else "/" in
  let st = { dir = "/"; listing = []; chosen = None; mode = Browse; clip = None;
             message = ""; services = []; procs = []; last_poll = -10. } in
  go st (if (try Sys.is_directory start with Sys_error _ -> false) then start else "/");
  Gui.run ~title:"Files" ~tick:1.0 ~resizable:(640, 400) width height () (fun ui () ->
      (* resizable: the size as it is now *)
      let width = Gui.width ui and height = Gui.height ui in
      let list_w = width - side_w - 16 and list_h = height - 180 in
      let g = ui.Gui.g in
      let now = Mynos.uptime () in
      if now -. st.last_poll > 2. then begin
        st.services <- (try Mynos.registered () with _ -> st.services);
        st.procs <- (try Mynos.processes () with _ -> st.procs);
        st.last_poll <- now
      end;
      (* the header *)
      Gfx.fill g 0 0 width 34 0x1B3A57;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 12 9 "Files";
      ignore (Gfx.text ~max:90 g 70 9 st.dir 0xB8C7D3);
      (* the places, and what serves the one shown *)
      Gui.panel ui 8 40 (side_w - 8) (height - 48);
      Gui.label ~colour:Gui.muted ~bold:true ui 18 48 "Places";
      let here, _ = place_of st.dir in
      List.iteri (fun i (p, _) ->
          let label = match p with "/" -> "/  RAM disk" | "/tmp" -> "/tmp  memory"
                                 | _ -> "/disk  FAT disk" in
          if Gui.list_item ui 10 (70 + i * 24) (side_w - 12) ~selected:(p = here) label then
            go st p) places;
      ignore (Gui.paragraph ~colour:Gui.muted ui 18 160 (side_w - 28) (served st st.dir));
      (match st.clip with
       | Some (p, cut) ->
         ignore (Gfx.text g 18 (height - 64) (if cut then "Cut:" else "Copied:") Gui.muted);
         ignore (Gfx.text ~max:19 g 18 (height - 46) (Filename.basename p) Gui.foreground)
       | None -> ());
      (* the toolbar *)
      let ty = 42 in
      let chosen_entry () = match st.chosen with
        | Some n -> List.find_opt (fun (e : Gui.entry) -> e.name = n) st.listing
        | None -> None in
      let b x w label = Gui.button ui x ty w label in
      let x0 = list_x in
      if b x0 48 "Up" then go st (Gui.parent st.dir);
      if b (x0 + 54) 64 "Open" then
        (match chosen_entry () with Some e -> open_entry st e | None -> ());
      if b (x0 + 124) 104 "New folder" then st.mode <- Naming (`Folder, "");
      if b (x0 + 234) 72 "Rename" then
        (match st.chosen with Some n -> st.mode <- Naming (`Rename n, n) | None -> ());
      if b (x0 + 312) 72 "Delete" then
        (match st.chosen with Some n -> st.mode <- Deleting n | None -> ());
      if b (x0 + 390) 56 "Copy" then
        (match st.chosen with
         | Some n -> st.clip <- Some (Gui.join st.dir n, false); st.message <- "copied: " ^ n
         | None -> ());
      if b (x0 + 452) 48 "Cut" then
        (match st.chosen with
         | Some n -> st.clip <- Some (Gui.join st.dir n, true); st.message <- "cut: " ^ n
         | None -> ());
      if b (x0 + 506) 64 "Paste" then paste st;
      if b (x0 + 576) 76 "Refresh" then refresh st;
      (* the entries, or what is viewed *)
      (match st.mode with
       | Viewing (path, what) ->
         if Gui.button ui (list_x + list_w - 80) (list_y + 2) 72 "Back" then st.mode <- Browse
         else begin
           ignore (Gfx.text ~bold:true ~max:70 g (list_x + 4) (list_y + 6) path Gui.foreground);
           Gui.scroll ui 2 list_x (list_y + 32) list_w (list_h - 32) (fun top ->
               match what with
               | `Text lines ->
                 List.iteri (fun i l ->
                     ignore (Gfx.text ~max:((list_w - 30) / 8) g (list_x + 8) (top + 4 + i * 18)
                               (String.map (fun c -> if c = '\t' || c = '\r' then ' ' else c) l)
                               Gui.foreground)) lines;
                 18 * List.length lines + 8
               | `Image m ->
                 Gfx.draw_mask g (list_x + 8) (top + 8) m 0x1A2228;
                 m.Gfx.mask_height + 16
               | `Binary ->
                 ignore (Gfx.text g (list_x + 8) (top + 6)
                           "Not text: a program, or data. A .byte is started by Open." Gui.muted);
                 30)
         end
       | _ ->
         Gui.scroll ui 1 list_x list_y list_w list_h (fun top ->
             List.iteri (fun i (e : Gui.entry) ->
                 let y = top + i * 22 in
                 let selected = st.chosen = Some e.name in
                 if Gui.list_item ui (list_x + 1) y (list_w - 14) ~selected
                     (if e.is_dir then e.name ^ "/" else e.name) then begin
                   if selected then open_entry st e else st.chosen <- Some e.name
                 end;
                 let kind =
                   if e.is_dir then "folder"
                   else if has ".byte" e.name then "program"
                   else if has ".trc" e.name || has ".trace" e.name then "recording"
                   else if has ".pgm" e.name then "image"
                   else Gui.size_text e.size in
                 let c = if selected then 0xFFFFFF else Gui.muted in
                 ignore (Gfx.text g (list_x + list_w - 30 - 8 * String.length kind) (y + 3) kind c);
                 if not e.is_dir && kind <> Gui.size_text e.size then
                   ignore (Gfx.text g (list_x + list_w - 150) (y + 3) (Gui.size_text e.size) c))
               st.listing;
             if st.listing = [] then
               ignore (Gfx.text g (list_x + 8) (top + 4) "(empty)" Gui.muted);
             22 * List.length st.listing + 4));
      (* the bottom: a question, or the state *)
      let by = list_y + list_h + 10 in
      Gui.panel ui list_x by list_w (height - by - 8);
      (match st.mode with
       | Naming (what, name) ->
         Gui.label ~bold:true ui (list_x + 10) (by + 10)
           (match what with `Folder -> "New folder:" | `Rename n -> "Rename " ^ n ^ " to:");
         let name = Gui.text_field ui 5 (list_x + 10) (by + 32) 380 name in
         ui.Gui.field <- 5;
         st.mode <- Naming (what, name);
         let ok = Gui.button ui (list_x + 400) (by + 30) 80 "OK"
                  || List.exists (fun k -> k = "\r" || k = "\n") ui.keys in
         if Gui.button ui (list_x + 486) (by + 30) 80 "Cancel" then st.mode <- Browse
         else if ok && String.trim name <> "" then begin
           let name = String.trim name in
           attempt st (fun () ->
               (match what with
                | `Folder -> Sys.mkdir (Gui.join st.dir name) 0o755
                | `Rename old -> Sys.rename (Gui.join st.dir old) (Gui.join st.dir name));
               st.message <- (match what with `Folder -> "new folder " | `Rename _ -> "renamed: ")
                             ^ name);
           st.mode <- Browse; refresh st; st.chosen <- Some name
         end
       | Deleting n ->
         Gui.label ~bold:true ui (list_x + 10) (by + 10) ("Delete " ^ Gui.join st.dir n ^ "?");
         Gui.label ~colour:Gui.muted ui (list_x + 10) (by + 34) "It cannot be undone.";
         if Gui.button ui (list_x + 400) (by + 30) 80 "Delete" then begin
           let path = Gui.join st.dir n in
           attempt st (fun () ->
               if Sys.is_directory path then Sys.rmdir path else Sys.remove path;
               st.message <- "deleted " ^ n);
           st.mode <- Browse; refresh st
         end;
         if Gui.button ui (list_x + 486) (by + 30) 80 "Cancel" then st.mode <- Browse
       | Browse | Viewing _ ->
         let info = match (match st.mode with Browse -> chosen_entry () | _ -> None) with
           | Some e when e.is_dir -> Gui.join st.dir e.name ^ "/: a folder (Open enters it)"
           | Some e ->
             Printf.sprintf "%s: %s" (Gui.join st.dir e.name)
               (if has ".byte" e.name then "a program: Open starts it"
                else if has ".trc" e.name || has ".trace" e.name then
                  "a recording: Open shows it in Recordings"
                else Gui.size_text e.size ^ ": Open shows it")
           | None -> Printf.sprintf "%d entries. Click to choose, again to open."
                       (List.length st.listing) in
         ignore (Gfx.text ~max:((list_w - 20) / 8) g (list_x + 10) (by + 10) info Gui.foreground);
         ignore (Gfx.text ~max:((list_w - 20) / 8) g (list_x + 10) (by + 34) st.message Gui.muted));
      (* keys, while browsing: Enter opens, Backspace goes up *)
      if st.mode = Browse then
        List.iter (function
            | "\r" | "\n" -> (match chosen_entry () with Some e -> open_entry st e | None -> ())
            | "\127" | "\b" -> go st (Gui.parent st.dir)
            | _ -> ()) ui.keys)

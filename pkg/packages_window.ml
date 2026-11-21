(* Packages: the graphical session's window on pkg (mynos-vcd,
   doc/decisions/packages.md). It reads the index and the installed
   packages itself (module Pkgdb), and runs pkg (/pkg.byte) as a process
   for what changes them: Update index, Install, Remove. The window keeps
   drawing while pkg works, and shows pkg's output as it comes. An
   installed package is started from here, or by its name in a Terminal. *)

open Pkgdb

let width = 720 and height = 460
let side = 220                      (* the list's width *)

type job = { pid : int; out : string; what : string }

type state = {
  mutable index : entry list;
  mutable installed : (string * (string * string)) list;
    (* name, (version, how): read at the start and after each job only.
       fatfs does not remove a file that is open, so reading the
       packages' files at every frame made pkg remove fail when the
       window had one open at that moment *)
  mutable runs : (string * string list) list;
    (* an installed package's window (package.json's run): read with
       [installed], for the same reason *)
  mutable selected : string;        (* a package's name *)
  mutable job : job option;
  mutable output : string list;     (* the last job's lines *)
  mutable verdict : (bool * string) option;
}

let reload st =
  st.index <- cached_index ();
  st.installed <- List.filter_map (fun n -> Option.map (fun i -> (n, i)) (installed n))
      (installed_names ());
  st.runs <- List.map (fun (n, _) ->
      (n, match manifest n with Some m -> m.run | None -> [])) st.installed

(* the rows: the index's packages, then the installed ones it lacks *)
let rows st =
  List.map (fun e -> (e.name, Some e)) st.index
  @ List.filter_map (fun n ->
      if List.exists (fun e -> e.name = n) st.index then None else Some (n, None))
    (List.map fst st.installed)

let lines_of file =
  try List.filter (( <> ) "") (String.split_on_char '\n' (read file))
  with Sys_error _ -> []

(* a line of output, cut to the box's width (in characters) *)
let wrap per s =
  let rec go acc s =
    if String.length s <= per then List.rev (s :: acc)
    else go (String.sub s 0 per :: acc) (String.sub s per (String.length s - per)) in
  go [] s

(* pkg ARGS, its output into a file of /tmp *)
let start st what args =
  let out = Printf.sprintf "/tmp/packages-%d.out" (Mynos.getpid ()) in
  let inp = out ^ ".in" in
  write out ""; write inp "";
  let env = Array.of_list (
      List.filter (fun kv ->
          not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                 [ "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ]))
        (Array.to_list (Mynos.environment ()))
      @ [ "MYNOS_STDIN=" ^ inp; "MYNOS_STDOUT=>>" ^ out; "MYNOS_STDERR=>>" ^ out ]) in
  st.output <- []; st.verdict <- None;
  match Mynos.spawn ~env "ocamlrun" (Array.of_list ("ocamlrun" :: "/pkg.byte" :: args)) with
  | pid -> st.job <- Some { pid; out; what }
  | exception Mynos.Error (_, code) ->
    st.verdict <- Some (false, "cannot start pkg: " ^ Mynos.error_name code)

(* at each frame: pkg's output so far, and its end *)
let poll st =
  match st.job with
  | None -> ()
  | Some j ->
    st.output <- lines_of j.out;
    (match Mynos.process_info j.pid with
     | Some { Mynos.alive = true; _ } -> ()
     | _ ->
       let ok = match Mynos.wait j.pid with
         | Mynos.Exited 0 -> true
         | _ -> false
         | exception Mynos.Error _ -> true in
       st.output <- lines_of j.out;
       List.iter (fun f -> try Sys.remove f with Sys_error _ -> ()) [ j.out; j.out ^ ".in" ];
       st.job <- None;
       st.verdict <- Some (ok, j.what ^ (if ok then ": done." else ": it failed, see above."));
       reload st)

(* the right side: the selected package, what can be done with it *)
let details ui st x =
  let w = width - x - 12 in
  let busy = st.job <> None in
  match List.assoc_opt st.selected (rows st) with
  | None ->
    let text =
      if st.index = [] && st.installed = [] then
        "No index yet. Update index reads the list of packages from the \
         repository on the web (ctrl-z-bg/mynos-packages on GitHub)."
      else "Choose a package on the left." in
    20 + Gui.paragraph ~colour:Gui.muted ui x 20 w text
  | Some e ->
    let name = st.selected in
    let inst = List.assoc_opt name st.installed in
    let title = match e with Some e -> name ^ " " ^ e.version | None -> name in
    Gui.label ~bold:true ui x 16 title;
    (* the description takes up to four lines; below it, the same places
       for every package *)
    let y = 128 in
    let rows = match e with
      | None ->
        ignore (Gui.paragraph ~colour:Gui.muted ui x 40 w
                  "Installed, but no longer in the index.");
        []
      | Some e ->
        ignore (Gui.paragraph ui x 40 w e.description);
        [ "Licence", e.license;
          "Size", Gui.size_text e.size;
          "Built on", "MyNOS " ^ e.mynos ]
        @ (if e.depends = [] then [] else [ "Needs", String.concat ", " e.depends ])
        @ (match e.programs with
            | [] -> []
            | ps -> [ "Commands", String.concat " " ps ]) in
    List.iteri (fun i (k, v) ->
        Gui.label ~colour:Gui.muted ui x (y + i * 18) k;
        ignore (Gfx.text ~max:((w - 96) / Gfx.char_w) ui.Gui.g (x + 96) (y + i * 18) v
                  Gui.foreground)) rows;
    let y = y + max 3 (List.length rows) * 18 + 6 in
    let status, newer = match inst, e with
      | None, _ -> "not installed", false
      | Some (v, how), Some e when v <> e.version ->
        Printf.sprintf "%s (%s); the index has %s" v how e.version, true
      | Some (v, how), _ -> Printf.sprintf "%s (%s)" v how, false in
    Gui.label ~colour:Gui.muted ui x y "Installed";
    Gui.label ui (x + 96) y status;
    let y = y + 30 in
    let run = Option.value (List.assoc_opt name st.runs) ~default:[] in
    let buttons =
      (match inst, e with
       | None, Some _ -> [ "Install", `Install ]
       | Some _, Some _ when newer -> [ "Upgrade", `Install ]
       | _ -> [])
      @ (if run <> [] then [ "Run", `Run ] else [])
      @ (if inst <> None then [ "Remove", `Remove ] else []) in
    List.iteri (fun i (label, act) ->
        if Gui.button ui (x + i * 104) y 96 label && not busy then
          match act with
          | `Install -> start st ("Installing " ^ name) [ "install"; name ]
          | `Remove -> start st ("Removing " ^ name) [ "remove"; name ]
          | `Run ->
            (match run with
             | p :: args -> Gui.spawn ~args (Filename.concat bin p)
             | [] -> ()))
      buttons;
    y + 40

let () =
  let st = { index = []; installed = []; runs = []; selected = ""; job = None; output = [];
             verdict = None } in
  reload st;
  if not (Sys.file_exists index_file) then start st "Reading the index" [ "update" ];
  Gui.run ~title:"Packages" ~tick:0.25 width height st (fun ui st ->
      poll st;
      let g = ui.Gui.g in
      (* the list *)
      Gfx.fill g 0 0 side height 0xE6EBF0;
      Gui.label ~bold:true ui 12 10 "Packages";
      let rs = rows st in
      if st.selected = "" then (match rs with (n, _) :: _ -> st.selected <- n | [] -> ());
      Gui.scroll ~colour:0xE6EBF0 ui 1 4 34 (side - 8) (height - 90) (fun top ->
          List.iteri (fun i (name, e) ->
              let y = top + i * 24 in
              if Gui.list_item ui 4 y (side - 16) ~selected:(name = st.selected) name
              && name <> st.selected then begin
                st.selected <- name;
                (* the last job's output belongs to the package it was for *)
                if st.job = None then begin st.output <- []; st.verdict <- None end
              end;
              let mark = match List.assoc_opt name st.installed, e with
                | None, _ -> ""
                | Some (v, _), Some e when v <> e.version -> "newer"
                | Some _, _ -> "installed" in
              Gui.label ~colour:(if name = st.selected then 0xD8E6F2 else Gui.muted) ui
                (side - 16 - Gfx.char_w * String.length mark - 6) (y + 3) mark)
            rs;
          24 * List.length rs);
      if Gui.button ui 12 (height - 44) (side - 24) "Update index" && st.job = None then
        start st "Reading the index" [ "update" ];
      (* the package, and pkg's output *)
      let x = side + 16 in
      Gfx.fill g (side) 0 1 height 0xD5DBE1;
      let y = details ui st x in
      let w = width - x - 12 in
      let y = max y 230 in
      (match st.job, st.verdict with
       | Some j, _ -> Gui.label ~bold:true ui x y (j.what ^ "...")
       | None, Some (ok, text) ->
         Gui.label ~bold:true ~colour:(if ok then 0x2E7D32 else 0xC62828) ui x y text
       | None, None -> ());
      if st.output <> [] then begin
        let lines = List.concat_map (wrap ((w - 20) / Gfx.char_w)) st.output in
        Gui.scroll ~colour:0xF4F6F8 ui 2 x (y + 22) w (height - y - 34) (fun top ->
            List.iteri (fun i l ->
                ignore (Gfx.text g (x + 6) (top + 4 + i * 18) l Gui.foreground)) lines;
            8 + 18 * List.length lines);
        if st.job <> None then Gui.scroll_to_end ui 2
      end;
      st)

(* Applications: the installed packages that open a window (package.json's
   "run"), in the graphical session; a click starts one. The menu's
   Applications opens it. The list is read at the start and whenever the
   window gets the focus back (after Packages installed something): not
   at every frame, which would keep the packages' files open while pkg
   removes them (packages_window.ml). *)

open Pkgdb

let width = 460 and height = 420
let row_h = 44

type app = { name : string; description : string; run : string list }

let apps () =
  List.filter_map (fun name ->
      match manifest name with
      | Some { run = _ :: _ as run; description; _ } -> Some { name; description; run }
      | _ -> None)
    (installed_names ())

type state = { mutable list : app list; mutable focused : bool }

let () =
  let st = { list = apps (); focused = true } in
  Gui.run ~title:"Applications" width height st (fun ui st ->
      if ui.Gui.focused && not st.focused then st.list <- apps ();
      st.focused <- ui.Gui.focused;
      let g = ui.Gui.g in
      Gui.label ~bold:true ui 12 10 "Applications";
      let list_h = height - 84 in
      if st.list = [] then
        ignore (Gui.paragraph ~colour:Gui.muted ui 12 40 (width - 24)
                  "No application is installed yet. Packages installs them: \
                   mines, paint, wiki, zmachine...")
      else
        Gui.scroll ui 1 8 34 (width - 16) list_h (fun top ->
            List.iteri (fun i a ->
                let y = top + i * row_h in
                let w = width - 16 - 14 in
                let over = Gui.hovered ui 8 y w row_h in
                if over then Gfx.fill g 8 y w row_h 0xDCE6EF;
                ignore (Gfx.text ~bold:true ~max:((w - 16) / Gfx.char_w) g 16 (y + 5) a.name
                          Gui.foreground);
                ignore (Gfx.text ~max:((w - 16) / Gfx.char_w) g 16 (y + 5 + Gfx.char_h + 2)
                          a.description Gui.muted);
                let px, py = ui.Gui.press in
                if ui.Gui.clicked && over && px >= 8 && px < 8 + w && py >= y && py < y + row_h then
                  match a.run with
                  | p :: args -> Gui.spawn ~args (Filename.concat bin p)
                  | [] -> ())
              st.list;
            row_h * List.length st.list);
      Gui.label ~colour:Gui.muted ui 12 (height - 36) "More in Packages:";
      if Gui.button ui (width - 12 - 120) (height - 42) 120 "Packages" then
        Gui.spawn "/packages.byte";
      st)

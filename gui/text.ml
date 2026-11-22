(* text: the text editor of the graphical session (doc/decisions/studio.md,
   mynos-y87.2): one file in a resizable window, on module Textarea.

     text [FILE]

   New, Open (the file picker), Save, Save as (a name, typed), Find (the
   field and its button, or Enter in it: the next occurrence); Ctrl-S
   saves, Ctrl-F goes to the find field, Ctrl-O opens. OCaml files (.ml,
   .mli) are coloured, and Tab gives two spaces in them. The MyNOS menu's
   Text opens it; Files' Edit opens a file in it. *)

let width = 720 and height = 520
let bar = 34

type mode = Editing | Saving_as of string

type state = {
  mutable path : string option;
  mutable area : Textarea.t;
  mutable find : string;
  mutable mode : mode;
  mutable message : string;
  mutable window_title : string;
}

let is_ocaml p = Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli"

let area_for path s =
  if is_ocaml path then Textarea.create ~tab:2 ~highlight:Textarea.ocaml s
  else Textarea.create s

let load st path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> st.path <- Some path; st.area <- area_for path s; st.message <- "opened " ^ path
  | exception Sys_error e -> st.message <- e

let save st path =
  match Out_channel.with_open_bin path (fun oc -> output_string oc (Textarea.text st.area)) with
  | () ->
    let was = st.path in
    st.path <- Some path; Textarea.set_modified st.area false;
    (* a new name may change the colours: an OCaml file named now *)
    if was <> Some path && is_ocaml path then begin
      let a = area_for path (Textarea.text st.area) in
      let l, c = Textarea.cursor st.area in
      Textarea.goto a l c; st.area <- a
    end;
    st.message <- "saved " ^ path
  | exception Sys_error e -> st.message <- e

let title st =
  (match st.path with Some p -> Filename.basename p | None -> "untitled")
  ^ (if Textarea.modified st.area then " *" else "") ^ " - Text"

let () =
  let st = { path = None; area = Textarea.create ""; find = ""; mode = Editing; message = "";
             window_title = "" } in
  (match List.tl (Array.to_list Sys.argv) with
   | f :: _ ->
     if Sys.file_exists f then load st f
     else begin st.path <- Some f; st.area <- area_for f ""; st.message <- "a new file: " ^ f end
   | [] -> ());
  let first = ref true in
  Gui.run ~title:(title st) ~resizable:(360, 200) ~unsaved:(fun () -> Textarea.modified st.area)
    width height st (fun ui st ->
      let width = Gui.width ui and height = Gui.height ui in
      if !first then begin first := false; ui.Gui.field <- 1 end;
      (* the title says the file, and whether it changed *)
      let t = title st in
      if t <> st.window_title then begin
        st.window_title <- t;
        (try Display.set_title ui.Gui.window t with _ -> ())
      end;
      let save_now () =
        match st.path with
        | Some p -> save st p
        | None -> st.mode <- Saving_as "/disk/untitled.txt"; ui.Gui.field <- 3 in
      let open_picker () =
        Gui.open_file_picker ~title:"A file to edit"
          ?dir:(Option.map Filename.dirname st.path) 1 in
      List.iter (function
          | "\019" -> save_now ()                               (* Ctrl-S *)
          | "\006" -> ui.Gui.field <- 2                         (* Ctrl-F *)
          | "\015" -> open_picker ()                            (* Ctrl-O *)
          | _ -> ()) ui.Gui.keys;
      (* the bar *)
      let g = ui.Gui.g in
      Gfx.fill g 0 0 width bar Gui.panel_colour;
      if Gui.button ui 6 4 52 "New" then begin
        st.path <- None; st.area <- Textarea.create ""; st.message <- ""; ui.Gui.field <- 1 end;
      if Gui.button ui 62 4 56 "Open" then open_picker ();
      if Gui.button ui 122 4 56 "Save" then save_now ();
      if Gui.button ui 182 4 76 "Save as" then begin
        st.mode <- Saving_as (Option.value st.path ~default:"/disk/untitled.txt");
        ui.Gui.field <- 3
      end;
      let fx = max 266 (width - 290) in
      let enter id = ui.Gui.field = id && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      let find_now = enter 2 in
      st.find <- Gui.text_field ui 2 fx 6 200 st.find;
      if (Gui.button ui (fx + 206) 4 70 "Find" || find_now) && st.find <> "" then begin
        if not (Textarea.find st.area st.find) then st.message <- "not found: " ^ st.find
        else st.message <- ""
      end;
      (* the text *)
      Textarea.frame ui 1 st.area 0 bar width (height - bar - 22);
      (* the status line: the file, where the cursor is, a message *)
      let sy = height - 22 in
      Gfx.fill g 0 sy width 22 Gui.panel_colour;
      let l, c = Textarea.cursor st.area in
      let where = Printf.sprintf "line %d, column %d" l c in
      ignore (Gfx.text g 8 (sy + 3)
                ((match st.path with Some p -> p | None -> "untitled")
                 ^ (if Textarea.modified st.area then " (changed)" else "")) Gui.muted);
      ignore (Gfx.text g (width - 8 - Gfx.char_w * String.length where) (sy + 3) where Gui.muted);
      if st.message <> "" then
        ignore (Gfx.text ~max:((width - 520) / Gfx.char_w) g 300 (sy + 3) st.message Gui.accent);
      (* Save as: a name *)
      (match st.mode with
       | Saving_as name ->
         Gui.panel ui (width / 2 - 220) 60 440 96;
         Gui.label ~bold:true ui (width / 2 - 206) 70 "Save as";
         let name = Gui.text_field ui 3 (width / 2 - 206) 94 412 name in
         let ok = Gui.button ui (width / 2 + 52) 124 76 "Save" || enter 3 in
         if ok && name <> "" then begin st.mode <- Editing; save st name; ui.Gui.field <- 1 end
         else if Gui.button ui (width / 2 + 134) 124 72 "Cancel" then begin
           st.mode <- Editing; ui.Gui.field <- 1 end
         else st.mode <- Saving_as name
       | Editing -> ());
      (match Gui.file_picker ui 1 with
       | Some (Gui.Picked p) -> load st p; ui.Gui.field <- 1
       | Some Gui.Cancelled | None -> ());
      st)

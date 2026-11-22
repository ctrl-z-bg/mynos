(* The Log window: the kernel's log (its messages and the services'),
   as `log -f` shows it at the console, followed as it grows. *)

let width = 760 and height = 460
let line_h = 18

let () =
  let lines = Dynarray.create () in
  let partial = Buffer.create 128 in            (* a line not ended yet *)
  let pos = ref (max 0 (Mynos.log_position () - 65536)) in
  let fresh = ref true in
  (* the new bytes, cut into lines *)
  let rec drain () =
    let s = Mynos.log_read !pos 16384 in
    if s <> "" then begin
      pos := !pos + String.length s;
      String.iter (fun c ->
          if c = '\n' then begin
            Dynarray.add_last lines (Buffer.contents partial);
            Buffer.clear partial
          end else if c <> '\r' then Buffer.add_char partial c) s;
      fresh := true;
      drain ()
    end in
  Gui.run ~title:"Log" ~tick:0.5 ~resizable:(360, 200) width height () (fun ui () ->
      (* resizable: the size as it is now *)
      let width = Gui.width ui and height = Gui.height ui in
      let g = ui.Gui.g in
      drain ();
      Gfx.fill g 0 0 width 30 0x1B3A57;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 12 7 "The kernel's log";
      ignore (Gfx.text g 160 7 "its messages and the services', since boot" 0xB8C7D3);
      Gui.scroll ui 1 8 38 (width - 16) (height - 46) (fun top ->
          let n = Dynarray.length lines in
          let all = n + (if Buffer.length partial > 0 then 1 else 0) in
          for i = 0 to all - 1 do
            let y = top + 4 + i * line_h in
            if y > -line_h && y < height then begin
              let l = if i < n then Dynarray.get lines i else Buffer.contents partial in
              ignore (Gfx.text ~max:((width - 40) / Gfx.char_w) g 14 y l 0x1A2228)
            end
          done;
          all * line_h + 8);
      (* new lines: to the end, at the next frame (the box knows its
         content's height then) *)
      if !fresh then (Gui.scroll_to_end ui 1; fresh := false))

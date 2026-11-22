(* keys: a window that writes to the kernel's log each key it gets, each
   release, and the keys held then (Gui.held); it ends when q is let go.
   It is resizable, and logs its size when it changes; it moves itself to
   200,300 first. The graphical session's test (tools/run-tests.sh) drags
   its grip, maximizes it, holds two keys at once and checks the lines. *)

let name k =
  String.concat "" (List.map (fun c -> if c = '\027' then "ESC" else String.make 1 c)
                      (List.of_seq (String.to_seq k)))

let () =
  let size = ref (0, 0) in
  Gui.run ~title:"Keys" ~resizable:(100, 40) 240 60 () (fun ui () ->
      if !size = (0, 0) then Display.move ui.Gui.window 200 300;
      if (Gui.width ui, Gui.height ui) <> !size then begin
        size := (Gui.width ui, Gui.height ui);
        Mynos.log (Printf.sprintf "keys: size %dx%d\n" (Gui.width ui) (Gui.height ui))
      end;
      let held () = String.concat " " (List.map name ui.Gui.held) in
      List.iter (fun k -> Mynos.log (Printf.sprintf "keys: down %s, held %s\n" (name k) (held ())))
        ui.Gui.keys;
      List.iter (fun k ->
          Mynos.log (Printf.sprintf "keys: up %s, held %s\n" (name k) (held ()));
          if k = "q" then raise Gui.Quit) ui.Gui.released;
      Gui.label ui 12 20 "Keys: q ends")

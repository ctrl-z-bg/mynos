(* keys: a window that writes to the kernel's log each key it gets, each
   release, and the keys held then (Gui.held); it ends when q is let go.
   The graphical session's test (tools/run-tests.sh) holds two keys at
   once and checks the lines. *)

let name k =
  String.concat "" (List.map (fun c -> if c = '\027' then "ESC" else String.make 1 c)
                      (List.of_seq (String.to_seq k)))

let () =
  Gui.run ~title:"Keys" 240 60 () (fun ui () ->
      let held () = String.concat " " (List.map name ui.Gui.held) in
      List.iter (fun k -> Mynos.log (Printf.sprintf "keys: down %s, held %s\n" (name k) (held ())))
        ui.Gui.keys;
      List.iter (fun k ->
          Mynos.log (Printf.sprintf "keys: up %s, held %s\n" (name k) (held ()));
          if k = "q" then raise Gui.Quit) ui.Gui.released;
      Gui.label ui 12 20 "Keys: q ends")

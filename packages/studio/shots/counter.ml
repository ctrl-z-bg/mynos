(* A counter in a window: a button counts, a label shows it, and each
   click plays a note (the sound service). *)

let () =
  Gui.run ~title:"Counter" 280 150 0 (fun ui n ->
      Gui.label ~bold:true ui 20 24 (Printf.sprintf "Clicked %d times" n);
      if Gui.button ui 20 70 140 "Click me" then begin
        (try Sound.tone (440 + 40 * n) 80 with _ -> ());
        n + 1
      end else n)

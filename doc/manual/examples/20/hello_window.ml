(* the example of Display's interface, made whole *)
let () =
  let w = Display.window ~title:"Hello" 300 120 in
  Gfx.fill w.Display.pixels 0 0 300 120 0x2D6CA2;
  ignore (Gfx.text w.pixels 20 50 "Hello, MyNOS" 0xFFFFFF);
  Display.damage w;
  let rec loop () =
    match Display.next_event w with
    | Display.Close -> Display.destroy w
    | Display.Key "q" -> Display.destroy w
    | Display.Mouse { x; y; buttons = 1 } ->
      Gfx.fill w.pixels (x - 2) (y - 2) 5 5 0xFFD000;
      Display.damage ~x:(x - 2) ~y:(y - 2) ~w:5 ~h:5 w;
      loop ()
    | _ -> loop () in
  loop ()

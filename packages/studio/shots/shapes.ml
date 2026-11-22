(* Four colours in a window, drawn with Gfx; Gui lays it out. *)

let colours = [ 0xD94F3D; 0xF2A541; 0x3E8E5E; 0x2F6DB5 ]

let () =
  Gui.run ~title:"Shapes" 320 180 () (fun ui () ->
      List.iteri (fun i c -> Gfx.fill ui.Gui.g (20 + i * 72) 30 60 60 c) colours;
      Gui.lable ui 20 120 "Four colours, one window")

(* The welcome window of the graphical session. *)

let () =
  Gui.run ~title:"Welcome to MyNOS" ~tick:2.0 520 330 () (fun ui () ->
      let g = ui.Gui.g in
      (* a banner *)
      Gfx.fill g 0 0 520 64 0x1B3A57;
      Gfx.fill g 24 18 6 28 0xF29B38;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 42 16 "MyNOS";
      Gui.label ~colour:0xB8C7D3 ui 42 34 "an operating system in OCaml, on a microkernel";
      let y = 84 in
      let h = Gui.paragraph ui 24 y 472
          "Every window here is a separate process. Its pixels live in its own \
           memory, shared with the display server, which composes the screen. \
           Services talk over typed IPC, and describe their own protocols." in
      let st = Mynos.stats () in
      let y = y + h + 14 in
      Gui.panel ui 24 y 472 64;
      Gui.label ~bold:true ui 36 (y + 10) "This system now";
      Gui.label ~colour:Gui.muted ui 36 (y + 32)
        (Printf.sprintf "%d processes, %d threads, %d MB free, up %.0f s"
           st.Mynos.processes st.threads (st.free_pages / 256) (Mynos.uptime ()));
      let y = y + 84 in
      if Gui.button ui 24 y 110 "Terminal" then Gui.spawn "/terminal.byte";
      if Gui.button ui 144 y 110 "Clock" then Gui.spawn "/clock.byte";
      if Gui.button ui 264 y 110 "Services" then Gui.spawn "/services.byte";
      if Gui.button ui 386 y 110 "Close" then raise Gui.Quit;
      Gui.label ~colour:Gui.muted ui 24 (y + 44)
        "The MyNOS menu, top left, opens programs and ends the session.")

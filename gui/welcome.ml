(* The welcome window of the graphical session. *)

(* the logo: the 2003 website's drawing (gui/make-logo.sh), as a mask *)
let logo = try Some (Gfx.load_mask "/mynos-logo.pgm") with _ -> None

let () =
  Gui.run ~title:"Welcome to MyNOS" ~tick:2.0 520 394 () (fun ui () ->
      let g = ui.Gui.g in
      (* a banner: the logo, light on blue, and the name *)
      Gfx.fill g 0 0 520 128 0x1B3A57;
      Option.iter (fun m -> Gfx.draw_mask g 14 8 m 0xE8EEF2) logo;
      Gfx.fill g 178 44 6 44 0xF29B38;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 196 42 "MyNOS";
      Gui.label ~colour:0xB8C7D3 ui 196 60 "an operating system in OCaml,";
      Gui.label ~colour:0xB8C7D3 ui 196 76 "on a microkernel";
      let y = 148 in
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
      List.iteri (fun i (label, program) ->
          if Gui.button ui (24 + i * 96) y 88 label then
            match program with Some p -> Gui.spawn p | None -> raise Gui.Quit)
        [ "Terminal", Some "/terminal.byte"; "Clock", Some "/clock.byte";
          "Services", Some "/services.byte"; "Agent", Some "/agent_window.byte";
          "Close", None ];
      Gui.label ~colour:Gui.muted ui 24 (y + 44)
        "The MyNOS menu, top left, opens programs and ends the session.")

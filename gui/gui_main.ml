(* gui: the graphical session (doc/decisions/gui.md).

     gui           start it, with a welcome window; back to the text
                   console when it ends (the MyNOS menu's Exit)
     gui stop      end it (from another program)
     gui check     compare displayd's description of its protocol with
                   display.ml's (the tests) *)

let () =
  match Array.to_list Sys.argv with
  | _ :: [ "stop" ] -> Display.call (Display.connect ()) Display.Stop
  | _ :: [ "check" ] ->
    let shape (rs : Ipc.request_doc list) =
      List.map (fun (r : Ipc.request_doc) -> (r.case, r.name, r.args, r.reply, r.safe)) rs in
    ignore (Display.connect ());
    let d = Ipc.describe "display" in
    if d.Ipc.protocol = "display/1" && shape d.requests = shape Display.Protocol.requests
    then print_endline "gui: displayd describes display/1 as display.ml does"
    else (print_endline "gui: displayd's description differs from display.ml's"; exit 1)
  | _ :: [] ->
    (match Display.connect () with
     | exception Mynos.Error _ ->
       prerr_endline "gui: no display service (displayd: QEMU's standard VGA is needed)";
       exit 1
     | d ->
       Display.call d Display.Start;
       Gui.spawn "/welcome.byte";
       Display.call d Display.Wait_session;
       print_endline "gui: the graphical session ended")
  | _ -> prerr_endline "usage: gui [stop]"; exit 2

(* gui: the graphical session (doc/decisions/gui.md).

     gui           start it, with a welcome window; back to the text
                   console when it ends (the MyNOS menu's Exit); at the
                   size chosen last (/disk/.display), or 1024x768
     gui WxH       start it with the screen at this size (1280x800,
                   1920x1080...), and keep it for the next times
     gui WxH once  this time only
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
  | _ :: args when List.length args <= 2 ->
    let saved = "/disk/.display" in
    let parse s = Scanf.sscanf_opt (String.trim s) "%dx%d%!" (fun w h -> (w, h)) in
    let size, keep = match args with
      | [] -> ((try parse (In_channel.with_open_bin saved In_channel.input_all)
                with Sys_error _ -> None), false)
      | [ s ] | [ s; "once" ] ->
        (match parse s with
         | Some _ as sz -> (sz, args = [ s ])
         | None -> prerr_endline "usage: gui [WIDTHxHEIGHT [once] | stop | check]"; exit 2)
      | _ -> prerr_endline "usage: gui [WIDTHxHEIGHT [once] | stop | check]"; exit 2 in
    (match Display.connect () with
     | exception Mynos.Error _ ->
       prerr_endline "gui: no display service (displayd: QEMU's standard VGA is needed)";
       exit 1
     | d ->
       (match size with
        | None | Some (1024, 768) -> Display.call d Display.Start
        | Some (w, h) ->
          (match Display.call d (Display.Start_at (w, h)) with
           | () -> ()
           | exception Ipc.Remote_error (_, m) ->
             Printf.eprintf "gui: %dx%d: %s; 1024x768\n%!" w h m;
             Display.call d Display.Start));
       if keep then
         (try Out_channel.with_open_bin saved (fun oc ->
              Option.iter (fun (w, h) -> Printf.fprintf oc "%dx%d\n" w h) size)
          with Sys_error _ -> ());
       Gui.spawn "/welcome.byte";
       Display.call d Display.Wait_session;
       print_endline "gui: the graphical session ended")
  | _ -> prerr_endline "usage: gui [WIDTHxHEIGHT [once] | stop | check]"; exit 2

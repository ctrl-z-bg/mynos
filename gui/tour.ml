(* The tour (doc/decisions/gui.md): lessons on how an operating system
   works, with MyNOS as the specimen. Each lesson (gui/lesson.ml; the
   lessons are /tour.txt, and /disk/tour.txt if there is one) says what to
   look at, then runs a command under the event recorder and opens the
   System window on its recording: the lesson's processes only, the steps
   it explains told in words.

     tour *)

let width = 780 and height = 500
let list_w = 248

type st = {
  lessons : Lesson.t array;
  mutable sel : int;
  mutable message : string;
  mutable running : bool;
}

let lock = Mutex.create ()
let finished : (string * string, string) result option ref = ref None

(* the lesson's command, recorded by trace in a domain; then the lesson
   itself, for the System window *)
let counter = ref 0
let run st (l : Lesson.t) =
  incr counter;
  let base = Printf.sprintf "/tmp/tour-%d-%d" (Mynos.getpid ()) !counter in
  let file = base ^ ".trc" and lesson = base ^ ".lesson" and out = base ^ ".out" in
  st.running <- true;
  st.message <- "running: " ^ l.command;
  ignore (Domain.spawn (fun () ->
      let result =
        try
          Out_channel.with_open_bin lesson (fun oc -> output_string oc (Lesson.to_string l));
          Out_channel.with_open_bin out (fun _ -> ());
          let env = Array.append
              (Array.of_list (List.filter (fun kv ->
                   not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                          [ "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ]))
                   (Array.to_list (Mynos.environment ()))))
              [| "MYNOS_STDIN=" ^ out; "MYNOS_STDOUT=>>" ^ out; "MYNOS_STDERR=>>" ^ out |] in
          let pid = Mynos.spawn ~env "ocamlrun"
              [| "ocamlrun"; "/trace.byte"; "-o"; file; l.command |] in
          if Mynos.wait pid = Mynos.Exited 0 || Sys.file_exists file then Ok (file, lesson)
          else Error (match In_channel.with_open_bin out In_channel.input_all
                            |> String.split_on_char '\n'
                            |> List.find_opt (String.starts_with ~prefix:"trace:") with
                      | Some m -> m
                      | None -> "the recording failed")
        with
        | Mynos.Error (f, code) -> Error (f ^ ": " ^ Mynos.error_name code)
        | Sys_error e -> Error e in
      Mutex.lock lock;
      finished := Some result;
      Mutex.unlock lock))

let () =
  let lessons = Array.of_list (Lesson.load "/tour.txt" @ Lesson.load "/disk/tour.txt") in
  let st = { lessons; sel = 0; message = ""; running = false } in
  Gui.run ~title:"Tour of MyNOS" ~tick:0.5 width height () (fun ui () ->
      let g = ui.Gui.g in
      Mutex.lock lock;
      let done_ = !finished in
      finished := None;
      Mutex.unlock lock;
      (match done_ with
       | Some (Ok (file, lesson)) ->
         st.running <- false;
         Gui.spawn ~args:[ file; "--lesson"; lesson ] "/system.byte";
         st.message <- "Recorded. The System window replays it: Next note goes to what \
                        the lesson explains."
       | Some (Error e) -> st.running <- false; st.message <- e
       | None -> ());
      (* the header *)
      Gfx.fill g 0 0 width 34 0x1B3A57;
      Gui.label ~colour:0xFFFFFF ~bold:true ui 12 9 "A tour of MyNOS";
      ignore (Gfx.text g 160 9 "how an operating system works, watched as it works" 0xB8C7D3);
      (* the lessons *)
      Gui.panel ui 8 42 list_w (height - 50);
      Array.iteri (fun i (l : Lesson.t) ->
          if Gui.list_item ui 10 (46 + i * 24) (list_w - 4) ~selected:(i = st.sel)
              (Printf.sprintf "%d. %s" (i + 1) l.title)
          then (st.sel <- i; st.message <- ""))
        st.lessons;
      if st.lessons = [||] then
        ignore (Gui.paragraph ~colour:Gui.muted ui 18 50 (list_w - 20)
                  "No lessons: /tour.txt is missing.");
      (* the lesson *)
      let x = list_w + 20 and w = width - list_w - 32 in
      if st.sel < Array.length st.lessons then begin
        let l = st.lessons.(st.sel) in
        Gui.label ~bold:true ui x 48 l.title;
        let y = ref 76 in
        List.iter (fun p -> y := !y + Gui.paragraph ui x !y w p + 8)
          (String.split_on_char '\n' l.text);
        let y = max !y 300 in
        Gui.label ~colour:Gui.muted ui x y "It runs:";
        Gfx.fill g x (y + 20) w 26 0x111820;
        ignore (Gfx.text ~max:((w - 16) / 8) g (x + 8) (y + 25) ("mynos:/$ " ^ l.command) 0xE8EEF2);
        if Gui.button ui x (y + 58) 160 (if st.running then "Running..." else "Run and watch")
        && not st.running then run st l;
        ignore (Gui.paragraph ~colour:Gui.muted ui (x + 172) (y + 58) (w - 172)
                  (if st.message <> "" then st.message
                   else "The command runs under the event recorder; the System window \
                         then replays what the processes said to each other."))
      end)

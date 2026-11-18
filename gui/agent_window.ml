(* The agent window (doc/decisions/gui.md, phase 4): a conversation with
   the agent (module Agent). The task is typed at the bottom; the model's
   words, the actions of its tools and their results scroll above; what
   changes things is shown in the conversation and waits for a button at
   the bottom, in place of the task's field: Allow, Deny, or Allow all. A
   follow-up continues the same conversation.

   The agent runs in a domain of its own (a model call takes seconds); it
   adds events to the log, and waits on a condition for the answer to a
   confirmation. The window's domain draws, at every event and four times a
   second while the agent works. *)

type entry =
  | You of string
  | Said of string
  | Action of string
  | Result of string * bool
  | Note of string
  | Problem of string

let lock = Mutex.create ()
let answered = Condition.create ()

type state = {
  mutable log : entry list;                  (* newest first *)
  mutable count : int;
  mutable drawn : int;                       (* entries at the last frame *)
  mutable running : bool;
  mutable pending : (string * Agent.answer option ref) option;
  mutable input : string;
  mutable model : string;
}

let add st e = st.log <- e :: st.log; st.count <- st.count + 1

(* ---- text, wrapped to the conversation's width ---- *)

let wrap cols text =
  List.concat_map (fun line ->
      let out = ref [] and cur = Buffer.create 96 in
      let flush () = out := Buffer.contents cur :: !out; Buffer.clear cur in
      List.iter (fun w ->
          if Buffer.length cur > 0
          && Gfx.cells (Buffer.contents cur) + 1 + Gfx.cells w > cols then flush ();
          let w = ref w in
          while Gfx.cells !w > cols do            (* a word longer than a line *)
            if Buffer.length cur > 0 then flush ();
            (* cols characters: a byte that continues one is not a start *)
            let i = ref 0 and n = ref 0 in
            while !n < cols do
              incr i;
              while !i < String.length !w && Char.code !w.[!i] land 0xC0 = 0x80 do incr i done;
              incr n
            done;
            out := String.sub !w 0 !i :: !out;
            w := String.sub !w !i (String.length !w - !i)
          done;
          if Buffer.length cur > 0 then Buffer.add_char cur ' ';
          Buffer.add_string cur !w)
        (String.split_on_char ' ' line);
      flush ();
      List.rev !out)
    (String.split_on_char '\n' text)

let first_lines n text =
  let lines = String.split_on_char '\n' (String.trim text) in
  let shown = List.filteri (fun i _ -> i < n) lines in
  String.concat "\n" shown
  ^ (if List.length lines > n then Printf.sprintf "\n... (%d lines)" (List.length lines) else "")

(* ---- the agent's side ---- *)

let start st session task =
  st.running <- true;
  ignore (Domain.spawn (fun () ->
      let emit e =
        Mutex.lock lock;
        add st (match e with
            | Agent.Task _ -> You task
            | Said s -> Said s
            | Action a -> Action a
            | Result { text; error } -> Result (text, error)
            | Note n -> Note n);
        Mutex.unlock lock in
      let confirm what =
        Mutex.lock lock;
        let answer = ref None in
        st.pending <- Some (what, answer);
        while !answer = None do Condition.wait answered lock done;
        st.pending <- None;
        (match !answer with
         | Some Agent.No -> add st (Note ("denied: " ^ what))
         | Some Agent.All -> add st (Action what); add st (Note "(allowed, and all after)")
         | _ -> add st (Action what));
        Mutex.unlock lock;
        Option.get !answer in
      (match Agent.run session ~emit ~confirm task with
       | _ -> ()
       | exception e -> Mutex.lock lock; add st (Problem (Printexc.to_string e)); Mutex.unlock lock);
      Mutex.lock lock;
      st.running <- false;
      Mutex.unlock lock))

(* ---- the window ---- *)

let width = 760 and height = 560
let conv_x = 8 and conv_y = 40 and conv_w = 744 and conv_h = 450
let cols = (conv_w - 32) / Gfx.char_w

let () =
  let st = { log = []; count = 0; drawn = 0; running = false; pending = None;
             input = ""; model = "" } in
  let session =
    match Agent.create ~warn:(fun m -> add st (Note m)) () with
    | a ->
      (match Llm.call (Llm.connect ()) Llm.Profiles with
       | (name, _, model) :: _ -> st.model <- Printf.sprintf "%s (%s)" name model
       | [] -> ()
       | exception (Ipc.Remote_error (_, m)) -> add st (Problem m)
       | exception _ -> ());
      Some a
    | exception Failure m -> add st (Problem m); None in
  add st (Note "Ask the agent to do something in MyNOS. What changes things waits for your yes.");
  Gui.run ~title:"Agent" ~tick:0.25 width height () (fun ui () ->
      Mutex.lock lock;
      Fun.protect ~finally:(fun () -> Mutex.unlock lock) (fun () ->
          let g = ui.Gui.g in
          (* the header *)
          Gfx.fill g 0 0 width 34 0x1B3A57;
          Gui.label ~colour:0xFFFFFF ~bold:true ui 12 9 "Agent";
          let info = match session with
            | None -> "no language model service"
            | Some a ->
              let i, o = Agent.tokens a in
              Printf.sprintf "%s  \xc2\xb7  %d tokens in, %d out"
                (if st.model = "" then "no model configured" else st.model) i o in
          ignore (Gfx.text g (width - 12 - 8 * Gfx.cells info) 9 info 0xB8C7D3);
          (* the conversation: the newest at the bottom *)
          if st.count <> st.drawn then (Gui.scroll_to_end ui 1; st.drawn <- st.count);
          Gui.scroll ui 1 conv_x conv_y conv_w conv_h (fun top ->
              let y = ref (top + 8) in
              let lines ?(bold = false) colour x text =
                List.iter (fun l ->
                    ignore (Gfx.text ~bold g x !y l colour); y := !y + 18) (wrap cols text) in
              List.iter (fun e ->
                  (match e with
                   | You t ->
                     y := !y + 6;
                     Gfx.fill g (conv_x + 8) !y 4 (18 * List.length (wrap cols t)) 0xF29B38;
                     lines ~bold:true Gui.foreground (conv_x + 20) t
                   | Said s -> lines Gui.foreground (conv_x + 12) s
                   | Action a -> lines Gui.accent (conv_x + 12) ("\xc2\xbb " ^ a)
                   | Result (text, error) ->
                     lines (if error then 0xC62828 else Gui.muted) (conv_x + 28)
                       (first_lines 6 text)
                   | Note n -> lines Gui.muted (conv_x + 12) n
                   | Problem p -> lines 0xC62828 (conv_x + 12) p);
                  y := !y + 4)
                (List.rev st.log);
              (* a confirmation: the action, and the buttons *)
              (match st.pending with
               | None ->
                 if st.running then
                   lines Gui.muted (conv_x + 12)
                     ("working" ^ String.make (1 + int_of_float (Mynos.uptime () *. 3.) mod 3) '.')
               | Some (what, _) ->
                 let h = 18 * List.length (wrap cols what) + 40 in
                 Gfx.fill g (conv_x + 8) !y (conv_w - 40) h 0xFFF4E0;
                 Gfx.rect g (conv_x + 8) !y (conv_w - 40) h 0xF29B38;
                 y := !y + 8;
                 Gui.label ~bold:true ui (conv_x + 20) !y "Allow this?";
                 y := !y + 22;
                 lines Gui.foreground (conv_x + 20) what;
                 y := !y + 10);
              !y - top + 8);
          let fy = conv_y + conv_h + 12 in
          (match st.pending with
           | Some (_, answer) ->
             (* the answer, where the task is typed otherwise *)
             let reply a = answer := Some a; Condition.signal answered in
             if Gui.button ui conv_x (fy - 2) 110 "Allow" then reply Agent.Yes;
             if Gui.button ui (conv_x + 120) (fy - 2) 110 "Deny" then reply Agent.No;
             if Gui.button ui (conv_x + 240) (fy - 2) 130 "Allow all" then reply Agent.All;
             Gui.label ~colour:Gui.muted ui (conv_x + 384) (fy + 3)
               "Allow all: no more questions for this window."
           | None ->
             (* the task *)
             let v = Gui.text_field ui 2 conv_x fy (conv_w - 128) st.input in
             let enter = List.exists (fun k -> k = "\r" || k = "\n") ui.keys in
             st.input <- v;
             let send = Gui.button ui (conv_x + conv_w - 116) (fy - 2) 116
                 (if st.running then "Working" else "Send") || enter in
             match session with
             | Some a when send && not st.running && String.trim st.input <> "" ->
               let task = String.trim st.input in
               st.input <- "";
               start st a task
             | _ -> ());
          Gui.label ~colour:Gui.muted ui conv_x (fy + 32)
            "Enter sends. A follow-up continues the conversation; what changes \
             things asks first.";
          ui.Gui.field <- 2));
  exit 0

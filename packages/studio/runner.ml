(* Running a program in Studio: Studio is its console (console/1, as a
   terminal window is: registered as studiorun<pid>, named to the program
   by MYNOS_CONSOLE). What the program writes comes to the output pane
   (escape sequences left out); a line typed in the pane answers its
   reads. Stop ends it. A program that opens a window opens it as
   anywhere. *)

let lock = Mutex.create ()
let output = Buffer.create 4096          (* what the program wrote *)
let input = Buffer.create 256            (* typed, waiting for a read *)
let pending : (int * int) list ref = ref []   (* reads: channel, max *)
let child = ref 0                         (* the program running, or 0 *)
let cols = ref 80

let reply ch s =
  (try Mynos.send ch s with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

(* the escape sequences of a terminal: not for a pane of text *)
let plain s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    (match s.[!i] with
     | '\027' when !i + 1 < n && s.[!i + 1] = '[' ->
       i := !i + 2;
       while !i < n && not (s.[!i] >= '@' && s.[!i] <= '~') do incr i done
     | '\r' -> ()
     | c -> Buffer.add_char b c);
    incr i
  done;
  Buffer.contents b

(* waiting reads get what was typed (under the lock) *)
let serve_reads () =
  pending := List.filter (fun (ch, max) ->
      if Buffer.length input > 0 then begin
        let k = min max (Buffer.length input) in
        let s = Buffer.sub input 0 k in
        let rest = Buffer.sub input k (Buffer.length input - k) in
        Buffer.clear input; Buffer.add_string input rest;
        reply ch (Console.reply (Console.Read 0) s); false
      end else true) !pending

let handle ch msg =
  match Console.decode msg with
  | Error answer -> reply ch answer
  | Ok (Console.Protocol.Request req) ->
    Mutex.protect lock (fun () ->
        let ok (type a) (r : a Console.request) (v : a) = reply ch (Console.reply r v) in
        match req with
        | Console.Read len -> pending := !pending @ [ (ch, max 1 len) ]; serve_reads ()
        | Console.Write data as r ->
          Buffer.add_string output (plain data);
          (* a pane keeps the last 64 KB *)
          if Buffer.length output > 65536 then begin
            let s = Buffer.sub output (Buffer.length output - 49152) 49152 in
            Buffer.clear output; Buffer.add_string output s
          end;
          ok r ()
        | Console.Mode _ as r -> ok r ()
        | Console.Keymap _ as r -> ok r Console.layout_us
        | Console.Foreground _ as r -> ok r ()
        | Console.Size as r -> ok r (!cols, 24)
        | Console.Ready as r -> ok r (Buffer.length input > 0))

let name () = Printf.sprintf "studiorun%d" (Mynos.getpid ())

let start_service () =
  let port = Mynos.register (name ()) in
  ignore (Domain.spawn (fun () ->
      while true do
        match Mynos.listen port with
        | ch ->
          (match Mynos.recv ~timeout:1.0 ch with
           | msg -> handle ch msg
           | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ()))
        | exception Mynos.Error _ -> ()
      done))

let alive () =
  !child > 0 && (match Mynos.process_info !child with
      | Some i -> i.Mynos.alive | None -> false | exception Mynos.Error _ -> false)

(* a program, its console here; its argument words after it *)
let run ?(args = []) program =
  Mutex.protect lock (fun () ->
      Buffer.clear output; Buffer.clear input;
      List.iter (fun (ch, _) -> reply ch (Console.reply (Console.Read 0) "")) !pending;
      pending := []);
  let env = Array.of_list (
      List.filter (fun kv ->
          not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                 [ "MYNOS_CONSOLE"; "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR"; "OCAMLLIB" ]))
        (Array.to_list (Mynos.environment ()))
      @ [ "MYNOS_CONSOLE=" ^ name (); "OCAMLLIB=/" ]) in
  child := Mynos.spawn ~env "ocamlrun" (Array.of_list ("ocamlrun" :: program :: args));
  !child

let stop () =
  if alive () then (try Mynos.kill !child with Mynos.Error _ -> ());
  Mutex.protect lock (fun () ->
      (* its reads end: the program is gone *)
      List.iter (fun (ch, _) -> reply ch (Console.reply (Console.Read 0) "")) !pending;
      pending := [])

(* a line typed in the pane *)
let type_line s =
  Mutex.protect lock (fun () ->
      Buffer.add_string output (s ^ "\n");
      Buffer.add_string input (s ^ "\n");
      serve_reads ())

let text () = Mutex.protect lock (fun () -> Buffer.contents output)

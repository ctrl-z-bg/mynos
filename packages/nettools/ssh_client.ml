(* The SSH client's protocol, after the transport: authentication (keys
   first, then the password), one session channel, its data both ways.
   The terminal is the caller's (ssh_main.ml). *)

open Ssh_wire
module C = Ssh_chan

exception Failed of string

type auth = {
  keys : Ssh_keys.key list;
  password : unit -> string option;     (* asked when needed; None: give up *)
  banner : string -> unit;
}

let authenticate tr ~user a =
  let send = Ssh_transport.send tr in
  send (byte Ssh_transport.service_request ^ str "ssh-userauth");
  let rec accept () =
    let p = Ssh_transport.recv tr in
    match Ssh_transport.msg_type p with
    | 6 -> ()
    | 7 -> accept ()                      (* EXT_INFO *)
    | _ -> raise (Failed "the server refused the ssh-userauth service") in
  accept ();
  let req meth rest = send (byte C.userauth_request ^ str user ^ str "ssh-connection" ^ str meth ^ rest) in
  (* an answer: Ok () success, Error methods *)
  let rec answer () =
    let p = Ssh_transport.recv tr in
    let r = reader ~pos:1 p in
    match Ssh_transport.msg_type p with
    | 52 -> Ok ()
    | 51 -> Error (get_names r)
    | 53 -> a.banner (get_str r); answer ()
    | 7 -> answer ()
    | n -> raise (Failed (Printf.sprintf "unexpected message %d while authenticating" n)) in
  req "none" "";
  match answer () with
  | Ok () -> ()
  | Error methods ->
    let methods = ref methods in
    let try_key (k : Ssh_keys.key) =
      List.mem "publickey" !methods &&
      let blob = Ssh_keys.blob k.pub in
      let signed = str (Ssh_transport.session_id tr) ^ byte C.userauth_request ^ str user
                   ^ str "ssh-connection" ^ str "publickey" ^ bool true ^ str Ssh_keys.alg ^ str blob in
      let signature = str Ssh_keys.alg ^ str (Curve25519.sign ~seed:k.seed signed) in
      req "publickey" (bool true ^ str Ssh_keys.alg ^ str blob ^ str signature);
      match answer () with Ok () -> true | Error m -> methods := m; false in
    if not (List.exists try_key a.keys) then begin
      let rec by_password n =
        if n = 0 || not (List.mem "password" !methods) then
          raise (Failed ("permission denied (" ^ String.concat "," !methods ^ ")"))
        else match a.password () with
          | None -> raise (Failed "no password")
          | Some pw ->
            req "password" (bool false ^ str pw);
            match answer () with
            | Ok () -> ()
            | Error m -> methods := m; by_password (n - 1) in
      by_password 3
    end

type session = {
  ch : C.t;
  mutable exit : int option;
}

(* a session: a shell (command None) or a command, with a terminal of
   [pty] (its type, columns, rows) or none *)
let open_session tr ~pty ~command =
  let send = Ssh_transport.send tr in
  let ch = C.create tr 0 in
  send (byte C.channel_open ^ str "session" ^ u32 0 ^ u32 C.our_window ^ u32 C.our_max);
  let rec opened () =
    let p = Ssh_transport.recv tr in
    let r = reader ~pos:1 p in
    match Ssh_transport.msg_type p with
    | 91 ->
      let _ours = get_u32 r in
      let peer = get_u32 r in
      let window = get_u32 r in
      let max = get_u32 r in
      C.set_peer ch ~peer ~window ~max
    | 92 ->
      let _ = get_u32 r in
      let _code = get_u32 r in
      raise (Failed ("the server refused the session: " ^ get_str r))
    | 80 -> let _ = get_str r in if get_bool r then send (byte C.request_failure); opened ()
    | _ -> opened () in
  opened ();
  let request kind rest = send (byte C.request ^ u32 ch.peer ^ str kind ^ bool true ^ rest) in
  let rec replied what =
    let p = Ssh_transport.recv tr in
    let r = reader ~pos:1 p in
    match Ssh_transport.msg_type p with
    | 99 -> ()
    | 100 -> raise (Failed ("the server refused " ^ what))
    | 93 -> let _ = get_u32 r in C.adjust ch (get_u32 r); replied what
    | 80 -> let _ = get_str r in if get_bool r then send (byte C.request_failure); replied what
    | _ -> replied what in
  (match pty with
   | Some (term, cols, rows) ->
     request "pty-req" (str term ^ u32 cols ^ u32 rows ^ u32 0 ^ u32 0 ^ str "\000");
     replied "a terminal"
   | None -> ());
  (* the reply comes in [run]: the command's output may come first *)
  (match command with
   | None -> request "shell" ""
   | Some c -> request "exec" (str c));
  { ch; exit = None }

let send_input s d = C.send_data s.ch d
let send_eof s = C.send_eof s.ch
let resize s cols rows =
  Ssh_transport.send s.ch.tr
    (byte C.request ^ u32 s.ch.peer ^ str "window-change" ^ bool false
     ^ u32 cols ^ u32 rows ^ u32 0 ^ u32 0)

(* the session's messages until it closes: its output to [output] and
   [errors]; the command's exit status (255 if the server gave none) *)
let run s ~output ~errors =
  let tr = s.ch.tr in
  let send = Ssh_transport.send tr in
  let rec loop () =
    let p = Ssh_transport.recv tr in
    let r = reader ~pos:1 p in
    match Ssh_transport.msg_type p with
    | 94 -> let _ = get_u32 r in let d = get_str r in
      output d; C.received s.ch (String.length d); loop ()
    | 95 -> let _ = get_u32 r in let _ = get_u32 r in let d = get_str r in
      errors d; C.received s.ch (String.length d); loop ()
    | 93 -> let _ = get_u32 r in C.adjust s.ch (get_u32 r); loop ()
    | 98 ->
      let _ = get_u32 r in
      let kind = get_str r in
      let want = get_bool r in
      if kind = "exit-status" then s.exit <- Some (get_u32 r)
      else if kind = "exit-signal" then s.exit <- Some 255;
      if want then send (byte C.failure ^ u32 s.ch.peer);
      loop ()
    | 96 | 99 -> loop ()
    | 100 -> C.gone s.ch; raise (Failed "the server refused the shell or the command")
    | 97 -> C.send_close s.ch; C.gone s.ch
    | 80 -> let _ = get_str r in if get_bool r then send (byte C.request_failure); loop ()
    | _ -> loop () in
  (try loop () with Ssh_transport.Disconnected _ when s.exit <> None -> ());
  C.gone s.ch;
  Option.value s.exit ~default:255

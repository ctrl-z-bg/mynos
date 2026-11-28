(* A connection to the SSH server, after the transport: the user's
   authentication (RFC 4252: "password", "publickey" with ssh-ed25519)
   and the session channels (RFC 4254: pty-req, shell, exec,
   window-change, exit-status). What a session runs is the backend's: in
   MyNOS sh (sshd.ml), in the host's test something else. *)

open Ssh_wire
module C = Ssh_chan

type session = {
  input : string -> unit;                 (* the client's bytes *)
  input_eof : unit -> unit;
  resize : int -> int -> unit;            (* columns, rows *)
  stop : unit -> unit;                    (* the client went away *)
}

type backend = {
  password : user:string -> string -> bool;
  key : user:string -> string -> bool;    (* an Ed25519 public key *)
  failed : unit -> unit;                  (* after a wrong password: a pause *)
  start : user:string -> pty:(string * int * int) option -> command:string option ->
    output:(string -> unit) -> errors:(string -> unit) -> exited:(int -> unit) -> session;
  log : string -> unit;
}

exception Refused of string

let auth tr b =
  let send = Ssh_transport.send tr in
  let methods = byte C.userauth_failure ^ names [ "publickey"; "password" ] ^ bool false in
  let p = Ssh_transport.recv tr in
  (match Ssh_transport.msg_type p with
   | 5 when get_str (reader ~pos:1 p) = "ssh-userauth" ->
     send (byte Ssh_transport.service_accept ^ str "ssh-userauth")
   | _ -> raise (Refused "expected the ssh-userauth service"));
  let tries = ref 0 in
  let rec loop () =
    let p = Ssh_transport.recv tr in
    if Ssh_transport.msg_type p <> C.userauth_request then raise (Refused "expected authentication");
    let r = reader ~pos:1 p in
    let user = get_str r in
    let service = get_str r in
    let meth = get_str r in
    let fail_once () =
      incr tries;
      if !tries >= 6 then raise (Refused ("too many tries for " ^ user));
      send methods; loop () in
    match meth with
    | "password" ->
      let _change = get_bool r in
      let pw = get_str r in
      if service = "ssh-connection" && b.password ~user pw then begin
        b.log (Printf.sprintf "%s: password accepted" user); send (byte C.userauth_success); user
      end else begin
        b.log (Printf.sprintf "%s: wrong password" user); b.failed (); fail_once ()
      end
    | "publickey" ->
      let has_sig = get_bool r in
      let alg = get_str r in
      let blob = get_str r in
      (match alg = Ssh_keys.alg, Ssh_keys.pub_of_blob blob with
       | true, Some pub when b.key ~user pub ->
         if not has_sig then begin
           send (byte C.userauth_pk_ok ^ str alg ^ str blob); loop ()
         end else begin
           let signed = str (Ssh_transport.session_id tr) ^ byte C.userauth_request ^ str user
                        ^ str service ^ str "publickey" ^ bool true ^ str alg ^ str blob in
           let sr = reader (get_str r) in
           let sig_alg = get_str sr in
           let signature = get_str sr in
           if service = "ssh-connection" && sig_alg = Ssh_keys.alg
              && Curve25519.verify ~pub signed signature then begin
             b.log (Printf.sprintf "%s: key %s accepted" user (Ssh_keys.fingerprint pub));
             send (byte C.userauth_success); user
           end else fail_once ()
         end
       | _ -> if has_sig then fail_once () else (send methods; loop ()))
    | _ -> send methods; loop () in
  loop ()

type chan = {
  ch : C.t;
  mutable pty : (string * int * int) option;
  mutable session : session option;
}

let rec serve ?(authenticated = ignore) tr b =
  Fun.protect ~finally:(fun () -> Ssh_transport.shutdown tr) (fun () -> serve_ ~authenticated tr b)

and serve_ ~authenticated tr b =
  let user = auth tr b in
  authenticated ();
  let chans : (int, chan) Hashtbl.t = Hashtbl.create 4 in
  let lock = Mutex.create () in
  let find n = Mutex.lock lock; let c = Hashtbl.find_opt chans n in Mutex.unlock lock; c in
  let next = ref 0 in
  let send = Ssh_transport.send tr in
  let finish () =
    Mutex.lock lock;
    let all = Hashtbl.fold (fun _ c acc -> c :: acc) chans [] in
    Mutex.unlock lock;
    List.iter (fun c -> C.gone c.ch; Option.iter (fun s -> s.stop ()) c.session) all in
  let reply want ok n = if want then send (byte (if ok then C.success else C.failure) ^ u32 n) in
  let start c ~command want =
    if c.session <> None then reply want false c.ch.peer else begin
      let ch = c.ch in
      let exited code =
        (try
           send (byte C.request ^ u32 ch.peer ^ str "exit-status" ^ bool false ^ u32 code);
           C.send_eof ch
         with _ -> ());
        C.send_close ch in
      match b.start ~user ~pty:c.pty ~command
              ~output:(fun s -> ignore (C.send_data ch s))
              ~errors:(fun s -> ignore (C.send_data ~stderr:true ch s)) ~exited with
      | s -> c.session <- Some s; reply want true ch.peer
      | exception e -> b.log ("cannot start: " ^ Printexc.to_string e); reply want false ch.peer
    end in
  let rec loop () =
    let p = Ssh_transport.recv tr in
    let r = reader ~pos:1 p in
    (match Ssh_transport.msg_type p with
     | 90 ->
       let kind = get_str r in
       let peer = get_u32 r in
       let window = get_u32 r in
       let max = get_u32 r in
       if kind = "session" then begin
         let n = !next in incr next;
         let ch = C.create tr n in
         C.set_peer ch ~peer ~window ~max;
         Mutex.lock lock; Hashtbl.replace chans n { ch; pty = None; session = None }; Mutex.unlock lock;
         send (byte C.open_confirmation ^ u32 peer ^ u32 n ^ u32 C.our_window ^ u32 C.our_max)
       end else
         send (byte C.open_failure ^ u32 peer ^ u32 3 ^ str ("no " ^ kind ^ " channels") ^ str "")
     | 98 ->
       let n = get_u32 r in
       let kind = get_str r in
       let want = get_bool r in
       (match find n with
        | None -> ()
        | Some c ->
          match kind with
          | "pty-req" ->
            let term = get_str r in
            let cols = get_u32 r in
            let rows = get_u32 r in
            c.pty <- Some (term, (if cols > 0 then cols else 80), (if rows > 0 then rows else 24));
            reply want true c.ch.peer
          | "shell" -> start c ~command:None want
          | "exec" -> start c ~command:(Some (get_str r)) want
          | "window-change" ->
            let cols = get_u32 r in
            let rows = get_u32 r in
            Option.iter (fun s -> s.resize cols rows) c.session
          | _ -> reply want false c.ch.peer)
     | 94 ->
       let n = get_u32 r in
       let d = get_str r in
       Option.iter (fun c ->
           C.received c.ch (String.length d);
           Option.iter (fun s -> s.input d) c.session) (find n)
     | 96 -> Option.iter (fun c -> Option.iter (fun s -> s.input_eof ()) c.session) (find (get_u32 r))
     | 97 ->
       let n = get_u32 r in
       Option.iter (fun c ->
           C.send_close c.ch; C.gone c.ch;
           Option.iter (fun s -> s.stop ()) c.session;
           Mutex.lock lock; Hashtbl.remove chans n; Mutex.unlock lock) (find n)
     | 93 ->
       let n = get_u32 r in
       let k = get_u32 r in
       Option.iter (fun c -> C.adjust c.ch k) (find n)
     | 80 ->
       let _name = get_str r in
       if get_bool r then send (byte C.request_failure)
     | _ -> ());
    loop () in
  Fun.protect ~finally:finish loop

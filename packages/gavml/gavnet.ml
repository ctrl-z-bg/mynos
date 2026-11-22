(* Gavnet: GAV's network game, as the original plays it (net/Net.h,
   NetServer.cpp, NetClient.cpp), over UDP, port 7145: GavML and GAV for
   Linux can play together.

   - A client registers: 5 bytes (id, players left, players right, big
     background, winning score), its id 0x80 for the left side or 0x40
     for the right. The server answers the same 5 bytes, the id with the
     player's number in its 6 low bits, and the sides' players.
   - Then the client sends its keys, 2 bytes (its id, left 1 | right 2 |
     jump 4), and the server sends, at each frame it draws, a snapshot of
     32 bytes: two players a side and the ball, each x, y and a state
     (16 bits, big-endian; the ball's state unused), then the scores.

   A player's number in GavML: its number on its side twice, plus 1 on the
   right. The network is MyNOS's (module Net); each side's receiving is a
   thread of its own. *)

let port = 7145
let left_flag = 0x80 and right_flag = 0x40
let snapshot_size = 32

type keys = { left : bool; right : bool; jump : bool }
let no_keys = { left = false; right = false; jump = false }

(* the player of a client id: (index lsl 1) lor side *)
let player_of_id b = ((b land 0x3F) lsl 1) lor (if b land left_flag <> 0 then 0 else 1)

let register_packet ~id ~nl ~nr ~winning =
  let b = Bytes.make 5 '\000' in
  Bytes.set_uint8 b 0 id; Bytes.set_uint8 b 1 nl; Bytes.set_uint8 b 2 nr;
  Bytes.set_uint8 b 4 winning;
  Bytes.to_string b

(* ---- snapshots ---- *)

type snapshot = {
  players : (int * int * int) array;   (* left 1, left 2, right 1, right 2: x, y, state *)
  ball_xy : int * int;
  scores : int * int;
}

let encode s =
  let b = Bytes.make snapshot_size '\000' in
  let put o (x, y, f) =
    Bytes.set_uint16_be b o (x land 0xFFFF); Bytes.set_uint16_be b (o + 2) (y land 0xFFFF);
    Bytes.set_uint16_be b (o + 4) (f land 0xFFFF) in
  Array.iteri (fun i p -> put (i * 6) p) s.players;
  put 24 (fst s.ball_xy, snd s.ball_xy, 0);
  Bytes.set_uint8 b 30 (fst s.scores land 0xFF);
  Bytes.set_uint8 b 31 (snd s.scores land 0xFF);
  Bytes.to_string b

let signed16 v = if v >= 0x8000 then v - 0x10000 else v

let decode d =
  let get o = (signed16 (String.get_uint16_be d o), signed16 (String.get_uint16_be d (o + 2)),
               String.get_uint16_be d (o + 4)) in
  let bx, by, _ = get 24 in
  { players = Array.init 4 (fun i -> get (i * 6)); ball_xy = (bx, by);
    scores = (String.get_uint8 d 30, String.get_uint8 d 31) }

(* ---- the server: the game runs here ---- *)

type server = {
  net : Net.t;
  sock : int;
  remote : bool array;                       (* the places played from the network *)
  clients : (int * string * int) list ref;   (* player, address, port *)
  inputs : keys array;
  lock : Mutex.t;
  mutable stop : bool;
}

let missing s =
  Mutex.protect s.lock (fun () ->
      Array.fold_left (fun n r -> if r then n + 1 else n) 0 s.remote - List.length !(s.clients))

let serve ~remote ~nl ~nr ~winning =
  let net = Net.connect () in
  let sock = Net.call net (Net.Udp_bind port) in
  Net.call net (Net.Set_timeout (sock, 500));
  let s = { net; sock; remote; clients = ref []; inputs = Array.make 4 no_keys;
            lock = Mutex.create (); stop = false } in
  ignore (Thread.create (fun () ->
      (* a connection of its own: calls from two threads, one each *)
      let rnet = Net.connect () in
      while not s.stop do
        match Net.call rnet (Net.Recv_from (sock, 64)) with
        | exception _ -> ()                        (* the timeout: look at stop *)
        | addr, p, d when String.length d = 5 ->
          (* a client registering: the first free network place of its side *)
          let flag = String.get_uint8 d 0 in
          let side = if flag land left_flag <> 0 then 0 else if flag land right_flag <> 0 then 1 else -1 in
          let answer = Mutex.protect s.lock (fun () ->
              match List.find_opt (fun (_, a, q) -> a = addr && q = p) !(s.clients) with
              | Some (pl, _, _) -> Some pl                (* registered already: again *)
              | None when side >= 0 ->
                let free = List.find_opt (fun i ->
                    let pl = (i lsl 1) lor side in
                    s.remote.(pl) && not (List.exists (fun (q, _, _) -> q = pl) !(s.clients)))
                    [ 0; 1 ] in
                Option.map (fun i ->
                    let pl = (i lsl 1) lor side in
                    s.clients := !(s.clients) @ [ (pl, addr, p) ]; pl) free
              | None -> None) in
          (match answer with
           | Some pl ->
             let id = (if pl land 1 = 0 then left_flag else right_flag) lor (pl lsr 1) in
             (try ignore (Net.call rnet (Net.Send_to (sock, addr, p,
                                                       register_packet ~id ~nl ~nr ~winning)))
              with _ -> ())
           | None -> ())
        | _, _, d when String.length d = 2 ->
          let pl = player_of_id (String.get_uint8 d 0) and c = String.get_uint8 d 1 in
          if pl < 4 then
            Mutex.protect s.lock (fun () ->
                s.inputs.(pl) <- { left = c land 1 <> 0; right = c land 2 <> 0; jump = c land 4 <> 0 })
        | _ -> ()
      done) ());
  s

let input s pl = Mutex.protect s.lock (fun () -> s.inputs.(pl))

let send_snapshot s snap =
  let d = encode snap in
  List.iter (fun (_, addr, p) ->
      try ignore (Net.call s.net (Net.Send_to (s.sock, addr, p, d))) with _ -> ())
    (Mutex.protect s.lock (fun () -> !(s.clients)))

let close_server s =
  s.stop <- true;
  (try Net.call s.net (Net.Close s.sock) with _ -> ())

(* ---- the client: the game runs at the server, here it is shown ---- *)

type client = {
  cnet : Net.t;
  csock : int;
  addr : string;
  cport : int;
  id : int;
  nl : int;
  nr : int;
  latest : string option ref;
  clock : Mutex.t;
  mutable cstop : bool;
}

(* "host" or "host:port": registered on this side, or why not *)
let join ~server ~left =
  let host, p = match String.index_opt server ':' with
    | Some i -> (String.sub server 0 i,
                 Option.value (int_of_string_opt (String.sub server (i + 1) (String.length server - i - 1)))
                   ~default:port)
    | None -> (server, port) in
  match Net.connect () with
  | exception _ -> Error "no network"
  | net ->
    let addr =
      if String.for_all (fun c -> c = '.' || (c >= '0' && c <= '9')) host then host
      else (try Net.call net (Net.Resolve host) with _ -> host) in
    match Net.call net (Net.Udp_bind 0) with
    | exception Ipc.Remote_error (_, m) -> Error m
    | sock ->
      Net.call net (Net.Set_timeout (sock, 1000));
      let flag = if left then left_flag else right_flag in
      (* asked again every second, for ten *)
      let rec ask n =
        if n = 0 then Error ("no answer from " ^ addr ^ ":" ^ string_of_int p)
        else begin
          (try ignore (Net.call net (Net.Send_to (sock, addr, p, register_packet ~id:flag ~nl:0 ~nr:0 ~winning:0)))
           with _ -> ());
          match Net.call net (Net.Recv_from (sock, 64)) with
          | _, _, d when String.length d = 5 ->
            Ok { cnet = net; csock = sock; addr; cport = p; id = String.get_uint8 d 0;
                 nl = String.get_uint8 d 1; nr = String.get_uint8 d 2; latest = ref None;
                 clock = Mutex.create (); cstop = false }
          | _ -> ask (n - 1)
          | exception _ -> ask (n - 1)
        end in
      match ask 10 with
      | Error m -> (try Net.call net (Net.Close sock) with _ -> ()); Error m
      | Ok c ->
        ignore (Thread.create (fun () ->
            let rnet = Net.connect () in
            while not c.cstop do
              match Net.call rnet (Net.Recv_from (sock, 64)) with
              | _, _, d when String.length d = snapshot_size ->
                Mutex.protect c.clock (fun () -> c.latest := Some d)
              | _ -> ()
              | exception _ -> ()
            done) ());
        Ok c

let snapshot c = Mutex.protect c.clock (fun () -> let d = !(c.latest) in c.latest := None; d)

let send_keys c k =
  let b = Bytes.make 2 '\000' in
  Bytes.set_uint8 b 0 c.id;
  Bytes.set_uint8 b 1 ((if k.left then 1 else 0) lor (if k.right then 2 else 0) lor (if k.jump then 4 else 0));
  try ignore (Net.call c.cnet (Net.Send_to (c.csock, c.addr, c.cport, Bytes.to_string b))) with _ -> ()

let close_client c =
  c.cstop <- true;
  (try Net.call c.cnet (Net.Close c.csock) with _ -> ())

(* this machine's address, to say to the others (asked once) *)
let my_address =
  let known = ref None in
  fun () -> match !known with
    | Some a -> a
    | None ->
      let a = try (Net.call (Net.connect ()) Net.Config).Net.address with _ -> "?" in
      known := Some a; a

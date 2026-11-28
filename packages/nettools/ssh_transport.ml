(* SSH's transport (RFC 4253): the identification lines, the binary
   packets, the key exchange, the keys. One choice for each algorithm,
   OpenSSH's first since 2014:

     kex      curve25519-sha256 (RFC 8731), and OpenSSH's strict kex
              (kex-strict-*-v00@openssh.com: Terrapin's mitigation)
     host key ssh-ed25519 (RFC 8709)
     cipher   chacha20-poly1305@openssh.com (OpenSSH's PROTOCOL.chacha20poly1305)
     compression none

   The connection is the caller's: two functions, to read some bytes and
   to write them. One thread reads (recv); any may send, and send never
   waits: the packets go into a queue that a thread of the transport's
   own writes out. (If the reader could wait to write, both ends' readers
   could wait for each other with both sockets full: the window adjusts
   a reader sends would never go.) A key exchange asked for by the peer
   later (OpenSSH rekeys after about 1 GB) is answered by the reader: the
   others' packets are held back until it is over. *)

open Ssh_wire

exception Disconnected of string

type io = {
  read : unit -> string;        (* some bytes; "" at the end *)
  write : string -> unit;
  close : unit -> unit;
}

type role = Client | Server

(* message numbers *)
let disconnect = 1 and ignore_ = 2 and unimplemented = 3 and debug_ = 4
let service_request = 5 and service_accept = 6
let kexinit = 20 and newkeys = 21 and kex_ecdh_init = 30 and kex_ecdh_reply = 31

let version = "SSH-2.0-MyNOS_nettools_1.0"

type dir = {
  mutable seq : int;
  mutable keys : (string * string) option;   (* main key (K_2), length key (K_1) *)
}

type item = Packet of string | Newkeys of (string * string) | Close

type t = {
  role : role;
  io : io;
  mutable buf : string;           (* bytes read, not yet used *)
  mutable pos : int;
  tx : dir;
  rx : dir;
  lock : Mutex.t;                 (* the queue's *)
  more : Condition.t;
  queue : item Queue.t;           (* for the writer *)
  held : string Queue.t;          (* sent during a key exchange *)
  mutable kexing : bool;
  mutable broken : string option; (* why the writer stopped *)
  mutable writer : Thread.t option;
  mutable v_c : string;
  mutable v_s : string;
  mutable session_id : string;
  mutable strict : bool;
  mutable host_pub : string;      (* the server's key *)
  host_seed : string;             (* a server's secret *)
  check_host : string -> bool;    (* a client's: whether it trusts the key *)
}

let fail m = raise (Disconnected m)

(* {1 Bytes in} *)

let fill t =
  let s = t.io.read () in
  if s = "" then fail "the connection was closed";
  t.buf <- String.sub t.buf t.pos (String.length t.buf - t.pos) ^ s;
  t.pos <- 0

let read_exact t n =
  while String.length t.buf - t.pos < n do fill t done;
  let s = String.sub t.buf t.pos n in
  t.pos <- t.pos + n; s

let read_line t =
  let b = Buffer.create 64 in
  let rec go () =
    if Buffer.length b > 255 then fail "identification line too long";
    match read_exact t 1 with
    | "\n" -> ()
    | c -> Buffer.add_string b c; go () in
  go ();
  let l = Buffer.contents b in
  if String.ends_with ~suffix:"\r" l then String.sub l 0 (String.length l - 1) else l

(* {1 Packets} *)

let ctr0 = String.make 8 '\000'
(* sequence numbers wrap at 2^32; on i386 an int stops at 2^30 - 1, a
   billion packets: before then OpenSSH has rekeyed, and with strict kex
   the numbers start again from 0 *)
let mask32 = if Sys.int_size > 32 then (1 lsl 32) - 1 else max_int
let be64 n = "\000\000\000\000" ^ u32 n

let ciphers key seq =
  Chacha20.create ~key ~iv:(ctr0 ^ be64 seq)

let max_packet = 262144

let send_packet t payload =
  let d = t.tx in
  let aead = d.keys <> None in
  let base = 1 + String.length payload + (if aead then 0 else 4) in
  let pad = let p = 8 - base mod 8 in if p < 4 then p + 8 else p in
  let len = 1 + String.length payload + pad in
  let body = byte pad ^ payload ^ String.make pad '\000' in
  (match d.keys with
   | None -> t.io.write (u32 len ^ body)
   | Some (k2, k1) ->
     let lenc = Chacha20.xor (ciphers k1 d.seq) (u32 len) in
     let c = ciphers k2 d.seq in
     let poly = Chacha20.stream c 32 in
     let enc = Chacha20.xor c body in
     t.io.write (lenc ^ enc ^ Poly1305.mac ~key:poly (lenc ^ enc)));
  d.seq <- (d.seq + 1) land mask32

let recv_packet t =
  let d = t.rx in
  let len_of s =
    let n = get_u32 (reader s) in
    if n < 5 || n > max_packet then fail "bad packet length" else n in
  let body =
    match d.keys with
    | None ->
      let n = len_of (read_exact t 4) in
      read_exact t n
    | Some (k2, k1) ->
      let lenc = read_exact t 4 in
      let n = len_of (Chacha20.xor (ciphers k1 d.seq) lenc) in
      let enc = read_exact t n in
      let tag = read_exact t 16 in
      let c = ciphers k2 d.seq in
      let poly = Chacha20.stream c 32 in
      if not (Poly1305.equal tag (Poly1305.mac ~key:poly (lenc ^ enc))) then
        fail "a packet's MAC is wrong";
      Chacha20.xor c enc in
  d.seq <- (d.seq + 1) land mask32;
  let pad = Char.code body.[0] in
  if pad + 1 > String.length body then fail "bad padding";
  String.sub body 1 (String.length body - pad - 1)

let msg_type p = if p = "" then -1 else Char.code p.[0]

(* {1 Key exchange} *)

let kex_algs = [ "curve25519-sha256"; "curve25519-sha256@libssh.org" ]
let cipher = "chacha20-poly1305@openssh.com"

let kexinit_payload t =
  let strict = match t.role with Client -> "kex-strict-c-v00@openssh.com"
                                | Server -> "kex-strict-s-v00@openssh.com" in
  let first = t.session_id = "" in
  byte kexinit ^ random 16
  ^ names (kex_algs @ (if first then [ strict ] else []))
  ^ names [ Ssh_keys.alg ]
  ^ names [ cipher ] ^ names [ cipher ]
  ^ names [ "hmac-sha2-256" ] ^ names [ "hmac-sha2-256" ]
  ^ names [ "none" ] ^ names [ "none" ]
  ^ names [] ^ names [] ^ bool false ^ u32 0

let negotiate t ~ours ~theirs =
  let client, server = match t.role with Client -> ours, theirs | Server -> theirs, ours in
  let lists s = let r = reader ~pos:17 s in List.init 10 (fun _ -> get_names r) in
  let c = lists client and s = lists server in
  let pick i what =
    match List.find_opt (fun a -> List.mem a (List.nth s i)) (List.nth c i) with
    | Some a -> a
    | None -> fail (Printf.sprintf "no %s in common (the peer offers %s)" what
                      (String.concat "," (List.nth (if t.role = Client then s else c) i))) in
  ignore (pick 0 "key exchange"); ignore (pick 1 "host key type");
  ignore (pick 2 "cipher"); ignore (pick 3 "cipher");
  ignore (pick 6 "compression"); ignore (pick 7 "compression");
  if t.session_id = "" then
    t.strict <- (match t.role with
        | Client -> List.mem "kex-strict-s-v00@openssh.com" (List.nth s 0)
        | Server -> List.mem "kex-strict-c-v00@openssh.com" (List.nth c 0));
  let r = reader ~pos:17 theirs in
  for _ = 1 to 10 do ignore (get_names r) done;
  if get_bool r then fail "the peer guessed the key exchange (not supported)"

(* the next packet of the key exchange: in the first, with strict kex,
   nothing else may come *)
let rec kex_packet t =
  let p = recv_packet t in
  match msg_type p with
  | 1 -> fail ("the peer disconnected: " ^ (try get_str (reader ~pos:5 p) with Bad _ -> ""))
  | 2 | 3 | 4 when not (t.strict && t.session_id = "") -> kex_packet t
  | _ -> p

let derive k h sid letter =
  let k1 = Sha2.sha256 (k ^ h ^ letter ^ sid) in
  k1 ^ Sha2.sha256 (k ^ h ^ k1)

(* the exchange, after both KEXINITs (ours sent, theirs [peer]); what it
   sends goes through [out] *)
let exchange t ~out ~ours ~peer =
  negotiate t ~ours ~theirs:peer;
  let i_c, i_s = match t.role with Client -> ours, peer | Server -> peer, ours in
  let secret = random 32 in
  let mine = Curve25519.x25519_public secret in
  let shared q =
    let k = Curve25519.x25519 secret q in
    if k = String.make 32 '\000' then fail "bad key exchange value";
    mpint_of_bytes k in
  let hash k_s q_c q_s k =
    Sha2.sha256 (str t.v_c ^ str t.v_s ^ str i_c ^ str i_s ^ str k_s ^ str q_c ^ str q_s ^ k) in
  let k, h =
    match t.role with
    | Client ->
      out (Packet (byte kex_ecdh_init ^ str mine));
      let p = kex_packet t in
      if msg_type p <> kex_ecdh_reply then fail "expected the server's key exchange reply";
      let r = reader ~pos:1 p in
      let k_s = get_str r in
      let q_s = get_str r in
      let signature = get_str r in
      if String.length q_s <> 32 then fail "bad key exchange value";
      let pub = match Ssh_keys.pub_of_blob k_s with
        | Some p -> p | None -> fail "the server's host key is not ssh-ed25519" in
      let k = shared q_s in
      let h = hash k_s mine q_s k in
      let sr = reader signature in
      if (try get_str sr with Bad _ -> "") <> Ssh_keys.alg
      || not (Curve25519.verify ~pub h (try get_str sr with Bad _ -> "")) then
        fail "the server's signature is wrong";
      if t.session_id <> "" && pub <> t.host_pub then fail "the server's host key changed";
      if t.session_id = "" && not (t.check_host pub) then fail "host key not accepted";
      t.host_pub <- pub;
      k, h
    | Server ->
      let p = kex_packet t in
      if msg_type p <> kex_ecdh_init then fail "expected the client's key exchange";
      let q_c = get_str (reader ~pos:1 p) in
      if String.length q_c <> 32 then fail "bad key exchange value";
      let k_s = Ssh_keys.blob t.host_pub in
      let k = shared q_c in
      let h = hash k_s q_c mine k in
      let signature = str Ssh_keys.alg ^ str (Curve25519.sign ~seed:t.host_seed h) in
      out (Packet (byte kex_ecdh_reply ^ str k_s ^ str mine ^ str signature));
      k, h in
  if t.session_id = "" then t.session_id <- h;
  let key c = let d = derive k h t.session_id c in String.sub d 0 32, String.sub d 32 32 in
  let c2s = key "C" and s2c = key "D" in
  let tx_keys, rx_keys = match t.role with Client -> c2s, s2c | Server -> s2c, c2s in
  out (Newkeys tx_keys);
  if msg_type (kex_packet t) <> newkeys then fail "expected NEWKEYS";
  t.rx.keys <- Some rx_keys;
  if t.strict then t.rx.seq <- 0

(* {1 The connection} *)

(* an item out: NEWKEYS then our new keys *)
let write_item t = function
  | Packet p -> send_packet t p
  | Newkeys k ->
    send_packet t (byte newkeys);
    t.tx.keys <- Some k;
    if t.strict then t.tx.seq <- 0
  | Close -> t.io.close ()

let writer t =
  let rec loop () =
    Mutex.lock t.lock;
    while Queue.is_empty t.queue do Condition.wait t.more t.lock done;
    let item = Queue.pop t.queue in
    Mutex.unlock t.lock;
    match write_item t item with
    | () -> if item <> Close then loop ()
    | exception e ->
      Mutex.lock t.lock;
      t.broken <- Some (match e with Disconnected m -> m | e -> Printexc.to_string e);
      Queue.clear t.queue;
      Mutex.unlock t.lock;
      (try t.io.close () with _ -> ()) in
  loop ()

let push t item = Queue.push item t.queue; Condition.signal t.more

let create ?(host_seed = "") ?(check_host = fun _ -> false) role io =
  let t = { role; io; buf = ""; pos = 0;
            tx = { seq = 0; keys = None }; rx = { seq = 0; keys = None };
            lock = Mutex.create (); more = Condition.create (); queue = Queue.create ();
            held = Queue.create (); kexing = false; broken = None; writer = None;
            v_c = ""; v_s = ""; session_id = ""; strict = false;
            host_pub = (if host_seed = "" then "" else Curve25519.ed25519_public host_seed);
            host_seed; check_host } in
  io.write (version ^ "\r\n");
  (* the peer's line: lines before it (a server's banner) are skipped *)
  let rec peer n =
    if n > 50 then fail "no SSH identification line";
    let l = read_line t in
    if String.starts_with ~prefix:"SSH-" l then l else peer (n + 1) in
  let theirs = peer 0 in
  if not (String.starts_with ~prefix:"SSH-2.0-" theirs || String.starts_with ~prefix:"SSH-1.99-" theirs)
  then fail ("not SSH 2: " ^ theirs);
  (match role with Client -> t.v_c <- version; t.v_s <- theirs
                 | Server -> t.v_c <- theirs; t.v_s <- version);
  let ours = kexinit_payload t in
  send_packet t ours;
  let peer = recv_packet t in
  if msg_type peer <> kexinit then fail "expected KEXINIT";
  exchange t ~out:(write_item t) ~ours ~peer;
  t.writer <- Some (Thread.create writer t);
  t

(* a packet to the peer, queued: it never waits *)
let send t payload =
  Mutex.lock t.lock;
  let broken = t.broken in
  if broken = None then begin
    if t.kexing then Queue.push payload t.held else push t (Packet payload)
  end;
  Mutex.unlock t.lock;
  match broken with Some m -> fail m | None -> ()

(* the next message for the layers above: the transport's own are dealt
   with here (a key exchange the peer starts, too) *)
let rec recv t =
  let p = recv_packet t in
  match msg_type p with
  | 1 ->
    let r = reader ~pos:1 p in
    let _code = (try get_u32 r with Bad _ -> 0) in
    fail (try get_str r with Bad _ -> "disconnected")
  | 2 | 3 | 4 -> recv t
  | 20 ->
    (* the others' packets wait; ours go first, in order *)
    let out item = Mutex.lock t.lock; push t item; Mutex.unlock t.lock in
    Mutex.lock t.lock; t.kexing <- true; Mutex.unlock t.lock;
    let ours = kexinit_payload t in
    out (Packet ours);
    exchange t ~out ~ours ~peer:p;
    Mutex.lock t.lock;
    t.kexing <- false;
    Queue.iter (fun q -> push t (Packet q)) t.held;
    Queue.clear t.held;
    Mutex.unlock t.lock;
    recv t
  | _ -> p

(* the writer told to stop, after what it has, and waited for: the
   connection's end (closed by the writer, once) *)
let shutdown t =
  Mutex.lock t.lock;
  if t.broken = None then (push t Close; t.broken <- Some "closed");
  Mutex.unlock t.lock;
  Option.iter Thread.join t.writer

(* DISCONNECT, written out, and the connection closed *)
let disconnect_with t reason =
  Mutex.lock t.lock;
  if t.broken = None then begin
    push t (Packet (byte disconnect ^ u32 11 ^ str reason ^ str ""));
    push t Close;
    t.broken <- Some "closed"
  end;
  Mutex.unlock t.lock;
  match t.writer with
  | Some w -> Thread.join w
  | None -> (try t.io.close () with _ -> ())

let session_id t = t.session_id
let host_key t = t.host_pub

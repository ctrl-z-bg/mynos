(* SSH's channels (RFC 4254), what client and server share: the message
   numbers, and data sent within the window the peer gives. *)

open Ssh_wire

let global_request = 80 and request_success = 81 and request_failure = 82
let channel_open = 90 and open_confirmation = 91 and open_failure = 92
let window_adjust = 93 and data = 94 and extended_data = 95 and eof = 96
let close = 97 and request = 98 and success = 99 and failure = 100
let userauth_request = 50 and userauth_failure = 51 and userauth_success = 52
let userauth_banner = 53 and userauth_pk_ok = 60

(* what we give the peer: our window, our largest packet *)
let our_window = 2 * 1024 * 1024
let our_max = 32768

type t = {
  tr : Ssh_transport.t;
  ours : int;                     (* our number for it *)
  mutable peer : int;             (* the peer's *)
  mutable window : int;           (* bytes we may still send *)
  mutable max : int;              (* the peer's largest data *)
  mutable consumed : int;         (* bytes received since our last adjust *)
  mutable closed : bool;          (* CLOSE sent *)
  mutable eof_sent : bool;
  m : Mutex.t;
  c : Condition.t;
}

let create tr ours = {
  tr; ours; peer = 0; window = 0; max = our_max; consumed = 0; closed = false; eof_sent = false;
  m = Mutex.create (); c = Condition.create () }

let locked ch f = Mutex.lock ch.m; Fun.protect ~finally:(fun () -> Mutex.unlock ch.m) f

let set_peer ch ~peer ~window ~max =
  locked ch (fun () ->
      ch.peer <- peer; ch.window <- window; ch.max <- (if max <= 0 then our_max else min max our_max);
      Condition.broadcast ch.c)

let adjust ch n =
  locked ch (fun () ->
      ch.window <- (if ch.window > max_int - n then max_int else ch.window + n);
      Condition.broadcast ch.c)

(* bytes to the peer, waiting for room in its window; false once the
   channel is closed *)
let send_data ?(stderr = false) ch s =
  let n = String.length s in
  let rec go off =
    if off >= n then true else begin
      let take = locked ch (fun () ->
          while ch.window <= 0 && not ch.closed do Condition.wait ch.c ch.m done;
          if ch.closed then 0 else begin
            let k = min (min ch.window ch.max) (n - off) in
            ch.window <- ch.window - k; k
          end) in
      if take = 0 then false else begin
        let chunk = String.sub s off take in
        Ssh_transport.send ch.tr
          (if stderr then byte extended_data ^ u32 ch.peer ^ u32 1 ^ str chunk
           else byte data ^ u32 ch.peer ^ str chunk);
        go (off + take)
      end
    end in
  go 0

(* bytes from the peer, used: our window again, by halves *)
let received ch n =
  let give = locked ch (fun () ->
      ch.consumed <- ch.consumed + n;
      if ch.consumed >= our_window / 2 then (let g = ch.consumed in ch.consumed <- 0; g) else 0) in
  if give > 0 then Ssh_transport.send ch.tr (byte window_adjust ^ u32 ch.peer ^ u32 give)

let send_eof ch =
  let go = locked ch (fun () -> let g = not ch.eof_sent && not ch.closed in ch.eof_sent <- true; g) in
  if go then Ssh_transport.send ch.tr (byte eof ^ u32 ch.peer)

let send_close ch =
  let go = locked ch (fun () ->
      let g = not ch.closed in ch.closed <- true; Condition.broadcast ch.c; g) in
  if go then (try Ssh_transport.send ch.tr (byte close ^ u32 ch.peer) with _ -> ())

(* the peer closed or the connection ended: writers stop waiting *)
let gone ch = locked ch (fun () -> ch.closed <- true; Condition.broadcast ch.c)

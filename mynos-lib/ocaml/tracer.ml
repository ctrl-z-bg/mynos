(* The event recorder and its player: see trace.mli. The event layout is
   the kernel's (mynos-core/kernel/trace.h). *)

external control : int -> int = "caml_mynos_trace_control"
external read_raw : int -> string = "caml_mynos_trace_read"
external info_raw : unit -> string = "caml_mynos_trace_info"

type kind = Process | Spawn | Exit | Connect | Send | Recv | Free | Irq | Other of int

type event = {
  seq : int; time : float; kind : kind; pid : int; tid : int; peer : int;
  channel : int; size : int; arg : int; data : string;
}

type recording = {
  events : event array;
  dropped : int;
  names : (int, (int * string) list) Hashtbl.t;
}

let event_size = 96

(* ---- recording ---- *)

let start () = ignore (control 0)
let stop () = ignore (control 1)

let read () =
  let b = Buffer.create 4096 in
  let rec go () =
    let s = read_raw 512 in
    Buffer.add_string b s;
    if String.length s = 512 * event_size then go () in
  go ();
  Buffer.contents b

type info = { recording : bool; pending : int; dropped_now : int; khz : float }

let u32 s i =
  let x = Int32.to_float (String.get_int32_le s i) in
  if x < 0. then x +. 4294967296. else x

let i32 s i = Int32.to_int (String.get_int32_le s i)

let info () =
  let w = info_raw () in
  let word n = u32 w (4 * n) in
  let tsc0 = word 3 +. word 4 *. 4294967296. and tsc1 = word 6 +. word 7 *. 4294967296. in
  let ticks = word 8 -. word 5 in
  (* the timer runs at 100 Hz: 10 ms a tick *)
  let khz = if ticks > 0. then (tsc1 -. tsc0) /. (ticks *. 10.) else 1e6 in
  { recording = word 0 <> 0.; pending = int_of_float (word 1);
    dropped_now = int_of_float (word 2); khz }

let magic = "MYNOSTR1"

let save file ~raw i =
  Out_channel.with_open_bin file (fun oc ->
      output_string oc magic;
      let b = Bytes.create 12 in
      Bytes.set_int64_le b 0 (Int64.bits_of_float i.khz);
      Bytes.set_int32_le b 8 (Int32.of_int i.dropped_now);
      output_bytes oc b;
      output_string oc raw)

let of_raw ~raw i =
  let n = String.length raw / event_size in
  let tsc o = u32 raw (o + 4) +. u32 raw (o + 8) *. 4294967296. in
  let t0 = if n > 0 then tsc 0 else 0. in
  let names = Hashtbl.create 32 in
  let events = Array.init n (fun k ->
      let o = k * event_size in
      let u16 i = String.get_uint16_le raw (o + i) in
      let nd = min (u16 36) 56 in
      let kind = match u16 12 with
        | 1 -> Process | 2 -> Spawn | 3 -> Exit | 4 -> Connect | 5 -> Send
        | 6 -> Recv | 7 -> Free | 8 -> Irq | k -> Other k in
      let e = { seq = int_of_float (u32 raw o); time = (tsc o -. t0) /. i.khz;
                kind; pid = u16 14; tid = i32 raw (o + 16); peer = i32 raw (o + 20);
                channel = i32 raw (o + 24); size = int_of_float (u32 raw (o + 28));
                arg = i32 raw (o + 32); data = String.sub raw (o + 40) nd } in
      let named p =
        let old = Option.value (Hashtbl.find_opt names p) ~default:[] in
        Hashtbl.replace names p ((e.seq, e.data) :: old) in
      (match kind with Process -> named e.pid | Spawn -> named e.peer | _ -> ());
      e) in
  { events; dropped = i.dropped_now; names }

let load file =
  let s = In_channel.with_open_bin file In_channel.input_all in
  if String.length s < 20 || String.sub s 0 8 <> magic then
    failwith (file ^ ": not a MyNOS recording");
  let khz = Int64.float_of_bits (String.get_int64_le s 8) in
  let dropped = i32 s 16 in
  of_raw ~raw:(String.sub s 20 (String.length s - 20))
    { recording = false; pending = 0; dropped_now = dropped; khz }

let stop_and_get () =
  stop ();
  let raw = read () in
  let i = info () in
  ignore (control 4);
  of_raw ~raw i

(* ---- names ---- *)

let program r ?(seq = max_int) pid =
  match Hashtbl.find_opt r.names pid with
  | None -> if pid = 0 then "kernel" else "?"
  | Some l ->
    (match List.find_opt (fun (s, _) -> s <= seq) l with
     | Some (_, n) -> n
     | None -> snd (List.nth l (List.length l - 1)))

let name r ?seq pid =
  if pid < 0 then "-" else Printf.sprintf "%s(%d)" (program r ?seq pid) pid

(* ---- messages ---- *)

(* a lenient reader: the data may be cut short *)
type cur = { s : string; mutable p : int }

let varint c =
  let rec go z shift =
    if c.p >= String.length c.s || shift > 56 then None
    else
      let b = Char.code c.s.[c.p] in
      c.p <- c.p + 1;
      let z = z lor ((b land 0x7F) lsl shift) in
      if b land 0x80 = 0 then Some z else go z (shift + 7) in
  go 0 0

let get_int c = Option.map (fun z -> (z lsr 1) lxor (- (z land 1))) (varint c)

let printable s =
  String.for_all (fun ch -> ch >= ' ' && ch < '\127' || ch = '\n' || ch = '\t') s

let show_bytes s total =
  let shown = String.map (fun ch -> if ch = '\n' || ch = '\t' then ' ' else ch) s in
  if total = 0 then "\"\""
  else if printable s && String.length s = total && total <= 32 then
    Printf.sprintf "%S" shown
  else if printable s && String.length s > 0 then
    Printf.sprintf "%S… (%d bytes)" (String.sub shown 0 (min 20 (String.length shown))) total
  else Printf.sprintf "(%d bytes)" total

let get_string c =
  match get_int c with
  | None -> None
  | Some n when n < 0 -> None
  | Some n ->
    let avail = max 0 (min n (String.length c.s - c.p)) in
    let s = String.sub c.s c.p avail in
    c.p <- c.p + avail;
    Some (show_bytes s n)

type arg = I | S

(* the typed protocols the player knows: request names and arguments, and
   the replies' types (mynos-lib/ocaml/block.ml, net.ml, llm.ml) *)
let protocols = [
  "block/1", [| "Info", [], [ I ]; "Read", [ I; I ], [ S ]; "Write", [ I; S ], [] |];
  "net/1", [| "Config", [], [ S; S; S; S; S ]; "Ping", [ S; I ], [ I ];
              "Resolve", [ S ], [ S ]; "Connect", [ S; I ], [ I ]; "Listen", [ I ], [ I ];
              "Accept", [ I ], [ I; S; I ]; "Send", [ I; S ], [ I ];
              "Recv", [ I; I ], [ S ]; "Close", [ I ], []; "Set_timeout", [ I; I ], [];
              "Connect_tls", [ S; I ], [ I ]; "Udp_bind", [ I ], [ I ];
              "Send_to", [ I; S; I; S ], [ I ]; "Recv_from", [ I; I ], [ S; I; S ] |];
  "llm/1", [| "Profiles", [], []; "Chat", [ S ], [] |];   (* Chat: its profile *)
]

let get_args c args =
  let one = function
    | I -> Option.map string_of_int (get_int c)
    | S -> get_string c in
  let parts = List.map (fun a -> Option.value (one a) ~default:"…") args in
  match parts with
  | [] -> ""
  | [ x ] -> " " ^ x
  | xs -> " (" ^ String.concat ", " xs ^ ")"

let protocol_id d =
  if String.length d < 2 then None
  else
    let n = Char.code d.[0] in
    if n land 1 <> 0 || n / 2 < 3 || n / 2 > 24 || String.length d < 1 + n / 2 then None
    else
      let id = String.sub d 1 (n / 2) in
      if String.contains id '/'
      && String.for_all (fun ch -> ch = '/' || ch = '_' || ch = '-'
                                   || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) id
      then Some id else None

(* a typed request: its text, and what decodes its reply *)
let typed_request d =
  match protocol_id d with
  | None -> None
  | Some id ->
    let c = { s = d; p = 1 + String.length id } in
    let case = get_int c in
    let known = List.assoc_opt id protocols in
    let text, reply_args = match case, known with
      | Some k, Some cases when k >= 0 && k < Array.length cases ->
        let nm, args, reply = cases.(k) in
        (id ^ " " ^ nm ^ get_args c args, Some reply)
      | Some k, _ -> (Printf.sprintf "%s #%d" id k, None)
      | None, _ -> (id, None) in
    Some (text, reply_args)

let typed_reply d reply_args =
  let c = { s = d; p = 0 } in
  match get_int c with
  | Some 0 ->
    (match reply_args with
     | Some [] -> "Ok"
     | Some args -> "Ok" ^ get_args c args
     | None -> "Ok")
  | Some 1 -> "Error " ^ Option.value (get_string c) ~default:"…"
  | _ -> show_bytes d (String.length d)

(* the C protocols (mynos_fs.h, mynos_registry.h, mynos_console.h) *)
let cstring s off =
  if off >= String.length s then ""
  else match String.index_from_opt s off '\000' with
    | Some e -> String.sub s off (e - off)
    | None -> String.sub s off (String.length s - off) ^ "…"

let fs_service = function "memrofsd" | "tmpfs" | "fatfs" -> true | _ -> false

let fs_request d =
  let w i = if String.length d >= i + 4 then i32 d i else 0 in
  let name = Printf.sprintf "%S" (cstring d 20) in
  match w 0 with
  | 0 -> "fs OPEN " ^ name
  | 1 -> Printf.sprintf "fs CLOSE %d" (w 8)
  | 2 -> Printf.sprintf "fs READ %d %d" (w 8) (w 12)
  | 3 -> Printf.sprintf "fs LSEEK %d %d" (w 8) (w 12)
  | 4 -> Printf.sprintf "fs LIST %s %d" name (w 12)
  | 5 -> Printf.sprintf "fs WRITE %d %d" (w 8) (w 12)
  | 6 -> "fs UNLINK " ^ name
  | 7 -> "fs MKDIR " ^ name
  | 8 -> "fs RMDIR " ^ name
  | 9 -> "fs RENAME " ^ name
  | t -> Printf.sprintf "fs #%d" t

let fs_status = [| "OK"; "NOT_FOUND"; "TOO_MANY"; "DENIED"; "NOT_OPEN"; "INVALID";
                   "READONLY"; "NO_SPACE"; "IS_DIR"; "NOT_EMPTY"; "EXISTS"; "NOT_DIR" |]

let fs_reply d =
  let st = i32 d 0 and v = i32 d 4 in
  if st = 0 then Printf.sprintf "OK %d" v
  else if st > 0 && st < Array.length fs_status then fs_status.(st)
  else Printf.sprintf "status %d" st

let registry_request d =
  match if String.length d >= 4 then i32 d 0 else 0 with
  | 1 -> Printf.sprintf "registry REGISTER %S" (cstring d 4)
  | 2 -> Printf.sprintf "registry LOOKUP %S" (cstring d 4)
  | 3 -> Printf.sprintf "registry DELETE %S" (cstring d 4)
  | n -> Printf.sprintf "registry #%d" n

let console_request d =
  match i32 d 0 with
  | 1 -> Printf.sprintf "console READ %d" (i32 d 4)
  | 2 -> Printf.sprintf "console MODE %d" (i32 d 12)
  | n -> Printf.sprintf "console #%d" n

(* every Send's description, in one pass: replies need their request *)
let memo : (event array * (int, string) Hashtbl.t) option ref = ref None

let descriptions r =
  match !memo with
  | Some (evs, t) when evs == r.events -> t
  | _ ->
    let t = Hashtbl.create 256 in
    let pending = Hashtbl.create 32 in       (* channel -> reply decoder *)
    Array.iter (fun e ->
        if e.kind = Send then begin
          let d = e.data in
          let receiver = program r ~seq:e.seq e.peer
          and sender = program r ~seq:e.seq e.pid in
          let text =
            match typed_request d with
            | Some (text, reply) -> Hashtbl.replace pending e.channel (e.peer, reply); text
            | None ->
              match Hashtbl.find_opt pending e.channel with
              | Some (server, reply) when server = e.pid ->
                Hashtbl.remove pending e.channel;
                typed_reply d reply
              | _ ->
                if e.size = 84 && fs_service receiver then fs_request d
                else if e.size = 8 && fs_service sender then fs_reply d
                else if e.size = 40 && receiver = "registry" then registry_request d
                else if e.size = 4 && sender = "registry" && String.length d = 4 then
                  Printf.sprintf "port %d" (i32 d 0)
                else if e.size = 24 && receiver = "consoled" then console_request d
                else if e.size = 0 then "(sync)"
                else show_bytes d e.size in
          Hashtbl.replace t e.seq text
        end) r.events;
    memo := Some (r.events, t);
    t

let describe r e =
  match e.kind with
  | Send -> Option.value (Hashtbl.find_opt (descriptions r) e.seq) ~default:""
  | Process | Spawn -> e.data
  | Exit -> Printf.sprintf "status %d" e.arg
  | Connect -> Printf.sprintf "port %d" e.arg
  | Recv -> Printf.sprintf "%d bytes" e.size
  | Irq -> Printf.sprintf "IRQ %d" e.arg
  | Free | Other _ -> ""

let print_events oc r =
  let duration = if Array.length r.events = 0 then 0.
    else r.events.(Array.length r.events - 1).time in
  Printf.fprintf oc "%d events in %.3f ms%s\n" (Array.length r.events) duration
    (if r.dropped > 0 then Printf.sprintf " (%d lost: the buffer was full)" r.dropped else "");
  Printf.fprintf oc "%9s  %-16s %-3s %-16s %s\n" "ms" "who" "" "with" "what";
  (* the two ends of each channel: the kernel cannot name the sender of a
     message received after the sender freed its end *)
  let ends = Hashtbl.create 32 in
  Array.iter (fun e ->
      (match e.kind with
       | Connect | Send -> Hashtbl.replace ends e.channel (e.pid, e.peer)
       | _ -> ());
      let peer =
        if e.peer >= 0 || e.kind <> Recv then e.peer
        else match Hashtbl.find_opt ends e.channel with
          | Some (a, b) -> if a = e.pid then b else a
          | None -> -1 in
      let who = name r ~seq:e.seq e.pid and other = name r ~seq:e.seq peer in
      let line arrow other what =
        Printf.fprintf oc "%9.3f  %-16s %-3s %-16s %s\n" e.time who arrow other what in
      match e.kind with
      | Process -> line "" "" ("running: " ^ e.data)
      | Spawn -> line "+" other ("spawn " ^ e.data)
      | Exit -> line "x" "" (Printf.sprintf "exit, status %d" e.arg)
      | Connect -> line "=>" other (Printf.sprintf "connect, channel %d" e.channel)
      | Send -> line "->" other (describe r e)
      | Recv -> line "<-" other (Printf.sprintf "received %d bytes" e.size)
      | Free -> line "" "" (Printf.sprintf "free channel %d" e.channel)
      | Irq -> line "!" other (Printf.sprintf "IRQ %d (interrupted %s)" e.arg other)
      | Other k -> line "?" "" (Printf.sprintf "event %d" k))
    r.events

(* ---- calls ---- *)

type call = {
  client : int; server : int; start : float; finish : float;
  request : string; reply : string; depth : int; client_tid : int;
  server_tid : int; server_start : float; server_finish : float;
}

type building = {
  b_client : int; b_server : int; b_start : float; b_request : string;
  b_tid : int; mutable b_finish : float; mutable b_reply : string;
  mutable b_server_tid : int; mutable b_server_start : float;
  mutable b_server_finish : float;
}

let calls r =
  let channels = Hashtbl.create 32 in        (* channel -> client, server *)
  let current = Hashtbl.create 32 in        (* channel -> the call *)
  let all = ref [] in
  Array.iter (fun e ->
      let ends () =
        match Hashtbl.find_opt channels e.channel with
        | Some ends -> ends
        | None ->
          (* a connection made before the recording: the first sender is
             the client *)
          let ends = (e.pid, e.peer) in
          Hashtbl.replace channels e.channel ends; ends in
      match e.kind with
      | Connect ->
        Hashtbl.replace channels e.channel (e.pid, e.peer);
        Hashtbl.remove current e.channel
      | Send ->
        let client, server = ends () in
        let cur = Hashtbl.find_opt current e.channel in
        if e.pid = client then begin
          match cur with
          | Some b when Float.is_nan b.b_finish -> ()   (* more of the request *)
          | _ ->
            let b = { b_client = client; b_server = server; b_start = e.time;
                      b_request = describe r e; b_tid = e.tid; b_finish = nan;
                      b_reply = ""; b_server_tid = 0; b_server_start = nan;
                      b_server_finish = nan } in
            Hashtbl.replace current e.channel b;
            all := b :: !all
        end else (match cur with
            | Some b ->
              b.b_server_finish <- e.time;
              if b.b_reply = "" then b.b_reply <- describe r e
            | None -> ())
      | Recv ->
        let client, server = ends () in
        (match Hashtbl.find_opt current e.channel with
         | Some b when e.pid = server && Float.is_nan b.b_server_start ->
           b.b_server_start <- e.time;
           b.b_server_tid <- e.tid
         | Some b when e.pid = client && b.b_reply <> "" -> b.b_finish <- e.time
         | _ -> ())
      | Free ->
        (match Hashtbl.find_opt channels e.channel with
         | Some (client, _) when client = e.pid -> Hashtbl.remove current e.channel
         | _ -> ())
      | _ -> ()) r.events;
  let built = List.rev !all in
  (* nesting: a call is inside the call its client was serving *)
  let serving = ref [] in                  (* calls already placed *)
  List.map (fun b ->
      let parent =
        List.find_opt (fun (p : call) ->
            p.server = b.b_client
            && not (Float.is_nan p.server_start) && p.server_start <= b.b_start
            && (Float.is_nan p.server_finish || b.b_start <= p.server_finish))
          !serving in
      let c = { client = b.b_client; server = b.b_server; start = b.b_start;
                finish = b.b_finish; request = b.b_request; reply = b.b_reply;
                depth = (match parent with Some p -> p.depth + 1 | None -> 0);
                client_tid = b.b_tid; server_tid = b.b_server_tid;
                server_start = b.b_server_start; server_finish = b.b_server_finish } in
      serving := c :: !serving;
      c) built

let print_calls oc r =
  let cs = calls r in
  Printf.fprintf oc "%d calls%s\n" (List.length cs)
    (if r.dropped > 0 then Printf.sprintf " (%d events lost)" r.dropped else "");
  Printf.fprintf oc "%9s %9s  %s\n" "ms" "took" "call";
  List.iter (fun c ->
      let took = if Float.is_nan c.finish then "?" else Printf.sprintf "%.3f" (c.finish -. c.start) in
      Printf.fprintf oc "%9.3f %9s  %s%s -> %s  %s%s\n" c.start took
        (String.make (2 * c.depth) ' ') (name r c.client) (name r c.server) c.request
        (if c.reply = "" then "" else "  =>  " ^ c.reply))
    cs

(* ---- Chrome trace event format ---- *)

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun ch ->
      match ch with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | c when c < ' ' || c >= '\127' -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let to_json r =
  let b = Buffer.create 65536 in
  let first = ref true in
  let add fmt = Printf.ksprintf (fun s ->
      if not !first then Buffer.add_string b ",\n";
      first := false;
      Buffer.add_string b s) fmt in
  Buffer.add_string b "{\"displayTimeUnit\": \"ms\", \"traceEvents\": [\n";
  let us t = t *. 1000. in
  let last = if Array.length r.events = 0 then 0.
    else r.events.(Array.length r.events - 1).time in
  (* the processes: their names *)
  let pids = Hashtbl.create 32 in
  Array.iter (fun e -> Hashtbl.replace pids e.pid ();
               if e.peer >= 0 then Hashtbl.replace pids e.peer ()) r.events;
  Hashtbl.iter (fun pid () ->
      add "{\"ph\": \"M\", \"name\": \"process_name\", \"pid\": %d, \"tid\": 0, \"args\": {\"name\": %s}}"
        pid (json_string (name r pid))) pids;
  (* spawns and exits *)
  Array.iter (fun e ->
      match e.kind with
      | Spawn -> add "{\"ph\": \"i\", \"s\": \"p\", \"name\": %s, \"pid\": %d, \"tid\": %d, \"ts\": %.3f}"
                   (json_string ("spawn " ^ name r ~seq:e.seq e.peer)) e.pid e.tid (us e.time)
      | Exit -> add "{\"ph\": \"i\", \"s\": \"p\", \"name\": %s, \"pid\": %d, \"tid\": %d, \"ts\": %.3f}"
                  (json_string (Printf.sprintf "exit %d" e.arg)) e.pid e.tid (us e.time)
      | Irq -> add "{\"ph\": \"i\", \"s\": \"p\", \"name\": %s, \"pid\": %d, \"tid\": 0, \"ts\": %.3f}"
                 (json_string (Printf.sprintf "IRQ %d" e.arg)) e.pid (us e.time)
      | _ -> ()) r.events;
  (* calls: a box on the client while it waits, one on the server while it
     serves, an arrow from one to the other *)
  List.iteri (fun k c ->
      let finish = if Float.is_nan c.finish then last else c.finish in
      let args = Printf.sprintf "{\"server\": %s, \"reply\": %s}"
          (json_string (name r c.server)) (json_string c.reply) in
      add "{\"ph\": \"X\", \"cat\": \"call\", \"name\": %s, \"pid\": %d, \"tid\": %d, \"ts\": %.3f, \"dur\": %.3f, \"args\": %s}"
        (json_string c.request) c.client c.client_tid (us c.start)
        (us (finish -. c.start)) args;
      if not (Float.is_nan c.server_start) then begin
        let sfinish = if Float.is_nan c.server_finish then last else c.server_finish in
        add "{\"ph\": \"X\", \"cat\": \"serve\", \"name\": %s, \"pid\": %d, \"tid\": %d, \"ts\": %.3f, \"dur\": %.3f, \"args\": %s}"
          (json_string c.request) c.server c.server_tid (us c.server_start)
          (us (max 0. (sfinish -. c.server_start))) args;
        add "{\"ph\": \"s\", \"cat\": \"ipc\", \"name\": \"request\", \"id\": %d, \"pid\": %d, \"tid\": %d, \"ts\": %.3f}"
          k c.client c.client_tid (us c.start);
        add "{\"ph\": \"f\", \"bp\": \"e\", \"cat\": \"ipc\", \"name\": \"request\", \"id\": %d, \"pid\": %d, \"tid\": %d, \"ts\": %.3f}"
          k c.server c.server_tid (us c.server_start)
      end) (calls r);
  Buffer.add_string b "\n]}\n";
  Buffer.contents b

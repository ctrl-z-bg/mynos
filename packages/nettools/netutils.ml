(* The small commands of nettools, over Net (netd):

     nc HOST PORT            a TCP connection: standard input to it, it to
     nc -l PORT              standard output (-l: wait for one)
     dig NAME [TYPE] [@SERVER]   a DNS question (A, AAAA, MX, TXT, NS,
                             CNAME, SOA, PTR, ANY), its answer
     sntp [SERVER]           the time of an NTP server, and how far ours is
     whois NAME              who holds a domain (IANA, then the registry)
     portscan HOST [PORTS]   which TCP ports answer (PORTS: 22,80 or 1-1024) *)

open Net_io

let die cmd m = prerr_endline (cmd ^ ": " ^ m); exit 1

(* {1 nc} *)

let pipe sock =
  let w = Net.connect () in
  let finished = ref false in
  ignore (Thread.create (fun () ->
      let buf = Bytes.create 4096 in
      let rec go () =
        match read_input buf (fun () -> !finished) with
        | "" -> ()
        | d -> (match Net.call w (Net.Send (sock, d)) with
            | _ -> go () | exception _ -> ()) in
      go ()) ());
  let r = Net.connect () in
  let rec go () =
    match Net.call r (Net.Recv (sock, 16384)) with
    | "" -> ()
    | s -> print_string s; flush stdout; go ()
    | exception _ -> () in
  go ();
  finished := true;
  (try Net.call w (Net.Close sock) with _ -> ())

let nc args =
  match args with
  | [ "-l"; port ] ->
    let ls = try call (Net.Listen (int_of_string port)) with e -> die "nc" (error e) in
    let sock, addr, p = call (Net.Accept ls) in
    Printf.eprintf "nc: connection from %s:%d\n%!" addr p;
    (try call (Net.Close ls) with _ -> ());
    pipe sock
  | [ host; port ] ->
    let sock = try connect host (int_of_string port) with e -> die "nc" (error e) in
    pipe sock
  | _ -> prerr_endline "usage: nc HOST PORT | nc -l PORT"; exit 2

(* {1 dig} *)

let types = [ "A", 1; "NS", 2; "CNAME", 5; "SOA", 6; "PTR", 12; "MX", 15; "TXT", 16;
              "AAAA", 28; "ANY", 255 ]

let u16 s i = (Char.code s.[i] lsl 8) lor Char.code s.[i + 1]
let u32f s i = float (u16 s i) *. 65536. +. float (u16 s (i + 2))

(* a name at [i] (pointers followed): it and where the next field is *)
let name s i =
  let rec go i acc jumped next =
    if i >= String.length s then failwith "short answer";
    let n = Char.code s.[i] in
    if n = 0 then String.concat "." (List.rev acc) ^ ".", (if jumped then next else i + 1)
    else if n land 0xC0 = 0xC0 then
      let p = ((n land 0x3F) lsl 8) lor Char.code s.[i + 1] in
      if p >= i then failwith "bad name";
      go p acc true (if jumped then next else i + 2)
    else go (i + 1 + n) (String.sub s (i + 1) n :: acc) jumped next in
  go i [] false 0

let rdata s typ i len =
  match typ with
  | 1 when len = 4 -> Printf.sprintf "%d.%d.%d.%d" (Char.code s.[i]) (Char.code s.[i + 1])
                        (Char.code s.[i + 2]) (Char.code s.[i + 3])
  | 28 when len = 16 -> String.concat ":" (List.init 8 (fun k -> Printf.sprintf "%x" (u16 s (i + 2 * k))))
  | 2 | 5 | 12 -> fst (name s i)
  | 15 -> Printf.sprintf "%d %s" (u16 s i) (fst (name s (i + 2)))
  | 16 ->
    let rec go j acc =
      if j >= i + len then String.concat " " (List.rev acc)
      else let n = Char.code s.[j] in go (j + 1 + n) (Printf.sprintf "%S" (String.sub s (j + 1) n) :: acc) in
    go i []
  | 6 ->
    let m, j = name s i in
    let r, j = name s j in
    Printf.sprintf "%s %s %.0f %.0f %.0f %.0f %.0f" m r (u32f s j) (u32f s (j + 4)) (u32f s (j + 8))
      (u32f s (j + 12)) (u32f s (j + 16))
  | _ -> Ssh_wire.hex (String.sub s i len)

let type_name t = match List.find_opt (fun (_, n) -> n = t) types with Some (s, _) -> s | None -> "TYPE" ^ string_of_int t

let dig args =
  let server = ref None and qtype = ref 1 and qname = ref None in
  List.iter (fun a ->
      if a = "" then ()
      else if a.[0] = '@' then server := Some (String.sub a 1 (String.length a - 1))
      else match List.assoc_opt (String.uppercase_ascii a) types with
        | Some t when !qname <> None -> qtype := t
        | _ -> qname := Some a) args;
  let qname = match !qname with Some n -> n | None -> prerr_endline "usage: dig NAME [TYPE] [@SERVER]"; exit 2 in
  (* a PTR question for an address: its in-addr.arpa name *)
  let qname = if !qtype = 12 && is_address qname then
      String.concat "." (List.rev (String.split_on_char '.' qname)) ^ ".in-addr.arpa" else qname in
  let server = match !server with Some s -> resolve s | None -> (call Net.Config).dns in
  let id = Char.code (Ssh_wire.random 1).[0] * 256 + Char.code (Ssh_wire.random 1).[0] in
  let q = Buffer.create 64 in
  Buffer.add_string q (Printf.sprintf "%c%c\001\000\000\001\000\000\000\000\000\000" (Char.chr (id lsr 8)) (Char.chr (id land 255)));
  List.iter (fun l -> if l <> "" then (Buffer.add_char q (Char.chr (String.length l)); Buffer.add_string q l))
    (String.split_on_char '.' qname);
  Buffer.add_string q (Printf.sprintf "\000\000%c\000\001" (Char.chr !qtype));
  let u = call (Net.Udp_bind 0) in
  call (Net.Set_timeout (u, 3000));
  let t0 = Mynos.uptime () in
  ignore (call (Net.Send_to (u, server, 53, Buffer.contents q)));
  let rec answer () =
    let _, _, s = try call (Net.Recv_from (u, 8192)) with e -> die "dig" ("no answer from " ^ server ^ ": " ^ error e) in
    if String.length s < 12 || u16 s 0 <> id then answer () else s in
  let s = answer () in
  let ms = (Mynos.uptime () -. t0) *. 1000. in
  (try call (Net.Close u) with _ -> ());
  let rcode = Char.code s.[3] land 15 in
  let counts = List.init 4 (fun k -> u16 s (4 + 2 * k)) in
  Printf.printf ";; %s %s, server %s, %.0f ms: %s\n" qname (type_name !qtype) server ms
    (match rcode with 0 -> "ok" | 2 -> "server failure" | 3 -> "no such name" | 5 -> "refused"
                    | n -> "error " ^ string_of_int n);
  (* the question, skipped *)
  let i = ref 12 in
  for _ = 1 to List.nth counts 0 do let _, j = name s !i in i := j + 4 done;
  List.iteri (fun sec n ->
      let sec = sec + 1 in
      if n > 0 then
        print_endline (match sec with 1 -> ";; answer" | 2 -> ";; authority" | _ -> ";; additional");
      for _ = 1 to n do
        let nm, j = name s !i in
        let typ = u16 s j and ttl = u32f s (j + 4) and len = u16 s (j + 8) in
        let data = try rdata s typ (j + 10) len with _ -> "?" in
        if typ <> 41 then Printf.printf "%-30s %6.0f IN %-5s %s\n" nm ttl (type_name typ) data;
        i := j + 10 + len
      done) (List.tl counts)

(* {1 sntp} *)

let ntp_epoch = 2208988800.     (* 1900 to 1970, in seconds *)

let sntp args =
  let server = match args with [ s ] -> s | [] -> "pool.ntp.org"
                             | _ -> prerr_endline "usage: sntp [SERVER]"; exit 2 in
  let addr = try resolve server with e -> die "sntp" (error e) in
  let u = call (Net.Udp_bind 0) in
  call (Net.Set_timeout (u, 3000));
  let t1 = Mynos.time () and u1 = Mynos.uptime () in
  ignore (call (Net.Send_to (u, addr, 123, "\x23" ^ String.make 47 '\000')));
  let _, _, s = try call (Net.Recv_from (u, 256)) with e -> die "sntp" ("no answer: " ^ error e) in
  let t4 = t1 +. (Mynos.uptime () -. u1) in
  (try call (Net.Close u) with _ -> ());
  if String.length s < 48 then die "sntp" "short answer";
  let ts i = u32f s i +. u32f s (i + 4) /. 4294967296. -. ntp_epoch in
  let t2 = ts 32 and t3 = ts 40 in
  let offset = ((t2 -. t1) +. (t3 -. t4)) /. 2. and delay = (t4 -. t1) -. (t3 -. t2) in
  let show t =
    let tm = Unix.gmtime t in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%06.3f UTC" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
      tm.tm_hour tm.tm_min (float tm.tm_sec +. Float.rem t 1.) in
  Printf.printf "%s (%s), stratum %d\n" server addr (Char.code s.[1]);
  Printf.printf "its time:  %s\nours:      %s\noffset:    %+.3f s (ours is %s)\nround trip: %.0f ms\n"
    (show t3) (show t4) offset (if offset > 0. then "behind" else "ahead") (delay *. 1000.)

(* {1 whois} *)

let whois_query server q =
  let sock = connect server 43 in
  let n = Net.connect () in
  ignore (Net.call n (Net.Send (sock, q ^ "\r\n")));
  let b = Buffer.create 4096 in
  let rec go () = match Net.call n (Net.Recv (sock, 16384)) with
    | "" -> () | s -> Buffer.add_string b s; go () | exception _ -> () in
  go ();
  (try Net.call n (Net.Close sock) with _ -> ());
  Buffer.contents b

let whois args =
  let q, server = match args with
    | [ q ] -> q, None | [ "-h"; s; q ] -> q, Some s
    | _ -> prerr_endline "usage: whois [-h SERVER] NAME"; exit 2 in
  try
    match server with
    | Some s -> print_string (whois_query s q)
    | None ->
      let iana = whois_query "whois.iana.org" q in
      let refer = List.find_map (fun l ->
          match String.index_opt l ':' with
          | Some i when String.trim (String.sub l 0 i) = "refer" ->
            Some (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
          | _ -> None) (String.split_on_char '\n' iana) in
      match refer with
      | Some r -> Printf.printf "%% from %s\n" r; print_string (whois_query r q)
      | None -> print_string iana
  with e -> die "whois" (error e)

(* {1 portscan} *)

let common = [ 21; 22; 23; 25; 53; 80; 110; 143; 443; 587; 993; 995; 3306; 5432; 6379; 8000; 8080; 8443 ]

let portscan args =
  let host, ports = match args with
    | [ h ] -> h, common
    | [ h; spec ] ->
      h, List.concat_map (fun part ->
          match String.split_on_char '-' part with
          | [ a; b ] -> List.init (int_of_string b - int_of_string a + 1) (fun k -> int_of_string a + k)
          | _ -> [ int_of_string part ]) (String.split_on_char ',' spec)
    | _ -> prerr_endline "usage: portscan HOST [22,80 or 1-1024]"; exit 2 in
  let addr = try resolve host with e -> die "portscan" (error e) in
  Printf.printf "%s (%s): %d ports\n%!" host addr (List.length ports);
  let todo = ref ports and m = Mutex.create () and opened = ref [] in
  let next () = Mutex.lock m; let p = match !todo with p :: r -> todo := r; Some p | [] -> None in
    Mutex.unlock m; p in
  let worker () =
    let n = Net.connect () in
    let rec go () = match next () with
      | None -> ()
      | Some p ->
        (match Net.call n (Net.Connect (addr, p)) with
         | s -> Mutex.lock m; opened := p :: !opened; Mutex.unlock m;
           Printf.printf "%5d open\n%!" p;
           (try Net.call n (Net.Close s) with _ -> ())
         | exception _ -> ());
        go () in
    go () in
  let ts = List.init 8 (fun _ -> Thread.create worker ()) in
  List.iter Thread.join ts;
  Printf.printf "%d open of %d\n" (List.length !opened) (List.length ports)

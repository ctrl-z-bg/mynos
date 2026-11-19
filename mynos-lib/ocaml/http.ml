(* HTTP/1.1 clients over Net: see http.mli. *)

type response = {
  status : int;
  reason : string;
  headers : (string * string) list;
  body : string;
}

exception Error of string

let error fmt = Printf.ksprintf (fun m -> raise (Error m)) fmt

let parse_url url =
  let tls, rest =
    let starts p = String.length url >= String.length p
                   && String.lowercase_ascii (String.sub url 0 (String.length p)) = p in
    if starts "https://" then true, String.sub url 8 (String.length url - 8)
    else if starts "http://" then false, String.sub url 7 (String.length url - 7)
    else error "%s: not an http:// or https:// URL" url in
  let authority, path =
    match String.index_opt rest '/' with
    | Some i -> String.sub rest 0 i, String.sub rest i (String.length rest - i)
    | None -> rest, "/" in
  let host, port =
    match String.rindex_opt authority ':' with
    | Some i ->
      (match int_of_string_opt (String.sub authority (i + 1) (String.length authority - i - 1)) with
       | Some p when p > 0 && p < 65536 -> String.sub authority 0 i, p
       | _ -> error "%s: bad port" url)
    | None -> authority, if tls then 443 else 80 in
  if host = "" then error "%s: no host" url;
  tls, host, port, path

let lower = String.lowercase_ascii

let find_sub s sub from =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1) in
  go from

(* "1a;ext\r\n" chunks, up to the "0" one *)
let unchunk s =
  let b = Buffer.create (String.length s) in
  let rec go pos =
    match find_sub s "\r\n" pos with
    | None -> error "HTTP: a chunk's size is missing"
    | Some eol ->
      let line = String.sub s pos (eol - pos) in
      let line = match String.index_opt line ';' with
        | Some i -> String.sub line 0 i | None -> line in
      match int_of_string_opt ("0x" ^ String.trim line) with
      | None -> error "HTTP: bad chunk size %S" line
      | Some 0 -> Buffer.contents b
      | Some n ->
        if eol + 2 + n > String.length s then error "HTTP: a chunk is cut";
        Buffer.add_string b (String.sub s (eol + 2) n);
        go (eol + 2 + n + 2) in
  go 0

let split_head s =
  match find_sub s "\r\n\r\n" 0 with
  | Some i -> Some (String.sub s 0 i, String.sub s (i + 4) (String.length s - i - 4))
  | None -> None

let parse_head head =
  match String.split_on_char '\n' head |> List.map String.trim with
  | [] -> error "HTTP: an empty answer"
  | status_line :: lines ->
    let status, reason =
      match String.split_on_char ' ' status_line with
      | v :: code :: reason when String.length v >= 5 && String.sub v 0 5 = "HTTP/" ->
        (match int_of_string_opt code with
         | Some c -> c, String.concat " " reason
         | None -> error "HTTP: bad status line %S" status_line)
      | _ -> error "HTTP: not an HTTP answer (%S)" status_line in
    let headers = List.filter_map (fun l ->
        match String.index_opt l ':' with
        | Some i -> Some (lower (String.trim (String.sub l 0 i)),
                          String.trim (String.sub l (i + 1) (String.length l - i - 1)))
        | None -> None) lines in
    status, reason, headers

let parse_response s =
  match split_head s with
  | None -> error "HTTP: the answer has no end of headers"
  | Some (head, rest) ->
    let status, reason, headers = parse_head head in
    let body =
      match List.assoc_opt "transfer-encoding" headers, List.assoc_opt "content-length" headers with
      | Some te, _ when lower te = "chunked" -> unchunk rest
      | _, Some cl ->
        (match int_of_string_opt (String.trim cl) with
         | Some n when n <= String.length rest -> String.sub rest 0 n
         | _ -> rest)
      | _ -> rest in
    { status; reason; headers; body }

let header name r = List.assoc_opt (lower name) r.headers

(* the answer is whole: Content-Length bytes, or the last chunk (else the
   end of the connection says so) *)
let complete s =
  match split_head s with
  | None -> false
  | Some (head, rest) ->
    match parse_head head with
    | exception Error _ -> false
    | _, _, headers ->
      match List.assoc_opt "transfer-encoding" headers, List.assoc_opt "content-length" headers with
      | Some te, _ when lower te = "chunked" ->
        (match unchunk rest with _ -> true | exception Error _ -> false)
      | _, Some cl ->
        (match int_of_string_opt (String.trim cl) with
         | Some n -> String.length rest >= n
         | None -> false)
      | _ -> false

(* what the head says about the body's end, once the head has come: its
   total length (head included), chunks, or nothing (until the close) *)
let body_end s =
  match split_head s with
  | None -> None
  | Some (head, rest) ->
    match parse_head head with
    | exception Error _ -> Some `Close
    | _, _, headers ->
      match List.assoc_opt "transfer-encoding" headers, List.assoc_opt "content-length" headers with
      | Some te, _ when lower te = "chunked" -> Some `Chunked
      | _, Some cl ->
        (match int_of_string_opt (String.trim cl) with
         | Some n -> Some (`Length (String.length s - String.length rest + n))
         | None -> Some `Close)
      | _ -> Some `Close

let request ?net ?meth ?(headers = []) ?body ?(timeout = 30000) url =
  let tls, host, port, path = parse_url url in
  let meth = match meth, body with
    | Some m, _ -> m | None, Some _ -> "POST" | None, None -> "GET" in
  let has h = List.exists (fun (k, _) -> lower k = h) headers in
  let b = Buffer.create 256 in
  Printf.bprintf b "%s %s HTTP/1.1\r\n" meth path;
  let default = (if tls && port = 443 || not tls && port = 80 then host
                 else Printf.sprintf "%s:%d" host port) in
  if not (has "host") then Printf.bprintf b "Host: %s\r\n" default;
  if not (has "user-agent") then Buffer.add_string b "User-Agent: MyNOS\r\n";
  if not (has "connection") then Buffer.add_string b "Connection: close\r\n";
  (match body with
   | Some d when not (has "content-length") ->
     Printf.bprintf b "Content-Length: %d\r\n" (String.length d)
   | _ -> ());
  List.iter (fun (k, v) -> Printf.bprintf b "%s: %s\r\n" k v) headers;
  Buffer.add_string b "\r\n";
  Option.iter (Buffer.add_string b) body;
  let n = match net with Some n -> n | None -> Net.connect () in
  let call r = try Net.call n r with Ipc.Remote_error (_, m) -> raise (Error m) in
  let s =
    if tls then call (Net.Connect_tls (host, port))
    else call (Net.Connect (call (Net.Resolve host), port)) in
  Fun.protect ~finally:(fun () -> try Net.call n (Net.Close s) with _ -> ())
    (fun () ->
       call (Net.Set_timeout (s, timeout));
       ignore (call (Net.Send (s, Buffer.contents b)));
       let answer = Buffer.create 4096 in
       (* the body's end, worked out once the head is in: not the whole
          answer parsed again after every piece (quadratic on large ones) *)
       let ending = ref None in
       let rec read () =
         match call (Net.Recv (s, 16384)) with
         | "" -> ()
         | data ->
           Buffer.add_string answer data;
           if !ending = None then ending := body_end (Buffer.contents answer);
           let n = Buffer.length answer in
           let finished = match !ending with
             | None | Some `Close -> false
             | Some (`Length total) -> n >= total
             | Some `Chunked ->
               n >= 5 && Buffer.sub answer (n - 5) 5 = "0\r\n\r\n"
               && complete (Buffer.contents answer) in
           if not finished then read () in
       read ();
       parse_response (Buffer.contents answer))

let get ?net ?headers ?timeout url = request ?net ?headers ?timeout url

let post ?net ?headers ?timeout ~body url =
  request ?net ?meth:(Some "POST") ?headers ~body ?timeout url

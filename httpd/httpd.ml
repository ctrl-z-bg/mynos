(* httpd: a small web server for MyNOS, in OCaml, over the network service
   (module Net). It serves the files of a directory over HTTP/1.0, with 8
   worker domains, and lists directories. Hidden files (".name") and
   ".env" files (llm.env: the language models' keys) are neither served
   nor listed.

     httpd [-w] [DIR [PORT]]   DIR: /disk by default, PORT: 80

   It also receives files: PUT writes one (curl -T FILE URL), and a
   directory's listing has a form that sends several (POST, multipart),
   into that directory. Writing is allowed to the computer QEMU runs on
   (the client 10.0.2.2, when MyNOS is 10.0.2.15 on QEMU's user network:
   what tools/run-demo.sh forwards), and to anyone with -w. A write must
   name this server in Host, and in Origin if there is one: a page of
   another site, open in a browser, cannot send it.

   init starts it at boot; tools/run-demo.sh forwards the host's port 8080
   to it: http://localhost:8080/ shows MyNOS's disk. *)

let open_writes, args =
  match List.tl (Array.to_list Sys.argv) with
  | "-w" :: rest -> true, rest
  | rest -> false, rest
let root = match args with d :: _ -> d | [] -> "/disk"
let port = match args with _ :: p :: _ -> int_of_string p | _ -> 80

let log fmt = Printf.ksprintf (fun s -> Mynos.log ("httpd: " ^ s ^ "\n")) fmt

let content_type name =
  match String.lowercase_ascii (Filename.extension name) with
  | ".html" | ".htm" -> "text/html"
  | ".txt" | ".ml" | ".mli" | ".c" | ".h" | ".md" | ".rc" | ".bat" | "" ->
    "text/plain; charset=utf-8"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".css" -> "text/css"
  | _ -> "application/octet-stream"

let html_escape s =
  let b = Buffer.create (String.length s) in
  String.iter (function
      | '<' -> Buffer.add_string b "&lt;" | '>' -> Buffer.add_string b "&gt;"
      | '&' -> Buffer.add_string b "&amp;" | '"' -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c) s;
  Buffer.contents b

(* %XX in a path *)
let decode s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then
      if s.[i] = '%' && i + 2 < String.length s then
        match int_of_string_opt ("0x" ^ String.sub s (i + 1) 2) with
        | Some c -> Buffer.add_char b (Char.chr c); go (i + 3)
        | None -> Buffer.add_char b '%'; go (i + 1)
      else (Buffer.add_char b s.[i]; go (i + 1)) in
  go 0;
  Buffer.contents b

(* names not to be served: hidden files, and .env files, which hold
   configuration and keys (mynos-n16); FAT names ignore case *)
let private_name n =
  n = "" || n.[0] = '.' || Filename.check_suffix (String.lowercase_ascii n) ".env"

(* [upload]: the listing ends with a form that sends files into it *)
let listing ~upload path dir =
  let names = Sys.readdir dir |> Array.to_list
              |> List.filter (fun n -> not (private_name n)) |> Array.of_list in
  Array.sort compare names;
  let link n =
    let d = Sys.is_directory (Filename.concat dir n) in
    Printf.sprintf "<li><a href=\"%s%s\">%s%s</a></li>\n"
      (html_escape n) (if d then "/" else "") (html_escape n) (if d then "/" else "") in
  Printf.sprintf
    "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>MyNOS %s</title></head>\n\
     <body><h1>MyNOS: %s</h1>\n<ul>\n%s</ul>\n%s\
     <p><small>served by httpd, in OCaml, on MyNOS</small></p></body></html>\n"
    (html_escape path) (html_escape path)
    (String.concat "" (Array.to_list (Array.map link names)))
    (if upload then
       "<form method=\"post\" enctype=\"multipart/form-data\">\
        <input type=\"file\" name=\"file\" multiple> \
        <button>Upload</button> (into this directory)</form>\n"
     else "")

let response ?(headers = "") status ctype body =
  Printf.sprintf "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\
                  Server: MyNOS httpd\r\nConnection: close\r\n\r\n%s"
    status ctype (String.length body) headers body

let text status body = response status "text/plain" (body ^ "\n")

(* {1 Reading a connection} *)

(* [sub] in [s] from [from]: its place *)
let find sub s from =
  let n = String.length sub and m = String.length s in
  let rec go i =
    if i + n > m then None
    else if String.unsafe_get s i = String.unsafe_get sub 0 && String.sub s i n = sub then Some i
    else go (i + 1) in
  go from

(* a connection's bytes: those read but not yet used, then more on demand *)
type conn = { recv : unit -> string; mutable pending : string }

let more c =
  match c.recv () with
  | "" -> false
  | data -> c.pending <- c.pending ^ data; true

(* the request's head: up to the empty line, without it; what follows
   stays pending *)
let read_head c =
  let rec go () =
    match find "\r\n\r\n" c.pending 0 with
    | Some i ->
      let head = String.sub c.pending 0 i in
      c.pending <- String.sub c.pending (i + 4) (String.length c.pending - i - 4);
      head
    | None ->
      if String.length c.pending > 16384 || not (more c) then c.pending
      else go () in
  go ()

type request = { meth : string; target : string; headers : (string * string) list }

let parse_head head =
  match String.split_on_char '\n' head with
  | [] -> None
  | first :: lines ->
    match String.split_on_char ' ' (String.trim first) with
    | meth :: target :: _ ->
      let headers = List.filter_map (fun l ->
          match String.index_opt l ':' with
          | Some i ->
            Some (String.lowercase_ascii (String.trim (String.sub l 0 i)),
                  String.trim (String.sub l (i + 1) (String.length l - i - 1)))
          | None -> None) lines in
      Some { meth; target; headers }
    | _ -> None

let header r name = List.assoc_opt name r.headers

(* {1 The files} *)

(* a target's path inside [root], or the answer that refuses it *)
let resolve target =
  let path = decode (List.hd (String.split_on_char '?' target)) in
  let parts = List.filter (fun p -> p <> "" && p <> ".") (String.split_on_char '/' path) in
  if List.mem ".." parts then Error (text "403 Forbidden" "forbidden")
  else if List.exists private_name parts then Error (text "404 Not Found" "not found")
  else Ok (path, List.fold_left Filename.concat root parts)

let rec mkdirs d =
  if not (Sys.file_exists d) then begin
    mkdirs (Filename.dirname d);
    Sys.mkdir d 0o755
  end

(* write [file] from [chunks] (it gives "" at the end): into a hidden
   file first, which replaces [file] only when complete, so that a
   transfer cut short leaves the old one. The bytes written *)
let save file chunks =
  let dir = Filename.dirname file in
  mkdirs dir;
  let part = Filename.concat dir (".upload-" ^ Filename.basename file) in
  let written = ref 0 in
  (match Out_channel.with_open_bin part (fun oc ->
       let rec go () =
         match chunks () with
         | "" -> ()
         | s -> Out_channel.output_string oc s; written := !written + String.length s; go () in
       go ()) with
   | () -> ()
   | exception e -> (try Sys.remove part with Sys_error _ -> ()); raise e);
  if Sys.file_exists file then Sys.remove file;
  Sys.rename part file;
  !written

exception Incomplete

(* the body: [len] bytes, the pending ones first, as chunks *)
let body_chunks c len =
  let left = ref len in
  fun () ->
    if !left = 0 then ""
    else begin
      if c.pending = "" && not (more c) then raise Incomplete;
      let n = min !left (String.length c.pending) in
      let s = String.sub c.pending 0 n in
      c.pending <- String.sub c.pending n (String.length c.pending - n);
      left := !left - n;
      s
    end

(* a multipart/form-data body (RFC 7578): each part with a file name is
   saved into [dir], as it arrives. The names saved, and their sizes *)
let save_parts c len boundary dir =
  let chunk = body_chunks c len in
  (* the body's bytes not yet used: [c.pending] holds the rest of the
     connection's; [buf] the body's *)
  let buf = ref "" in
  let fill () = match chunk () with "" -> false | s -> buf := !buf ^ s; true in
  let rec upto sub =
    match find sub !buf 0 with
    | Some i ->
      let before = String.sub !buf 0 i in
      buf := String.sub !buf (i + String.length sub) (String.length !buf - i - String.length sub);
      before
    | None -> if fill () then upto sub else raise Incomplete in
  let delim = "\r\n--" ^ boundary in
  (* a part's data, as chunks, up to the delimiter (kept: its last bytes
     may be in the next chunk) *)
  let data () =
    let finished = ref false in
    fun () ->
      if !finished then ""
      else
        let rec go () =
          match find delim !buf 0 with
          | Some i ->
            let s = String.sub !buf 0 i in
            buf := String.sub !buf (i + String.length delim) (String.length !buf - i - String.length delim);
            finished := true;
            s
          | None ->
            let keep = String.length delim - 1 in
            let n = String.length !buf - keep in
            if n > 0 then begin
              let s = String.sub !buf 0 n in
              buf := String.sub !buf n keep; s
            end else if fill () then go () else raise Incomplete in
        go () in
  let filename headers =
    (* Content-Disposition: form-data; name="file"; filename="a.png" *)
    match find "filename=\"" headers 0 with
    | None -> None
    | Some i ->
      let j = i + 10 in
      match String.index_from_opt headers j '"' with
      | Some k -> Some (Filename.basename (String.sub headers j (k - j)))
      | None -> None in
  ignore (upto ("--" ^ boundary));
  let rec parts acc =
    (* after a delimiter: "--" ends the body, CRLF begins a part *)
    while String.length !buf < 2 && fill () do () done;
    if String.length !buf >= 2 && String.sub !buf 0 2 = "--" then List.rev acc
    else begin
      ignore (upto "\r\n");
      let headers = upto "\r\n\r\n" in
      let chunks = data () in
      match filename headers with
      | Some name when name <> "" && not (private_name name) && name <> ".." ->
        let n = save (Filename.concat dir name) chunks in
        parts ((name, n) :: acc)
      | _ ->
        (* a field, or no file chosen, or a name refused: read past it *)
        while chunks () <> "" do () done;
        parts acc
    end in
  let saved = parts [] in
  (* the epilogue, if any *)
  (try while chunk () <> "" do () done with Incomplete -> ());
  saved

(* {1 Who may write} *)

(* the host part of "name:port" *)
let host_name h =
  let h = String.lowercase_ascii h in
  match String.rindex_opt h ':' with Some i -> String.sub h 0 i | None -> h

(* Host names this server, and Origin, if any, too: a browser always
   sends Origin with a form posted from another site's page, and a page
   whose name leads here (DNS rebinding) still sends its own Host *)
let addressed_here r address =
  let ours h = List.mem (host_name h) [ "localhost"; "127.0.0.1"; address ] in
  (match header r "host" with Some h -> ours h | None -> false)
  && (match header r "origin" with
      | None -> true
      | Some o ->
        let p = "http://" in
        String.length o > String.length p && String.sub o 0 (String.length p) = p
        && ours (String.sub o (String.length p) (String.length o - String.length p)))

let config n = try Some (Net.call n Net.Config) with _ -> None

(* QEMU's user network: MyNOS 10.0.2.15, the gateway 10.0.2.2, which is
   also where the host's forwarded connections come from *)
let may_write n peer =
  open_writes
  || (match config n with
      | Some c -> c.Net.address = "10.0.2.15" && c.Net.gateway = "10.0.2.2" && peer = "10.0.2.2"
      | None -> false)

(* {1 Answers} *)

let get n peer r =
  match resolve r.target with
  | Error answer -> answer
  | Ok (path, file) ->
    match Sys.is_directory file with
    | true -> response "200 OK" "text/html; charset=utf-8" (listing ~upload:(may_write n peer) path file)
    | false ->
      response "200 OK" (content_type file) (In_channel.with_open_bin file In_channel.input_all)
    | exception Sys_error _ -> text "404 Not Found" "not found"

let write n peer c r =
  let address = match config n with Some cfg -> cfg.Net.address | None -> "" in
  if not (may_write n peer) then
    text "403 Forbidden" "writing is off (httpd -w turns it on)"
  else if not (addressed_here r address) then
    text "403 Forbidden" "Host or Origin is not this server"
  else
    match resolve r.target, Option.bind (header r "content-length") int_of_string_opt with
    | Error answer, _ -> answer
    | _, None -> text "411 Length Required" "a length is needed (Content-Length)"
    | Ok (path, file), Some len ->
      match r.meth with
      | "PUT" ->
        if Sys.file_exists file && Sys.is_directory file then
          text "409 Conflict" (path ^ " is a directory")
        else begin
          let existed = Sys.file_exists file in
          let n = save file (body_chunks c len) in
          log "%s PUT %s: %d bytes written" peer path n;
          text (if existed then "200 OK" else "201 Created")
            (Printf.sprintf "%s: %d bytes written" path n)
        end
      | _ ->
        let ctype = Option.value (header r "content-type") ~default:"" in
        match find "boundary=" ctype 0 with
        | None -> text "415 Unsupported Media Type" "a form (multipart/form-data) is needed"
        | Some i ->
          let b = String.sub ctype (i + 9) (String.length ctype - i - 9) in
          let b = match String.index_opt b ';' with Some j -> String.sub b 0 j | None -> b in
          let b = String.trim b in
          let b = if String.length b >= 2 && b.[0] = '"' then String.sub b 1 (String.length b - 2) else b in
          if not (Sys.file_exists file && Sys.is_directory file) then
            text "404 Not Found" "not a directory"
          else begin
            let saved = save_parts c len b file in
            List.iter (fun (name, n) -> log "%s POST %s: %s, %d bytes written" peer path name n) saved;
            (* back to the listing, which now shows them *)
            response ~headers:(Printf.sprintf "Location: %s\r\n" r.target) "303 See Other" "text/plain"
              (String.concat "" (List.map (fun (name, n) -> Printf.sprintf "%s: %d bytes written\n" name n) saved))
          end

(* one connection: the request, the reply. A connection that sends nothing
   (browsers open some in advance) times out instead of holding a worker *)
let serve n s peer =
  (try
     Net.call n (Net.Set_timeout (s, 10000));
     let c = { recv = (fun () -> Net.call n (Net.Recv (s, 65536))); pending = "" } in
     let head = read_head c in
     if head <> "" then begin
       let reply =
         match parse_head head with
         | Some ({ meth = "GET"; _ } as r) -> get n peer r
         | Some ({ meth = "PUT" | "POST"; _ } as r) ->
           (* curl waits a second for this before it sends a large body *)
           if header r "expect" = Some "100-continue" then
             ignore (Net.call n (Net.Send (s, "HTTP/1.1 100 Continue\r\n\r\n")));
           (match write n peer c r with
            | answer -> answer
            | exception Incomplete -> text "400 Bad Request" "the body ended early"
            | exception Sys_error m -> log "%s: %s" peer m; text "500 Internal Server Error" m)
         | _ -> text "400 Bad Request" "bad request" in
       log "%s %s" peer (String.trim (List.hd (String.split_on_char '\n' head)));
       ignore (Net.call n (Net.Send (s, reply)))
     end
   with Ipc.Remote_error (_, m) -> log "%s: %s" peer m);
  (try Net.call n (Net.Close s) with Ipc.Remote_error _ -> ())

(* connections are served by a few domains at once, so that a slow or idle
   one does not stop the others: the main domain accepts them and queues
   them for the workers *)
let workers = 8
let queue = Queue.create ()
let lock = Mutex.create ()
let nonempty = Condition.create ()

(* each connection comes with the network service it was accepted from:
   after netd restarts, the next ones come from the new one *)
let worker () =
  while true do
    Mutex.lock lock;
    while Queue.is_empty queue do Condition.wait nonempty lock done;
    let n, s, peer = Queue.pop queue in
    Mutex.unlock lock;
    serve n s peer
  done

let listen () =
  match Net.connect () with
  | exception Mynos.Error _ -> Error "no network service"
  | n ->
    match Net.call n (Net.Listen port) with
    | l -> Ok (n, l)
    | exception Ipc.Remote_error (_, m) -> Error (Printf.sprintf "port %d: %s" port m)

(* accept, and queue for the workers. Errors in a row mean that the
   listening socket is gone (netd ended, and init started it again: its
   sockets are new): listen again, on the new netd, instead of asking the
   dead socket for ever (mynos-f2d) *)
let rec accept n l errors =
  match Net.call n (Net.Accept l) with
  | s, peer, _ ->
    Mutex.lock lock;
    Queue.push (n, s, peer) queue;
    Condition.signal nonempty;
    Mutex.unlock lock;
    accept n l 0
  | exception e when errors < 3 ->
    log "accept: %s" (match e with Ipc.Remote_error (_, m) -> m | e -> Printexc.to_string e);
    accept n l (errors + 1)
  | exception _ ->
    log "the listening socket is gone: listening again";
    relisten ()
and relisten () =
  Mynos.sleep 1.0;
  match listen () with
  | Ok (n, l) -> log "serving %s on port %d again" root port; accept n l 0
  | Error _ -> relisten ()

let () =
  match listen () with
  | Error m -> log "%s" m
  | Ok (n, l) ->
    log "serving %s on port %d, %d connections at a time%s" root port workers
      (if open_writes then ", writes from anyone (-w)" else "");
    for _ = 1 to workers do ignore (Domain.spawn worker) done;
    accept n l 0

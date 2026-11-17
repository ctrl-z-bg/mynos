(* httpd: a small web server for MyNOS, in OCaml, over the network service
   (module Net). It serves the files of a directory over HTTP/1.0, one
   connection at a time, and lists directories.

     httpd [DIR [PORT]]        DIR: /disk by default, PORT: 80

   init starts it at boot; tools/run-demo.sh forwards the host's port 8080
   to it: http://localhost:8080/ shows MyNOS's disk. *)

let root = if Array.length Sys.argv > 1 then Sys.argv.(1) else "/disk"
let port = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 80

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

let listing path dir =
  let names = Sys.readdir dir |> Array.to_list
              |> List.filter (fun n -> n <> "" && n.[0] <> '.') |> Array.of_list in
  Array.sort compare names;
  let link n =
    let d = Sys.is_directory (Filename.concat dir n) in
    Printf.sprintf "<li><a href=\"%s%s\">%s%s</a></li>\n"
      (html_escape n) (if d then "/" else "") (html_escape n) (if d then "/" else "") in
  Printf.sprintf
    "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>MyNOS %s</title></head>\n\
     <body><h1>MyNOS: %s</h1>\n<ul>\n%s</ul>\n\
     <p><small>served by httpd, in OCaml, on MyNOS</small></p></body></html>\n"
    (html_escape path) (html_escape path)
    (String.concat "" (Array.to_list (Array.map link names)))

let response status ctype body =
  Printf.sprintf "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n\
                  Server: MyNOS httpd\r\nConnection: close\r\n\r\n%s"
    status ctype (String.length body) body

let answer request =
  match String.split_on_char ' ' (List.hd (String.split_on_char '\r' request)) with
  | "GET" :: target :: _ ->
    let path = decode (List.hd (String.split_on_char '?' target)) in
    let parts = List.filter (fun p -> p <> "" && p <> ".") (String.split_on_char '/' path) in
    if List.mem ".." parts then response "403 Forbidden" "text/plain" "forbidden\n"
    else begin
      let file = List.fold_left Filename.concat root parts in
      match Sys.is_directory file with
      | true -> response "200 OK" "text/html; charset=utf-8" (listing path file)
      | false ->
        response "200 OK" (content_type file)
          (In_channel.with_open_bin file In_channel.input_all)
      | exception Sys_error _ -> response "404 Not Found" "text/plain" "not found\n"
    end
  | _ -> response "400 Bad Request" "text/plain" "bad request\n"

(* the request: up to the empty line *)
let read_request n s =
  let rec go acc =
    if String.length acc > 16384 then acc
    else
      let ends_header =
        let rec has i = i + 4 <= String.length acc
                        && (String.sub acc i 4 = "\r\n\r\n" || has (i + 1)) in
        has 0 in
      if ends_header then acc
      else (match Net.call n (Net.Recv (s, 4096)) with
          | "" -> acc
          | data -> go (acc ^ data)) in
  go ""

let () =
  match Net.connect () with
  | exception Mynos.Error _ -> log "no network service"
  | n ->
    match Net.call n (Net.Listen port) with
    | exception Ipc.Remote_error (_, m) -> log "port %d: %s" port m
    | l ->
      log "serving %s on port %d" root port;
      while true do
        match Net.call n (Net.Accept l) with
        | exception Ipc.Remote_error (_, m) -> log "accept: %s" m
        | s, peer, _ ->
          (try
             let request = read_request n s in
             let reply = answer request in
             log "%s %s" peer (List.hd (String.split_on_char '\r' request));
             ignore (Net.call n (Net.Send (s, reply)))
           with Ipc.Remote_error (_, m) -> log "%s: %s" peer m);
          (try Net.call n (Net.Close s) with Ipc.Remote_error _ -> ())
      done

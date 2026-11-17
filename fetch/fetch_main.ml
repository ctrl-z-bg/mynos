(* fetch: an HTTP or HTTPS request from the command line, with module Http
   (TLS in netd). A small curl:

     fetch https://example.com/
     fetch -i URL                      the status and the headers too
     fetch -o FILE URL                 the body into FILE
     fetch -H "Name: value" ... URL    a header
     fetch -d DATA URL                 POST DATA (-d @FILE: the file's bytes)
     fetch -X METHOD URL               another method *)

let usage () =
  prerr_endline "usage: fetch [-i] [-o FILE] [-H 'Name: value']... [-d DATA|@FILE] [-X METHOD] URL";
  exit 2

let read_file path = In_channel.with_open_bin path In_channel.input_all

let () =
  let include_head = ref false and out = ref None and headers = ref []
  and body = ref None and meth = ref None and url = ref None in
  let rec args = function
    | "-i" :: rest -> include_head := true; args rest
    | "-o" :: f :: rest -> out := Some f; args rest
    | "-H" :: h :: rest ->
      (match String.index_opt h ':' with
       | Some i ->
         headers := (String.trim (String.sub h 0 i),
                     String.trim (String.sub h (i + 1) (String.length h - i - 1))) :: !headers
       | None -> usage ());
      args rest
    | "-d" :: d :: rest ->
      body := Some (if String.length d > 0 && d.[0] = '@'
                    then read_file (String.sub d 1 (String.length d - 1)) else d);
      args rest
    | "-X" :: m :: rest -> meth := Some m; args rest
    | u :: rest when !url = None && (String.length u = 0 || u.[0] <> '-') ->
      url := Some u; args rest
    | [] -> ()
    | _ -> usage () in
  args (List.tl (Array.to_list Sys.argv));
  let url = match !url with Some u -> u | None -> usage () in
  match Http.request ?meth:!meth ~headers:(List.rev !headers) ?body:!body url with
  | r ->
    if !include_head then begin
      Printf.printf "%d %s\n" r.Http.status r.reason;
      List.iter (fun (k, v) -> Printf.printf "%s: %s\n" k v) r.headers;
      print_newline ()
    end;
    (match !out with
     | Some f -> Out_channel.with_open_bin f (fun oc -> output_string oc r.body)
     | None -> print_string r.body; flush stdout);
    if r.status >= 400 then exit 1
  | exception Http.Error m -> prerr_endline ("fetch: " ^ m); exit 1

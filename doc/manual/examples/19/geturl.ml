(* geturl: fetch a URL, print the answer.  geturl [-i] URL
   -i: the status line and the headers too. *)

let () =
  let head, url =
    match List.tl (Array.to_list Sys.argv) with
    | [ "-i"; url ] -> true, url
    | [ url ] -> false, url
    | _ -> prerr_endline "usage: geturl [-i] URL"; exit 2 in
  match Http.get ~timeout:10_000 url with
  | r ->
    if head then begin
      Printf.printf "%d %s\n" r.Http.status r.reason;
      List.iter (fun (k, v) -> Printf.printf "%s: %s\n" k v) r.headers;
      print_newline ()
    end;
    print_string r.body;
    exit (if r.status < 400 then 0 else 1)
  | exception Http.Error m -> prerr_endline ("geturl: " ^ m); exit 1
  | exception Mynos.Error _ -> prerr_endline "geturl: no network service"; exit 1

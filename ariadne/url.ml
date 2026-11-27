(* URLs, as M0 needs them: the scheme, the fragment, a link resolved
   against the page's address, what the user typed. From
   packages/browser; M3 replaces it with the WHATWG URL parser. *)

let scheme_of u =
  match String.index_opt u ':' with
  | Some i when i > 0 && String.for_all (fun c ->
      match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '+' | '-' | '.' -> true | _ -> false)
      (String.sub u 0 i) -> Some (String.lowercase_ascii (String.sub u 0 i))
  | _ -> None

(* the URL without its fragment, and the fragment *)
let strip_fragment u =
  match String.index_opt u '#' with
  | Some i -> (String.sub u 0 i, Some (String.sub u (i + 1) (String.length u - i - 1)))
  | None -> (u, None)

(* "a/b/../c/./d" -> "a/c/d" *)
let remove_dots path =
  let parts = String.split_on_char '/' path in
  let out = List.fold_left (fun acc p ->
      match p with
      | "." -> acc
      | ".." -> (match acc with _ :: rest when rest <> [] -> rest | l -> l)
      | p -> p :: acc) [] parts in
  let r = String.concat "/" (List.rev out) in
  if String.length path > 0 && path.[String.length path - 1] = '/' && r <> ""
     && r.[String.length r - 1] <> '/' then r ^ "/" else r

(* the origin ("https://host:port") and the path of an absolute URL *)
let split u =
  match String.index_opt u ':' with
  | None -> (u, "/")
  | Some i ->
    let rest = String.sub u (i + 1) (String.length u - i - 1) in
    if String.length rest >= 2 && String.sub rest 0 2 = "//" then
      match String.index_from_opt rest 2 '/' with
      | Some j -> (String.sub u 0 (i + 1 + j), String.sub rest j (String.length rest - j))
      | None -> (u, "/")
    else (String.sub u 0 (i + 1), rest)

let without_query p = match String.index_opt p '?' with Some i -> String.sub p 0 i | None -> p

let resolve base href =
  let href = String.trim href in
  if href = "" then base
  else match scheme_of href with
    | Some _ -> href
    | None ->
      let origin, path = split (fst (strip_fragment base)) in
      if String.length href >= 2 && String.sub href 0 2 = "//" then
        (match scheme_of base with Some s -> s ^ ":" ^ href | None -> "http:" ^ href)
      else if href.[0] = '/' then origin ^ remove_dots href
      else if href.[0] = '#' then fst (strip_fragment base) ^ href
      else if href.[0] = '?' then origin ^ without_query path ^ href
      else begin
        let path = without_query path in
        let dir = match String.rindex_opt path '/' with
          | Some i -> String.sub path 0 (i + 1) | None -> "/" in
        origin ^ remove_dots (dir ^ href)
      end

let known = [ "http"; "https"; "file"; "about"; "mailto"; "javascript"; "tel"; "data" ]

(* what the user typed: a URL, a path, or a host ("example.com") *)
let of_typed s =
  let s = String.trim s in
  if s = "" then "about:start"
  else if (match scheme_of s with Some k -> List.mem k known | None -> false) then s
  else if s.[0] = '/' then "file:" ^ s
  else if (s.[0] >= '0' && s.[0] <= '9') || String.starts_with ~prefix:"localhost" s then "http://" ^ s
  else "https://" ^ s

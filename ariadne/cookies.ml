(* Cookies (RFC 6265's essentials): a jar, what Set-Cookie puts in it, what
   a request sends. No input or output (the Loader keeps the jar, and
   saves it); the time is the caller's, in seconds since 1970. There is no
   public suffix list: a Domain attribute must have a dot and contain the
   request's host. *)

type cookie = {
  name : string;
  value : string;
  domain : string;            (* lower case, without a leading dot *)
  host_only : bool;           (* no Domain attribute: that host only *)
  path : string;
  secure : bool;
  http_only : bool;
  expires : float option;     (* None: until the browser closes *)
  created : float;
}

type t = { mutable cookies : cookie list }   (* the most recently set first *)

let create () = { cookies = [] }

let max_cookies = 3000
let max_per_domain = 60

(* ---- dates (RFC 6265, 5.1.1: tolerant) ---- *)

let months = [ "jan"; "feb"; "mar"; "apr"; "may"; "jun"; "jul"; "aug"; "sep"; "oct"; "nov"; "dec" ]

(* days from 1970-01-01 to y-m-d (the proleptic Gregorian calendar) *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - era * 400 in
  let mp = (m + 9) mod 12 in
  let doy = (153 * mp + 2) / 5 + d - 1 in
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy in
  era * 146097 + doe - 719468

let parse_date s =
  let tokens = List.filter (fun t -> t <> "")
      (String.split_on_char ' ' (String.map (fun c -> match c with
           | ',' | '-' | ';' | '\t' -> ' ' | c -> c) s)) in
  let time = ref None and day = ref None and month = ref None and year = ref None in
  List.iter (fun t ->
      let t = String.lowercase_ascii t in
      match String.split_on_char ':' t with
      | [ h; mi; se ] when !time = None ->
        (match int_of_string_opt h, int_of_string_opt mi, int_of_string_opt se with
         | Some h, Some mi, Some se -> time := Some (h, mi, se) | _ -> ())
      | _ ->
        if !month = None && String.length t >= 3 && List.mem (String.sub t 0 3) months then begin
          let m = String.sub t 0 3 in
          let rec idx i = function x :: r -> if x = m then i else idx (i + 1) r | [] -> 1 in
          month := Some (idx 1 months)
        end
        else match int_of_string_opt t with
          | Some n when String.length t <= 2 && !day = None && n >= 1 && n <= 31 -> day := Some n
          | Some n when !year = None && (String.length t = 4 || (String.length t = 2 && !day <> None)) ->
            year := Some (if n < 70 then n + 2000 else if n < 100 then n + 1900 else n)
          | _ -> ()) tokens;
  match !day, !month, !year, !time with
  | Some d, Some m, Some y, Some (h, mi, se) when y >= 1601 && h < 24 && mi < 60 && se < 61 ->
    Some (float (days_from_civil y m d) *. 86400. +. float (h * 3600 + mi * 60 + se))
  | _ -> None

(* ---- matching ---- *)

let domain_match ~host domain =
  host = domain
  || (String.length host > String.length domain
      && String.ends_with ~suffix:("." ^ domain) host
      (* not an IP address *)
      && not (String.for_all (fun c -> (c >= '0' && c <= '9') || c = '.') host))

(* the default path: the request path's directory *)
let default_path path =
  if path = "" || path.[0] <> '/' then "/"
  else match String.rindex_opt path '/' with
    | Some 0 | None -> "/"
    | Some i -> String.sub path 0 i

let path_match ~path cpath =
  path = cpath
  || (String.starts_with ~prefix:cpath path
      && (String.ends_with ~suffix:"/" cpath || (String.length path > String.length cpath && path.[String.length cpath] = '/')))

let expired ~now c = match c.expires with Some e -> e <= now | None -> false

(* ---- Set-Cookie ---- *)

let trim = String.trim

(* a Set-Cookie header, from a response to [host] [path] (https or not) *)
let set t ~now ~host ~path ~secure_origin header =
  let host = String.lowercase_ascii host in
  match String.split_on_char ';' header with
  | [] -> ()
  | first :: attrs ->
    match String.index_opt first '=' with
    | None -> ()
    | Some i ->
      let name = trim (String.sub first 0 i) and value = trim (String.sub first (i + 1) (String.length first - i - 1)) in
      if name = "" then ()
      else begin
        let expires = ref None and max_age = ref None and domain = ref None and cpath = ref None in
        let secure = ref false and http_only = ref false in
        List.iter (fun a ->
            let k, v = match String.index_opt a '=' with
              | Some j -> (String.lowercase_ascii (trim (String.sub a 0 j)), trim (String.sub a (j + 1) (String.length a - j - 1)))
              | None -> (String.lowercase_ascii (trim a), "") in
            match k with
            | "expires" -> (match parse_date v with Some d -> expires := Some d | None -> ())
            | "max-age" -> (match int_of_string_opt v with Some n -> max_age := Some n | None -> ())
            | "domain" when v <> "" ->
              let d = String.lowercase_ascii (if v.[0] = '.' then String.sub v 1 (String.length v - 1) else v) in
              domain := Some d
            | "path" when v <> "" && v.[0] = '/' -> cpath := Some v
            | "secure" -> secure := true
            | "httponly" -> http_only := true
            | _ -> ()) attrs;
        let expires = match !max_age with
          | Some n -> Some (if n <= 0 then 0. else now +. float n)
          | None -> !expires in
        let ok_domain, domain, host_only = match !domain with
          | None -> (true, host, true)
          | Some d -> (String.contains d '.' && domain_match ~host d, d, false) in
        if ok_domain && not (!secure && not secure_origin) then begin
          let c = { name; value; domain; host_only; path = Option.value !cpath ~default:(default_path path);
                    secure = !secure; http_only = !http_only; expires; created = now } in
          let same x = x.name = c.name && x.domain = c.domain && x.path = c.path in
          let created = match List.find_opt same t.cookies with Some old -> old.created | None -> now in
          let live = List.filter (fun x -> not (expired ~now x)) t.cookies in
          (* a cookie replaced keeps its place (and its creation time) *)
          let kept =
            if expired ~now c then List.filter (fun x -> not (same x)) live
            else if List.exists same live then List.map (fun x -> if same x then { c with created } else x) live
            else c :: live in
          (* the limits: the oldest of the domain, then of all, dropped *)
          let in_domain = List.filter (fun x -> x.domain = c.domain) kept in
          let kept = if List.length in_domain > max_per_domain then
              let oldest = List.nth in_domain (List.length in_domain - 1) in
              List.filter (fun x -> x != oldest) kept else kept in
          t.cookies <- List.filteri (fun i _ -> i < max_cookies) kept
        end
      end

(* ---- sending ---- *)

(* the cookies for a request: the Cookie header's value, or None; with
   [script], not the HttpOnly ones (document.cookie) *)
let header ?(script = false) t ~now ~host ~path ~secure =
  let host = String.lowercase_ascii host in
  let fits c =
    not (expired ~now c)
    && (if c.host_only then c.domain = host else domain_match ~host c.domain)
    && path_match ~path c.path
    && (secure || not c.secure)
    && not (script && c.http_only) in
  match List.filter fits t.cookies with
  | [] -> None
  | l ->
    (* longer paths first, then the older first *)
    let l = List.stable_sort (fun a b ->
        compare (String.length b.path, a.created) (String.length a.path, b.created)) (List.rev l) in
    Some (String.concat "; " (List.map (fun c -> c.name ^ "=" ^ c.value) l))

(* ---- the jar as text (those that outlive the session) ---- *)

let to_string t ~now =
  String.concat "" (List.filter_map (fun c ->
      match c.expires with
      | Some e when e > now ->
        Some (String.concat "\t" [ c.name; c.value; c.domain; (if c.host_only then "1" else "0"); c.path;
                                   (if c.secure then "1" else "0"); (if c.http_only then "1" else "0");
                                   Printf.sprintf "%.0f" e; Printf.sprintf "%.0f" c.created ] ^ "\n")
      | _ -> None) t.cookies)

let of_string s =
  { cookies = List.filter_map (fun l ->
        match String.split_on_char '\t' l with
        | [ name; value; domain; host_only; path; secure; http_only; e; created ] ->
          (match float_of_string_opt e, float_of_string_opt created with
           | Some e, Some created ->
             Some { name; value; domain; host_only = host_only = "1"; path; secure = secure = "1";
                    http_only = http_only = "1"; expires = Some e; created }
           | _ -> None)
        | _ -> None) (String.split_on_char '\n' s) }

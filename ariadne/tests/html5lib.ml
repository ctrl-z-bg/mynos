(* Ariadne's HTML parser against html5lib-tests: the tokenizer tests
   (third_party/html5lib-tests/tokenizer/*.test, JSON) and the tree
   construction tests (third_party/wpt-html-parsing/*.dat). On the host only
   (make -C ariadne test). Parse errors are not checked: the parser does not
   report them. Tests that need scripting (#script-on) are skipped: Ariadne
   parses with scripting off.

     html5lib [-v] [--fail-under PERCENT] DIR...
       -v              every failure, with what was expected and what came
       --fail-under N  exit 1 if fewer than N% of the tests pass *)

let verbose = ref false

(* ---- the tree, as the tests print it ---- *)

let serialize ?(fragment = false) (root : Dom.node) =
  let b = Buffer.create 1024 in
  let line depth s = Buffer.add_string b "| "; Buffer.add_string b (String.make (2 * depth) ' ');
    Buffer.add_string b s; Buffer.add_char b '\n' in
  let attr_name (a : Dom.attr) =
    match a.ans with
    | Dom.No_ns -> a.name
    | Dom.Xlink | Dom.Xml | Dom.Xmlns ->
      (match String.index_opt a.name ':' with
       | Some i -> String.sub a.name 0 i ^ " " ^ String.sub a.name (i + 1) (String.length a.name - i - 1)
       | None -> a.name) in
  (* a stack instead of a recursion (the tree may be deep) *)
  let rec node depth (n : Dom.node) =
    (match n.kind with
     | Doctype { name; public_id; system_id } ->
       if public_id = "" && system_id = "" then line depth (Printf.sprintf "<!DOCTYPE %s>" name)
       else line depth (Printf.sprintf "<!DOCTYPE %s \"%s\" \"%s\">" name public_id system_id)
     | Comment { data } -> line depth (Printf.sprintf "<!-- %s -->" data)
     | Pi { target; data } -> line depth (Printf.sprintf "<?%s %s?>" target data)
     | Text { data } -> line depth (Printf.sprintf "\"%s\"" data)
     | Element { name; ns; attrs } ->
       let prefix = match ns with Dom.Html -> "" | Dom.Svg -> "svg " | Dom.Mathml -> "math " in
       line depth (Printf.sprintf "<%s%s>" prefix name);
       let shown = List.sort compare (List.map (fun a -> (attr_name a, a.Dom.value)) attrs) in
       List.iter (fun (k, v) -> line (depth + 1) (Printf.sprintf "%s=\"%s\"" k v)) shown;
       (match n.content with
        | Some c -> line (depth + 1) "content"; List.iter (node (depth + 2)) (Dom.children c)
        | None -> ())
     | Document _ | Fragment -> ());
    List.iter (node (depth + 1)) (Dom.children n) in
  ignore fragment;
  List.iter (node 0) (Dom.children root);
  Buffer.contents b

(* ---- tree construction tests (.dat) ---- *)

type tree_test = { data : string; fragment : string option; script : [ `On | `Off | `Both ]; document : string }

let read_file f = In_channel.with_open_bin f In_channel.input_all

let parse_dat text =
  let lines = String.split_on_char '\n' text in
  let tests = ref [] in
  let section = ref "" and acc = Hashtbl.create 8 in
  let finish () =
    if Hashtbl.mem acc "data" then begin
      let get k = match Hashtbl.find_opt acc k with Some l -> List.rev l | None -> [] in
      let data = String.concat "\n" (get "data") in
      let doc = get "document" in
      (* the blank line between tests is not part of the document *)
      let rec drop_last_blank = function
        | [] -> [] | l -> if List.nth l (List.length l - 1) = "" then drop_last_blank (List.filteri (fun i _ -> i < List.length l - 1) l) else l in
      let doc = drop_last_blank doc in
      let script = if Hashtbl.mem acc "script-on" then `On else if Hashtbl.mem acc "script-off" then `Off else `Both in
      let fragment = match get "document-fragment" with f :: _ -> Some (String.trim f) | [] -> None in
      tests := { data; fragment; script; document = String.concat "\n" doc ^ "\n" } :: !tests
    end;
    Hashtbl.reset acc in
  let headers = [ "#data"; "#errors"; "#new-errors"; "#document"; "#document-fragment"; "#script-on";
                  "#script-off"; "#description" ] in
  List.iter (fun l ->
      if List.mem l headers then begin
        if l = "#data" then finish ();
        section := String.sub l 1 (String.length l - 1);
        if not (Hashtbl.mem acc !section) then Hashtbl.replace acc !section []
      end else
        let prev = Option.value (Hashtbl.find_opt acc !section) ~default:[] in
        Hashtbl.replace acc !section (l :: prev)) lines;
  finish ();
  List.rev !tests

let context_of s =
  match String.index_opt s ' ' with
  | Some i ->
    let ns = match String.sub s 0 i with "svg" -> Dom.Svg | "math" -> Dom.Mathml | _ -> Dom.Html in
    Dom.element ~ns (String.sub s (i + 1) (String.length s - i - 1))
  | None -> Dom.element s

let run_tree_test t =
  let got =
    match t.fragment with
    | Some ctx -> serialize ~fragment:true (Html.parse_fragment ~context:(context_of ctx) t.data)
    | None -> serialize (Html.parse t.data) in
  (got = t.document, got)

(* ---- tokenizer tests (.test, JSON) ---- *)

let utf8 c = let b = Buffer.create 4 in Encoding.add_utf8 b c; Buffer.contents b

(* "\uD800" written out in the test (doubleEscaped): decoded here, a lone
   surrogate as its three bytes, as the tokenizer passes it on *)
let unescape s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if !i + 5 < n && s.[!i] = '\\' && s.[!i + 1] = 'u' then begin
      Buffer.add_string b (utf8 (int_of_string ("0x" ^ String.sub s (!i + 2) 4)));
      i := !i + 6
    end else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

let token_to_json (t : Tokenizer.token) =
  let open Json in
  match t with
  | Doctype { name; public_id; system_id; force_quirks } ->
    let s = function Some x -> String x | None -> Null in
    Some (Array [ String "DOCTYPE"; s name; s public_id; s system_id; Bool (not force_quirks) ])
  | Start_tag { name; attrs; self_closing } ->
    let a = Object (List.map (fun (k, v) -> (k, String v)) attrs) in
    Some (Array ([ String "StartTag"; String name; a ] @ if self_closing then [ Bool true ] else []))
  | End_tag name -> Some (Array [ String "EndTag"; String name ])
  | Comment c -> Some (Array [ String "Comment"; String c ])
  | Pi { target; data } -> Some (Array [ String "ProcessingInstruction"; String target; String data ])
  | Chars c -> Some (Array [ String "Character"; String c ])
  | Eof -> None

(* adjacent characters as one token; attributes in a fixed order *)
let normalize ?(unesc = false) tokens =
  let open Json in
  let u s = if unesc then unescape s else s in
  let rec go acc = function
    | Array [ String "Character"; String a ] :: Array [ String "Character"; String b ] :: rest ->
      go acc (Array [ String "Character"; String (a ^ b) ] :: rest)
    | Array [ String "Character"; String a ] :: rest -> go (Array [ String "Character"; String (u a) ] :: acc) rest
    | Array (String "StartTag" :: String n :: Object a :: tl) :: rest ->
      let a = List.sort compare (List.map (fun (k, v) -> (u k, match v with String s -> String (u s) | v -> v)) a) in
      let tl = match tl with [ Bool false ] -> [] | tl -> tl in
      go (Array (String "StartTag" :: String (u n) :: Object a :: tl) :: acc) rest
    | Array [ String "Comment"; String c ] :: rest -> go (Array [ String "Comment"; String (u c) ] :: acc) rest
    | t :: rest -> go (t :: acc) rest
    | [] -> List.rev acc in
  go [] tokens

let state_of = function
  | "Data state" -> Some Tokenizer.Data | "PLAINTEXT state" -> Some Tokenizer.Plaintext
  | "RCDATA state" -> Some Tokenizer.Rcdata | "RAWTEXT state" -> Some Tokenizer.Rawtext
  | "Script data state" -> Some Tokenizer.Script_data | "CDATA section state" -> Some Tokenizer.Cdata_section
  | _ -> None

let run_tokenizer_test t =
  let open Json in
  let str k = match member k t with String s -> Some s | _ -> None in
  let double = match member "doubleEscaped" t with Bool b -> b | _ -> false in
  let input = Option.value (str "input") ~default:"" in
  let input = if double then unescape input else input in
  let expected = match member "output" t with Array l -> normalize ~unesc:double l | _ -> [] in
  let states = match member "initialStates" t with
    | Array l -> List.filter_map (function String s -> Some s | _ -> None) l
    | _ -> [ "Data state" ] in
  List.for_all (fun st ->
      match state_of st with
      | None -> true
      | Some state ->
        let tk = Tokenizer.create input in
        Tokenizer.set_state tk state;
        (match str "lastStartTag" with Some l -> Tokenizer.set_last_start_tag tk l | None -> ());
        let rec all acc = match Tokenizer.next tk with
          | Tokenizer.Eof -> List.rev acc
          | tok -> all (match token_to_json tok with Some j -> j :: acc | None -> acc) in
        let got = normalize (all []) in
        let ok = got = expected in
        if not ok && !verbose then
          Printf.printf "  FAIL %s (%s)\n    input    %S\n    expected %s\n    got      %s\n"
            (Option.value (str "description") ~default:"") st input
            (Json.to_string (Array expected)) (Json.to_string (Array got));
        ok) states

(* ---- running them ---- *)

let () =
  let dirs = ref [] and fail_under = ref 0. in
  let rec args = function
    | "-v" :: r -> verbose := true; args r
    | "--fail-under" :: n :: r -> fail_under := float_of_string n; args r
    | d :: r -> dirs := d :: !dirs; args r
    | [] -> () in
  args (List.tl (Array.to_list Sys.argv));
  let total = ref 0 and passed = ref 0 and skipped = ref 0 in
  let report kind file p n =
    Printf.printf "html5lib: %-9s %-40s %4d/%-4d%s\n%!" kind (Filename.basename file) p n
      (if p = n then "" else "  (" ^ string_of_int (n - p) ^ " failed)") in
  List.iter (fun dir ->
      let files = List.sort compare (Array.to_list (Sys.readdir dir)) in
      List.iter (fun f ->
          let path = Filename.concat dir f in
          if Filename.check_suffix f ".test" then begin
            let j = Json.of_string (read_file path) in
            match Json.member "tests" j with
            | Json.Array tests ->
              let p = List.length (List.filter (fun t ->
                  try run_tokenizer_test t with e ->
                    if !verbose then Printf.printf "  ERROR %s\n" (Printexc.to_string e); false) tests) in
              report "tokenizer" path p (List.length tests);
              total := !total + List.length tests; passed := !passed + p
            | _ -> ()
          end else if Filename.check_suffix f ".dat" then begin
            let tests = parse_dat (read_file path) in
            let run = List.filter (fun t -> t.script <> `On) tests in
            skipped := !skipped + List.length tests - List.length run;
            let p = List.length (List.filter (fun t ->
                match run_tree_test t with
                | true, _ -> true
                | false, got ->
                  if !verbose then
                    Printf.printf "  FAIL %s\n    data     %S%s\n    expected\n%s    got\n%s"
                      f t.data (match t.fragment with Some c -> " (fragment in " ^ c ^ ")" | None -> "")
                      t.document got;
                  false
                | exception e ->
                  if !verbose then Printf.printf "  ERROR %s %S: %s\n" f t.data (Printexc.to_string e);
                  false) run) in
            report "tree" path p (List.length run);
            total := !total + List.length run; passed := !passed + p
          end) files) (List.rev !dirs);
  let pct = if !total = 0 then 100. else 100. *. float !passed /. float !total in
  Printf.printf "html5lib: %d of %d tests pass (%.2f%%); %d skipped (scripting on)\n" !passed !total pct !skipped;
  if pct < !fail_under then exit 1

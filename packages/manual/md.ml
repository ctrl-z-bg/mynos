(* Md: the manual's Markdown, as lines to show: headings, paragraphs
   wrapped, lists, code blocks and tables kept as they are. Inline marks
   are taken out (`code`, **bold**, *italic*, [links](...)), and what
   was bold is kept as spans. *)

type kind = Heading of int | Para | Code | Table | Blank
type line = { kind : kind; spans : (string * bool) list }   (* text, bold *)

(* the inline marks of a line: its spans *)
let inline s =
  let n = String.length s in
  let spans = ref [] and cur = Buffer.create 80 and bold = ref false in
  let flush () =
    if Buffer.length cur > 0 then spans := (Buffer.contents cur, !bold) :: !spans;
    Buffer.clear cur in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = '*' && !i + 1 < n && s.[!i + 1] = '*' then begin flush (); bold := not !bold; i := !i + 2 end
    else if c = '`' then begin
      (match String.index_from_opt s (!i + 1) '`' with
       | Some j -> Buffer.add_string cur (String.sub s (!i + 1) (j - !i - 1)); i := j + 1
       | None -> Buffer.add_char cur c; incr i)
    end
    else if c = '[' then begin
      (* [text](target): the text *)
      match String.index_from_opt s !i ']' with
      | Some j when j + 1 < n && s.[j + 1] = '(' ->
        (match String.index_from_opt s j ')' with
         | Some k -> Buffer.add_string cur (String.sub s (!i + 1) (j - !i - 1)); i := k + 1
         | None -> Buffer.add_char cur c; incr i)
      | _ -> Buffer.add_char cur c; incr i
    end
    else if c = '*' || (c = '_' && (!i = 0 || s.[!i - 1] = ' ') && !i + 1 < n && s.[!i + 1] <> ' ') then incr i
    else if c = '\\' && !i + 1 < n then begin Buffer.add_char cur s.[!i + 1]; i := !i + 2 end
    else begin Buffer.add_char cur c; incr i end
  done;
  flush ();
  List.rev !spans

let cells s =
  let n = ref 0 in String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s; !n

(* spans wrapped to [width] characters, the first line indented by
   [first], the others by [rest] *)
let wrap width ?(first = "") ?(rest = "") spans =
  (* words, each a list of pieces (a word may change from bold to plain:
     "**OCaml**." is one word) *)
  let words = ref [] and cur = ref [] in
  let end_word () = if !cur <> [] then words := List.rev !cur :: !words; cur := [] in
  List.iter (fun (t, b) ->
      List.iteri (fun i piece ->
          if i > 0 then end_word ();
          if piece <> "" then cur := (piece, b) :: !cur) (String.split_on_char ' ' t)) spans;
  end_word ();
  let words = List.rev !words in
  let lines = ref [] and line = ref [] and len = ref 0 in
  let start () =
    let ind = if !lines = [] then first else rest in
    line := [ (ind, false) ]; len := cells ind in
  start ();
  let fresh () = match !line with [ _ ] -> true | _ -> false in
  List.iter (fun w ->
      let l = List.fold_left (fun a (t, _) -> a + cells t) 0 w in
      if !len + 1 + l > width && not (fresh ()) then begin
        lines := { kind = Para; spans = List.rev !line } :: !lines; start ()
      end;
      if not (fresh ()) then (line := (" ", false) :: !line; incr len);
      List.iter (fun p -> line := p :: !line) w;
      len := !len + l) words;
  if not (fresh ()) then lines := { kind = Para; spans = List.rev !line } :: !lines;
  List.rev !lines

let render width text =
  let out = ref [] in
  let add l = out := l :: !out in
  let blank () = match !out with { kind = Blank; _ } :: _ | [] -> () | _ -> add { kind = Blank; spans = [] } in
  let para = Buffer.create 256 and para_first = ref "" and para_rest = ref "" in
  let end_para () =
    if Buffer.length para > 0 then begin
      List.iter add (wrap width ~first:!para_first ~rest:!para_rest (inline (Buffer.contents para)));
      Buffer.clear para
    end in
  let in_code = ref false in
  List.iter (fun raw ->
      let l = String.trim raw in
      if String.starts_with ~prefix:"```" l then begin
        end_para ();
        if !in_code then (in_code := false; blank ()) else (blank (); in_code := true)
      end
      else if !in_code then add { kind = Code; spans = [ ("    " ^ raw, false) ] }
      else if l = "" then (end_para (); blank ())
      else if l.[0] = '#' then begin
        end_para (); blank ();
        let level = ref 0 in
        while !level < String.length l && l.[!level] = '#' do incr level done;
        let t = String.trim (String.sub l !level (String.length l - !level)) in
        add { kind = Heading !level; spans = List.map (fun (s, _) -> (s, true)) (inline t) };
        blank ()
      end
      else if l.[0] = '|' then begin
        end_para ();
        if not (String.for_all (fun c -> c = '|' || c = '-' || c = ':' || c = ' ') l) then begin
          let cols = List.map String.trim (List.filter (fun c -> String.trim c <> "")
                                             (String.split_on_char '|' l)) in
          add { kind = Table; spans = inline ("  " ^ String.concat "  |  " cols) }
        end
      end
      else if (l.[0] = '-' || l.[0] = '*') && String.length l > 1 && l.[1] = ' ' then begin
        end_para ();
        para_first := "  - "; para_rest := "    ";
        Buffer.add_string para (String.sub l 2 (String.length l - 2))
      end
      else if String.length l > 2 && l.[0] >= '0' && l.[0] <= '9' && String.contains (String.sub l 0 (min 4 (String.length l))) '.' then begin
        end_para ();
        let i = String.index l '.' in
        para_first := "  " ^ String.sub l 0 (i + 1) ^ " "; para_rest := "     ";
        Buffer.add_string para (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
      end
      else begin
        if Buffer.length para = 0 then begin
          para_first := ""; para_rest := "";
          if raw <> "" && raw.[0] = ' ' && String.starts_with ~prefix:"  " raw then begin
            para_first := "    "; para_rest := "    " end
        end else Buffer.add_char para ' ';
        Buffer.add_string para l
      end) (String.split_on_char '\n' text);
  end_para ();
  List.rev !out

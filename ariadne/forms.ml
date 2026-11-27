(* Forms without JavaScript (the HTML Standard, 4.10): what a control is,
   its state, what it shows, and a form's submission. The state lives in
   the DOM (a text field's value attribute, checked, an option's
   selected), so that the layout and the painters read it as they read the
   rest; the window changes it. No input or output here. *)

type kind =
  | Field of { password : bool }      (* a line of text: text, search, email, url... *)
  | Area                              (* textarea *)
  | Check                             (* checkbox *)
  | Radio
  | Button of { submit : bool; reset : bool }
  | Select
  | Not_control

let attr n k = Dom.attr n k

(* the characters of a UTF-8 string *)
let utf8_length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let input_type n = String.lowercase_ascii (String.trim (Option.value (attr n "type") ~default:"text"))

let kind (n : Dom.node) =
  if Dom.is_html n "input" then
    match input_type n with
    | "image" -> Button { submit = true; reset = false }
    | "hidden" | "file" | "range" | "color" -> Not_control
    | "checkbox" -> Check
    | "radio" -> Radio
    | "submit" -> Button { submit = true; reset = false }
    | "reset" -> Button { submit = false; reset = true }
    | "button" -> Button { submit = false; reset = false }
    | "password" -> Field { password = true }
    | _ -> Field { password = false }
  else if Dom.is_html n "textarea" then Area
  else if Dom.is_html n "select" then Select
  else if Dom.is_html n "button" then
    match String.lowercase_ascii (Option.value (attr n "type") ~default:"submit") with
    | "reset" -> Button { submit = false; reset = true }
    | "button" -> Button { submit = false; reset = false }
    | _ -> Button { submit = true; reset = false }
  else Not_control

let disabled n = attr n "disabled" <> None

(* ---- the state, in the DOM ---- *)

let set_attr (n : Dom.node) k v =
  let others = List.filter (fun (a : Dom.attr) -> a.name <> k) (Dom.attrs n) in
  Dom.set_attrs n (match v with
      | Some v -> others @ [ { Dom.name = k; value = v; ans = Dom.No_ns } ]
      | None -> others)

(* a text field's or textarea's value *)
let value (n : Dom.node) =
  if Dom.is_html n "textarea" then Dom.text_content n
  else Option.value (attr n "value") ~default:""

let set_value (n : Dom.node) v =
  if Dom.is_html n "textarea" then begin
    List.iter Dom.remove (Dom.children n);
    Dom.append n (Dom.text v)
  end else set_attr n "value" (Some v)

let checked n = attr n "checked" <> None
let set_checked n b = set_attr n "checked" (if b then Some "" else None)

(* a select's options (in its optgroups too), in order *)
let options (sel : Dom.node) =
  let out = ref [] in
  Dom.walk ~leave:ignore sel ~enter:(fun o ->
      if Dom.is_html o "option" then (out := o :: !out; false) else true);
  List.rev !out

let option_label o = String.trim (Text.collapse (Dom.text_content o))
let option_value o = match attr o "value" with Some v -> v | None -> option_label o

(* the chosen option: the last one marked selected, else the first *)
let selected sel =
  let opts = options sel in
  match List.rev (List.filter (fun o -> attr o "selected" <> None) opts) with
  | o :: _ -> Some o
  | [] -> (match opts with o :: _ -> Some o | [] -> None)

let select sel (o : Dom.node) =
  List.iter (fun p -> set_attr p "selected" (if p == o then Some "" else None)) (options sel)

(* ---- the form ---- *)

(* its form: the form attribute's (an id), else the nearest form ancestor *)
let form_of (n : Dom.node) =
  let rec root (x : Dom.node) = match x.parent with Some p -> root p | None -> x in
  match attr n "form" with
  | Some id -> Dom.find (fun f -> Dom.is_html f "form" && attr f "id" = Some id) (root n)
  | None ->
    let rec up (x : Dom.node) = match x.parent with
      | Some p when Dom.is_html p "form" -> Some p
      | Some p -> up p
      | None -> None in
    up n

(* the form's controls, in document order (those outside it with
   form="its id" too) *)
let controls (form : Dom.node) =
  let rec root (x : Dom.node) = match x.parent with Some p -> root p | None -> x in
  let out = ref [] in
  Dom.walk ~leave:ignore (root form) ~enter:(fun n ->
      if kind n <> Not_control && (match form_of n with Some f -> f == form | None -> false) then
        out := n :: !out;
      true);
  List.rev !out

(* a radio's group: the same name, in the same form (or none) *)
let group (n : Dom.node) =
  match attr n "name" with
  | None | Some "" -> [ n ]
  | Some name ->
    let rec root (x : Dom.node) = match x.parent with Some p -> root p | None -> x in
    let f = form_of n in
    let out = ref [] in
    Dom.walk ~leave:ignore (root n) ~enter:(fun x ->
        if kind x = Radio && attr x "name" = Some name
           && (match form_of x, f with Some a, Some b -> a == b | None, None -> true | _ -> false) then
          out := x :: !out;
        true);
    List.rev !out

(* a click on a check box or a radio button *)
let toggle n =
  match kind n with
  | Check -> set_checked n (not (checked n))
  | Radio -> List.iter (fun r -> set_checked r (r == n)) (group n)
  | _ -> ()

(* ---- what a control shows ---- *)

type shown = {
  text : string;            (* its text: a value, a placeholder, a button's label *)
  placeholder : bool;       (* the text is the placeholder (greyed) *)
  centred : bool;           (* a button's *)
  mark : [ `None | `Check | `Dot ];
}

let shown (n : Dom.node) =
  let plain text = { text; placeholder = false; centred = false; mark = `None } in
  match kind n with
  | Field { password } ->
    let v = value n in
    if v = "" then { (plain (Option.value (attr n "placeholder") ~default:"")) with placeholder = true }
    else if password then plain (String.concat "" (List.init (utf8_length v) (fun _ -> "\xe2\x80\xa2")))
    else plain v
  | Area ->
    let v = value n in
    if v = "" then { (plain (Option.value (attr n "placeholder") ~default:"")) with placeholder = true }
    else plain v
  | Check -> { (plain "") with mark = (if checked n then `Check else `None) }
  | Radio -> { (plain "") with mark = (if checked n then `Dot else `None) }
  | Button _ ->
    let label =
      if Dom.is_html n "button" then String.trim (Text.collapse (Dom.text_content n))
      else match attr n "value" with
        | Some v -> v
        | None -> (match kind n with
            | Button { reset = true; _ } -> "Reset"
            | Button { submit = true; _ } -> if input_type n = "image" then Option.value (attr n "alt") ~default:"Submit" else "Submit"
            | _ -> "") in
    { (plain label) with centred = true }
  | Select -> plain (match selected n with Some o -> option_label o | None -> "")   (* the painter adds an arrow *)
  | Not_control -> plain ""

(* ---- submitting ---- *)

(* application/x-www-form-urlencoded *)
let urlencode s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '*' | '-' | '.' | '_' -> Buffer.add_char b c
      | ' ' -> Buffer.add_char b '+'
      | c -> Printf.bprintf b "%%%02X" (Char.code c)) s;
  Buffer.contents b

let encode pairs = String.concat "&" (List.map (fun (k, v) -> urlencode k ^ "=" ^ urlencode v) pairs)

(* the form data set (4.10.21.4): the controls with a name, not disabled;
   check boxes and radio buttons when checked; the submitter alone of the
   buttons; hidden inputs *)
let data ?submitter (form : Dom.node) =
  let rec root (x : Dom.node) = match x.parent with Some p -> root p | None -> x in
  let out = ref [] in
  Dom.walk ~leave:ignore (root form) ~enter:(fun n ->
      (if (Dom.is_html n "input" || Dom.is_html n "textarea" || Dom.is_html n "select" || Dom.is_html n "button")
          && (match form_of n with Some f -> f == form | None -> false) && not (disabled n) then
         match attr n "name" with
         | None | Some "" -> ()
         | Some name ->
           let add v = out := (name, v) :: !out in
           if Dom.is_html n "input" && input_type n = "hidden" then add (value n)
           else match kind n with
             | Field _ | Area -> add (value n)
             | Check | Radio -> if checked n then add (Option.value (attr n "value") ~default:"on")
             | Select -> Option.iter (fun o -> add (option_value o)) (selected n)
             | Button _ -> (match submitter with
                 | Some s when s == n -> add (Option.value (attr n "value") ~default:"")
                 | _ -> ())
             | Not_control -> ());
      true);
  List.rev !out

type request = Get of string | Post of string * string    (* the URL; the body *)

(* a form submitted (by [submitter], or by Enter in a field): where to go.
   [base]: the document's URL. The submitter's formaction and formmethod
   come before the form's *)
let submit ~base ?submitter (form : Dom.node) =
  let from_submitter k = Option.bind submitter (fun s -> attr s k) in
  let action = match from_submitter "formaction" with
    | Some a -> a | None -> Option.value (attr form "action") ~default:"" in
  let url = if String.trim action = "" then base else Url.resolve base (String.trim action) in
  let meth = String.lowercase_ascii (match from_submitter "formmethod" with
      | Some m -> m | None -> Option.value (attr form "method") ~default:"get") in
  let body = encode (data ?submitter form) in
  if meth = "post" then Post (url, body)
  else
    let url, _ = Url.strip_fragment url in
    let url = match String.index_opt url '?' with Some i -> String.sub url 0 i | None -> url in
    Get (url ^ "?" ^ body)

(* the button Enter submits with: the form's first submit button *)
let default_button form =
  List.find_opt (fun n -> match kind n with Button { submit = true; _ } -> not (disabled n) | _ -> false)
    (controls form)

(* a radio button's look, d x d, as grey masks (0: ink, 255: paper): its
   ring, and the dot of a checked one *)
let circle_mask d ~ring =
  let r = float d /. 2. in
  String.init (d * d) (fun i ->
      let x = float (i mod d) +. 0.5 -. r and y = float (i / d) +. 0.5 -. r in
      let dist = Float.sqrt (x *. x +. y *. y) in
      let ink =
        if ring then Float.max 0. (1. -. Float.abs (dist -. (r -. 1.)) /. 0.9)
        else Float.max 0. (Float.min 1. (r -. 3. -. dist +. 0.5)) in
      Char.chr (255 - int_of_float (ink *. 255.)))

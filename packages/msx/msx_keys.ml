(* The MSX's keyboard (msx_keys.mli). *)

type key = int
type t = int array                      (* a row's keys down, a 1 bit each *)

let rows = [|
  [| "0"; "1"; "2"; "3"; "4"; "5"; "6"; "7" |];
  [| "8"; "9"; "MINUS"; "EQUAL"; "BSLASH"; "LBRACKET"; "RBRACKET"; "SEMICOLON" |];
  [| "QUOTE"; "BACKQUOTE"; "COMMA"; "PERIOD"; "SLASH"; "DEAD"; "A"; "B" |];
  [| "C"; "D"; "E"; "F"; "G"; "H"; "I"; "J" |];
  [| "K"; "L"; "M"; "N"; "O"; "P"; "Q"; "R" |];
  [| "S"; "T"; "U"; "V"; "W"; "X"; "Y"; "Z" |];
  [| "SHIFT"; "CTRL"; "GRAPH"; "CAPS"; "CODE"; "F1"; "F2"; "F3" |];
  [| "F4"; "F5"; "ESC"; "TAB"; "STOP"; "BS"; "SELECT"; "ENTER" |];
  [| "SPACE"; "HOME"; "INS"; "DEL"; "LEFT"; "UP"; "DOWN"; "RIGHT" |];
|]

let create () = Array.make 11 0
let set t k down =
  let r = k lsr 3 and b = 1 lsl (k land 7) in
  t.(r) <- (if down then t.(r) lor b else t.(r) land lnot b)
let clear t = Array.fill t 0 11 0
let read t row = if row < 11 then (lnot t.(row)) land 0xFF else 0xFF

let names =
  "A-Z 0-9 ENTER SPACE SHIFT CTRL GRAPH CAPS CODE ESC TAB STOP BS SELECT HOME INS DEL \
   UP DOWN LEFT RIGHT F1-F5 MINUS EQUAL BSLASH LBRACKET RBRACKET SEMICOLON QUOTE \
   BACKQUOTE COMMA PERIOD SLASH DEAD"

let of_name s =
  let n = match String.uppercase_ascii s with "RETURN" -> "ENTER" | "BACKSPACE" -> "BS" | n -> n in
  let found = ref (-1) in
  Array.iteri (fun r row -> Array.iteri (fun b name -> if name = n then found := r * 8 + b) row) rows;
  if !found < 0 then failwith ("no key " ^ s ^ " (" ^ names ^ ")");
  !found

let shift = of_name "SHIFT"

(* the PC's characters on the MSX's international keyboard, which has
   the same symbols over the same keys as a US one *)
let plain = [ '-', "MINUS"; '=', "EQUAL"; '\\', "BSLASH"; '[', "LBRACKET"; ']', "RBRACKET";
              ';', "SEMICOLON"; '\'', "QUOTE"; '`', "BACKQUOTE"; ',', "COMMA"; '.', "PERIOD";
              '/', "SLASH" ]
let shifted = [ '!', "1"; '@', "2"; '#', "3"; '$', "4"; '%', "5"; '^', "6"; '&', "7"; '*', "8";
                '(', "9"; ')', "0"; '_', "MINUS"; '+', "EQUAL"; '|', "BSLASH"; '{', "LBRACKET";
                '}', "RBRACKET"; ':', "SEMICOLON"; '"', "QUOTE"; '~', "BACKQUOTE"; '<', "COMMA";
                '>', "PERIOD"; '?', "SLASH" ]

let of_char c =
  if c >= 'a' && c <= 'z' then Some [ of_name (String.make 1 (Char.uppercase_ascii c)) ]
  else if c >= 'A' && c <= 'Z' then Some [ shift; of_name (String.make 1 c) ]
  else if c >= '0' && c <= '9' then Some [ of_name (String.make 1 c) ]
  else match List.assoc_opt c plain with
    | Some n -> Some [ of_name n ]
    | None -> match List.assoc_opt c shifted with
      | Some n -> Some [ shift; of_name n ]
      | None -> None

let is_number s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

let parse s =
  List.map (fun w ->
      let keys, frames = match String.index_opt w ':' with
        | Some i ->
          let n = String.sub w (i + 1) (String.length w - i - 1) in
          if not (is_number n) then failwith ("keys: not a number of frames: " ^ w);
          String.sub w 0 i, max 1 (int_of_string n)
        | None -> w, 2 in
      List.map of_name (String.split_on_char '+' keys), frames)
    (List.filter (( <> ) "") (String.split_on_char ' ' s))

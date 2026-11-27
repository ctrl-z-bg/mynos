(* The 48K's keyboard (keyboard.mli): 8 half-rows of 5 keys, a bit each,
   1 while the key is down; port 0xFE reads them inverted. *)

type key =
  | Caps_shift | Symbol_shift | Enter | Space
  | Digit of int
  | Letter of char

type t = int array                      (* the 8 half-rows *)

(* each half-row's keys, bit 0 first *)
let half_rows = [|
  [| Caps_shift; Letter 'Z'; Letter 'X'; Letter 'C'; Letter 'V' |];
  [| Letter 'A'; Letter 'S'; Letter 'D'; Letter 'F'; Letter 'G' |];
  [| Letter 'Q'; Letter 'W'; Letter 'E'; Letter 'R'; Letter 'T' |];
  [| Digit 1; Digit 2; Digit 3; Digit 4; Digit 5 |];
  [| Digit 0; Digit 9; Digit 8; Digit 7; Digit 6 |];
  [| Letter 'P'; Letter 'O'; Letter 'I'; Letter 'U'; Letter 'Y' |];
  [| Enter; Letter 'L'; Letter 'K'; Letter 'J'; Letter 'H' |];
  [| Space; Symbol_shift; Letter 'M'; Letter 'N'; Letter 'B' |];
|]

let where key =
  let rec find r =
    if r = 8 then invalid_arg "Keyboard: no such key"
    else
      let rec col c = if c = 5 then find (r + 1)
        else if half_rows.(r).(c) = key then (r, c) else col (c + 1) in
      col 0 in
  find 0

let create () = Array.make 8 0

let set t key down =
  let r, c = where key in
  t.(r) <- (if down then t.(r) lor (1 lsl c) else t.(r) land lnot (1 lsl c))

let clear t = Array.fill t 0 8 0

let read t high =
  let v = ref 0 in
  for r = 0 to 7 do
    if high land (1 lsl r) = 0 then v := !v lor t.(r)
  done;
  (lnot !v) land 0x1F

let names = "A-Z 0-9 ENTER SPACE CS SS"

let key_of_name s =
  match String.uppercase_ascii s with
  | "ENTER" -> Enter | "SPACE" -> Space
  | "CS" | "CAPS" -> Caps_shift | "SS" | "SYM" | "SYMBOL" -> Symbol_shift
  | n when String.length n = 1 && n.[0] >= 'A' && n.[0] <= 'Z' -> Letter n.[0]
  | n when String.length n = 1 && n.[0] >= '0' && n.[0] <= '9' -> Digit (Char.code n.[0] - 48)
  | _ -> failwith ("no key " ^ s ^ " (" ^ names ^ ")")

let is_number s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

(* a group: names joined by +, then :frames if not 2 *)
let parse s =
  List.map (fun w ->
      let keys, frames = match String.index_opt w ':' with
        | Some i ->
          let n = String.sub w (i + 1) (String.length w - i - 1) in
          if not (is_number n) then failwith ("keys: not a number of frames: " ^ w);
          String.sub w 0 i, max 1 (int_of_string n)
        | None -> w, 2 in
      List.map key_of_name (String.split_on_char '+' keys), frames)
    (List.filter (( <> ) "") (String.split_on_char ' ' s))

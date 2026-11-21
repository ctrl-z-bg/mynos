(* Zvm: the Z-machine, Infocom's virtual machine (the Z-Machine Standards
   Document 1.1), versions 1 to 5, 7 and 8: Zork and the other Infocom
   games of 1979 to 1989, and the games written since with Inform.

   The machine runs until it needs something from outside (a line, a
   key, a file name) and says so; the front end (zmachine.ml: a window,
   or a terminal) gives it, and runs it again. What it prints goes to a
   [screen] the front end draws. *)

exception Error of string
let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(* {1 The screen, as the game sees it} *)

type style = { reverse : bool; bold : bool; italic : bool; fixed : bool }
let plain = { reverse = false; bold = false; italic = false; fixed = false }

type screen = {
  mutable cols : int;
  mutable rows : int;
  mutable upper : (string * style) array array;   (* the upper window: rows x cols *)
  mutable upper_rows : int;
  mutable cur_row : int;                          (* the upper window's cursor, from 0 *)
  mutable cur_col : int;
  mutable window : int;                           (* 0 lower, 1 upper *)
  mutable style : style;
  mutable lower : (string * style) list;          (* printed, not yet taken by the front end *)
  lower_buf : Buffer.t;                           (* the last run of [lower], in [lower_style] *)
  mutable lower_style : style;
  mutable status : (string * string) option;      (* version 3: the place, the score or time *)
  mutable cleared : bool;                         (* the lower window was erased *)
}

let new_screen cols rows =
  { cols; rows; upper = [||]; upper_rows = 0; cur_row = 0; cur_col = 0; window = 0;
    style = plain; lower = []; lower_buf = Buffer.create 256; lower_style = plain;
    status = None; cleared = false }

let split s n =
  let old = s.upper in
  s.upper <- Array.init n (fun r ->
      if r < Array.length old then old.(r) else Array.make s.cols (" ", plain));
  s.upper_rows <- n;
  if s.cur_row >= n then begin s.cur_row <- 0; s.cur_col <- 0 end

let clear_upper s =
  Array.iter (fun row -> Array.fill row 0 (Array.length row) (" ", plain)) s.upper;
  s.cur_row <- 0; s.cur_col <- 0

(* a character (UTF-8) to the window in use *)
let rec put s ch =
  if s.window = 1 then begin
    if ch = "\n" then begin s.cur_row <- s.cur_row + 1; s.cur_col <- 0 end
    else if s.cur_row < s.upper_rows && s.cur_col < s.cols then begin
      s.upper.(s.cur_row).(s.cur_col) <- (ch, s.style);
      s.cur_col <- s.cur_col + 1
    end
  end else lower_text s ch

and lower_text s text =
  if s.style <> s.lower_style then begin
    if Buffer.length s.lower_buf > 0 then
      s.lower <- (Buffer.contents s.lower_buf, s.lower_style) :: s.lower;
    Buffer.clear s.lower_buf;
    s.lower_style <- s.style
  end;
  Buffer.add_string s.lower_buf text

(* what the lower window was given since the last call, in order *)
let take_lower s =
  if Buffer.length s.lower_buf > 0 then
    s.lower <- (Buffer.contents s.lower_buf, s.lower_style) :: s.lower;
  Buffer.clear s.lower_buf;
  let l = List.rev s.lower in s.lower <- []; l

let drop_lower s = s.lower <- []; Buffer.clear s.lower_buf

(* {1 The machine} *)

type frame = {
  ret_pc : int;
  store : int option;                  (* the variable the result goes to *)
  locals : int array;
  stack_base : int;                    (* the stack's size when it was called *)
  args : int;
  id : int;                            (* for catch and throw *)
}

type wants =
  | Line of int                        (* the most characters a line may have *)
  | Key
  | File_name of [ `Save | `Restore ]
  | Quit

type vm = {
  story : string;                      (* the file, as it was: restart and verify *)
  mem : Bytes.t;
  version : int;
  mutable pc : int;
  mutable stack : int array;
  mutable sp : int;
  mutable frames : frame list;
  mutable frame_ids : int;
  screen : screen;
  mutable streams3 : (int * Buffer.t) list;   (* output stream 3: tables *)
  mutable screen_on : bool;
  mutable random : Random.State.t;
  mutable predictable : (int * int) option;   (* random with a negative seed: a sequence *)
  mutable pending : (int * int) option;       (* a read's text and parse tables, or read_char's store *)
  mutable pending_kind : [ `Read | `Char | `Save of int | `Restore of int ] option;
  mutable undo : (Bytes.t * int array * int * frame list * int) list;   (* the last first, 10 at most *)
  mutable name : string;                      (* the story's name, for saved games *)
}

let byte vm a = Char.code (Bytes.unsafe_get vm.mem a)
let word vm a = (byte vm a lsl 8) lor byte vm (a + 1)
let set_byte vm a v = Bytes.unsafe_set vm.mem a (Char.unsafe_chr (v land 255))
let set_word vm a v = set_byte vm a (v lsr 8); set_byte vm (a + 1) v

let signed v = if v land 0x8000 <> 0 then v - 0x10000 else v
let u16 v = v land 0xFFFF

let static_start vm = word vm 0x0E
let globals vm = word vm 0x0C
let check_write vm a = if a < 0 || a >= static_start vm then error "a write to static memory (%d)" a

let unpack vm ~routine p =
  match vm.version with
  | 1 | 2 | 3 -> 2 * p
  | 4 | 5 -> 4 * p
  | 6 | 7 -> 4 * p + 8 * word vm (if routine then 0x28 else 0x2A)
  | _ -> 8 * p

(* {2 The stack and the variables} *)

let push vm v =
  if vm.sp >= Array.length vm.stack then begin
    let s = Array.make (2 * Array.length vm.stack) 0 in
    Array.blit vm.stack 0 s 0 vm.sp; vm.stack <- s
  end;
  vm.stack.(vm.sp) <- u16 v; vm.sp <- vm.sp + 1

let pop vm =
  let base = match vm.frames with f :: _ -> f.stack_base | [] -> 0 in
  if vm.sp <= base then error "the stack is empty";
  vm.sp <- vm.sp - 1; vm.stack.(vm.sp)

let peek vm =
  let base = match vm.frames with f :: _ -> f.stack_base | [] -> 0 in
  if vm.sp <= base then error "the stack is empty";
  vm.stack.(vm.sp - 1)

let locals vm = match vm.frames with f :: _ -> f.locals | [] -> [||]

let read_var vm v =
  if v = 0 then pop vm
  else if v < 16 then
    (let l = locals vm in if v > Array.length l then error "no local %d" v else l.(v - 1))
  else word vm (globals vm + 2 * (v - 16))

let write_var vm v x =
  let x = u16 x in
  if v = 0 then push vm x
  else if v < 16 then
    (let l = locals vm in if v > Array.length l then error "no local %d" v else l.(v - 1) <- x)
  else set_word vm (globals vm + 2 * (v - 16)) x

(* the instructions that name a variable read the stack's top in place *)
let read_var_in_place vm v = if v = 0 then peek vm else read_var vm v
let write_var_in_place vm v x =
  if v = 0 then (ignore (pop vm); push vm x) else write_var vm v x

(* {2 Text} *)

let a2_v1 = " 0123456789.,!?_#'\"/\\<-:()"
let a2 = " \n0123456789.,!?_#'\"/\\-:()"

let alphabet vm n =
  let custom = if vm.version >= 5 then word vm 0x34 else 0 in
  if custom <> 0 then String.init 26 (fun i -> Char.chr (byte vm (custom + 26 * n + i)))
  else match n with
    | 0 -> "abcdefghijklmnopqrstuvwxyz"
    | 1 -> "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    | _ -> if vm.version = 1 then a2_v1 else a2

(* ZSCII 155-251: the default table of accented letters *)
let extra = [| "ä"; "ö"; "ü"; "Ä"; "Ö"; "Ü"; "ß"; "»"; "«"; "ë"; "ï"; "ÿ"; "Ë"; "Ï"; "á"; "é"; "í";
               "ó"; "ú"; "ý"; "Á"; "É"; "Í"; "Ó"; "Ú"; "Ý"; "à"; "è"; "ì"; "ò"; "ù"; "À"; "È"; "Ì";
               "Ò"; "Ù"; "â"; "ê"; "î"; "ô"; "û"; "Â"; "Ê"; "Î"; "Ô"; "Û"; "å"; "Å"; "ø"; "Ø"; "ã";
               "ñ"; "õ"; "Ã"; "Ñ"; "Õ"; "æ"; "Æ"; "ç"; "Ç"; "þ"; "ð"; "Þ"; "Ð"; "£"; "œ"; "Œ"; "¡";
               "¿" |]

let utf8 cp =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b (Uchar.of_int cp); Buffer.contents b

let zscii_string vm c =
  if c = 13 then "\n"
  else if c >= 32 && c <= 126 then String.make 1 (Char.chr c)
  else if c >= 155 && c <= 251 then begin
    let ut = if vm.version >= 5 && word vm 0x36 <> 0 && word vm 0x36 + 6 < Bytes.length vm.mem
               && word vm (word vm 0x36) >= 3 then word vm (word vm 0x36 + 6) else 0 in
    if ut <> 0 then
      (let n = byte vm ut in
       if c - 155 < n then utf8 (word vm (ut + 1 + 2 * (c - 155))) else "?")
    else if c - 155 < Array.length extra then extra.(c - 155) else "?"
  end else if c = 9 then " " else ""

(* the text at [addr]: its characters, and the address after it *)
let rec decode vm addr =
  let b = Buffer.create 64 in
  let zchars = ref [] and a = ref addr and fin = ref false in
  while not !fin do
    let w = word vm !a in
    zchars := (w land 31) :: ((w lsr 5) land 31) :: ((w lsr 10) land 31) :: !zchars;
    a := !a + 2;
    if w land 0x8000 <> 0 || !a + 1 >= Bytes.length vm.mem then fin := true
  done;
  let zs = Array.of_list (List.rev !zchars) in
  let n = Array.length zs in
  let lock = ref 0 and temp = ref (-1) in
  let i = ref 0 in
  while !i < n do
    let z = zs.(!i) in
    let alpha = if !temp >= 0 then !temp else !lock in
    temp := -1;
    (match z with
     | 0 -> Buffer.add_char b ' '
     | 1 when vm.version = 1 -> Buffer.add_char b '\n'
     | 1 | 2 | 3 when vm.version >= 3 || (vm.version = 2 && z = 1) ->
       if !i + 1 < n then begin
         let idx = 32 * (z - 1) + zs.(!i + 1) in
         let at = word vm (word vm 0x18 + 2 * idx) in
         Buffer.add_string b (fst (decode vm (2 * at)));
         incr i
       end
     | 2 | 3 -> temp := (!lock + z - 1) mod 3          (* versions 1 and 2 *)
     | 4 | 5 when vm.version <= 2 -> lock := (!lock + z - 3) mod 3
     | 4 | 5 -> temp := z - 3
     | 6 when alpha = 2 ->
       if !i + 2 < n then begin
         Buffer.add_string b (zscii_string vm ((zs.(!i + 1) lsl 5) lor zs.(!i + 2)));
         i := !i + 2
       end else i := n
     | 7 when alpha = 2 && vm.version > 1 -> Buffer.add_char b '\n'
     | _ ->
       let c = (alphabet vm alpha).[z - 6] in
       Buffer.add_string b (if Char.code c >= 155 then zscii_string vm (Char.code c) else String.make 1 c));
    incr i
  done;
  Buffer.contents b, !a

(* a word of the input, as the dictionary keeps it: 6 or 9 Z-characters *)
let encode vm (s : string) =
  let n = if vm.version <= 3 then 6 else 9 in
  let zs = ref [] in
  String.iter (fun c ->
      let c = Char.lowercase_ascii c in
      match String.index_opt (alphabet vm 0) c with
      | Some i -> zs := (i + 6) :: !zs
      | None ->
        match String.index_opt (alphabet vm 2) c with
        | Some i when i >= 2 || vm.version = 1 -> zs := (i + 6) :: (if vm.version <= 2 then 3 else 5) :: !zs
        | _ ->
          let code = Char.code c in
          zs := (code land 31) :: (code lsr 5) :: 6 :: 5 :: !zs) s;
  let zs = List.rev !zs in
  let zs = List.filteri (fun i _ -> i < n) (zs @ List.init n (fun _ -> 5)) in
  let a = Array.of_list zs in
  List.init (n / 3) (fun k ->
      let w = (a.(3 * k) lsl 10) lor (a.(3 * k + 1) lsl 5) lor a.(3 * k + 2) in
      if k = n / 3 - 1 then w lor 0x8000 else w)

(* {2 Output} *)

let print vm s =
  match vm.streams3 with
  | (_, b) :: _ -> Buffer.add_string b s
  | [] ->
    if vm.screen_on && vm.screen.window = 0 then lower_text vm.screen s
    else if vm.screen_on then
      (* by characters: the upper window places each *)
      let d = String.get_utf_8_uchar in
      let rec go i =
        if i < String.length s then begin
          let u = d s i in
          let len = Uchar.utf_decode_length u in
          put vm.screen (String.sub s i len);
          go (i + len)
        end in
      go 0

let print_zscii vm c =
  if c <> 0 then                       (* ZSCII 0 prints nothing *)
  match vm.streams3 with
  | (_, b) :: _ -> Buffer.add_char b (Char.chr (c land 255))
  | [] -> print vm (zscii_string vm c)

(* stream 3 holds ZSCII: what was printed, back to ZSCII (an accented
   letter as its code) *)
let print_text vm s =
  match vm.streams3 with
  | (_, b) :: _ ->
    String.iter (fun c -> Buffer.add_char b (if c = '\n' then '\r' else c)) s
  | [] -> print vm s

(* {2 Objects} *)

let obj_entry_size vm = if vm.version <= 3 then 9 else 14
let obj_addr vm o =
  if o = 0 then error "object 0";
  word vm 0x0A + (if vm.version <= 3 then 31 * 2 else 63 * 2) + (o - 1) * obj_entry_size vm

let parent vm o = if vm.version <= 3 then byte vm (obj_addr vm o + 4) else word vm (obj_addr vm o + 6)
let sibling vm o = if vm.version <= 3 then byte vm (obj_addr vm o + 5) else word vm (obj_addr vm o + 8)
let child vm o = if vm.version <= 3 then byte vm (obj_addr vm o + 6) else word vm (obj_addr vm o + 10)
let set_rel vm o k v =
  if vm.version <= 3 then set_byte vm (obj_addr vm o + 4 + k) v
  else set_word vm (obj_addr vm o + 6 + 2 * k) v
let set_parent vm o v = set_rel vm o 0 v
let set_sibling vm o v = set_rel vm o 1 v
let set_child vm o v = set_rel vm o 2 v

let props vm o = word vm (obj_addr vm o + (if vm.version <= 3 then 7 else 12))

let attr vm o a =
  if o = 0 then false
  else (byte vm (obj_addr vm o + a / 8) lsr (7 - a mod 8)) land 1 = 1

let set_attr vm o a on =
  if o <> 0 then begin
    let addr = obj_addr vm o + a / 8 in
    let bit = 1 lsl (7 - a mod 8) in
    set_byte vm addr (if on then byte vm addr lor bit else byte vm addr land lnot bit)
  end

let obj_name vm o =
  if o = 0 then "" else let p = props vm o in if byte vm p = 0 then "" else fst (decode vm (p + 1))

let remove_obj vm o =
  let p = parent vm o in
  if p <> 0 then begin
    if child vm p = o then set_child vm p (sibling vm o)
    else begin
      let c = ref (child vm p) in
      while !c <> 0 && sibling vm !c <> o do c := sibling vm !c done;
      if !c <> 0 then set_sibling vm !c (sibling vm o)
    end;
    set_parent vm o 0; set_sibling vm o 0
  end

let insert_obj vm o dest =
  remove_obj vm o;
  set_sibling vm o (child vm dest);
  set_child vm dest o;
  set_parent vm o dest

(* a property's number, the address of its data and its length, from
   the address of its size byte *)
let prop_at vm a =
  let b = byte vm a in
  if vm.version <= 3 then (b land 31, a + 1, (b lsr 5) + 1)
  else if b land 0x80 <> 0 then
    (let l = byte vm (a + 1) land 63 in (b land 63, a + 2, if l = 0 then 64 else l))
  else (b land 63, a + 1, if b land 0x40 <> 0 then 2 else 1)

let first_prop vm o = let p = props vm o in p + 1 + 2 * byte vm p

let find_prop vm o n =
  let rec go a =
    let (num, data, len) = prop_at vm a in
    if num = 0 then None
    else if num = n then Some (data, len)
    else if num < n then None
    else go (data + len) in
  go (first_prop vm o)

let prop_len vm addr =
  if addr = 0 then 0
  else
    let b = byte vm (addr - 1) in
    if vm.version <= 3 then (b lsr 5) + 1
    else if b land 0x80 <> 0 then (let l = b land 63 in if l = 0 then 64 else l)
    else if b land 0x40 <> 0 then 2 else 1

let get_prop vm o n =
  match find_prop vm o n with
  | Some (data, 1) -> byte vm data
  | Some (data, _) -> word vm data
  | None -> word vm (word vm 0x0A + 2 * (n - 1))

(* {2 Dictionary and tokenising} *)

let lookup vm dict text =
  let n = byte vm dict in
  let entry_len = byte vm (dict + 1 + n) in
  let count = signed (word vm (dict + 2 + n)) in
  let start = dict + 4 + n in
  let key = encode vm text in
  let words = List.length key in
  let matches a = List.for_all2 (fun i w -> word vm (a + 2 * i) = w) (List.init words Fun.id) key in
  let cmp a =
    let rec go i = function
      | [] -> 0
      | w :: rest -> let c = compare (word vm (a + 2 * i)) w in if c <> 0 then c else go (i + 1) rest in
    go 0 key in
  if count >= 0 then begin
    let lo = ref 0 and hi = ref (count - 1) and found = ref 0 in
    while !lo <= !hi && !found = 0 do
      let mid = (!lo + !hi) / 2 in
      let a = start + mid * entry_len in
      let c = cmp a in
      if c = 0 then found := a else if c < 0 then lo := mid + 1 else hi := mid - 1
    done;
    !found
  end else begin
    let found = ref 0 in
    for i = 0 to - count - 1 do
      let a = start + i * entry_len in
      if !found = 0 && matches a then found := a
    done;
    !found
  end

(* the words of the text (at [text_start], [len] characters) into the
   parse table *)
let tokenise vm text_start len parse ?(dict = 0) ?(skip_unknown = false) () =
  let dict = if dict = 0 then word vm 0x08 else dict in
  let seps = List.init (byte vm dict) (fun i -> Char.chr (byte vm (dict + 1 + i))) in
  let max_words = byte vm parse in
  let words = ref [] in
  let i = ref 0 in
  while !i < len do
    let c = Char.chr (byte vm (text_start + !i)) in
    if c = ' ' then incr i
    else if List.mem c seps then begin words := (!i, 1) :: !words; incr i end
    else begin
      let s = !i in
      while !i < len && (let c = Char.chr (byte vm (text_start + !i)) in c <> ' ' && not (List.mem c seps)) do incr i done;
      words := (s, !i - s) :: !words
    end
  done;
  let words = List.filteri (fun k _ -> k < max_words) (List.rev !words) in
  set_byte vm (parse + 1) (List.length words);
  List.iteri (fun k (s, l) ->
      let t = String.init l (fun j -> Char.chr (byte vm (text_start + s + j))) in
      let d = lookup vm dict t in
      let e = parse + 2 + 4 * k in
      if not (skip_unknown && d = 0) then begin
        set_word vm e d;
        set_byte vm (e + 2) l;
        set_byte vm (e + 3) (s + if vm.version <= 4 then 1 else 2)
      end) words

(* {2 Calls and returns} *)

let call vm addr args store =
  if addr = 0 then (match store with Some v -> write_var vm v 0 | None -> ())
  else begin
    let a = unpack vm ~routine:true addr in
    let n = byte vm a in
    if n > 15 then error "a routine with %d locals at %d" n a;
    let locals =
      if vm.version <= 4 then Array.init n (fun i -> word vm (a + 1 + 2 * i))
      else Array.make n 0 in
    List.iteri (fun i v -> if i < n then locals.(i) <- v) args;
    vm.frame_ids <- vm.frame_ids + 1;
    vm.frames <- { ret_pc = vm.pc; store; locals; stack_base = vm.sp; args = List.length args;
                   id = vm.frame_ids } :: vm.frames;
    vm.pc <- (if vm.version <= 4 then a + 1 + 2 * n else a + 1)
  end

let return vm v =
  match vm.frames with
  | f :: rest ->
    vm.sp <- f.stack_base;
    vm.frames <- rest;
    vm.pc <- f.ret_pc;
    (match f.store with Some var -> write_var vm var v | None -> ())
  | [] -> error "a return from the main routine"

(* {2 Saving} *)

(* the frames, their locals copied: they change after a snapshot *)
let copy_frames fs = List.map (fun f -> { f with locals = Array.copy f.locals }) fs

type saved = {
  s_name : string;
  s_release : int;
  s_serial : string;
  s_dynamic : string;
  s_stack : int array;
  s_sp : int;
  s_frames : frame list;
  s_pc : int;
}

let serial vm = Bytes.sub_string vm.mem 0x12 6

let snapshot vm pc =
  { s_name = vm.name; s_release = word vm 2; s_serial = serial vm;
    s_dynamic = Bytes.sub_string vm.mem 0 (static_start vm);
    s_stack = Array.sub vm.stack 0 vm.sp; s_sp = vm.sp; s_frames = vm.frames; s_pc = pc }

let save_file vm file pc =
  try
    Out_channel.with_open_bin file (fun oc ->
        output_string oc "MyNOS Z-machine save 1\n";
        Marshal.to_channel oc (snapshot vm pc) []);
    true
  with Sys_error _ -> false

(* the header's bits the interpreter sets: kept across a restore *)
let keep_header vm f =
  let flags2 = word vm 0x10 and h = Bytes.sub vm.mem 0x1E 8 in
  f ();
  set_word vm 0x10 ((word vm 0x10 land lnot 3) lor (flags2 land 3));
  Bytes.blit h 0 vm.mem 0x1E 8

let restore_file vm file =
  try
    In_channel.with_open_bin file (fun ic ->
        if In_channel.input_line ic <> Some "MyNOS Z-machine save 1" then None
        else
          let (s : saved) = Marshal.from_channel ic in
          if s.s_release <> word vm 2 || s.s_serial <> serial vm then None
          else begin
            keep_header vm (fun () ->
                Bytes.blit_string s.s_dynamic 0 vm.mem 0 (String.length s.s_dynamic));
            vm.stack <- Array.append s.s_stack (Array.make 1024 0);
            vm.sp <- s.s_sp; vm.frames <- s.s_frames;
            vm.frame_ids <- List.fold_left (fun a f -> max a f.id) 0 s.s_frames;
            Some s.s_pc
          end)
  with Sys_error _ | Failure _ | End_of_file -> None

(* {1 Starting} *)

let set_header vm =
  let s = vm.screen in
  let f1 = byte vm 1 in
  if vm.version <= 3 then
    (* a status line, a split screen; not a fixed font by default *)
    set_byte vm 1 ((f1 land lnot 0x10) lor 0x20)
  else begin
    (* bold, italic, fixed; no colours, pictures or timed input *)
    set_byte vm 1 ((f1 land lnot 0xA3) lor 0x1C);
    set_byte vm 0x1E 6; set_byte vm 0x1F (Char.code 'M');
    set_byte vm 0x20 s.rows; set_byte vm 0x21 s.cols;
    if vm.version >= 5 then begin
      set_word vm 0x22 s.cols; set_word vm 0x24 s.rows;
      set_byte vm 0x26 1; set_byte vm 0x27 1;
      set_byte vm 0x2C 2; set_byte vm 0x2D 9
    end
  end;
  (* flags 2: no pictures, mouse, sound or menus; undo, yes *)
  if vm.version >= 5 then set_word vm 0x10 ((word vm 0x10 land lnot 0x1B8) lor 0x10)
  else set_word vm 0x10 (word vm 0x10 land 0x3);
  set_word vm 0x32 0x0101

let reset vm =
  Bytes.blit_string vm.story 0 vm.mem 0 (String.length vm.story);
  set_header vm;
  vm.sp <- 0; vm.frames <- []; vm.streams3 <- []; vm.screen_on <- true;
  vm.pending <- None; vm.pending_kind <- None;
  if vm.version = 6 then error "version 6 (pictures) is not supported"
  else vm.pc <- word vm 6

let create ?(cols = 80) ?(rows = 25) ~name story =
  if String.length story < 64 then error "not a story file";
  let version = Char.code story.[0] in
  if version < 1 || version > 8 || version = 6 then error "a story of version %d: not supported" version;
  let mem = Bytes.make (max (String.length story) 64) '\000' in
  let vm = { story; mem; version; pc = 0; stack = Array.make 1024 0; sp = 0; frames = [];
             frame_ids = 0; screen = new_screen cols rows; streams3 = []; screen_on = true;
             random = Random.State.make_self_init (); predictable = None; pending = None;
             pending_kind = None; undo = []; name } in
  reset vm;
  vm

(* {1 Running} *)

let status_line vm =
  if vm.version <= 3 then begin
    let place = obj_name vm (read_var vm 16) in
    let a = signed (read_var vm 17) and b = read_var vm 18 in
    let right =
      if vm.version = 3 && byte vm 1 land 2 <> 0 then
        Printf.sprintf "Time: %d:%02d %s" (if a mod 12 = 0 then 12 else a mod 12) b
          (if a >= 12 then "pm" else "am")
      else Printf.sprintf "Score: %d  Moves: %d" a b in
    vm.screen.status <- Some (place, right)
  end

exception Stop of wants

(* one instruction *)
let step vm =
  let start_pc = vm.pc in
  let fetch () = let b = byte vm vm.pc in vm.pc <- vm.pc + 1; b in
  let fetch_word () = let w = word vm vm.pc in vm.pc <- vm.pc + 2; w in
  let op = fetch () in
  (* the operands' types: 0 large, 1 small, 2 variable, 3 none *)
  let types_byte b =
    (* the types stop at the first "none" *)
    let rec go acc = function 3 :: _ | [] -> List.rev acc | t :: r -> go (t :: acc) r in
    go [] [ (b lsr 6) land 3; (b lsr 4) land 3; (b lsr 2) land 3; b land 3 ] in
  let form, opnum, types =
    if op = 0xBE && vm.version >= 5 then
      let ext = fetch () in `Ext, ext, types_byte (fetch ())
    else if op < 0x80 then
      `Two, op land 31, [ (if op land 0x40 <> 0 then 2 else 1); (if op land 0x20 <> 0 then 2 else 1) ]
    else if op < 0xC0 then
      let t = (op lsr 4) land 3 in
      if t = 3 then `Zero, op land 15, [] else `One, op land 15, [ t ]
    else if op < 0xE0 then `Two, op land 31, types_byte (fetch ())
    else begin
      let n = op land 31 in
      if n = 12 || n = 26 then
        let b1 = fetch () in let b2 = fetch () in
        `Var, n, types_byte b1 @ (if List.length (types_byte b1) = 4 then types_byte b2 else [])
      else `Var, n, types_byte (fetch ())
    end in
  let args = List.map (function
      | 0 -> fetch_word ()
      | 1 -> fetch ()
      | _ -> read_var vm (fetch ())) types in
  let a = Array.of_list args in
  let n = Array.length a in
  let arg i = if i < n then a.(i) else 0 in
  let store v = write_var vm (fetch ()) v in
  let branch cond =
    let b = fetch () in
    let off = if b land 0x40 <> 0 then b land 63
      else let b2 = fetch () in let o = ((b land 63) lsl 8) lor b2 in if o land 0x2000 <> 0 then o - 0x4000 else o in
    if cond = (b land 0x80 <> 0) then
      (match off with
       | 0 -> return vm 0
       | 1 -> return vm 1
       | o -> vm.pc <- vm.pc + o - 2) in
  let print_here () = let s, after = decode vm vm.pc in vm.pc <- after; print_text vm s in
  let bad () = error "the instruction %d (form %s) at %d" opnum
      (match form with `Two -> "2OP" | `One -> "1OP" | `Zero -> "0OP" | `Var -> "VAR" | `Ext -> "EXT")
      start_pc in
  let s16 i = signed (arg i) in
  let save_game kind = vm.pending_kind <- Some kind; raise (Stop (File_name (match kind with `Save _ -> `Save | _ -> `Restore))) in
  match form, opnum with
  (* 2OP *)
  | `Two, 1 -> branch (n > 1 && List.exists (( = ) (arg 0)) (List.tl args))
  | `Two, 2 -> branch (s16 0 < s16 1)
  | `Two, 3 -> branch (s16 0 > s16 1)
  | `Two, 4 -> let v = signed (u16 (read_var_in_place vm (arg 0) - 1)) in
    write_var_in_place vm (arg 0) v; branch (v < s16 1)
  | `Two, 5 -> let v = signed (u16 (read_var_in_place vm (arg 0) + 1)) in
    write_var_in_place vm (arg 0) v; branch (v > s16 1)
  | `Two, 6 -> branch (arg 0 <> 0 && parent vm (arg 0) = arg 1)
  | `Two, 7 -> branch (arg 0 land arg 1 = arg 1)
  | `Two, 8 -> store (arg 0 lor arg 1)
  | `Two, 9 -> store (arg 0 land arg 1)
  | `Two, 10 -> branch (attr vm (arg 0) (arg 1))
  | `Two, 11 -> set_attr vm (arg 0) (arg 1) true
  | `Two, 12 -> set_attr vm (arg 0) (arg 1) false
  | `Two, 13 -> write_var_in_place vm (arg 0) (arg 1)
  | `Two, 14 -> if arg 0 <> 0 && arg 1 <> 0 then insert_obj vm (arg 0) (arg 1)
  | `Two, 15 -> store (word vm (u16 (arg 0 + 2 * s16 1)))
  | `Two, 16 -> store (byte vm (u16 (arg 0 + s16 1)))
  | `Two, 17 -> store (if arg 0 = 0 then 0 else get_prop vm (arg 0) (arg 1))
  | `Two, 18 -> store (if arg 0 = 0 then 0 else match find_prop vm (arg 0) (arg 1) with Some (d, _) -> d | None -> 0)
  | `Two, 19 ->
    if arg 0 = 0 then store 0
    else if arg 1 = 0 then store (let (num, _, _) = prop_at vm (first_prop vm (arg 0)) in num)
    else (match find_prop vm (arg 0) (arg 1) with
        | Some (d, l) -> let (num, _, _) = prop_at vm (d + l) in store num
        | None -> error "get_next_prop: no property %d" (arg 1))
  | `Two, 20 -> store (s16 0 + s16 1)
  | `Two, 21 -> store (s16 0 - s16 1)
  | `Two, 22 -> store (s16 0 * s16 1)
  | `Two, 23 -> if arg 1 = 0 then error "division by zero" else
      (let q = abs (s16 0) / abs (s16 1) in store (if (s16 0 < 0) <> (s16 1 < 0) then - q else q))
  | `Two, 24 -> if arg 1 = 0 then error "division by zero" else
      (let r = abs (s16 0) mod abs (s16 1) in store (if s16 0 < 0 then - r else r))
  | `Two, 25 -> call vm (arg 0) (List.tl args) (Some (fetch ()))
  | `Two, 26 -> call vm (arg 0) (List.tl args) None
  | `Two, 27 -> ()                                           (* set_colour *)
  | `Two, 28 ->                                              (* throw *)
    let rec unwind () =
      match vm.frames with
      | f :: _ when f.id = arg 1 -> return vm (arg 0)
      | _ :: rest -> vm.frames <- rest; unwind ()
      | [] -> error "throw: no such frame" in
    unwind ()
  (* 1OP *)
  | `One, 0 -> branch (arg 0 = 0)
  | `One, 1 -> let s = if arg 0 = 0 then 0 else sibling vm (arg 0) in store s; branch (s <> 0)
  | `One, 2 -> let c = if arg 0 = 0 then 0 else child vm (arg 0) in store c; branch (c <> 0)
  | `One, 3 -> store (if arg 0 = 0 then 0 else parent vm (arg 0))
  | `One, 4 -> store (prop_len vm (arg 0))
  | `One, 5 -> write_var_in_place vm (arg 0) (signed (read_var_in_place vm (arg 0)) + 1)
  | `One, 6 -> write_var_in_place vm (arg 0) (signed (read_var_in_place vm (arg 0)) - 1)
  | `One, 7 -> print_text vm (fst (decode vm (arg 0)))
  | `One, 8 -> call vm (arg 0) [] (Some (fetch ()))
  | `One, 9 -> if arg 0 <> 0 then remove_obj vm (arg 0)
  | `One, 10 -> print_text vm (obj_name vm (arg 0))
  | `One, 11 -> return vm (arg 0)
  | `One, 12 -> vm.pc <- vm.pc + s16 0 - 2
  | `One, 13 -> print_text vm (fst (decode vm (unpack vm ~routine:false (arg 0))))
  | `One, 14 -> store (read_var_in_place vm (arg 0))
  | `One, 15 -> if vm.version <= 4 then store (lnot (arg 0)) else call vm (arg 0) [] None
  (* 0OP *)
  | `Zero, 0 -> return vm 1
  | `Zero, 1 -> return vm 0
  | `Zero, 2 -> print_here ()
  | `Zero, 3 -> print_here (); print_text vm "\n"; return vm 1
  | `Zero, 4 -> ()
  | `Zero, 5 -> if vm.version >= 5 then bad () else save_game (`Save start_pc)
  | `Zero, 6 -> if vm.version >= 5 then bad () else save_game (`Restore start_pc)
  | `Zero, 7 -> reset vm
  | `Zero, 8 -> return vm (pop vm)
  | `Zero, 9 -> if vm.version >= 5 then store (match vm.frames with f :: _ -> f.id | [] -> 0) else ignore (pop vm)
  | `Zero, 10 -> raise (Stop Quit)
  | `Zero, 11 -> print_text vm "\n"
  | `Zero, 12 -> status_line vm
  | `Zero, 13 ->
    let len = word vm 0x1A * (if vm.version <= 3 then 2 else if vm.version <= 5 then 4 else 8) in
    let sum = ref 0 in
    for i = 0x40 to min len (String.length vm.story) - 1 do sum := (!sum + Char.code vm.story.[i]) land 0xFFFF done;
    branch (!sum = word vm 0x1C)
  | `Zero, 15 -> branch true                                   (* piracy: genuine *)
  (* VAR *)
  | `Var, 0 -> call vm (arg 0) (List.tl args) (Some (fetch ()))
  | `Var, 1 -> let a = u16 (arg 0 + 2 * s16 1) in check_write vm a; set_word vm a (arg 2)
  | `Var, 2 -> let a = u16 (arg 0 + s16 1) in check_write vm a; set_byte vm a (arg 2)
  | `Var, 3 ->
    (match find_prop vm (arg 0) (arg 1) with
     | Some (d, 1) -> set_byte vm d (arg 2)
     | Some (d, _) -> set_word vm d (arg 2)
     | None -> error "put_prop: object %d has no property %d" (arg 0) (arg 1))
  | `Var, 4 ->
    if vm.version <= 3 then status_line vm;
    vm.pending <- Some (arg 0, arg 1);
    vm.pending_kind <- Some `Read;
    (* the store byte (version 5) is read when the line comes *)
    let room = if vm.version <= 4 then byte vm (arg 0) - 1 else byte vm (arg 0) in
    raise (Stop (Line (max 0 room)))
  | `Var, 5 -> print_zscii vm (arg 0)
  | `Var, 6 -> print_text vm (string_of_int (s16 0))
  | `Var, 7 ->
    let r = s16 0 in
    if r > 0 then
      store (match vm.predictable with
          | Some (seed, k) ->
            vm.predictable <- Some (seed, (k mod seed) + 1);
            (k - 1) mod r + 1
          | None -> Random.State.int vm.random r + 1)
    else begin
      if r = 0 then (vm.random <- Random.State.make_self_init (); vm.predictable <- None)
      else if - r < 1000 then vm.predictable <- Some (- r, 1)
      else (vm.random <- Random.State.make [| - r |]; vm.predictable <- None);
      store 0
    end
  | `Var, 8 -> push vm (arg 0)
  | `Var, 9 ->
    if vm.version = 6 then bad ()
    else let v = pop vm in write_var_in_place vm (arg 0) v
  | `Var, 10 -> split vm.screen (arg 0); if vm.version = 3 then clear_upper vm.screen
  | `Var, 11 -> vm.screen.window <- arg 0;
    if arg 0 = 1 then begin vm.screen.cur_row <- 0; vm.screen.cur_col <- 0 end
  | `Var, 12 -> call vm (arg 0) (List.tl args) (Some (fetch ()))
  | `Var, 13 ->
    (match s16 0 with
     | -1 -> split vm.screen 0; vm.screen.cleared <- true; drop_lower vm.screen; vm.screen.window <- 0
     | -2 -> clear_upper vm.screen; vm.screen.cleared <- true; drop_lower vm.screen
     | 0 -> vm.screen.cleared <- true; drop_lower vm.screen
     | 1 -> clear_upper vm.screen
     | _ -> ())
  | `Var, 14 -> ()                                             (* erase_line *)
  | `Var, 15 -> if vm.screen.window = 1 then begin
      vm.screen.cur_row <- max 0 (s16 0 - 1); vm.screen.cur_col <- max 0 (s16 1 - 1) end
  | `Var, 16 -> set_word vm (arg 0) (vm.screen.cur_row + 1); set_word vm (arg 0 + 2) (vm.screen.cur_col + 1)
  | `Var, 17 ->
    let s = arg 0 in
    vm.screen.style <- if s = 0 then plain
      else { reverse = vm.screen.style.reverse || s land 1 <> 0; bold = vm.screen.style.bold || s land 2 <> 0;
             italic = vm.screen.style.italic || s land 4 <> 0; fixed = vm.screen.style.fixed || s land 8 <> 0 }
  | `Var, 18 -> ()                                             (* buffer_mode *)
  | `Var, 19 ->
    (match s16 0 with
     | 1 -> vm.screen_on <- true
     | -1 -> vm.screen_on <- false
     | 3 ->
       if List.length vm.streams3 >= 16 then error "output stream 3 nested too deep";
       vm.streams3 <- (arg 1, Buffer.create 64) :: vm.streams3
     | -3 ->
       (match vm.streams3 with
        | (table, b) :: rest ->
          let s = Buffer.contents b in
          set_word vm table (String.length s);
          String.iteri (fun i c -> set_byte vm (table + 2 + i) (Char.code c)) s;
          vm.streams3 <- rest
        | [] -> ())
     | _ -> ())
  | `Var, 20 -> ()                                             (* input_stream *)
  | `Var, 21 -> ()                                             (* sound_effect *)
  | `Var, 22 ->
    vm.pending_kind <- Some `Char;
    raise (Stop Key)
  | `Var, 23 ->
    let x = arg 0 and table = arg 1 and len = arg 2 in
    let form = if n > 3 then arg 3 else 0x82 in
    let size = form land 0x7F and words = form land 0x80 <> 0 in
    let found = ref 0 in
    let i = ref 0 in
    while !found = 0 && !i < len do
      let a = table + !i * size in
      if (if words then word vm a else byte vm a) = x then found := a;
      incr i
    done;
    store !found; branch (!found <> 0)
  | `Var, 24 -> store (lnot (arg 0))
  | `Var, 25 -> call vm (arg 0) (List.tl args) None
  | `Var, 26 -> call vm (arg 0) (List.tl args) None
  | `Var, 27 ->
    let text = arg 0 in
    let start, len = if vm.version <= 4 then
        (text + 1, let rec l i = if byte vm (text + 1 + i) = 0 then i else l (i + 1) in l 0)
      else (text + 2, byte vm (text + 1)) in
    tokenise vm start len (arg 1) ~dict:(arg 2) ~skip_unknown:(arg 3 <> 0) ()
  | `Var, 28 ->
    let s = String.init (arg 1) (fun i -> Char.chr (byte vm (arg 0 + arg 2 + i))) in
    List.iteri (fun i w -> set_word vm (arg 3 + 2 * i) w) (encode vm s)
  | `Var, 29 ->
    let first = arg 0 and second = arg 1 and size = s16 2 in
    if second = 0 then for i = 0 to abs size - 1 do set_byte vm (first + i) 0 done
    else if size < 0 || first > second then
      for i = 0 to abs size - 1 do set_byte vm (second + i) (byte vm (first + i)) done
    else
      for i = size - 1 downto 0 do set_byte vm (second + i) (byte vm (first + i)) done
  | `Var, 30 ->
    let text = arg 0 and w = arg 1 and h = if n > 2 then arg 2 else 1 and skip = arg 3 in
    let row0 = vm.screen.cur_row and col0 = vm.screen.cur_col in
    for r = 0 to h - 1 do
      if r > 0 then begin
        if vm.screen.window = 1 then begin vm.screen.cur_row <- row0 + r; vm.screen.cur_col <- col0 end
        else print_text vm "\n"
      end;
      for c = 0 to w - 1 do print_zscii vm (byte vm (text + r * (w + skip) + c)) done
    done
  | `Var, 31 -> branch (match vm.frames with f :: _ -> arg 0 <= f.args | [] -> false)
  (* EXT *)
  | `Ext, 0 -> save_game (`Save start_pc)
  | `Ext, 1 -> save_game (`Restore start_pc)
  | `Ext, 2 -> let v = arg 0 and p = s16 1 in store (if p >= 0 then v lsl p else v lsr (- p))
  | `Ext, 3 -> let v = s16 0 and p = s16 1 in store (if p >= 0 then v lsl p else v asr (- p))
  | `Ext, 4 -> store (if arg 0 = 1 || arg 0 = 4 then 1 else 0)
  | `Ext, 9 ->
    (* save_undo: the state as it will be after the store *)
    vm.undo <- List.filteri (fun i _ -> i < 10)
        ((Bytes.sub vm.mem 0 (static_start vm), Array.sub vm.stack 0 vm.sp, vm.sp,
          copy_frames vm.frames, vm.pc) :: vm.undo);
    store 1
  | `Ext, 10 ->
    (match vm.undo with
     | (dyn, stack, sp, frames, pc) :: rest ->
       vm.undo <- rest;
       keep_header vm (fun () -> Bytes.blit dyn 0 vm.mem 0 (Bytes.length dyn));
       vm.stack <- Array.append stack (Array.make 1024 0); vm.sp <- sp;
       vm.frames <- copy_frames frames;
       vm.pc <- pc;
       write_var vm (byte vm (vm.pc)) 2; vm.pc <- vm.pc + 1
     | [] -> store 0)
  | `Ext, 11 -> print_text vm (utf8 (arg 0))
  | `Ext, 12 -> store (if arg 0 < 0x80 || (arg 0 >= 0xA0 && arg 0 < 0x10000) then 3 else 0)
  | `Ext, 13 -> ()                                             (* set_true_colour *)
  | _ -> bad ()

(* run until the machine needs something *)
let run vm =
  try
    while true do step vm done;
    Quit
  with Stop w -> w

(* {1 What the front end gives} *)

(* a line typed: into the text table, tokenised; the machine goes on *)
let give_line vm (line : string) =
  match vm.pending, vm.pending_kind with
  | Some (text, parse), Some `Read ->
    vm.pending <- None; vm.pending_kind <- None;
    (* ASCII, lower case: the dictionary's characters *)
    let line = String.lowercase_ascii line in
    let line = String.map (fun c -> if Char.code c < 32 || Char.code c > 126 then ' ' else c) line in
    if vm.version <= 4 then begin
      let max = byte vm text - 1 in
      let line = if String.length line > max then String.sub line 0 max else line in
      String.iteri (fun i c -> set_byte vm (text + 1 + i) (Char.code c)) line;
      set_byte vm (text + 1 + String.length line) 0;
      if parse <> 0 then tokenise vm (text + 1) (String.length line) parse ()
    end else begin
      let max = byte vm text in
      let line = if String.length line > max then String.sub line 0 max else line in
      String.iteri (fun i c -> set_byte vm (text + 2 + i) (Char.code c)) line;
      set_byte vm (text + 1) (String.length line);
      if parse <> 0 then tokenise vm (text + 2) (String.length line) parse ();
      write_var vm (byte vm vm.pc) 13; vm.pc <- vm.pc + 1
    end
  | _ -> ()

let give_key vm code =
  match vm.pending_kind with
  | Some `Char -> vm.pending_kind <- None; write_var vm (byte vm vm.pc) code; vm.pc <- vm.pc + 1
  | _ -> ()

(* a file name for save or restore ("": given up); what to say *)
let give_file vm file =
  let ok_v3 ok = (* versions 1 to 3 branch, the others store *)
    if vm.version <= 3 then begin
      let b = byte vm vm.pc in
      vm.pc <- vm.pc + 1;
      let off = if b land 0x40 <> 0 then b land 63
        else (let b2 = byte vm vm.pc in vm.pc <- vm.pc + 1;
              let o = ((b land 63) lsl 8) lor b2 in if o land 0x2000 <> 0 then o - 0x4000 else o) in
      if ok = (b land 0x80 <> 0) then
        (match off with 0 -> return vm 0 | 1 -> return vm 1 | o -> vm.pc <- vm.pc + o - 2)
    end in
  match vm.pending_kind with
  | Some (`Save pc) ->
    vm.pending_kind <- None;
    (* the pc saved is the instruction's: the game, restored, finds it
       done, with the answer a restore gives *)
    let after = vm.pc in
    let ok = file <> "" && save_file vm file pc in
    vm.pc <- after;
    if vm.version <= 3 then ok_v3 ok
    else (write_var vm (byte vm vm.pc) (if ok then 1 else 0); vm.pc <- vm.pc + 1);
    if file = "" then "" else if ok then "Saved: " ^ file else "Could not save " ^ file
  | Some (`Restore _) ->
    vm.pending_kind <- None;
    (match if file = "" then None else restore_file vm file with
     | Some pc ->
       (* the save instruction again: its operands skipped, its answer
          "restored" (2), or a branch taken (version 3) *)
       vm.pc <- pc;
       let op = byte vm vm.pc in
       vm.pc <- vm.pc + 1;
       if op = 0xBE then begin
         vm.pc <- vm.pc + 1;
         let types = byte vm vm.pc in
         vm.pc <- vm.pc + 1;
         List.iter (fun sh -> match (types lsr sh) land 3 with
             | 0 -> vm.pc <- vm.pc + 2 | 1 | 2 -> vm.pc <- vm.pc + 1 | _ -> ()) [ 6; 4; 2; 0 ]
       end;
       if vm.version <= 3 then ok_v3 true
       else (write_var vm (byte vm vm.pc) 2; vm.pc <- vm.pc + 1);
       "Restored: " ^ file
     | None ->
       if vm.version <= 3 then ok_v3 false
       else (write_var vm (byte vm vm.pc) 0; vm.pc <- vm.pc + 1);
       if file = "" then "" else "Could not restore " ^ file)
  | _ -> ""

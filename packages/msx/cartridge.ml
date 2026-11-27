(* A cartridge (cartridge.mli). The ROM is kept padded with 0xFF to a
   whole number of banks of 8 KB, a power of two of them for a MegaROM
   (a bank number is masked by their count). [banks]: the 8 KB banks at
   0x4000, 0x6000, 0x8000, 0xA000 (a MegaROM's; a plain ROM has none). *)

type kind = Plain of int | Konami | Konami_scc | Ascii8 | Ascii16

type t = {
  data : Bytes.t;
  size : int;                 (* the file's *)
  kind : kind;
  nbanks : int;               (* of 8 KB, a power of two for a MegaROM *)
  banks : int array;
}

let initial = function
  | Konami | Konami_scc -> [| 0; 1; 2; 3 |]
  | Ascii16 -> [| 0; 1; 0; 1 |]
  | Ascii8 | Plain _ -> [| 0; 0; 0; 0 |]

let word s i = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8)
let has_ab s i = String.length s >= i + 2 && s.[i] = 'A' && s.[i + 1] = 'B'

(* a MegaROM's kind, from the addresses its LD (nnnn),A write to (the
   counts fMSX and openMSX use) *)
let guess s =
  let konami = ref 0 and scc = ref 0 and a8 = ref 0 and a16 = ref 0 in
  for i = 0 to String.length s - 3 do
    if s.[i] = '\x32' then
      match word s (i + 1) with
      | 0x5000 | 0x9000 | 0xB000 -> incr scc
      | 0x4000 | 0x8000 | 0xA000 -> incr konami
      | 0x6800 | 0x7800 -> incr a8
      | 0x6000 -> incr konami; incr a8; incr a16
      | 0x7000 -> incr scc; incr a8; incr a16
      | 0x77FF -> incr a16
      | _ -> ()
  done;
  let best = List.fold_left (fun (k, n) (k', n') -> if n' > n then (k', n') else (k, n))
      (Ascii8, !a8) [ (Ascii16, !a16); (Konami, !konami); (Konami_scc, !scc) ] in
  fst best

let rec pow2 n k = if k >= n then k else pow2 n (2 * k)

let of_string s =
  let size = String.length s in
  if size = 0 then failwith "cartridge: an empty file";
  let kind =
    if size <= 0x10000 then begin
      if has_ab s 0 then
        let init = word s 2 in
        if size <= 0x4000 && init >= 0x8000 && init < 0xC000 then Plain 0x8000
        else Plain 0x4000
      else if has_ab s 0x4000 then Plain 0
      else failwith "cartridge: no MSX ROM (no \"AB\" at its start, nor 16 KB in)"
    end else begin
      if not (has_ab s 0) then failwith "cartridge: a MegaROM without \"AB\" at its start";
      guess s
    end in
  let nbanks = match kind with
    | Plain _ -> (size + 0x1FFF) / 0x2000
    | _ -> pow2 ((size + 0x1FFF) / 0x2000) 1 in
  let data = Bytes.make (nbanks * 0x2000) '\xFF' in
  Bytes.blit_string s 0 data 0 size;
  { data; size; kind; nbanks; banks = initial kind }

let kind t = t.kind

let describe t =
  match t.kind with
  | Plain base -> Printf.sprintf "%d KB at 0x%04X" ((t.size + 1023) / 1024) base
  | k ->
    Printf.sprintf "MegaROM %s, %d KB"
      (match k with Konami -> "Konami" | Konami_scc -> "Konami SCC" | Ascii8 -> "ASCII8"
                  | Ascii16 -> "ASCII16" | Plain _ -> "")
      ((t.size + 1023) / 1024)

let reset t = Array.blit (initial t.kind) 0 t.banks 0 4

let block t i =
  match t.kind with
  | Plain base ->
    let a = i * 0x2000 in
    let len = Bytes.length t.data in
    if len <= 0x2000 && a >= base && a < base + 0x4000 then Some (t.data, 0)   (* 8 KB: twice *)
    else if a >= base && a - base < len then Some (t.data, a - base)
    else None
  | _ ->
    if i < 2 || i > 5 then None
    else Some (t.data, (t.banks.(i - 2) land (t.nbanks - 1)) * 0x2000)

let set t region bank =
  if t.banks.(region) = bank then false else begin t.banks.(region) <- bank; true end

let write t a v =
  match t.kind with
  | Plain _ -> false
  | Konami ->
    if a >= 0x6000 && a < 0xC000 then set t ((a - 0x4000) lsr 13) v else false
  | Konami_scc ->
    if a >= 0x5000 && a < 0xC000 && a land 0x1800 = 0x1000 then set t ((a - 0x4000) lsr 13) v
    else false
  | Ascii8 ->
    if a >= 0x6000 && a < 0x8000 then set t ((a lsr 11) land 3) v else false
  | Ascii16 ->
    if a >= 0x6000 && a < 0x6800 then (let x = set t 0 (2 * v) in let y = set t 1 (2 * v + 1) in x || y)
    else if a >= 0x7000 && a < 0x7800 then (let x = set t 2 (2 * v) in let y = set t 3 (2 * v + 1) in x || y)
    else false

let banks t = Array.copy t.banks
let set_banks t b = Array.blit b 0 t.banks 0 4

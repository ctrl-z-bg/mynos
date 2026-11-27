(* A .tap file, loaded through a trap on LD-BYTES (tape.mli). *)

type t = { blocks : string array; mutable next : int }

let of_string s =
  let n = String.length s in
  let rec go i acc =
    if i = n then Array.of_list (List.rev acc)
    else if i + 2 > n then failwith "tape: not a .tap (a block's length cut)"
    else
      let len = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8) in
      if len = 0 || i + 2 + len > n then failwith "tape: not a .tap (a block longer than the file)"
      else go (i + 2 + len) (String.sub s (i + 2) len :: acc) in
  let blocks = go 0 [] in
  if blocks = [||] then failwith "tape: an empty .tap";
  { blocks; next = 0 }

let blocks t = Array.length t.blocks
let left t = Array.length t.blocks - t.next

let trap t z poke =
  if t.next >= Array.length t.blocks then false
  else begin
    let block = t.blocks.(t.next) in
    t.next <- t.next + 1;
    let a = Z80.get z Z80.A and f = Z80.get z Z80.F in
    let loading = f land 1 <> 0 in
    let ix = Z80.get z Z80.IX and de = Z80.get z Z80.DE in
    let ok =
      if String.length block < 1 || Char.code block.[0] <> a then false   (* another flag: skipped *)
      else begin
        let data = String.length block - 2 in                (* flag and checksum apart *)
        let n = min de (max 0 data) in
        let check = ref (Char.code block.[0]) and same = ref true in
        for i = 0 to n - 1 do
          let b = Char.code block.[i + 1] in
          check := !check lxor b;
          if loading then poke ((ix + i) land 0xFFFF) b
        done;
        if not loading then same := true;
        (* the checksum: of every byte of the block, the flag's included *)
        let all = ref 0 in
        String.iter (fun c -> all := !all lxor Char.code c) block;
        Z80.set z Z80.IX ((ix + n) land 0xFFFF);
        Z80.set z Z80.DE ((de - n) land 0xFFFF);
        n = de && !all = 0 && !same
      end in
    Z80.set z Z80.F (if ok then f lor 1 else f land lnot 1);
    (* LD-BYTES's RET *)
    let sp = Z80.get z Z80.SP in
    let mem = (Z80.bus z).Z80.read in
    Z80.set z Z80.PC (mem sp lor (mem ((sp + 1) land 0xFFFF) lsl 8));
    Z80.set z Z80.SP ((sp + 2) land 0xFFFF);
    true
  end

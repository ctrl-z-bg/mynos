(* .sna and .z80 snapshots of a 48K (snapshot.mli). *)

let b s i = Char.code s.[i]
let w s i = b s i lor (b s (i + 1) lsl 8)

let set_regs z l = List.iter (fun (r, v) -> Z80.set z r v) l

(* ---- .sna: 27 bytes of registers, then 48 KB; the PC on the stack ---- *)

let load_sna s z mem =
  if String.length s <> 27 + 49152 then failwith "snapshot: not a 48K .sna (its size)";
  set_regs z Z80.[ I, b s 0; HL', w s 1; DE', w s 3; BC', w s 5; AF', w s 7;
                   HL, w s 9; DE, w s 11; BC, w s 13; IY, w s 15; IX, w s 17;
                   IFF2, (b s 19) land 4; IFF1, (b s 19) land 4; R, b s 20; AF, w s 21;
                   SP, w s 23; IM, (b s 25) land 3 ];
  Bytes.blit_string s 27 mem 0x4000 49152;
  (* the RETN *)
  let sp = Z80.get z Z80.SP in
  let rd a = Char.code (Bytes.get mem (a land 0xFFFF)) in
  Z80.set z Z80.PC (rd sp lor (rd (sp + 1) lsl 8));
  Z80.set z Z80.SP ((sp + 2) land 0xFFFF);
  b s 26 land 7

let save_sna z mem ~border =
  let ram = Bytes.sub mem 0x4000 49152 in
  let sp = (Z80.get z Z80.SP - 2) land 0xFFFF in
  let pc = Z80.get z Z80.PC in
  let put a v = if a >= 0x4000 then Bytes.set ram (a - 0x4000) (Char.chr (v land 0xFF)) in
  put sp pc; put ((sp + 1) land 0xFFFF) (pc lsr 8);
  let h = Bytes.make 27 '\000' in
  let pb i v = Bytes.set h i (Char.chr (v land 0xFF)) in
  let pw i v = pb i v; pb (i + 1) (v lsr 8) in
  let g r = Z80.get z r in
  pb 0 (g Z80.I); pw 1 (g Z80.HL'); pw 3 (g Z80.DE'); pw 5 (g Z80.BC'); pw 7 (g Z80.AF');
  pw 9 (g Z80.HL); pw 11 (g Z80.DE); pw 13 (g Z80.BC); pw 15 (g Z80.IY); pw 17 (g Z80.IX);
  pb 19 (if g Z80.IFF2 <> 0 then 4 else 0); pb 20 (g Z80.R); pw 21 (g Z80.AF);
  pw 23 sp; pb 25 (g Z80.IM); pb 26 border;
  Bytes.to_string h ^ Bytes.to_string ram

(* ---- .z80 ---- *)

(* ED ED n b: n times b; anything else as it is; [stop] at v1's end mark *)
let unpack s from upto ~v1 =
  let out = Buffer.create 49152 in
  let i = ref from in
  (try
     while !i < upto do
       if v1 && !i + 3 < String.length s && b s !i = 0
          && b s (!i + 1) = 0xED && b s (!i + 2) = 0xED && b s (!i + 3) = 0 then raise Exit;
       if !i + 3 < String.length s && b s !i = 0xED && b s (!i + 1) = 0xED then begin
         for _ = 1 to b s (!i + 2) do Buffer.add_char out s.[!i + 3] done;
         i := !i + 4
       end else begin
         Buffer.add_char out s.[!i]; incr i
       end
     done
   with Exit -> ());
  Buffer.contents out

let pack data =
  let n = String.length data in
  let out = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    let c = data.[!i] in
    let run = ref 1 in
    while !i + !run < n && !run < 255 && data.[!i + !run] = c do incr run done;
    if (c = '\xED' && !run >= 2) || !run >= 5 then begin
      Buffer.add_string out "\xED\xED"; Buffer.add_char out (Char.chr !run); Buffer.add_char out c;
      i := !i + !run
    end else if c = '\xED' then begin
      (* a lone ED: the byte after it as it is, so that no ED ED forms *)
      Buffer.add_char out c; incr i;
      if !i < n then begin Buffer.add_char out data.[!i]; incr i end
    end else begin
      Buffer.add_char out c; incr i
    end
  done;
  Buffer.contents out

let load_z80 s z mem =
  let n = String.length s in
  if n < 30 then failwith "snapshot: not a .z80 (too short)";
  let flags1 = if b s 12 = 255 then 1 else b s 12 in
  let pc0 = w s 6 in
  set_regs z Z80.[ A, b s 0; F, b s 1; BC, w s 2; HL, w s 4; SP, w s 8; I, b s 10;
                   R, (b s 11 land 0x7F) lor ((flags1 land 1) lsl 7); DE, w s 13;
                   BC', w s 15; DE', w s 17; HL', w s 19;
                   AF', (b s 21 lsl 8) lor b s 22; IY, w s 23; IX, w s 25;
                   IFF1, b s 27; IFF2, b s 28; IM, b s 29 land 3 ];
  let border = (flags1 lsr 1) land 7 in
  if pc0 <> 0 then begin                        (* version 1: 48 KB after the header *)
    let ram = if flags1 land 0x20 <> 0 then unpack s 30 n ~v1:true else String.sub s 30 (n - 30) in
    if String.length ram < 49152 then failwith "snapshot: a .z80 cut short";
    Bytes.blit_string ram 0 mem 0x4000 49152;
    Z80.set z Z80.PC pc0
  end else begin
    let extra = w s 30 in
    let version = if extra = 23 then 2 else 3 in
    let mode = b s 34 in
    let is48 = if version = 2 then mode = 0 || mode = 1 else mode = 0 || mode = 1 || mode = 3 in
    if not is48 then failwith "snapshot: a .z80 of another machine than the 48K";
    Z80.set z Z80.PC (w s 32);
    let i = ref (32 + extra) in
    while !i + 3 <= n do
      let len = w s !i and page = b s (!i + 2) in
      let start = !i + 3 in
      let data, next =
        if len = 0xFFFF then String.sub s start (min 16384 (n - start)), start + 16384
        else unpack s start (min n (start + len)) ~v1:false, start + len in
      let at = match page with 8 -> 0x4000 | 4 -> 0x8000 | 5 -> 0xC000 | _ -> -1 in
      if at >= 0 then Bytes.blit_string data 0 mem at (min 16384 (String.length data));
      i := next
    done
  end;
  border

let save_z80 z mem ~border =
  let h = Bytes.make (32 + 54) '\000' in
  let pb i v = Bytes.set h i (Char.chr (v land 0xFF)) in
  let pw i v = pb i v; pb (i + 1) (v lsr 8) in
  let g r = Z80.get z r in
  pb 0 (g Z80.A); pb 1 (g Z80.F); pw 2 (g Z80.BC); pw 4 (g Z80.HL); pw 6 0;
  pw 8 (g Z80.SP); pb 10 (g Z80.I); pb 11 (g Z80.R land 0x7F);
  pb 12 (((g Z80.R) lsr 7) lor ((border land 7) lsl 1));
  pw 13 (g Z80.DE); pw 15 (g Z80.BC'); pw 17 (g Z80.DE'); pw 19 (g Z80.HL');
  pb 21 (g Z80.AF' lsr 8); pb 22 (g Z80.AF'); pw 23 (g Z80.IY); pw 25 (g Z80.IX);
  pb 27 (g Z80.IFF1); pb 28 (g Z80.IFF2); pb 29 (g Z80.IM);
  pw 30 54; pw 32 (g Z80.PC); pb 34 0;
  let b = Buffer.create 50000 in
  Buffer.add_bytes b h;
  List.iter (fun (page, at) ->
      let data = Bytes.sub_string mem at 16384 in
      let packed = pack data in
      if String.length packed >= 16384 then begin
        Buffer.add_string b "\xFF\xFF"; Buffer.add_char b (Char.chr page); Buffer.add_string b data
      end else begin
        let l = String.length packed in
        Buffer.add_char b (Char.chr (l land 0xFF)); Buffer.add_char b (Char.chr (l lsr 8));
        Buffer.add_char b (Char.chr page); Buffer.add_string b packed
      end) [ 8, 0x4000; 4, 0x8000; 5, 0xC000 ];
  Buffer.contents b

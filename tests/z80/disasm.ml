(* Z80_disasm against known instructions: each one's bytes, its text, its
   length; the lengths of every opcode checked against Z80.step's (the
   bytes it consumed), for the plain, CB, ED, DD, FD, DDCB and FDCB
   ones. *)

let cases = [
  "00", "NOP"; "01 34 12", "LD BC,$1234"; "36 7F", "LD (HL),$7F";
  "DD 7E 05", "LD A,(IX+5)"; "FD 74 FE", "LD (IY-2),H"; "DD 26 10", "LD IXH,$10";
  "DD 65", "LD IXH,IXL"; "DD 36 03 99", "LD (IX+3),$99"; "FD CB 02 46", "BIT 0,(IY+2)";
  "DD CB FF 06", "RLC (IX-1)"; "DD CB 01 00", "RLC (IX+1),B"; "CB 7E", "BIT 7,(HL)";
  "ED B0", "LDIR"; "ED 70", "IN F,(C)"; "ED 71", "OUT (C),0"; "ED 4B 00 40", "LD BC,($4000)";
  "10 FE", "DJNZ $0000"; "20 02", "JR NZ,$0004"; "C3 00 80", "JP $8000"; "D3 FE", "OUT ($FE),A";
  "DD E9", "JP (IX)"; "FD 21 00 5C", "LD IY,$5C00"; "DD 09", "ADD IX,BC"; "DD 29", "ADD IX,IX";
  "ED 56", "IM 1"; "FF", "RST $38"; "76", "HALT"; "ED 00", "DB $ED,$00"; "DD 00", "NOP";
]

let () =
  let fails = ref 0 in
  let mem = Bytes.make 0x10000 '\000' in
  let read a = Char.code (Bytes.get mem (a land 0xFFFF)) in
  List.iter (fun (bytes, want) ->
      let bs = List.map (fun s -> int_of_string ("0x" ^ s)) (String.split_on_char ' ' bytes) in
      Bytes.fill mem 0 16 '\000';
      List.iteri (fun i b -> Bytes.set mem i (Char.chr b)) bs;
      let got, len = Z80_disasm.disasm read 0 in
      if got <> want || len <> List.length bs then begin
        incr fails;
        Printf.printf "disasm %s: %S, %d bytes (want %S, %d)\n" bytes got len want (List.length bs)
      end) cases;
  (* lengths: the disassembler's against the bytes the core reads *)
  let z = Z80.create Z80.{ fetch = read; read; write = (fun _ _ -> ());
                           input = (fun _ -> 0xFF); output = (fun _ _ -> ()) } in
  let check prefix =
    for op = 0 to 255 do
      Bytes.fill mem 0 16 '\000';
      List.iteri (fun i b -> Bytes.set mem i (Char.chr b)) (prefix @ [ op; 0; 0; 0 ]);
      (* a prefix's own opcode: not an instruction of this table *)
      let skip = (prefix = [] && (op = 0xCB || op = 0xDD || op = 0xED || op = 0xFD))
                 || ((prefix = [ 0xDD ] || prefix = [ 0xFD ]) && (op = 0xDD || op = 0xFD || op = 0xED || op = 0xCB)) in
      if not skip then begin
        let _, len = Z80_disasm.disasm read 0 in
        Z80.reset z;
        Z80.set z Z80.SP 0x8000;
        (* DJNZ, LDIR... fall through: BC 1; INIR... B 1 *)
        Z80.set z Z80.BC (if prefix = [ 0xED ] && List.mem op [ 0xB2; 0xB3; 0xBA; 0xBB ] then 0x0100
                          else 0x0001);
        Z80.set z Z80.F 0;                  (* conditions: NZ, NC, PO, P taken *)
        ignore (Z80.step z);
        let pc = Z80.get z Z80.PC in
        let jumps = List.mem op [ 0x10; 0x18; 0x20; 0x28; 0x30; 0x38; 0xC0; 0xC2; 0xC3; 0xC4; 0xC7;
                                   0xC8; 0xC9; 0xCA; 0xCC; 0xCD; 0xCF; 0xD0; 0xD2; 0xD4; 0xD7; 0xD8;
                                   0xDA; 0xDC; 0xDF; 0xE0; 0xE2; 0xE4; 0xE7; 0xE8; 0xE9; 0xEA; 0xEC;
                                   0xEF; 0xF0; 0xF2; 0xF4; 0xF7; 0xF8; 0xFA; 0xFC; 0xFF; 0x76 ]
                    || (prefix = [ 0xED ] && List.mem op [ 0x45; 0x4D; 0x55; 0x5D; 0x65; 0x6D; 0x75; 0x7D ]) in
        if not jumps && pc <> len then begin
          incr fails;
          Printf.printf "length %s %02X: disasm %d, core %d\n"
            (String.concat " " (List.map (Printf.sprintf "%02X") prefix)) op len pc
        end
      end
    done in
  List.iter check [ []; [ 0xCB ]; [ 0xED ]; [ 0xDD ]; [ 0xFD ]; [ 0xDD; 0xCB; 0x05 ]; [ 0xFD; 0xCB; 0x05 ] ];
  Printf.printf "disasm: %d failed\n" !fails;
  exit (if !fails = 0 then 0 else 1)

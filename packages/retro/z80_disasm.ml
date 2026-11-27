(* The Z80's instructions as text (z80_disasm.mli): decoded by Z80.decode,
   named from Z80's tables, by the usual x/y/z fields of an opcode (x =
   bits 7-6, y = 5-3, z = 2-0; p = y / 2, q = y mod 2). Numbers in hex
   with $, displacements signed in decimal. *)

let h2 v = Printf.sprintf "$%02X" (v land 0xFF)
let h4 v = Printf.sprintf "$%04X" (v land 0xFFFF)

let disasm read pc =
  let rd a = read (a land 0xFFFF) in
  let pre, op, d, nx = Z80.decode read pc in
  let n () = rd nx and nn () = rd nx lor (rd (nx + 1) lsl 8) in
  let len = ref (nx - pc) in
  let use k = len := max !len (nx + k - pc) in
  let n8 () = use 1; h2 (n ()) and n16 () = use 2; h4 (nn ()) in
  let ix = match pre with Z80.Dd | Z80.Ddcb -> "IX" | Z80.Fd | Z80.Fdcb -> "IY" | _ -> "HL" in
  let idx = if ix = "HL" then "(HL)"
    else Printf.sprintf "(%s%c%d)" ix (if d < 0 then '-' else '+') (abs d) in
  (* a register field, HL's part taken by the index register's (but not
     beside (IX+d), which keeps H and L) *)
  let reg ?(mem = false) k =
    match k with
    | 6 -> idx
    | 4 when ix <> "HL" && not mem -> ix ^ "H"
    | 5 when ix <> "HL" && not mem -> ix ^ "L"
    | _ -> Z80.r8.(k) in
  let rp k = if k = 2 then ix else Z80.rp.(k) in
  let rp2 k = if k = 2 then ix else Z80.rp2.(k) in
  let x = op lsr 6 and y = (op lsr 3) land 7 and z = op land 7 in
  let p = y lsr 1 and q = y land 1 in
  let rel () = use 1; let e = n () in h4 (nx + 1 + (if e >= 128 then e - 256 else e)) in
  let text =
    match pre with
    | Z80.Cb | Z80.Ddcb | Z80.Fdcb ->
      let tgt = if pre = Z80.Cb then reg z else idx in
      let copy = if pre <> Z80.Cb && z <> 6 && x <> 1 then "," ^ Z80.r8.(z) else "" in
      (match x with
       | 0 -> Z80.rot.(y) ^ " " ^ tgt ^ copy
       | 1 -> Printf.sprintf "BIT %d,%s" y tgt
       | 2 -> Printf.sprintf "RES %d,%s%s" y tgt copy
       | _ -> Printf.sprintf "SET %d,%s%s" y tgt copy)
    | Z80.Ed ->
      (match x, z with
       | 1, 0 -> if y = 6 then "IN F,(C)" else "IN " ^ Z80.r8.(y) ^ ",(C)"
       | 1, 1 -> if y = 6 then "OUT (C),0" else "OUT (C)," ^ Z80.r8.(y)
       | 1, 2 -> (if q = 0 then "SBC HL," else "ADC HL,") ^ Z80.rp.(p)
       | 1, 3 -> if q = 0 then "LD (" ^ n16 () ^ ")," ^ Z80.rp.(p)
         else "LD " ^ Z80.rp.(p) ^ ",(" ^ n16 () ^ ")"
       | 1, 4 -> "NEG"
       | 1, 5 -> if y = 1 then "RETI" else "RETN"
       | 1, 6 -> "IM " ^ [| "0"; "0"; "1"; "2"; "0"; "0"; "1"; "2" |].(y)
       | 1, _ -> [| "LD I,A"; "LD R,A"; "LD A,I"; "LD A,R"; "RRD"; "RLD"; "DB $ED,$77"; "DB $ED,$7F" |].(y)
       | 2, _ when z <= 3 && y >= 4 ->
         [| [| "LDI"; "CPI"; "INI"; "OUTI" |]; [| "LDD"; "CPD"; "IND"; "OUTD" |];
            [| "LDIR"; "CPIR"; "INIR"; "OTIR" |]; [| "LDDR"; "CPDR"; "INDR"; "OTDR" |] |].(y - 4).(z)
       | _ -> "DB $ED," ^ h2 op)
    | _ ->
      (match x with
       | 1 -> if op = 0x76 then "HALT"
         else if y = 6 || z = 6 then "LD " ^ reg ~mem:true y ^ "," ^ reg ~mem:true z
         else "LD " ^ reg y ^ "," ^ reg z
       | 2 -> Z80.alu.(y) ^ reg z
       | 0 ->
         (match z with
          | 0 -> (match y with
              | 0 -> "NOP" | 1 -> "EX AF,AF'" | 2 -> "DJNZ " ^ rel () | 3 -> "JR " ^ rel ()
              | _ -> "JR " ^ Z80.cc.(y - 4) ^ "," ^ rel ())
          | 1 -> if q = 0 then "LD " ^ rp p ^ "," ^ n16 () else "ADD " ^ ix ^ "," ^ rp p
          | 2 -> (match q, p with
              | 0, 0 -> "LD (BC),A" | 0, 1 -> "LD (DE),A"
              | 0, 2 -> "LD (" ^ n16 () ^ ")," ^ ix | 0, _ -> "LD (" ^ n16 () ^ "),A"
              | _, 0 -> "LD A,(BC)" | _, 1 -> "LD A,(DE)"
              | _, 2 -> "LD " ^ ix ^ ",(" ^ n16 () ^ ")" | _ -> "LD A,(" ^ n16 () ^ ")")
          | 3 -> (if q = 0 then "INC " else "DEC ") ^ rp p
          | 4 -> "INC " ^ reg y
          | 5 -> "DEC " ^ reg y
          | 6 -> "LD " ^ reg y ^ "," ^ n8 ()
          | _ -> [| "RLCA"; "RRCA"; "RLA"; "RRA"; "DAA"; "CPL"; "SCF"; "CCF" |].(y))
       | _ ->
         (match z with
          | 0 -> "RET " ^ Z80.cc.(y)
          | 1 -> if q = 0 then "POP " ^ rp2 p
            else [| "RET"; "EXX"; "JP (" ^ ix ^ ")"; "LD SP," ^ ix |].(p)
          | 2 -> "JP " ^ Z80.cc.(y) ^ "," ^ n16 ()
          | 3 -> (match y with
              | 0 -> "JP " ^ n16 () | 2 -> "OUT (" ^ n8 () ^ "),A" | 3 -> "IN A,(" ^ n8 () ^ ")"
              | 4 -> "EX (SP)," ^ ix | 5 -> "EX DE,HL" | 6 -> "DI" | 7 -> "EI"
              | _ -> "DB $CB")
          | 4 -> "CALL " ^ Z80.cc.(y) ^ "," ^ n16 ()
          | 5 -> if q = 0 then "PUSH " ^ rp2 p else if p = 0 then "CALL " ^ n16 ()
            else "DB " ^ h2 op
          | 6 -> Z80.alu.(y) ^ n8 ()
          | _ -> "RST " ^ h2 (y * 8))) in
  text, !len

let lines read pc n =
  let b = Buffer.create (n * 40) in
  let pc = ref (pc land 0xFFFF) in
  for _ = 1 to n do
    let text, len = disasm read !pc in
    let bytes = String.concat " " (List.init len (fun i -> Printf.sprintf "%02X" (read ((!pc + i) land 0xFFFF)))) in
    Buffer.add_string b (Printf.sprintf "%04X  %-12s %s\n" !pc bytes text);
    pc := (!pc + len) land 0xFFFF
  done;
  Buffer.contents b

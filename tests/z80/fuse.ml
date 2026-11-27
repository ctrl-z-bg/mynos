(* FUSE's tests of the Z80 (tests.in, tests.expected: FUSE's z80/tests,
   GPL), against packages/retro/z80.ml: each test's registers, state and
   memory set, its instructions run until its T-states are reached, then
   the registers, the state and every byte of memory compared with what
   FUSE's core gave. As FUSE's coretest.c: memory filled with DE AD BE EF,
   a port's read gives its high byte.

     fuse tests.in tests.expected     (exit status 0 if all passed) *)

let hex s = int_of_string ("0x" ^ s)
let words l = List.filter (( <> ) "") (String.split_on_char ' ' l)

(* a file's tests, each its lines up to a blank one *)
let blocks file =
  let ic = open_in file in
  let rec go acc cur =
    match input_line ic with
    | l when String.trim l = "" -> go (if cur = [] then acc else List.rev cur :: acc) []
    | l -> go acc (l :: cur)
    | exception End_of_file -> close_in ic; List.rev (if cur = [] then acc else List.rev cur :: acc) in
  go [] []

let fill mem =
  for i = 0 to 0xFFFF do
    Bytes.set mem i (Char.chr (match i land 3 with 0 -> 0xDE | 1 -> 0xAD | 2 -> 0xBE | _ -> 0xEF))
  done

(* memory lines: "addr bytes... -1" *)
let rec load_memory mem = function
  | l :: rest when (match words l with [ "-1" ] -> false | w :: _ -> String.length w = 4 | [] -> false) ->
    (match words l with
     | a :: bytes ->
       let a = hex a in
       let rec put i = function
         | "-1" :: _ | [] -> ()
         | b :: r -> Bytes.set mem ((a + i) land 0xFFFF) (Char.chr (hex b)); put (i + 1) r in
       put 0 bytes
     | [] -> ());
    load_memory mem rest
  | _ -> ()

let regs = Z80.[ AF; BC; DE; HL; AF'; BC'; DE'; HL'; IX; IY; SP; PC; MEMPTR ]

let () =
  let ins = blocks Sys.argv.(1) and exps = blocks Sys.argv.(2) in
  let mem = Bytes.create 0x10000 in
  let bus = Z80.{ fetch = (fun a -> Char.code (Bytes.unsafe_get mem a));
                  read = (fun a -> Char.code (Bytes.unsafe_get mem a));
                  write = (fun a v -> Bytes.unsafe_set mem a (Char.unsafe_chr v));
                  input = (fun p -> p lsr 8);
                  output = (fun _ _ -> ()) } in
  let z = Z80.create bus in
  let exp_of = Hashtbl.create 2048 in
  List.iter (fun b -> match b with name :: rest -> Hashtbl.replace exp_of name rest | [] -> ()) exps;
  let passed = ref 0 and failed = ref [] in
  List.iter (fun b ->
      match b with
      | name :: r1 :: r2 :: memlines ->
        Z80.reset z;
        fill mem;
        List.iter2 (fun r v -> Z80.set z r (hex v)) regs (words r1);
        let i, r, iff1, iff2, im, halted, until =
          match words r2 with
          | [ i; r; a; b; c; d; e ] -> hex i, hex r, int_of_string a, int_of_string b,
                                       int_of_string c, int_of_string d, int_of_string e
          | _ -> failwith ("bad state line in " ^ name) in
        Z80.set z Z80.I i; Z80.set z Z80.R r; Z80.set z Z80.IFF1 iff1; Z80.set z Z80.IFF2 iff2;
        Z80.set z Z80.IM im;
        if halted <> 0 then failwith ("a halted start in " ^ name);
        load_memory mem memlines;
        let before = Bytes.copy mem in
        Z80.set_tstates z 0;
        while Z80.tstates z < until do ignore (Z80.step z) done;
        (* what FUSE gave *)
        let exp = try Hashtbl.find exp_of name with Not_found -> failwith ("no result for " ^ name) in
        let exp = List.filter (fun l -> l = "" || l.[0] <> ' ') exp in
        (match exp with
         | e1 :: e2 :: emem ->
           let errs = ref [] in
           List.iter2 (fun reg v ->
               let got = Z80.get z reg in
               if got <> hex v then
                 errs := Printf.sprintf "%s %04x (FUSE %s)"
                     (List.assoc reg Z80.[ AF, "AF"; BC, "BC"; DE, "DE"; HL, "HL"; AF', "AF'";
                                           BC', "BC'"; DE', "DE'"; HL', "HL'"; IX, "IX";
                                           IY, "IY"; SP, "SP"; PC, "PC"; MEMPTR, "MEMPTR" ])
                     got v :: !errs) regs (words e1);
           (match words e2 with
            | [ ei; er; ef1; ef2; eim; eh; et ] ->
              let chk n got want = if got <> want then
                  errs := Printf.sprintf "%s %d (FUSE %d)" n got want :: !errs in
              chk "I" (Z80.get z Z80.I) (hex ei);
              chk "R" (Z80.get z Z80.R) (hex er);
              chk "IFF1" (Z80.get z Z80.IFF1) (int_of_string ef1);
              chk "IFF2" (Z80.get z Z80.IFF2) (int_of_string ef2);
              chk "IM" (Z80.get z Z80.IM) (int_of_string eim);
              chk "halted" (Bool.to_int (Z80.halted z)) (int_of_string eh);
              chk "T" (Z80.tstates z) (int_of_string et)
            | _ -> errs := "bad expected state" :: !errs);
           let want = Bytes.copy before in
           load_memory want emem;
           let diffs = ref 0 in
           for a = 0 to 0xFFFF do
             if Bytes.get want a <> Bytes.get mem a then begin
               if !diffs < 3 then
                 errs := Printf.sprintf "(%04x) %02x (FUSE %02x)" a
                     (Char.code (Bytes.get mem a)) (Char.code (Bytes.get want a)) :: !errs;
               incr diffs
             end
           done;
           if !errs = [] then incr passed
           else failed := (name ^ ": " ^ String.concat ", " (List.rev !errs)) :: !failed
         | _ -> failed := (name ^ ": no expected state") :: !failed)
      | _ -> ()) ins;
  List.iter print_endline (List.rev !failed);
  Printf.printf "fuse: %d passed, %d failed\n" !passed (List.length !failed);
  exit (if !failed = [] then 0 else 1)

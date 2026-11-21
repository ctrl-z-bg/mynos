(* hexdump [-n N] [-s OFFSET] [FILE...]: the bytes in hexadecimal, 16 a
   line, and as text on the right (hexdump -C's layout). *)

open Util

let main () =
  let set, files = parse ~valued:"ns" ~flags:"C" ~usage:"[-n N] [-s OFFSET] [FILE...]" "hexdump" in
  let skip = int_value set 's' 0 and limit = int_value set 'n' max_int in
  let all = Buffer.create 4096 in
  each_input files (fun _ ic -> Buffer.add_string all (In_channel.input_all ic));
  let s = Buffer.contents all in
  let len = String.length s in
  let stop = if limit = max_int then len else min len (skip + limit) in
  let off = ref (min skip len) in
  while !off < stop do
    let n = min 16 (stop - !off) in
    let b = Buffer.create 80 in
    Printf.bprintf b "%08x " !off;
    for i = 0 to 15 do
      if i = 8 then Buffer.add_char b ' ';
      if i < n then Printf.bprintf b " %02x" (Char.code s.[!off + i])
      else Buffer.add_string b "   "
    done;
    Buffer.add_string b "  |";
    for i = 0 to n - 1 do
      let c = s.[!off + i] in
      Buffer.add_char b (if c >= ' ' && c <= '~' then c else '.')
    done;
    Buffer.add_char b '|';
    print_endline (Buffer.contents b);
    off := !off + n
  done;
  if stop > skip then Printf.printf "%08x\n" stop;
  finish ()

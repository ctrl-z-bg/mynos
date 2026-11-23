(* mapcat: the external pager from the shell (module Pager, pagerd).

   mapcat FILE...           files written out through it: mapped into
                            memory, each page read by pagerd when touched
   mapcat -c FILE...        each mapping compared with the file read as usual
   mapcat -t FILE           the time for a page, through the pager and read
                            as usual (to the 10 ms of MyNOS's clock)
   mapcat -a PAGES [BUDGET] memory of so many pages (and pagerd's budget set
                            first): each page written, then all read back,
                            through the swap when they are more than the budget
   mapcat -w FILE TEXT      TEXT written at the start of FILE through a shared
                            mapping, then the file read as usual
   mapcat -p FILE           a private mapping changed: the file must not be
   mapcat -s                what pagerd has done *)

let print_stats () =
  let s = Pager.stats () in
  Printf.printf "%d mappings, %d pages given, %d refused; %d in memory of %d; \
                 swap: %d out, %d in; %d written back\n"
    s.Pager.regions s.given s.refused s.resident s.budget s.swapped_out s.swapped_in s.written

let read_file f =
  let ic = open_in_bin f in
  let d = really_input_string ic (in_channel_length ic) in
  close_in ic; d

let fail f e = Printf.eprintf "mapcat: %s: %s\n" f e; exit 1

let guard f k =
  try k () with
  | Failure e | Sys_error e -> fail f e
  | Ipc.Remote_error (_, e) -> fail f e

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [] -> prerr_endline "usage: mapcat FILE... | -c FILE... | -t FILE | -a PAGES [BUDGET] \
                         | -w FILE TEXT | -p FILE | -s"; exit 2
  | [ "-s" ] -> print_stats ()
  | "-a" :: n :: rest ->
    guard "memory" (fun () ->
        let pages = int_of_string n in
        (match rest with [ b ] -> Pager.set_budget (int_of_string b) | _ -> ());
        let before = Pager.stats () in
        let m = Pager.alloc pages in
        (* each page: its number in its first bytes, a letter after *)
        for p = 0 to pages - 1 do
          let o = p * 4096 in
          m.{o} <- p land 255; m.{o + 1} <- p lsr 8; m.{o + 100} <- 65 + p mod 26
        done;
        let same = ref true in
        for p = 0 to pages - 1 do
          let o = p * 4096 in
          if m.{o} <> p land 255 || m.{o + 1} <> p lsr 8 || m.{o + 100} <> 65 + p mod 26
             || m.{o + 200} <> 0 then same := false
        done;
        let after = Pager.stats () in
        Pager.unmap m;
        Printf.printf "mapcat: %d pages of memory: %s (swap: %d out, %d in)\n" pages
          (if !same then "the same" else "DIFFERENT")
          (after.swapped_out - before.swapped_out) (after.swapped_in - before.swapped_in))
  | [ "-w"; f; text ] ->
    guard f (fun () ->
        let m = Pager.map_file ~mode:Pager.Shared f in
        if String.length text > Bigarray.Array1.dim m then fail f "the text is longer than the file";
        String.iteri (fun i c -> m.{i} <- Char.code c) text;
        Pager.unmap m;
        let d = read_file f in
        Printf.printf "mapcat: %s: %s\n" f
          (if String.starts_with ~prefix:text d then "written through the mapping"
           else "NOT WRITTEN"))
  | [ "-p"; f ] ->
    guard f (fun () ->
        let before = read_file f in
        let m = Pager.map_file ~mode:Pager.Private f in
        let seen = m.{0} in
        m.{0} <- (seen + 1) land 255;
        let changed = m.{0} = (seen + 1) land 255 in
        Pager.unmap m;
        Printf.printf "mapcat: %s: %s\n" f
          (if changed && read_file f = before then "changed in memory, not in the file"
           else "WRONG"))
  | [ "-t"; f ] ->
    guard f (fun () ->
        let t0 = Unix.gettimeofday () in
        let m = Pager.map_file f in
        let n = Bigarray.Array1.dim m and sum = ref 0 in
        let i = ref 0 in
        while !i < n do sum := !sum + m.{!i}; i := !i + 4096 done;
        let t1 = Unix.gettimeofday () in
        Pager.unmap m;
        let pages = (n + 4095) / 4096 in
        let ic = open_in_bin f and b = Bytes.create 4096 in
        let t2 = Unix.gettimeofday () in
        for p = 0 to pages - 1 do seek_in ic (p * 4096); ignore (input ic b 0 4096) done;
        let t3 = Unix.gettimeofday () in
        close_in ic;
        Printf.printf "mapcat: %d pages: %.0f us a page through the pager, %.0f us read\n" pages
          ((t1 -. t0) *. 1e6 /. float pages) ((t3 -. t2) *. 1e6 /. float pages))
  | "-c" :: files ->
    List.iter (fun f ->
        guard f (fun () ->
            let data = read_file f in
            let m = Pager.map_file f in
            let n = Bigarray.Array1.dim m in
            let same = ref (n = String.length data) in
            String.iteri (fun i c -> if !same && m.{i} <> Char.code c then same := false) data;
            Pager.unmap m;
            Printf.printf "mapcat: %s: %s (%d bytes, %d pages)\n" f
              (if !same then "the same" else "DIFFERENT") n ((n + 4095) / 4096))) files
  | files ->
    let buf = Bytes.create 4096 in
    List.iter (fun f ->
        guard f (fun () ->
            let m = Pager.map_file f in
            let n = Bigarray.Array1.dim m in
            let i = ref 0 in
            while !i < n do
              let k = min 4096 (n - !i) in
              for j = 0 to k - 1 do Bytes.unsafe_set buf j (Char.unsafe_chr m.{!i + j}) done;
              output stdout buf 0 k;
              i := !i + k
            done;
            Pager.unmap m)) files

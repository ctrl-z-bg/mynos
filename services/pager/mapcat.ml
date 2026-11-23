(* mapcat: files written out through the external pager (module Pager):
   mapped into memory, each page read by pagerd when first touched.
   mapcat -s: what pagerd has done (mappings open, pages given, refused).
   mapcat -c FILE...: each mapping compared with the file read as usual.
   mapcat -t FILE: the time for a page, through the pager (a byte of each
   page touched) and read as usual (4 KB at a time). *)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [] -> prerr_endline "usage: mapcat FILE... | mapcat -s"; exit 2
  | [ "-s" ] ->
    let s = Pager.stats () in
    Printf.printf "%d mappings, %d pages given, %d refused\n" s.Pager.regions s.given s.refused
  | [ "-t"; f ] ->
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
      ((t1 -. t0) *. 1e6 /. float pages) ((t3 -. t2) *. 1e6 /. float pages)
  | "-c" :: files ->
    List.iter (fun f ->
        let ic = open_in_bin f in
        let data = really_input_string ic (in_channel_length ic) in
        close_in ic;
        let m = Pager.map_file f in
        let n = Bigarray.Array1.dim m in
        let same = ref (n = String.length data) in
        String.iteri (fun i c -> if !same && m.{i} <> Char.code c then same := false) data;
        Pager.unmap m;
        Printf.printf "mapcat: %s: %s (%d bytes, %d pages)\n" f
          (if !same then "the same" else "DIFFERENT") n ((n + 4095) / 4096)) files
  | files ->
    let buf = Bytes.create 4096 in
    List.iter (fun f ->
        match Pager.map_file f with
        | m ->
          let n = Bigarray.Array1.dim m in
          let i = ref 0 in
          while !i < n do
            let k = min 4096 (n - !i) in
            for j = 0 to k - 1 do Bytes.unsafe_set buf j (Char.unsafe_chr m.{!i + j}) done;
            output stdout buf 0 k;
            i := !i + k
          done;
          Pager.unmap m
        | exception (Failure e | Sys_error e) -> Printf.eprintf "mapcat: %s: %s\n" f e
        | exception Ipc.Remote_error (_, e) -> Printf.eprintf "mapcat: %s: %s\n" f e) files

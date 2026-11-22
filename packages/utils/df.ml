(* df [-h]: the file systems, their size, used and free space (in KB; -h
   in K, M, G), and where they are: / the RAM disk (memrofs, read-only),
   /tmp the memory (tmpfs), /disk the FAT disk (fatfs). Each one is a
   service, asked through its protocol (fs/1's space). *)

open Util

let mounts = [ "memrofs", "/"; "tmpfs", "/tmp"; "fatfs", "/disk" ]

let main () =
  let set, _ = parse ~flags:"h" ~usage:"[-h]" "df" in
  let show kb = if flag set 'h' then human (kb * 1024) else string_of_int kb in
  Printf.printf "%-10s %9s %9s %9s %5s  %s\n" "Service" (if flag set 'h' then "Size" else "1K-blocks")
    "Used" "Free" "Use%" "Mounted on";
  List.iter (fun (service, at) ->
      match Fs.call (Fs.connect service) Fs.Space with
      | size, free ->
        let used = max 0 (size - free) in
        Printf.printf "%-10s %9s %9s %9s %4d%%  %s\n" service (show size) (show used) (show free)
          (if size > 0 then (used * 100 + size - 1) / size else 0) at
      | exception _ -> warn "%s (%s): no answer" service at) mounts;
  finish ()

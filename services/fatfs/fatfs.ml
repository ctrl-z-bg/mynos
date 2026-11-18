(* fatfs: the FAT filesystem of the disk, written in OCaml. Programs see it
   as /disk (libmynos sends /disk/PATH here as PATH). It reads and writes
   the disk through the block service of the ATA driver (module Block), and
   speaks fs/1, the protocol of the file services (module Fs,
   mynos-lib/include/mynos_fs.h), over typed IPC.

   FAT16 and FAT32, as made by mkfs.fat; directories; 8.3 names (with the
   lower-case flags of Windows NT) and VFAT long names, read and written.
   The whole FAT is kept in memory and written back (to every copy) after
   each change; the sectors read are cached (2 MB, write-through), missing
   ones read in runs, and an open file keeps its cluster chain while the
   FAT does not change. File times come from the clock read at boot. *)

(* ---- protocol: flags and errors as in Fs ---- *)

let o_write = 1 and o_creat = 2 and o_trunc = 4 and o_append = 8

let ok = 0 and not_found = 1 and too_many = 2 and denied = 3
and not_open = 4 and invalid = 5 and no_space = 7 and is_dir = 8
and not_empty = 9 and exists = 10 and not_dir = 11

let name_max = 64
let io_max = 16384

(* a request that fails with a status *)
exception Status of int

(* ---- little-endian fields ---- *)

let u8 b i = Char.code (Bytes.get b i)
let u16 b i = u8 b i lor (u8 b (i + 1) lsl 8)
(* OCaml ints have 31 bits on i386: u32 is for values below 2^30 (sizes,
   counts); 32-bit fields with high bits are handled as two halves *)
let u32 b i = u16 b i lor (u16 b (i + 2) lsl 16)
let set_u8 b i v = Bytes.set b i (Char.chr (v land 0xFF))
let set_u16 b i v = set_u8 b i v; set_u8 b (i + 1) (v lsr 8)
let set_u32 b i v = set_u16 b i (v land 0xFFFF); set_u16 b (i + 2) (v lsr 16)

(* ---- the volume ---- *)

let rec device tries =
  match Block.connect () with
  | d -> d
  | exception Mynos.Error _ when tries > 0 ->
    Mynos.sleep 0.1; device (tries - 1)

let dev = device 100

let boot = Bytes.of_string (Block.read dev 0 1)
let bps = u16 boot 11
let spc = u8 boot 13
let reserved = u16 boot 14
let nfats = u8 boot 16
let root_entries = u16 boot 17
let total = if u16 boot 19 <> 0 then u16 boot 19 else u32 boot 32
let fat_size = if u16 boot 22 <> 0 then u16 boot 22 else u32 boot 36
let root_sectors = (root_entries * 32 + bps - 1) / bps
let root_start = reserved + nfats * fat_size          (* FAT16 root *)
let first_data = root_start + root_sectors
let clusters = (total - first_data) / spc
let fat32 = clusters >= 65525
let root_cluster = if fat32 then u32 boot 44 else 0
let cluster_bytes = spc * bps

let () =
  if bps <> 512 || spc = 0 || clusters < 4085 then
    failwith "fatfs: not a FAT16 or FAT32 volume of 512-byte sectors"

(* ---- the sectors, through a cache ----

   Sectors read are kept (4096 of them, 2 MB; the oldest go first), so
   that a file read twice, a directory looked up at every command (PATH)
   or two readers of one file read the disk once. Writes go to the disk at
   once (write-through) and to the cache. Missing sectors are read in runs:
   one request for consecutive sectors, not one per sector. *)

let cache_max = 4096
let cache : (int, Bytes.t) Hashtbl.t = Hashtbl.create cache_max
let cache_order : int Queue.t = Queue.create ()       (* oldest first *)
let cache_hits = ref 0 and cache_misses = ref 0

let cache_put lba b =
  if not (Hashtbl.mem cache lba) then begin
    while Hashtbl.length cache >= cache_max && not (Queue.is_empty cache_order) do
      Hashtbl.remove cache (Queue.pop cache_order)
    done;
    Queue.push lba cache_order
  end;
  Hashtbl.replace cache lba b

(* n sectors from lba: a fresh buffer (the cache keeps its own copies) *)
let read_sectors lba n =
  let out = Bytes.create (n * bps) in
  let i = ref 0 in
  while !i < n do
    match Hashtbl.find_opt cache (lba + !i) with
    | Some b -> incr cache_hits; Bytes.blit b 0 out (!i * bps) bps; incr i
    | None ->
      (* the run of missing sectors from here: one request *)
      let j = ref (!i + 1) in
      while !j < n && !j - !i < 64 && not (Hashtbl.mem cache (lba + !j)) do incr j done;
      let data = Block.read dev (lba + !i) (!j - !i) in
      cache_misses := !cache_misses + (!j - !i);
      for k = !i to !j - 1 do
        let b = Bytes.of_string (String.sub data ((k - !i) * bps) bps) in
        cache_put (lba + k) b;
        Bytes.blit b 0 out (k * bps) bps
      done;
      i := !j
  done;
  out

let write_sectors lba b =
  Block.write dev lba (Bytes.to_string b);
  for k = 0 to Bytes.length b / bps - 1 do
    cache_put (lba + k) (Bytes.sub b (k * bps) bps)
  done

(* ---- the FAT ---- *)

(* kept whole in memory: read once, not through the cache *)
let fat = Bytes.of_string (Block.read dev reserved fat_size)
let fat_version = ref 0                 (* changes with every change of the FAT *)
let dirty = Array.make fat_size false

let eoc = if fat32 then 0x0FFFFFFF else 0xFFFF
let is_end c = if fat32 then c >= 0x0FFFFFF8 else c >= 0xFFF8

let get_fat c =
  if fat32 then u16 fat (4 * c) lor ((u16 fat (4 * c + 2) land 0x0FFF) lsl 16)
  else u16 fat (2 * c)

(* FAT32 entries have 28 bits: the top 4 are kept *)
let set_fat c v =
  if fat32 then begin
    set_u16 fat (4 * c) (v land 0xFFFF);
    set_u16 fat (4 * c + 2)
      ((u16 fat (4 * c + 2) land 0xF000) lor ((v lsr 16) land 0x0FFF))
  end else set_u16 fat (2 * c) v;
  incr fat_version;
  dirty.((if fat32 then 4 else 2) * c / bps) <- true

(* write the changed sectors of the FAT to every copy *)
let flush_fat () =
  Array.iteri (fun i d ->
      if d then begin
        let s = Bytes.sub fat (i * bps) bps in
        for k = 0 to nfats - 1 do write_sectors (reserved + k * fat_size + i) s done;
        dirty.(i) <- false
      end)
    dirty

let next_free = ref 2

let alloc_cluster () =
  let rec find c n =
    if n = 0 then raise (Status no_space)
    else
      let c = if c >= clusters + 2 then 2 else c in
      if get_fat c = 0 then c else find (c + 1) (n - 1) in
  let c = find !next_free clusters in
  set_fat c eoc;
  next_free := c + 1;
  c

(* the clusters of a chain *)
let chain first =
  let rec go c acc n =
    if c < 2 || is_end c || n > clusters then List.rev acc
    else go (get_fat c) (c :: acc) (n + 1) in
  go first [] 0

let free_chain first = List.iter (fun c -> set_fat c 0) (chain first)

let cluster_lba c = first_data + (c - 2) * spc
let read_cluster c = read_sectors (cluster_lba c) spc
let write_cluster c b = write_sectors (cluster_lba c) b
let zero_cluster c = write_cluster c (Bytes.make cluster_bytes '\000')

(* FAT32: the free-cluster hints become "unknown", as we change the FAT *)
let () =
  if fat32 then begin
    let fsinfo = u16 boot 48 in
    if fsinfo > 0 && fsinfo < reserved then begin
      let s = read_sectors fsinfo 1 in
      if u16 s 0 = 0x5252 && u16 s 2 = 0x4161 then begin   (* "RRaA" *)
        List.iter (fun o -> set_u16 s o 0xFFFF) [ 488; 490; 492; 494 ];
        write_sectors fsinfo s
      end
    end
  end

(* ---- time ---- *)

(* FAT date and time of now (UTC) *)
let fat_now () =
  (* the seconds since 1970 do not fit an OCaml int on i386 (31 bits):
     split them into days and seconds while still a float *)
  let t = Mynos.time () in
  let days = int_of_float (t /. 86400.) in
  let secs = int_of_float (t -. Float.of_int days *. 86400.) in
  (* days since 1970-01-01 to a civil date (Howard Hinnant's algorithm) *)
  let z = days + 719468 in
  let era = z / 146097 in
  let doe = z - era * 146097 in
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 in
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) in
  let mp = (5 * doy + 2) / 153 in
  let d = doy - (153 * mp + 2) / 5 + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = yoe + era * 400 + (if m <= 2 then 1 else 0) in
  let date = ((max 0 (y - 1980)) lsl 9) lor (m lsl 5) lor d in
  let time = ((secs / 3600) lsl 11) lor ((secs / 60 mod 60) lsl 5) lor (secs mod 60 / 2) in
  (date, time)

(* ---- directories ---- *)

(* the FAT16 root is a fixed region; other directories are chains *)
type dir = Root16 | Chain of int

let root = if fat32 then Chain root_cluster else Root16

type loaded = { dir : dir; clus : int list; data : Bytes.t }

let load d =
  match d with
  | Root16 -> { dir = d; clus = []; data = read_sectors root_start root_sectors }
  | Chain c ->
    let cl = chain c in
    { dir = d; clus = cl; data = Bytes.concat Bytes.empty (List.map read_cluster cl) }

let store l =
  match l.dir with
  | Root16 -> write_sectors root_start l.data
  | Chain _ ->
    List.iteri (fun i c -> write_cluster c (Bytes.sub l.data (i * cluster_bytes) cluster_bytes))
      l.clus

let slots l = Bytes.length l.data / 32

type entry = {
  name : string;          (* long name, or the short one *)
  attr : int;
  first : int;            (* first cluster *)
  size : int;
  slot : int;             (* slot of the 8.3 entry *)
  first_slot : int;       (* first slot of its long name entries *)
}

let attr_dir = 0x10 and attr_lfn = 0x0F and attr_volume = 0x08

let short_name b off =
  let part o n = String.trim (Bytes.sub_string b o n) in
  let base = part off 8 and ext = part (off + 8) 3 in
  let nt = u8 b (off + 12) in
  let base = if nt land 0x08 <> 0 then String.lowercase_ascii base else base in
  let ext = if nt land 0x10 <> 0 then String.lowercase_ascii ext else ext in
  if ext = "" then base else base ^ "." ^ ext

let checksum b off =
  let s = ref 0 in
  for i = 0 to 10 do
    s := (((!s land 1) lsl 7) + (!s lsr 1) + u8 b (off + i)) land 0xFF
  done;
  !s

(* UTF-16 code units <-> UTF-8 (the Basic Multilingual Plane) *)
let utf8_of_units units =
  let buf = Buffer.create 32 in
  List.iter (fun u -> Buffer.add_utf_8_uchar buf
                (if Uchar.is_valid u then Uchar.of_int u else Uchar.rep)) units;
  Buffer.contents buf

let units_of_utf8 s =
  let rec go i acc =
    if i >= String.length s then List.rev acc
    else
      let d = String.get_utf_8_uchar s i in
      let u = Uchar.to_int (Uchar.utf_decode_uchar d) in
      go (i + Uchar.utf_decode_length d) ((if u > 0xFFFF then 0x5F else u) :: acc) in
  go 0 []

let lfn_offsets = [ 1; 3; 5; 7; 9; 14; 16; 18; 20; 22; 24; 28; 30 ]

(* the entries of a loaded directory, without "." and ".." *)
let entries l =
  let b = l.data in
  let rec go i lfn lfn_start lfn_sum acc =
    if i >= slots l then List.rev acc
    else
      let off = 32 * i in
      let first_byte = u8 b off in
      if first_byte = 0 then List.rev acc
      else if first_byte = 0xE5 then go (i + 1) [] (-1) 0 acc
      else
        let attr = u8 b (off + 11) in
        if attr = attr_lfn then begin
          let part =
            List.filter_map (fun o ->
                let u = u16 b (off + o) in
                if u = 0 || u = 0xFFFF then None else Some u) lfn_offsets in
          if first_byte land 0x40 <> 0 then go (i + 1) part i (u8 b (off + 13)) acc
          else go (i + 1) (part @ lfn) lfn_start lfn_sum acc
        end else if attr land attr_volume <> 0 then go (i + 1) [] (-1) 0 acc
        else begin
          let short = short_name b off in
          let long_ok = lfn <> [] && lfn_start >= 0 && lfn_sum = checksum b off in
          let e = {
            name = (if long_ok then utf8_of_units lfn else short);
            attr;
            first = u16 b (off + 26) lor (if fat32 then u16 b (off + 20) lsl 16 else 0);
            size = u32 b (off + 28);
            slot = i;
            first_slot = (if long_ok then lfn_start else i);
          } in
          let acc = if short = "." || short = ".." then acc else e :: acc in
          go (i + 1) [] (-1) 0 acc
        end in
  go 0 [] (-1) 0 []

let same a b = String.lowercase_ascii a = String.lowercase_ascii b

let find l name = List.find_opt (fun e -> same e.name name) (entries l)

let entry_dir e = if e.first = 0 then root else Chain e.first

(* the directory containing a path, and the last name of the path *)
let parent path =
  let parts = List.filter (fun s -> s <> "") (String.split_on_char '/' path) in
  match List.rev parts with
  | [] -> raise (Status invalid)
  | last :: rev_dirs ->
    let d =
      List.fold_left (fun d name ->
          match find (load d) name with
          | Some e when e.attr land attr_dir <> 0 -> entry_dir e
          | Some _ -> raise (Status not_dir)
          | None -> raise (Status not_found))
        root (List.rev rev_dirs) in
    (d, last)

(* the directory named by a path ("" is the root) *)
let directory path =
  if String.for_all (fun c -> c = '/') path then root
  else
    let d, name = parent path in
    match find (load d) name with
    | Some e when e.attr land attr_dir <> 0 -> entry_dir e
    | Some _ -> raise (Status not_dir)
    | None -> raise (Status not_found)

(* ---- new entries ---- *)

let short_chars = "!#$%&'()-@^_`{}~"
let short_char c =
  (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || String.contains short_chars c

let split_ext name =
  match String.rindex_opt name '.' with
  | Some i when i > 0 -> (String.sub name 0 i, String.sub name (i + 1) (String.length name - i - 1))
  | _ -> (name, "")

(* the 11-byte short name and NT case flags when the name fits 8.3 *)
let fits_short name =
  let base, ext = split_ext name in
  let uniform s = s = String.lowercase_ascii s || s = String.uppercase_ascii s in
  let valid s = String.for_all short_char (String.uppercase_ascii s) in
  if base <> "" && String.length base <= 8 && String.length ext <= 3
     && valid base && valid ext && uniform base && uniform ext
     && not (String.contains base '.') then
    let pad s n = s ^ String.make (n - String.length s) ' ' in
    let flags =
      (if base <> String.uppercase_ascii base then 0x08 else 0)
      lor (if ext <> String.uppercase_ascii ext then 0x10 else 0) in
    Some (pad (String.uppercase_ascii base) 8 ^ pad (String.uppercase_ascii ext) 3, flags)
  else None

(* a short alias BASIS~N.EXT, unique in the directory *)
let short_alias l name =
  let base, ext = split_ext name in
  let clean s n =
    let s = String.uppercase_ascii s in
    let b = Buffer.create n in
    String.iter (fun c -> if Buffer.length b < n && short_char c then Buffer.add_char b c) s;
    Buffer.contents b in
  let base = clean base 6 and ext = clean ext 3 in
  let base = if base = "" then "FILE" else base in
  let taken =
    List.map (fun e -> String.sub (Bytes.sub_string l.data (32 * e.slot) 11) 0 11)
      (entries l) in
  let rec try_n n =
    let tail = "~" ^ string_of_int n in
    let b = String.sub base 0 (min (String.length base) (8 - String.length tail)) ^ tail in
    let raw = b ^ String.make (8 - String.length b) ' ' ^ ext ^ String.make (3 - String.length ext) ' ' in
    if List.mem raw taken then try_n (n + 1) else raw in
  try_n 1

(* free consecutive slots in a directory, growing it if needed *)
let rec free_slots l k =
  let n = slots l in
  let free i = let b = u8 l.data (32 * i) in b = 0 || b = 0xE5 in
  let rec scan i run =
    if i >= n then None
    else if free i then (if run + 1 = k then Some (i - k + 1) else scan (i + 1) (run + 1))
    else scan (i + 1) 0 in
  match scan 0 0, l.dir with
  | Some s, _ -> (l, s)
  | None, Root16 -> raise (Status no_space)
  | None, Chain _ ->
    let c = alloc_cluster () in
    zero_cluster c;
    set_fat (List.nth l.clus (List.length l.clus - 1)) c;
    flush_fat ();
    free_slots (load l.dir) k

(* write an entry (and its long name) for name in directory d *)
let add_entry d name attr first =
  if name = "" || String.length name > 255 || name = "." || name = ".."
     || String.exists (fun c -> c = '/' || c = '\\' || c < ' ') name then
    raise (Status invalid);
  let l = load d in
  if find l name <> None then raise (Status exists);
  let raw, flags, lfn =
    match fits_short name with
    | Some (raw, flags) -> (raw, flags, [])
    | None ->
      let units = units_of_utf8 name in
      let n = (List.length units + 12) / 13 in
      (* each long entry holds 13 units: the name, a 0, then 0xFFFF *)
      let padded = Array.make (13 * n) 0xFFFF in
      List.iteri (fun i u -> padded.(i) <- u) units;
      if List.length units < 13 * n then padded.(List.length units) <- 0;
      (short_alias l name, 0, List.init n (fun k -> Array.sub padded (13 * k) 13)) in
  let l, s = free_slots l (List.length lfn + 1) in
  let b = l.data in
  let short_off = 32 * (s + List.length lfn) in
  Bytes.fill b short_off 32 '\000';
  Bytes.blit_string raw 0 b short_off 11;
  let sum = checksum b short_off in
  let n = List.length lfn in
  List.iteri (fun k units ->                   (* k = 0: the first 13 units *)
      let off = 32 * (s + n - 1 - k) in
      Bytes.fill b off 32 '\000';
      set_u8 b off ((k + 1) lor (if k = n - 1 then 0x40 else 0));
      set_u8 b (off + 11) attr_lfn;
      set_u8 b (off + 13) sum;
      List.iteri (fun j o -> set_u16 b (off + o) units.(j)) lfn_offsets)
    lfn;
  let date, time = fat_now () in
  set_u8 b (short_off + 11) attr;
  set_u8 b (short_off + 12) flags;
  set_u16 b (short_off + 14) time;
  set_u16 b (short_off + 16) date;
  set_u16 b (short_off + 18) date;
  set_u16 b (short_off + 20) (first lsr 16);
  set_u16 b (short_off + 22) time;
  set_u16 b (short_off + 24) date;
  set_u16 b (short_off + 26) (first land 0xFFFF);
  store l;
  s + n

(* mark an entry and its long name entries deleted *)
let delete_entry d e =
  let l = load d in
  for i = e.first_slot to e.slot do set_u8 l.data (32 * i) 0xE5 done;
  store l

(* ---- open files ---- *)

type desc = {
  client : int;
  ddir : dir;               (* where its entry is *)
  dslot : int;
  mutable dfirst : int;
  mutable dsize : int;
  mutable pos : int;
  writable : bool;
  append : bool;
  mutable dchain : int * int * int array;   (* first, FAT version, its clusters *)
}

(* a file's clusters, kept while the FAT does not change: not walked again
   at every read *)
let clusters_of f =
  let first, version, cl = f.dchain in
  if first = f.dfirst && version = !fat_version then cl
  else begin
    let cl = Array.of_list (chain f.dfirst) in
    f.dchain <- (f.dfirst, !fat_version, cl);
    cl
  end

let descs : (int, desc) Hashtbl.t = Hashtbl.create 16
let next_fd = ref 3

let is_open d slot =
  Hashtbl.fold (fun _ x acc -> acc || (x.ddir = d && x.dslot = slot)) descs false

(* write back the first cluster, size and time of an open file's entry *)
let update_entry f =
  let l = load f.ddir in
  let off = 32 * f.dslot in
  let date, time = fat_now () in
  set_u16 l.data (off + 20) (f.dfirst lsr 16);
  set_u16 l.data (off + 26) (f.dfirst land 0xFFFF);
  set_u32 l.data (off + 28) f.dsize;
  set_u16 l.data (off + 22) time;
  set_u16 l.data (off + 24) date;
  set_u16 l.data (off + 18) date;
  store l

let do_open r name =
  let d, last = parent name in
  let writable = r.(3) land o_write <> 0 in
  let l = load d in
  let f =
    match find l last with
    | Some e when e.attr land attr_dir <> 0 -> raise (Status is_dir)
    | Some e ->
      let f = { client = r.(1); ddir = d; dslot = e.slot; dfirst = e.first;
                dsize = e.size; pos = 0; dchain = (-1, -1, [||]); writable;
                append = r.(3) land o_append <> 0 } in
      if writable && r.(3) land o_trunc <> 0 && e.size > 0 then begin
        free_chain f.dfirst;
        flush_fat ();
        f.dfirst <- 0;
        f.dsize <- 0;
        update_entry f
      end;
      f
    | None when r.(3) land o_creat <> 0 ->
      let slot = add_entry d last 0x20 0 in
      { client = r.(1); ddir = d; dslot = slot; dfirst = 0; dsize = 0; pos = 0; dchain = (-1, -1, [||]);
        writable; append = r.(3) land o_append <> 0 }
    | None -> raise (Status not_found) in
  let fd = !next_fd in
  incr next_fd;
  Hashtbl.replace descs fd f;
  fd

let owned r =
  match Hashtbl.find_opt descs r.(2) with
  | None -> raise (Status not_open)
  | Some f when f.client <> r.(1) -> raise (Status denied)
  | Some f -> f

(* n bytes of a file from pos *)
let read_file f n =
  let n = max 0 (min n (f.dsize - f.pos)) in
  let cl = clusters_of f in
  let buf = Bytes.create n in
  let rec go done_ =
    if done_ < n then begin
      let p = f.pos + done_ in
      let idx = p / cluster_bytes and o = p mod cluster_bytes in
      (* the clusters that follow each other on the disk, from idx: one read *)
      let last = (f.pos + n - 1) / cluster_bytes in
      let j = ref idx in
      while !j < last && cl.(!j + 1) = cl.(!j) + 1 do incr j done;
      let run = read_sectors (cluster_lba cl.(idx)) ((!j - idx + 1) * spc) in
      let k = min (n - done_) (Bytes.length run - o) in
      Bytes.blit run o buf done_ k;
      go (done_ + k)
    end in
  go 0;
  f.pos <- f.pos + n;
  Bytes.to_string buf

let write_file f data =
  if f.append then f.pos <- f.dsize;
  let n = String.length data in
  if n = 0 then 0
  else begin
    let needed = (f.pos + n + cluster_bytes - 1) / cluster_bytes in
    let cl = ref (chain f.dfirst) in
    let old = List.length !cl in
    while List.length !cl < needed do               (* grow the chain *)
      let c = alloc_cluster () in
      (match !cl with
       | [] -> f.dfirst <- c
       | l -> set_fat (List.nth l (List.length l - 1)) c);
      cl := !cl @ [ c ]
    done;
    let cl = Array.of_list !cl in
    (* new clusters before the written range (after a seek past the end)
       hold zeros *)
    for i = old to f.pos / cluster_bytes - 1 do zero_cluster cl.(i) done;
    let rec go done_ =
      if done_ < n then begin
        let p = f.pos + done_ in
        let idx = p / cluster_bytes and o = p mod cluster_bytes in
        let k = min (n - done_) (cluster_bytes - o) in
        let content =
          if o = 0 && k = cluster_bytes then Bytes.create cluster_bytes
          else if idx < old then begin
            (* keep the data before; what was past the end becomes zeros *)
            let c = read_cluster cl.(idx) in
            let z = max 0 (f.dsize - idx * cluster_bytes) in
            if z < cluster_bytes then Bytes.fill c z (cluster_bytes - z) '\000';
            c
          end else Bytes.make cluster_bytes '\000' in
        Bytes.blit_string data done_ content o k;
        write_cluster cl.(idx) content;
        go (done_ + k)
      end in
    go 0;
    flush_fat ();
    f.pos <- f.pos + n;
    if f.pos > f.dsize then f.dsize <- f.pos;
    update_entry f;
    n
  end

let do_mkdir name =
  let d, last = parent name in
  let c = alloc_cluster () in
  let b = Bytes.make cluster_bytes '\000' in
  let date, time = fat_now () in
  let dot off raw first =
    Bytes.blit_string raw 0 b off 11;
    set_u8 b (off + 11) attr_dir;
    set_u16 b (off + 14) time;
    set_u16 b (off + 16) date;
    set_u16 b (off + 20) (first lsr 16);
    set_u16 b (off + 22) time;
    set_u16 b (off + 24) date;
    set_u16 b (off + 26) (first land 0xFFFF) in
  let parent_cluster = match d with Chain p when p <> root_cluster -> p | _ -> 0 in
  dot 0 ".          " c;
  dot 32 "..         " parent_cluster;
  write_cluster c b;
  flush_fat ();
  (try ignore (add_entry d last attr_dir c)
   with e -> free_chain c; flush_fat (); raise e)

let remove name ~want_dir =
  let d, last = parent name in
  match find (load d) last with
  | None -> raise (Status not_found)
  | Some e ->
    let dir = e.attr land attr_dir <> 0 in
    if want_dir && not dir then raise (Status not_dir);
    if (not want_dir) && dir then raise (Status is_dir);
    if dir && entries (load (entry_dir e)) <> [] then raise (Status not_empty);
    if is_open d e.slot then raise (Status denied);
    delete_entry d e;
    free_chain e.first;
    flush_fat ()

(* rename (or move) an entry; an existing file of the new name goes *)
let do_rename name target =
  let target =
    match String.index_opt target '\000' with
    | Some n -> String.sub target 0 n
    | None -> target in
  let d, last = parent name in
  let d2, last2 = parent target in
  match find (load d) last with
  | None -> raise (Status not_found)
  | Some e ->
    if is_open d e.slot then raise (Status denied);
    if d = d2 && same last last2 && last = last2 then ()
    else begin
      let moving_dir = e.attr land attr_dir <> 0 in
      (match find (load d2) last2 with
       | Some t when d = d2 && t.slot = e.slot -> ()   (* only the case *)
       | Some t when t.attr land attr_dir <> 0 -> raise (Status is_dir)
       | Some _ when moving_dir -> raise (Status not_dir)
       | Some _ -> remove target ~want_dir:false
       | None -> ());
      (* moving a directory: it must not go inside itself *)
      if moving_dir && (match d2 with Chain c -> c = e.first | Root16 -> false) then
        raise (Status invalid);
      let e = match find (load d) last with Some e -> e | None -> raise (Status not_found) in
      let slot = add_entry d2 last2 e.attr e.first in
      let l = load d2 in
      set_u32 l.data (32 * slot + 28) e.size;
      store l;
      let e = match find (load d) last with Some e -> e | None -> raise (Status not_found) in
      delete_entry d e;
      (* a directory moved elsewhere: its ".." names the new parent *)
      if moving_dir && d <> d2 then begin
        let l = load (Chain e.first) in
        let p = match d2 with Chain c when c <> root_cluster -> c | _ -> 0 in
        set_u16 l.data (32 + 20) (p lsr 16);
        set_u16 l.data (32 + 26) (p land 0xFFFF);
        store l
      end
    end

(* ---- the service: fs/1 (module Fs), typed IPC ---- *)

let handle = { Fs.handle = fun (type a) (caller : Ipc.caller) (q : a Fs.request) : a ->
    let me = caller.Ipc.pid in
    (* the internal functions take a request as an array: type, client, fd,
       arg1, arg2 *)
    let r ?(fd = 0) ?(a1 = 0) ?(a2 = 0) () = [| 0; me; fd; a1; a2 |] in
    try
      match q with
      | Fs.Open (name, flags) -> do_open (r ~a1:flags ()) name
      | Fs.Close fd -> ignore (owned (r ~fd ())); Hashtbl.remove descs fd
      | Fs.Read (fd, n) -> read_file (owned (r ~fd ())) (min n io_max)
      | Fs.Write (fd, data) ->
        let f = owned (r ~fd ()) in
        if not f.writable then raise (Status denied);
        write_file f data
      | Fs.Seek (fd, offset, whence) ->
        let f = owned (r ~fd ()) in
        let base = match whence with
          | 0 -> 0 | 1 -> f.pos | 2 -> f.dsize | _ -> raise (Status invalid) in
        if base + offset < 0 then raise (Status invalid);
        f.pos <- base + offset;
        f.pos
      | Fs.List name ->
        List.map (fun e -> (e.name, if e.attr land attr_dir <> 0 then -1 else e.size))
          (entries (load (directory name)))
      | Fs.Remove name -> remove name ~want_dir:false
      | Fs.Mkdir name -> do_mkdir name
      | Fs.Rmdir name -> remove name ~want_dir:true
      | Fs.Rename (name, target) -> do_rename name target
    with
    | Status st -> Fs.fail st
    | Invalid_argument e -> Mynos.log ("fatfs: " ^ e); Fs.fail Fs.invalid }

let () =
  Mynos.log (Printf.sprintf "fatfs: FAT%d, %d clusters of %d bytes, service fs/1 as fatfs"
               (if fat32 then 32 else 16) clusters cluster_bytes);
  Fs.serve "fatfs" handle

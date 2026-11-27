(* bench: how fast this MyNOS is. The processor through OCaml, the
   system (a system call, IPC between processes, threads, starting a
   program, files), the network, and in a window the drawing.

     bench                    a window in the graphical session; else as -t
     bench -t [GROUP...]      in the terminal: cpu, system, net, graphics
                              (graphics only in a window)
     bench --quick ...        shorter measures, less precise
     bench --no-save ...      the run not kept in /disk/bench

   Each measure is in its own unit (operations a second, microseconds)
   and as a score: 1000 is MyNOS 1.0.1 in QEMU with KVM on the reference
   PC (the package's README), more is faster. A group's score is its
   measures' geometric mean; the score is the groups' (cpu, system, net:
   graphics, which needs a window, has its own). Measures marked
   "unscored" depend on the Internet, not on MyNOS.

   The clock moves in ticks of 10 ms: a measure starts on a tick and
   lasts 0.3 s at least, three times (the median kept).

   Runs are kept in /disk/bench/history.json: each measure is shown
   against the last run's. *)

let version = "1.0"

(* ---- timing ---- *)

let now = Mynos.uptime
let quick = ref false

(* the clock's next tick: a measure starts on one *)
let tick_edge () =
  let t0 = now () in
  let t = ref (now ()) in
  while !t = t0 do t := now () done;
  !t

let median l =
  let a = Array.of_list l in
  Array.sort compare a;
  a.(Array.length a / 2)

(* [f n] does n operations: how many a second. n grows until a run takes
   a quarter of the time wanted, then is set for the whole of it *)
let rate f =
  let target = if !quick then 0.12 else 0.3 in
  let measure n = let t0 = tick_edge () in f n; now () -. t0 in
  let n = ref 1 in
  let dt = ref (measure 1) in
  while !dt < target /. 4. do
    n := !n * (if !dt < 0.01 then 8 else 2);
    dt := measure !n
  done;
  let n = max 1 (int_of_float (float !n *. target /. !dt)) in
  let runs = if !quick then 1 else 3 in
  median (List.init runs (fun _ -> float n /. max (measure n) 0.005))

let per_op_us f = 1e6 /. rate f

exception Skip of string          (* not measured here, and why *)

(* ---- the measures ---- *)

type kind = Rate of string | Time of string     (* more is better; less is *)

type ctx = { ui : Gui.ui option; canvas : int * int * int * int }

type test = {
  group : string;
  id : string;
  name : string;
  kind : kind;
  reference : float;                  (* 1000 points; 0: none yet *)
  scored : bool;
  run : ctx -> float;
}

let groups = [ "cpu"; "system"; "net"; "graphics" ]

(* -- cpu -- *)

let sieve n =
  let b = Bytes.make (n + 1) '\001' in
  let count = ref 0 in
  for i = 2 to n do
    if Bytes.unsafe_get b i = '\001' then begin
      incr count;
      (* i * i only while it fits: 31-bit integers on the i386 *)
      let j = ref (if i <= n / i then i * i else n + 1) in
      while !j <= n do Bytes.unsafe_set b !j '\000'; j := !j + i done
    end
  done;
  !count

let mandelbrot size =
  let inside = ref 0 in
  for py = 0 to size - 1 do
    for px = 0 to size - 1 do
      let cr = -2.0 +. 2.5 *. float px /. float size
      and ci = -1.25 +. 2.5 *. float py /. float size in
      let zr = ref 0. and zi = ref 0. and k = ref 0 in
      while !k < 64 && !zr *. !zr +. !zi *. !zi <= 4. do
        let t = !zr *. !zr -. !zi *. !zi +. cr in
        zi := 2. *. !zr *. !zi +. ci;
        zr := t;
        incr k
      done;
      if !k = 64 then incr inside
    done
  done;
  !inside

type tree = Leaf | Node of tree * tree
let rec make d = if d = 0 then Leaf else Node (make (d - 1), make (d - 1))
let rec check = function Leaf -> 1 | Node (l, r) -> 1 + check l + check r

let words = Array.init 1000 (fun i -> "word" ^ string_of_int (i * 7919 mod 1000))

let strings () =
  let b = Buffer.create 8192 in
  Array.iter (fun w -> Buffer.add_string b w; Buffer.add_char b ' ') words;
  let s = Buffer.contents b in
  let parts = String.split_on_char ' ' s in
  String.length (String.concat "," (List.map String.uppercase_ascii parts))

let mb = 1024 * 1024
let src = lazy (Bytes.init mb (fun i -> Char.chr (i land 0xFF)))
let dst = lazy (Bytes.create mb)
let quarter = lazy (String.init (mb / 4) (fun i -> Char.chr ((i * 31) land 0xFF)))
let to_sort = lazy (Array.init 10_000 (fun i -> (i * 7919 + 13) mod 10_007))

let times n f = for _ = 1 to n do ignore (Sys.opaque_identity (f ())) done

let cpu = [
  { group = "cpu"; id = "sieve"; name = "integers: sieve to 100 000"; kind = Rate "runs/s";
    reference = 640.0; scored = true;
    run = fun _ -> rate (fun n -> times n (fun () -> sieve 100_000)) };
  { group = "cpu"; id = "mandel"; name = "floats: Mandelbrot 64 x 64"; kind = Rate "runs/s";
    reference = 230.0; scored = true;
    run = fun _ -> rate (fun n -> times n (fun () -> mandelbrot 64)) };
  { group = "cpu"; id = "alloc"; name = "GC: trees of 4095 nodes"; kind = Rate "trees/s";
    reference = 17000.0; scored = true;
    run = fun _ -> rate (fun n -> times n (fun () -> check (make 11))) };
  { group = "cpu"; id = "strings"; name = "strings: join, split"; kind = Rate "runs/s";
    reference = 2060.0; scored = true;
    run = fun _ -> rate (fun n -> times n strings) };
  { group = "cpu"; id = "sort"; name = "sorting 10 000 integers"; kind = Rate "runs/s";
    reference = 148.0; scored = true;
    run = fun _ ->
      let a = Lazy.force to_sort in
      rate (fun n -> times n (fun () -> let c = Array.copy a in Array.sort compare c; c)) };
  { group = "cpu"; id = "copy"; name = "memory: 1 MB copied"; kind = Rate "MB/s";
    reference = 26700.0; scored = true;
    run = fun _ ->
      let s = Lazy.force src and d = Lazy.force dst in
      rate (fun n -> for _ = 1 to n do Bytes.blit s 0 d 0 mb done) };
  { group = "cpu"; id = "md5"; name = "hashing: MD5"; kind = Rate "MB/s";
    reference = 876.0; scored = true;
    run = fun _ ->
      let s = Lazy.force quarter in
      rate (fun n -> times n (fun () -> Digest.string s)) /. 4. };
]

(* -- system -- *)

(* this program, to start again as a child *)
let self () =
  let a = Sys.argv.(0) in
  if Sys.file_exists a then a else "/disk/bin/bench.byte"

let spawn_self args = Mynos.spawn "ocamlrun" (Array.of_list ("ocamlrun" :: self () :: args))

(* the child of the IPC measures: what it gets, it sends back, until "" *)
let echo port =
  let ch = Mynos.connect port in
  let rec loop () =
    match Mynos.recv ch with
    | "" -> ()
    | m -> Mynos.send ch m; loop () in
  loop ();
  exit 0

(* a child that echoes, for [f channel]; then it ends *)
let with_echo f =
  let port = Mynos.alloc_port () in
  let pid = spawn_self [ "--echo"; string_of_int port ] in
  let ch = Mynos.listen port in
  Fun.protect (fun () -> f ch)
    ~finally:(fun () ->
        (try Mynos.send ch "" with _ -> ());
        (try ignore (Mynos.wait pid) with _ -> ());
        (try Mynos.free_channel ch with _ -> ());
        (try Mynos.free_port port with _ -> ()))

let round_trips size =
  with_echo (fun ch ->
      let m = String.make size 'x' in
      per_op_us (fun n -> for _ = 1 to n do Mynos.send ch m; ignore (Mynos.recv ch) done))

(* two threads, a mutex and two conditions: each wakes the other *)
let thread_switch () =
  let m = Mutex.create () and c = Condition.create () in
  let turn = ref 0 and stop = ref false in
  let other = Thread.create (fun () ->
      Mutex.lock m;
      while not !stop do
        while !turn = 0 && not !stop do Condition.wait c m done;
        turn := 0; Condition.broadcast c
      done;
      Mutex.unlock m) () in
  let r = per_op_us (fun n ->
      Mutex.lock m;
      for _ = 1 to n do
        turn := 1; Condition.broadcast c;
        while !turn = 1 do Condition.wait c m done
      done;
      Mutex.unlock m) in
  Mutex.lock m; stop := true; Condition.broadcast c; Mutex.unlock m;
  Thread.join other;
  r /. 2.

let write_file path data = Out_channel.with_open_bin path (fun oc -> output_string oc data)
let read_file path = In_channel.with_open_bin path In_channel.input_all

let file_rates dir =
  if not (Sys.file_exists dir && Sys.is_directory dir) then raise (Skip (dir ^ ": not there"));
  let path = Filename.concat dir "bench.tmp" in
  let data = Bytes.to_string (Lazy.force src) in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       let w = rate (fun n -> for _ = 1 to n do write_file path data done) in
       let r = rate (fun n -> for _ = 1 to n do ignore (read_file path) done) in
       (w, r))

(* both measures of a directory at once, the second kept for its test *)
let files_cache = Hashtbl.create 2
let file_rate dir which =
  let w, r = match Hashtbl.find_opt files_cache dir with
    | Some x -> x
    | None -> let x = file_rates dir in Hashtbl.replace files_cache dir x; x in
  if which = `Write then w else r

let small_files dir =
  per_op_us (fun n ->
      for i = 1 to n do
        let p = Filename.concat dir ("bench" ^ string_of_int (i land 15) ^ ".tmp") in
        write_file p "x"; Sys.remove p
      done)

let system = [
  { group = "system"; id = "syscall"; name = "a system call (getpid)"; kind = Time "us";
    reference = 0.17; scored = true;
    run = fun _ -> per_op_us (fun n -> for _ = 1 to n do ignore (Mynos.getpid ()) done) };
  { group = "system"; id = "ipc"; name = "IPC round trip, 4 bytes"; kind = Time "us";
    reference = 3.37; scored = true; run = fun _ -> round_trips 4 };
  { group = "system"; id = "ipc4k"; name = "IPC round trip, 4 KB"; kind = Time "us";
    reference = 9.9; scored = true; run = fun _ -> round_trips 4096 };
  { group = "system"; id = "threads"; name = "thread switch"; kind = Time "us";
    reference = 1.11; scored = true; run = fun _ -> thread_switch () };
  { group = "system"; id = "spawn"; name = "a program started, ended"; kind = Time "ms";
    reference = 5.58; scored = true;
    run = fun _ ->
      per_op_us (fun n -> for _ = 1 to n do ignore (Mynos.wait (spawn_self [ "--exit" ])) done) /. 1000. };
  { group = "system"; id = "tmpw"; name = "/tmp: 1 MB written"; kind = Rate "MB/s";
    reference = 683.0; scored = true; run = fun _ -> file_rate "/tmp" `Write };
  { group = "system"; id = "tmpr"; name = "/tmp: 1 MB read"; kind = Rate "MB/s";
    reference = 491.0; scored = true; run = fun _ -> file_rate "/tmp" `Read };
  { group = "system"; id = "tmpf"; name = "/tmp: a file made, removed"; kind = Time "us";
    reference = 57.1; scored = true; run = fun _ -> small_files "/tmp" };
  { group = "system"; id = "diskw"; name = "/disk: 1 MB written"; kind = Rate "MB/s";
    reference = 0.627; scored = true; run = fun _ -> file_rate "/disk" `Write };
  { group = "system"; id = "diskr"; name = "/disk: 1 MB read"; kind = Rate "MB/s";
    reference = 306.0; scored = true; run = fun _ -> file_rate "/disk" `Read };
]

(* -- net -- *)

let net_conn = ref None
let net () =
  match !net_conn with
  | Some n -> n
  | None ->
    let n = try Net.connect () with _ -> raise (Skip "no network service") in
    net_conn := Some n; n

let config () = try Net.call (net ()) Net.Config with Ipc.Remote_error (_, m) -> raise (Skip m)

(* TCP through netd to ourselves: a thread accepts and reads, another
   connection sends *)
let loopback () =
  let c = config () in
  let server = Net.connect () and client = Net.connect () in
  let port = 47000 + Mynos.getpid () mod 1000 in
  let l = Net.call server (Net.Listen port) in
  let got = ref 0 in
  let reader = Thread.create (fun () ->
      let s, _, _ = Net.call server (Net.Accept l) in
      let rec loop () = match Net.call server (Net.Recv (s, 16384)) with
        | "" -> ()
        | d -> got := !got + String.length d; loop () in
      (try loop () with _ -> ());
      (try Net.call server (Net.Close s) with _ -> ())) () in
  let s = try Net.call client (Net.Connect (c.Net.address, port))
    with Ipc.Remote_error (_, m) -> raise (Skip ("connect: " ^ m)) in
  let chunk = String.make 16384 'x' in
  let r = rate (fun n -> for _ = 1 to n do ignore (Net.call client (Net.Send (s, chunk))) done) in
  (try Net.call client (Net.Close s) with _ -> ());
  Thread.join reader;
  (try Net.call server (Net.Close l) with _ -> ());
  r *. 16384. /. float mb

(* the packages' repository, as pkg finds it *)
let repository () =
  let slash u = if String.ends_with ~suffix:"/" u then u else u ^ "/" in
  match Sys.getenv_opt "MYNOS_PKG_URL" with
  | Some u when u <> "" -> slash u
  | _ ->
    match In_channel.with_open_bin "/disk/pkg/url" In_channel.input_line with
    | Some u when String.trim u <> "" -> slash (String.trim u)
    | _ | exception Sys_error _ -> "https://raw.githubusercontent.com/ctrl-z-bg/mynos-packages/main/"

let timed f = let t0 = now () in let r = f () in (now () -. t0, r)

let net_tests = [
  { group = "net"; id = "netd"; name = "network service request"; kind = Time "us";
    reference = 44.8; scored = true;
    run = fun _ -> let n = net () in ignore (config ());
      per_op_us (fun k -> for _ = 1 to k do ignore (Net.call n Net.Config) done) };
  { group = "net"; id = "ping"; name = "ping the gateway"; kind = Time "us";
    reference = 272.0; scored = true;
    run = fun _ -> let n = net () and g = (config ()).Net.gateway in
      (try ignore (Net.call n (Net.Ping (g, 1000))) with Ipc.Remote_error (_, m) -> raise (Skip m));
      per_op_us (fun k -> for _ = 1 to k do ignore (Net.call n (Net.Ping (g, 1000))) done) };
  { group = "net"; id = "tcp"; name = "TCP to ourselves"; kind = Rate "MB/s";
    reference = 118.0; scored = true; run = fun _ -> loopback () };
  { group = "net"; id = "dns"; name = "DNS: the repository's host"; kind = Time "ms";
    reference = 0.; scored = false;
    run = fun _ ->
      let _, host, _, _ = Http.parse_url (repository ()) in
      if String.for_all (fun c -> c = '.' || (c >= '0' && c <= '9')) host then
        raise (Skip "the repository is an address, no name");
      let n = net () in
      match timed (fun () -> Net.call n (Net.Resolve host)) with
      | dt, _ -> dt *. 1000.
      | exception Ipc.Remote_error (_, m) -> raise (Skip m) };
  { group = "net"; id = "https"; name = "packages' index fetched"; kind = Rate "KB/s";
    reference = 0.; scored = false;
    run = fun _ ->
      match timed (fun () -> Http.get ~timeout:15000 (repository () ^ "index.json")) with
      | dt, r when r.Http.status = 200 -> float (String.length r.Http.body) /. 1024. /. max dt 0.01
      | _, r -> raise (Skip (Printf.sprintf "HTTP %d" r.Http.status))
      | exception Http.Error m -> raise (Skip m) };
]

(* -- graphics: in the window's canvas -- *)

let need_ui ctx = match ctx.ui with Some ui -> ui | None -> raise (Skip "only in a window")

let rng = ref 12345
let rand k = rng := (!rng * 69069 + 1) land 0x3FFFFFFF; (!rng lsr 6) mod k
let colour () = rand 0x1000000

let pattern = lazy (let p = Gfx.create 64 64 in
                    for y = 0 to 63 do for x = 0 to 63 do
                        Gfx.fill p x y 1 1 (Gfx.rgb (x * 4) (y * 4) ((x lxor y) * 4)) done done;
                    p)

let graphics = [
  { group = "graphics"; id = "fill"; name = "rectangles 64 x 64"; kind = Rate "Mpixel/s";
    reference = 6140.0; scored = true;
    run = fun ctx -> let ui = need_ui ctx and (x, y, w, h) = ctx.canvas in
      rate (fun n -> for _ = 1 to n do
               Gfx.fill ui.Gui.g (x + rand (w - 64)) (y + rand (h - 64)) 64 64 (colour ()) done)
      *. 4096. /. 1e6 };
  { group = "graphics"; id = "blit"; name = "pictures 64 x 64 copied"; kind = Rate "Mpixel/s";
    reference = 6020.0; scored = true;
    run = fun ctx -> let ui = need_ui ctx and (x, y, w, h) = ctx.canvas in
      let p = Lazy.force pattern in
      rate (fun n -> for _ = 1 to n do
               Gfx.blit p 0 0 ui.Gui.g (x + rand (w - 64)) (y + rand (h - 64)) 64 64 done)
      *. 4096. /. 1e6 };
  { group = "graphics"; id = "lines"; name = "lines"; kind = Rate "lines/s";
    reference = 2440000.0; scored = true;
    run = fun ctx -> let ui = need_ui ctx and (x, y, w, h) = ctx.canvas in
      rate (fun n -> for _ = 1 to n do
               Gfx.line ui.Gui.g (x + rand w) (y + rand h) (x + rand w) (y + rand h) (colour ()) done) };
  { group = "graphics"; id = "text"; name = "text, 30 characters a line"; kind = Rate "chars/s";
    reference = 13330000.0; scored = true;
    run = fun ctx -> let ui = need_ui ctx and (x, y, w, h) = ctx.canvas in
      let s = "The quick brown fox, MyNOS 1.0" in
      rate (fun n -> for _ = 1 to n do
               ignore (Gfx.text ui.Gui.g (x + rand (w - 30 * Gfx.char_w))
                         (y + rand (h - Gfx.char_h)) s (colour ())) done)
      *. 30. };
  { group = "graphics"; id = "frames"; name = "frames shown, 270 x 200"; kind = Rate "frames/s";
    reference = 17400.0; scored = true;
    run = fun ctx -> let ui = need_ui ctx and (x, y, w, h) = ctx.canvas in
      rate (fun n -> for i = 1 to n do
               Gfx.fill ui.Gui.g x y w h (Gfx.rgb (i * 5) 40 (255 - i * 5));
               Display.damage ~x ~y ~w ~h ui.Gui.window done) };
]

let all = cpu @ system @ net_tests @ graphics

(* ---- scores ---- *)

let score t v =
  if t.reference <= 0. || not t.scored then None
  else Some (1000. *. (match t.kind with Rate _ -> v /. t.reference | Time _ -> t.reference /. v))

let geomean = function
  | [] -> None
  | l -> Some (exp (List.fold_left (fun a x -> a +. log x) 0. l /. float (List.length l)))

type result = Value of float | Skipped of string | Failed of string

let group_score results g =
  geomean (List.filter_map (fun (t, r) ->
      match r with Value v when t.group = g -> score t v | _ -> None) results)

(* the score: cpu, system and net's, those measured *)
let total results =
  geomean (List.filter_map (fun g -> group_score results g) [ "cpu"; "system"; "net" ])

(* ---- the runs kept ---- *)

let history_dir = "/disk/bench"
let history_file = Filename.concat history_dir "history.json"

let load_history () =
  match Json.of_string (read_file history_file) with
  | Json.Array l -> l
  | _ -> []
  | exception _ -> []

let last_values () =
  match List.rev (load_history ()) with
  | run :: _ ->
    (match Json.member "values" run with
     | Json.Object l -> List.filter_map (fun (k, v) ->
         match v with Json.Number f -> Some (k, f) | _ -> None) l
     | _ -> [])
  | [] -> []

let save results =
  if Sys.file_exists "/disk" then begin
    (try if not (Sys.file_exists history_dir) then Sys.mkdir history_dir 0o755 with Sys_error _ -> ());
    let num f = Json.Number (Float.round (f *. 1000.) /. 1000.) in
    let values = List.filter_map (fun (t, r) ->
        match r with Value v -> Some (t.id, num v) | _ -> None) results in
    let scores = List.filter_map (fun g ->
        Option.map (fun s -> (g, num s)) (group_score results g)) groups in
    let run = Json.Object ([ "time", Json.Number (Float.round (Mynos.time ()));
                             "mynos", Json.String (Mynos.version ());
                             "bench", Json.String version;
                             "quick", Json.Bool !quick;
                             "values", Json.Object values;
                             "scores", Json.Object scores ]
                           @ (match total results with Some s -> [ "score", num s ] | None -> [])) in
    let keep = List.rev (List.filteri (fun i _ -> i < 49) (List.rev (load_history ()))) in
    try write_file history_file (Json.to_string (Json.Array (keep @ [ run ])))
    with Sys_error _ -> ()
  end

(* ---- the lines shown ---- *)

let unit_of t = match t.kind with Rate u | Time u -> u

let number v =
  if v >= 100. then Printf.sprintf "%.0f" v
  else if v >= 10. then Printf.sprintf "%.1f" v
  else Printf.sprintf "%.2f" v

let change t v previous =
  match List.assoc_opt t.id previous with
  | Some p when p > 0. ->
    let r = match t.kind with Rate _ -> v /. p | Time _ -> p /. v in
    let pc = (r -. 1.) *. 100. in
    if Float.abs pc < 0.5 then "=" else Printf.sprintf "%+.0f%%" pc
  | _ -> ""

let result_text t r previous =
  match r with
  | Value v ->
    let s = match score t v with
      | Some s -> Printf.sprintf "%5.0f" s
      | None -> if t.scored then "    -" else "unscored" in
    Printf.sprintf "%10s %-9s %8s %5s" (number v) (unit_of t) s (change t v previous)
  | Skipped why -> "skipped: " ^ why
  | Failed why -> "failed: " ^ why

let measure ctx t =
  match t.run ctx with
  | v -> Value v
  | exception Skip why -> Skipped why
  | exception (Failure m | Sys_error m | Ipc.Remote_error (_, m) | Mynos.Error (m, _)) -> Failed m
  | exception e -> Failed (Printexc.to_string e)

let processors () = max 1 (Domain.recommended_domain_count ())

let header () =
  Printf.sprintf "bench %s: MyNOS %s, %d processor%s%s" version (Mynos.version ())
    (processors ()) (if processors () = 1 then "" else "s") (if !quick then ", quick" else "")

(* ---- in the terminal ---- *)

let console ~save:keep chosen =
  let tests = List.filter (fun t -> List.mem t.group chosen) all in
  let previous = last_values () in
  print_endline (header ());
  let ctx = { ui = None; canvas = (0, 0, 0, 0) } in
  let results = List.concat_map (fun g ->
      let ts = List.filter (fun t -> t.group = g) tests in
      if ts = [] then []
      else begin
        Printf.printf "%s\n%!" g;
        let rs = List.map (fun t ->
            Printf.printf "  %-28s %!" t.name;
            let r = measure ctx t in
            Printf.printf "%s\n%!" (result_text t r previous);
            (t, r)) ts in
        (match group_score rs g with
         | Some s -> Printf.printf "  %-28s %20s %8.0f\n%!" ("score " ^ g) "" s
         | None -> ());
        rs
      end) groups in
  (match total results with
   | Some s ->
     Printf.printf "score %.0f (%s)\n" s
       (String.concat ", " (List.filter_map (fun g ->
            Option.map (fun x -> Printf.sprintf "%s %.0f" g x) (group_score results g))
            [ "cpu"; "system"; "net" ]))
   | None -> print_endline "score: none (no reference for these measures yet)");
  if keep then save results

(* ---- in a window ---- *)

type state = {
  mutable queue : test list;           (* still to measure *)
  mutable results : (test * result) list;
  mutable previous : (string * float) list;
  mutable running : bool;
  mutable saved : bool;
}

let win_w = 880 and win_h = 680
let row_h = 17
let canvas = (590, 56, 270, 200)

let window ~save:keep =
  let st = { queue = []; results = []; previous = last_values (); running = false; saved = false } in
  let start q =
    quick := q; st.queue <- all; st.results <- []; st.previous <- last_values ();
    st.running <- true; st.saved <- false in
  let (cx, cy, cw, ch) = canvas in
  Gui.run ~title:"Benchmark" ~tick:0.05 win_w win_h ()
    (fun ui () ->
       List.iter (function "\027" -> raise Gui.Quit | _ -> ()) ui.Gui.keys;
       let g = ui.Gui.g in
       let current = if st.running then (match st.queue with t :: _ -> Some t | [] -> None) else None in
       (* the buttons, the header *)
       Gfx.fill g 0 0 win_w 44 Gui.panel_colour;
       if not st.running then begin
         if Gui.button ui 12 8 120 "Run" then start false;
         if Gui.button ui 140 8 120 "Quick run" then start true
       end else Gui.label ~colour:Gui.muted ui 16 14 "measuring... (Esc quits)";
       Gui.label ~colour:Gui.muted ui 280 14 (header ());
       (* the table: a row a measure, a group's score under it *)
       let x0 = 12 in
       let y = ref 56 in
       List.iter (fun grp ->
           ignore (Gfx.text ~bold:true g x0 !y grp Gui.foreground); y := !y + row_h;
           List.iter (fun t ->
               let here = match current with Some u -> u == t | None -> false in
               ignore (Gfx.text ~max:30 g x0 !y ((if here then "> " else "  ") ^ t.name)
                         (if here then Gui.accent else Gui.foreground));
               (match List.assq_opt t st.results with
                | Some r ->
                  ignore (Gfx.text ~max:31 g (x0 + 31 * Gfx.char_w) !y (result_text t r st.previous)
                            (match r with Value _ -> Gui.foreground | _ -> Gui.muted))
                | None -> ());
               y := !y + row_h) (List.filter (fun t -> t.group = grp) all);
           (match group_score st.results grp with
            | Some s when not (List.exists (fun t -> t.group = grp) st.queue) ->
              ignore (Gfx.text g x0 !y (Printf.sprintf "  score %s: %.0f" grp s) Gui.accent);
              y := !y + row_h
            | _ -> ())) groups;
       (* the canvas, the progress, the score *)
       Gfx.rect g (cx - 1) (cy - 1) (cw + 2) (ch + 2) Gui.muted;
       Gfx.fill g cx cy cw ch Gui.panel_colour;
       ignore (Gfx.text g cx (cy + ch + 8) "the graphics measures draw here" Gui.muted);
       if st.running then begin
         Gfx.fill g cx (cy + ch + 30) cw 10 Gui.panel_colour;
         Gfx.fill g cx (cy + ch + 30) (cw * List.length st.results / List.length all) 10 Gui.accent
       end else begin
         (match total st.results with
          | Some s ->
            ignore (Gfx.text ~bold:true g cx (cy + ch + 40) (Printf.sprintf "score %.0f" s) Gui.accent)
          | None -> ());
         (match group_score st.results "graphics" with
          | Some s -> ignore (Gfx.text g cx (cy + ch + 60) (Printf.sprintf "graphics %.0f" s) Gui.foreground)
          | None -> ());
         let notes = [ "1000: MyNOS in QEMU with KVM"; "on the reference PC (README);";
                       "more is faster. The score is"; "cpu, system and net's." ] in
         List.iteri (fun i s -> ignore (Gfx.text g cx (cy + ch + 90 + i * row_h) s Gui.muted)) notes
       end;
       (* the measure due, the frame drawn first (the window shows it
          meanwhile); a graphics measure draws in the canvas *)
       if ui.Gui.tick then
         match current with
         | Some t ->
           if t.group = "graphics" then Gfx.fill g cx cy cw ch 0;
           let r = Gfx.with_clip cx cy cw ch (fun () -> measure { ui = Some ui; canvas } t) in
           st.results <- st.results @ [ (t, r) ];
           st.queue <- List.tl st.queue
         | None ->
           if st.running then begin
             st.running <- false;
             if keep && not st.saved then begin save st.results; st.saved <- true end
           end)

(* ---- the command line ---- *)

(* is there a graphical session? A window asked, and closed at once *)
let session () =
  match Display.window ~title:"" 16 16 with
  | w -> Display.destroy w; true
  | exception _ -> false

let usage () =
  prerr_endline "usage: bench [-t] [--quick] [--no-save] [cpu|system|net|graphics...]";
  exit 2

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--echo"; port ] -> echo (int_of_string port)
  | [ "--exit" ] -> exit 0
  | args ->
    let term = ref false and keep = ref true and chosen = ref [] in
    List.iter (fun a ->
        (* the agent's tool gives the groups as one argument: "cpu, net" *)
        List.iter (fun w ->
            match w with
            | "" -> ()
            | "-t" -> term := true
            | "--quick" -> quick := true
            | "--no-save" -> keep := false
            | g when List.mem g groups -> chosen := !chosen @ [ g ]
            | "all" -> chosen := !chosen @ groups
            | _ -> usage ())
          (String.split_on_char ' ' (String.map (function ',' -> ' ' | c -> c) a))) args;
    if !term || !chosen <> [] || not (session ()) then
      console ~save:!keep (if !chosen = [] then [ "cpu"; "system"; "net" ] else !chosen)
    else window ~save:!keep

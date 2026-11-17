(* See mynos.mli. The primitives are in mynos-runtime/mynos_stubs.c. *)

exception Error of string * int
let () = Callback.register_exception "Mynos.Error" (Error ("", 0))

let error_name = function
  | -1 -> "full" | -2 -> "busy" | -3 -> "invalid" | -4 -> "deny"
  | -5 -> "broken" | -6 -> "expired" | n -> string_of_int n

let () =
  Printexc.register_printer (function
    | Error (fn, code) ->
        Some (Printf.sprintf "Mynos.Error(%s: %s)" fn (error_name code))
    | _ -> None)

external getpid : unit -> int = "caml_mynos_getpid"
external log : string -> unit = "caml_mynos_log"
external uptime : unit -> float = "caml_mynos_uptime"
external time : unit -> float = "caml_mynos_time"
external sleep_us : int -> unit = "caml_mynos_sleep_us"
let sleep s = if s > 0. then sleep_us (int_of_float (s *. 1e6))

type stats = {
  processes : int; threads : int; pid : int; ppid : int; free_pages : int;
}
external stats_raw : unit -> int * int * int * int * int = "caml_mynos_stats"
let stats () =
  let processes, threads, pid, ppid, free_pages = stats_raw () in
  { processes; threads; pid; ppid; free_pages }

external alloc_port : unit -> int = "caml_mynos_alloc_port"
external listen : int -> int = "caml_mynos_listen"
external connect : int -> int = "caml_mynos_connect"
external free_port_raw : int -> int = "caml_mynos_free_port"
let free_port p = ignore (free_port_raw p)
external change_port_owner_raw : int -> int -> int
  = "caml_mynos_change_port_owner"
let change_port_owner p pid = ignore (change_port_owner_raw p pid)

external send : int -> string -> unit = "caml_mynos_send"
external recv_raw : int -> int -> string = "caml_mynos_recv"
let recv ?timeout c =
  let ms = match timeout with
    | None -> 0
    | Some s -> max 1 (int_of_float (s *. 1000.)) in
  recv_raw c ms
external free_channel_raw : int -> int = "caml_mynos_free_channel"
let free_channel c = ignore (free_channel_raw c)

external sem_create : int -> int = "caml_mynos_sem_create"
external sem_p_raw : int -> int = "caml_mynos_sem_p"
let sem_p s = ignore (sem_p_raw s)
external sem_try_p : int -> bool = "caml_mynos_sem_try_p"
external sem_v_raw : int -> int = "caml_mynos_sem_v"
let sem_v s = ignore (sem_v_raw s)
external sem_free_raw : int -> int = "caml_mynos_sem_free"
let sem_free s = ignore (sem_free_raw s)

external register : string -> int = "caml_mynos_registry_register"
external lookup : string -> int = "caml_mynos_registry_lookup"

type status = Exited of int | Signaled of int

external spawn_raw : string -> string array -> string array -> bool -> int
  = "caml_mynos_spawn"
let spawn ?(env = [||]) ?(io = false) path argv = spawn_raw path argv env io

external channel_peer : int -> int = "caml_mynos_channel_peer"

type process_info = { alive : bool; io : bool }

external process_info_raw : int -> int = "caml_mynos_process_info"
let process_info pid =
  let r = process_info_raw pid in
  if r < 0 then None
  else Some { alive = r land 0x100 <> 0; io = r land 1 <> 0 }

external wait_raw : int -> int * int = "caml_mynos_wait"
let decode s = if s land 0x7f = 0 then Exited ((s lsr 8) land 0xff)
               else Signaled (s land 0x7f)
let wait pid = decode (snd (wait_raw pid))
let wait_any () = let pid, s = wait_raw (-1) in (pid, decode s)

external inb : int -> int = "caml_mynos_inb"
external outb : int -> int -> unit = "caml_mynos_outb"
external inw : int -> int = "caml_mynos_inw"
external outw : int -> int -> unit = "caml_mynos_outw"
external insw : int -> int -> string = "caml_mynos_insw"
external outsw : int -> string -> unit = "caml_mynos_outsw"
external driver_register : string -> int -> int = "caml_mynos_driver_register"
external enable_irq_raw : int -> int = "caml_mynos_enable_irq"
let enable_irq n = ignore (enable_irq_raw n)

external console_mode_raw : bool -> bool -> int -> int -> unit
  = "caml_mynos_console_mode"
let console_mode ~canon ~echo ?(vmin = 1) ?(vtime = 0) () =
  console_mode_raw canon echo vmin vtime

external environment : unit -> string array = "caml_mynos_environment"

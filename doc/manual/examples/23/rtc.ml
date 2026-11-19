(* rtc: a driver for the PC's real-time clock (the MC146818 in the
   CMOS), served as "rtc" with protocol "rtc/1": the time of day, read
   through ports 0x70 and 0x71, and the number of its periodic
   interrupts (IRQ 8, twice a second) since the driver started. *)

(* ---- the device ---- *)

let index = 0x70 and data = 0x71

let get r = Mynos.outb index r; Mynos.inb data
let set r v = Mynos.outb index r; Mynos.outb data v

let bcd v = (v land 0x0F) + 10 * (v lsr 4)

let time () =
  while get 0x0A land 0x80 <> 0 do () done;       (* an update in progress *)
  let binary = get 0x0B land 0x04 <> 0 in
  let read r = let v = get r in if binary then v else bcd v in
  (read 0x04, read 0x02, read 0x00)               (* hours, minutes, seconds *)

(* ---- the protocol ---- *)

type _ request =
  | Time : (int * int * int) request
  | Ticks : int request

module Protocol = struct
  let id = "rtc/1"
  let summary = "The real-time clock of the PC: the time, and its interrupts."
  let requests = Ipc.[
      request ~safe:true 0 "time" "The time of day (UTC): hours, minutes, seconds."
        Wire.unit Wire.(triple int int int);
      request ~safe:true 1 "ticks" "The clock's interrupts since the driver started."
        Wire.unit Wire.int ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    Wire.write w Wire.int (match r with Time -> 0 | Ticks -> 1)
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Time
    | 1 -> Request Ticks
    | n -> raise (Wire.Error (Printf.sprintf "rtc: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function
    | Time -> Wire.(triple int int int)
    | Ticks -> Wire.int
end

module I = Ipc.Make (Protocol)

(* ---- the driver ---- *)

let ticks = Atomic.make 0

let interrupts sem () =
  while true do
    Mynos.sem_p sem;                 (* the kernel's V: an interrupt came *)
    ignore (get 0x0C);               (* the device's own acknowledgement *)
    Atomic.incr ticks
  done

let () =
  let sem = Mynos.driver_register "rtc" 8 in
  set 0x0A ((get 0x0A land 0xF0) lor 15);    (* rate 15: 2 Hz *)
  set 0x0B (get 0x0B lor 0x40);              (* the periodic interrupt on *)
  ignore (get 0x0C);
  Mynos.enable_irq 8;
  ignore (Domain.spawn (interrupts sem));
  Mynos.log "rtc: service rtc, IRQ 8";
  I.serve "rtc" { I.handle = fun (type a) _caller (r : a request) : a ->
      match r with
      | Time -> time ()
      | Ticks -> Atomic.get ticks }

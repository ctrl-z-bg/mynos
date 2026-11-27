(* The RP5C01 (rtc.mli). *)

type t = {
  clock : unit -> float;
  mutable reg : int;
  mutable mode : int;                   (* register 13: bits 0-1 the block *)
  ram : int array;                      (* blocks 1 to 3, 13 nibbles each *)
}

let create ~clock = { clock; reg = 0; mode = 0; ram = Array.make 39 0 }

let reset t =
  t.reg <- 0; t.mode <- 0;
  Array.fill t.ram 0 39 0;
  t.ram.(10) <- 1                       (* block 1, register 10: 24 hours *)

let select t v = t.reg <- v land 15

(* the days since 1970-01-01 as (year, month, day) (Howard Hinnant's
   civil_from_days) *)
let civil days =
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - era * 146097 in
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 in
  let y = yoe + era * 400 in
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) in
  let mp = (5 * doy + 2) / 153 in
  let d = doy - (153 * mp + 2) / 5 + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((if m <= 2 then y + 1 else y), m, d)

let time_digit t r =
  let s = int_of_float (t.clock ()) in
  let days = s / 86400 and secs = s mod 86400 in
  let y, mo, d = civil days in
  let h = secs / 3600 and mi = secs mod 3600 / 60 and se = secs mod 60 in
  let yy = (y - 1980) mod 100 in
  match r with
  | 0 -> se mod 10 | 1 -> se / 10
  | 2 -> mi mod 10 | 3 -> mi / 10
  | 4 -> h mod 10 | 5 -> h / 10
  | 6 -> (days + 4) mod 7               (* 1970-01-01 was a Thursday: 0 Sunday *)
  | 7 -> d mod 10 | 8 -> d / 10
  | 9 -> mo mod 10 | 10 -> mo / 10
  | 11 -> yy mod 10 | 12 -> yy / 10
  | _ -> 0

let write t v =
  let v = v land 15 in
  match t.reg with
  | 13 -> t.mode <- v
  | 14 | 15 -> ()
  | r ->
    let block = t.mode land 3 in
    if block > 0 then t.ram.((block - 1) * 13 + r) <- v

let read t =
  let v = match t.reg with
    | 13 -> t.mode
    | 14 | 15 -> 0xF
    | r ->
      let block = t.mode land 3 in
      if block = 0 then time_digit t r else t.ram.((block - 1) * 13 + r) in
  0xF0 lor (v land 15)

let state_size = 41

let save t =
  String.init state_size (fun i ->
      Char.chr (if i = 0 then t.reg else if i = 1 then t.mode else t.ram.(i - 2)))

let restore t s =
  t.reg <- Char.code s.[0] land 15;
  t.mode <- Char.code s.[1] land 15;
  for i = 0 to 38 do t.ram.(i) <- Char.code s.[i + 2] land 15 done

(* msx, msx2: an MSX1 or an MSX2 in a window, and the service msx<pid> or
   msx2<pid> (emu/1) (doc/decisions/retro-emulators.md); the window, the
   service and the command line are Emu_frontend's.

     msx [CARTRIDGE|GAME]               an MSX1, in a window
     msx2 [CARTRIDGE|GAME]              an MSX2 (or msx --msx2)
     msx --headless [CARTRIDGE|GAME]    no window
     msx --bench N [--no-service] [CARTRIDGE|GAME]

   The BIOS: a real MSX1's, if /disk/roms/msx/msx1.rom is there (32 KB:
   it brings MSX-BASIC); a real MSX2's, if /disk/roms/msx/msx2.rom (32
   KB) and msx2ext.rom (16 KB, the SUB-ROM) are; else C-BIOS (the
   package's, free: it starts cartridges only).

   Keys: letters, digits, the punctuation as on a PC (the MSX's
   international keyboard has the same over the same keys), Enter, Space,
   Backspace (BS), Tab, the arrows, Home, Insert, Delete; Ctrl and a
   letter: CTRL and it; End: the MSX's ESC (Escape quits). Page Up
   pauses, Page Down turns the sound on and off. *)

let beside f = Filename.concat (Filename.dirname Sys.argv.(0)) f

let find_file name =
  List.find_opt Sys.file_exists [ beside name; "/disk/pkg/msx/" ^ name ]

let read_file f =
  let ic = open_in_bin f in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let roms = "/disk/roms/msx/"

let sized f n what =
  let s = read_file f in
  if String.length s <> n then failwith (Printf.sprintf "%s: %s is %d KB" f what (n / 1024));
  s

(* the machine: MSX1's or MSX2's, with its BIOS *)
let machine2 msx2 () =
  if not msx2 then
    if Sys.file_exists (roms ^ "msx1.rom") then
      Msx.create ~bios:(sized (roms ^ "msx1.rom") 0x8000 "an MSX1's BIOS") (),
      "MSX1 BIOS (" ^ roms ^ "msx1.rom)"
    else match find_file "cbios_main_msx1.rom", find_file "cbios_logo_msx1.rom" with
      | Some b, Some l -> Msx.create ~bios:(read_file b) ~logo:(read_file l) (), "C-BIOS 0.29a"
      | _ -> failwith "no BIOS: C-BIOS is not in /disk/pkg/msx (pkg install msx)"
  else
    let clock = Mynos.time in
    if Sys.file_exists (roms ^ "msx2.rom") && Sys.file_exists (roms ^ "msx2ext.rom") then
      Msx.create ~clock ~bios:(sized (roms ^ "msx2.rom") 0x8000 "an MSX2's BIOS")
        ~sub:(sized (roms ^ "msx2ext.rom") 0x4000 "an MSX2's SUB-ROM") (),
      "MSX2 BIOS (" ^ roms ^ "msx2.rom, msx2ext.rom)"
    else match find_file "cbios_main_msx2.rom", find_file "cbios_logo_msx2.rom",
               find_file "cbios_sub.rom" with
      | Some b, Some l, Some s ->
        Msx.create ~clock ~bios:(read_file b) ~logo:(read_file l) ~sub:(read_file s) (),
        "C-BIOS 0.29a"
      | _ -> failwith "no BIOS: C-BIOS's MSX2 ROMs are not in /disk/pkg/msx (pkg install msx)"

module Machine (P : sig val msx2 : bool end) = struct
  type t = { m : Msx.t; rom : string }
  type key = Msx_keys.key

  let program = "msx"                   (* the games: /disk/pkg/msx/games *)
  let service = if P.msx2 then "msx2" else "msx"
  let title = if P.msx2 then "MSX2" else "MSX"
  let hz = 60.
  let width = if P.msx2 then 576 else 288
  let height = if P.msx2 then 228 else 216
  let x_scale = if P.msx2 then 1 else 2
  let game_exts = [ ".rom"; ".mx1"; ".mx2" ]

  let create () = let m, rom = machine2 P.msx2 () in { m; rom }

  let machine _ = if P.msx2 then "MSX2" else "MSX1"
  let rom_name t = t.rom
  let z80 t = Msx.z80 t.m
  let frame t = Msx.frame t.m
  let conv = function
    | Msx.Frame_done -> Emu_frontend.Frame_done
    | Msx.Breakpoint pc -> Emu_frontend.Breakpoint pc
    | Msx.Watch (pc, a) -> Emu_frontend.Watch (pc, a)
  let run_fast t = conv (Msx.run_fast t.m)
  let run_checked t ~check = conv (Msx.run_checked t.m ~check)
  let step t = conv (Msx.step t.m)
  let set_watch t w = Msx.set_watch t.m w
  let press t k down = Msx.press t.m k down

  let k = Msx_keys.of_name
  let keys_of s =
    match s with
    | "\r" | "\n" -> Some [ k "ENTER" ]
    | " " -> Some [ k "SPACE" ]
    | "\127" | "\b" -> Some [ k "BS" ]
    | "\t" -> Some [ k "TAB" ]
    | "\027[A" -> Some [ k "UP" ] | "\027[B" -> Some [ k "DOWN" ]
    | "\027[C" -> Some [ k "RIGHT" ] | "\027[D" -> Some [ k "LEFT" ]
    | "\027[H" -> Some [ k "HOME" ] | "\027[F" -> Some [ k "ESC" ]
    | "\027[2~" -> Some [ k "INS" ] | "\027[3~" -> Some [ k "DEL" ]
    | _ when String.length s = 1 ->
      let c = s.[0] in
      if c >= '\001' && c <= '\026' then
        Some [ k "CTRL"; k (String.make 1 (Char.chr (Char.code c + 64))) ]
      else Msx_keys.of_char c
    | _ -> None

  let queue_keys t s = Msx.queue_keys t.m (Msx_keys.parse s)
  let keys_pending t = Msx.keys_pending t.m
  let key_names = Msx_keys.names
  let peek t = Msx.peek t.m
  let poke t = Msx.poke t.m
  let screen t = Msx.screen t.m
  let set_draw t b = Msx.set_draw t.m b
  let changed t = Msx.changed t.m
  let screen_text t = Msx.screen_text t.m
  let set_audio t on = Msx.set_audio t.m on
  let audio_samples t = Msx.audio_samples t.m
  let load t f = Msx.load t.m f
  let save_state t f = Msx.save_state t.m f
  let reset t = Msx.reset t.m
  let reset_keeps_loaded = true
end

module F1 = Emu_frontend.Make (Machine (struct let msx2 = false end))
module F2 = Emu_frontend.Make (Machine (struct let msx2 = true end))

(* msx and msx2 are scripts of one line that run this program (pkg's
   COMMANDS): their path comes first *)
let () =
  match List.tl (Array.to_list Sys.argv) with
  | script :: rest when String.contains script '/' && Filename.basename script = "msx2" ->
    F2.main ~args:rest ()
  | script :: rest when String.contains script '/' && Filename.basename script = "msx" ->
    (match rest with "--msx2" :: r -> F2.main ~args:r () | _ -> F1.main ~args:rest ())
  | "--msx2" :: rest -> F2.main ~args:rest ()
  | args -> F1.main ~args ()

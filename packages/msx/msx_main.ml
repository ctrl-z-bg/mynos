(* msx: an MSX1 in a window, and the service msx<pid> (emu/1)
   (doc/decisions/retro-emulators.md); the window, the service and the
   command line are Emu_frontend's.

     msx [CARTRIDGE|GAME]               a window
     msx --headless [CARTRIDGE|GAME]    no window
     msx --bench N [--no-service] [CARTRIDGE|GAME]

   The BIOS: a real MSX1's, if /disk/roms/msx/msx1.rom is there (32 KB:
   it brings MSX-BASIC), else C-BIOS (the package's, free: it starts
   cartridges only).

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

let real_bios = "/disk/roms/msx/msx1.rom"

module Machine = struct
  type t = { m : Msx.t; rom : string }
  type key = Msx_keys.key

  let program = "msx"
  let service = "msx"
  let title = "MSX"
  let hz = 60.
  let width = Vdp.width
  let height = Vdp.height
  let game_exts = [ ".rom"; ".mx1"; ".mx2" ]

  let create () =
    if Sys.file_exists real_bios then begin
      let bios = read_file real_bios in
      if String.length bios <> 0x8000 then
        failwith (real_bios ^ ": an MSX1's BIOS is 32 KB (its main ROM only)");
      { m = Msx.create ~bios (); rom = "MSX1 BIOS (" ^ real_bios ^ ")" }
    end else
      match find_file "cbios_main_msx1.rom", find_file "cbios_logo_msx1.rom" with
      | Some b, Some l ->
        { m = Msx.create ~bios:(read_file b) ~logo:(read_file l) (); rom = "C-BIOS 0.29a" }
      | _ -> failwith "no BIOS: C-BIOS is not in /disk/pkg/msx (pkg install msx)"

  let machine _ = "MSX1"
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
  let changed t = Msx.changed t.m
  let screen_text t = Msx.screen_text t.m
  let set_audio t on = Msx.set_audio t.m on
  let audio_samples t = Msx.audio_samples t.m
  let load t f = Msx.load t.m f
  let save_state t f = Msx.save_state t.m f
  let reset t = Msx.reset t.m
  let reset_keeps_loaded = true
end

module F = Emu_frontend.Make (Machine)

let () = F.main ()

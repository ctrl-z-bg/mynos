(* zxspectrum: a ZX Spectrum 48K in a window, and the service zx<pid>
   (emu/1) that lets anyone else look at it and drive it
   (doc/decisions/retro-emulators.md); the window, the service and the
   command line are Emu_frontend's.

     zxspectrum [FILE|GAME]               a window; FILE a .tap, .sna or .z80
     zxspectrum --headless [FILE|GAME]    no window: the machine and its service
     zxspectrum --bench N [--no-service] [FILE|GAME]
                                          N frames as fast as it can, the screen
                                          made each frame as for a window: frames
                                          a second (the package's MYNOS.md)

   Keys: letters, digits, Enter, Space; Shift and a letter: CAPS SHIFT
   and it, Ctrl and a letter: SYMBOL SHIFT and it; the punctuation the
   Spectrum has (the double quote, the colon, the comma, the signs...)
   as SYMBOL SHIFT and its key; Backspace: DELETE (CAPS SHIFT and 0); the arrows:
   CAPS SHIFT and 5-8. Page Up pauses, Page Down turns the sound on and
   off, Escape quits (P and M are the Spectrum's). *)

let rom_path () =
  let beside = Filename.concat (Filename.dirname Sys.argv.(0)) "48.rom" in
  if Sys.file_exists beside then beside else "/disk/pkg/zxspectrum/48.rom"

let read_file f =
  let ic = open_in_bin f in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

(* ---- a window's key: the Spectrum's keys it holds ---- *)

let ss k = Some [ Keyboard.Symbol_shift; k ]
let cs k = Some [ Keyboard.Caps_shift; k ]
let symbols = [
  "\"", 'P'; ":", 'Z'; ";", 'O'; ",", 'N'; ".", 'M'; "+", 'K'; "-", 'J'; "*", 'B'; "/", 'V';
  "=", 'L'; "<", 'R'; ">", 'T'; "?", 'C'; "^", 'H'; "'", '7'; "!", '1'; "@", '2'; "#", '3';
  "$", '4'; "%", '5'; "&", '6'; "(", '8'; ")", '9'; "_", '0' ]

let keys_of s =
  let open Keyboard in
  match s with
  | "\r" | "\n" -> Some [ Enter ]
  | " " -> Some [ Space ]
  | "\127" | "\b" -> cs (Digit 0)
  | "\027[D" -> cs (Digit 5) | "\027[B" -> cs (Digit 6)
  | "\027[A" -> cs (Digit 7) | "\027[C" -> cs (Digit 8)
  | _ when String.length s = 1 ->
    let c = s.[0] in
    if c >= 'a' && c <= 'z' then Some [ Letter (Char.uppercase_ascii c) ]
    else if c >= 'A' && c <= 'Z' then cs (Letter c)
    else if c >= '0' && c <= '9' then Some [ Digit (Char.code c - 48) ]
    else if c >= '\001' && c <= '\026' then ss (Letter (Char.chr (Char.code c + 64)))
    else (match List.assoc_opt s symbols with
        | Some k when k >= '0' && k <= '9' -> ss (Digit (Char.code k - 48))
        | Some k -> ss (Letter k)
        | None -> None)
  | _ -> None

module Machine = struct
  type t = Spectrum.t
  type key = Keyboard.key

  let program = "zxspectrum"
  let service = "zx"
  let title = "ZX Spectrum"
  let hz = 50.
  let width = Ula.width
  let height = Ula.height
  let x_scale = 2
  let game_exts = [ ".tap"; ".z80"; ".sna" ]

  let create () =
    let rom = rom_path () in
    if not (Sys.file_exists rom) then
      failwith "no ROM: 48.rom is not in /disk/pkg/zxspectrum (pkg install zxspectrum)";
    Spectrum.create ~rom:(read_file rom)

  let machine _ = "ZX Spectrum 48K"
  let rom_name _ = "Sinclair 48K BASIC (Amstrad)"
  let z80 = Spectrum.z80
  let frame = Spectrum.frame
  let conv = function
    | Spectrum.Frame_done -> Emu_frontend.Frame_done
    | Spectrum.Breakpoint pc -> Emu_frontend.Breakpoint pc
    | Spectrum.Watch (pc, a) -> Emu_frontend.Watch (pc, a)
  let run_fast t = conv (Spectrum.run_fast t)
  let run_checked t ~check = conv (Spectrum.run_checked t ~check)
  let step t = conv (Spectrum.step t)
  let set_watch = Spectrum.set_watch
  let press = Spectrum.press
  let keys_of = keys_of
  let queue_keys t s = Spectrum.queue_keys t (Keyboard.parse s)
  let keys_pending = Spectrum.keys_pending
  let key_names = Keyboard.names
  let peek = Spectrum.peek
  let poke = Spectrum.poke
  let screen = Spectrum.screen
  let set_draw _ _ = ()                       (* the ULA draws when asked *)
  let changed = Spectrum.changed
  let screen_text = Spectrum.screen_text
  let set_audio = Spectrum.set_audio
  let audio_samples = Spectrum.audio_samples
  let load = Spectrum.load
  let save_state = Spectrum.save_state
  let reset = Spectrum.reset
  let reset_keeps_loaded = false              (* the tape is gone *)
end

module F = Emu_frontend.Make (Machine)

let () = F.main ()

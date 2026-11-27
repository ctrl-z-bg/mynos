open Uints

module type S = sig
  type t

  val show : t -> string

  val create_with_rom : print_serial_port:bool -> rom_bytes:Bigstringaf.t -> t

  val run_instruction : t -> Gpu.run_result

  val press : t -> Joypad.key -> unit

  val release : t -> Joypad.key -> unit

  val audio_samples : t -> string
  (** Stereo 16-bit little-endian samples at 22050 Hz, made since the last
      call (MyNOS's Apu). *)

  val set_audio : t -> bool -> unit

  (** MyNOS's (emu/1, packages/camlboy): the CPU's registers by name, its
      PC, and memory as the CPU sees it (a byte; 0..0xFFFF) *)
  val registers : t -> (string * int) list
  val pc : t -> int
  val peek : t -> int -> int
  val poke : t -> int -> int -> unit

  module For_tests : sig
    val prev_inst : t -> Instruction.t

    val get_ly : t -> int

    val get_lcd_stat : t -> uint8

    val get_mcycles_in_mode : t -> int

    val get_tima_count : t -> uint8
  end
end

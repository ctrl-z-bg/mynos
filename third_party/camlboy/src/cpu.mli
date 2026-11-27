open Uints

module Make (Bus : Word_addressable_intf.S) : sig
  type t

  val create :
    bus:Bus.t ->
    ic:Interrupt_controller.t ->
    registers:Registers.t ->
    sp:uint16 ->
    pc:uint16 ->
    halted:bool ->
    ime:bool ->
    t

  (** Executes a single instruction.
   ** Returns machine cycle (mcycle) count consumed during the execution. *)
  val run_instruction : t -> int

  val show : t -> string

  (* MyNOS's (emu/1, packages/camlboy): the CPU's state, read *)
  val pc : t -> int
  val sp : t -> int
  val halted : t -> bool
  val ime : t -> bool

  module For_tests : sig

    val execute : t -> Inst_info.t -> int

    val prev_inst : t -> Instruction.t

  end
end

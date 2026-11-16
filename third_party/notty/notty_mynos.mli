(** A full-screen Notty terminal on the MyNOS console (see notty_mynos.ml). *)

module Term : sig
  type t

  val create : ?mouse:bool -> unit -> t
  (** Raw console input, the alternate screen; released at exit. *)

  val release : t -> unit
  val image : t -> Notty.image -> unit
  val cursor : t -> (int * int) option -> unit
  val refresh : t -> unit
  val size : t -> int * int

  val event : t -> [ Notty.Unescape.event | `End ]
  (** The next key (blocks). *)
end

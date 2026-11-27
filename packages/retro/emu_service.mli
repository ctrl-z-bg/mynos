(** The service of an emulator (doc/decisions/retro-emulators.md, section
    6): a thread that listens for emu/1 requests and queues them, with
    their channels, for the emulation loop, which does them between
    frames (or when it has stopped) and answers. The thread never touches
    the machine; the loop takes no lock unless something is queued.

    {[
      let svc = Emu_service.start "zx" in
      (* the loop, once a frame: *)
      if Emu_service.pending svc then
        List.iter (fun (Emu_service.Job (to_, r)) -> ... answer to_ r v) (Emu_service.take svc)
    ]} *)

type reply_to
(** Where an answer goes: the request's channel. *)

type job = Job : reply_to * 'a Emu_proto.request -> job

type t

val start : string -> t
(** [start "zx"]: registers zx<pid> and starts the thread (a [Thread],
    not a [Domain]: a second domain slows every minor collection). *)

val name : t -> string

val pending : t -> bool
(** Something is queued ([Atomic.get]: no lock). *)

val take : t -> job list
(** The queued requests, oldest first; the queue emptied (under its lock). *)

val answer : reply_to -> 'a Emu_proto.request -> 'a -> unit
val fail : reply_to -> string -> unit
(** The answers: the value, or an error with this message. *)

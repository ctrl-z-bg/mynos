(** Sound, over typed IPC with the service [sound] (soundd,
    services/sound): streams of samples, mixed and played by a Sound
    Blaster 16, tones, the volume. Protocol ["sound/1"].

    The output is {!rate} samples a second, stereo, 16-bit signed
    little-endian: a stream gets them as they are; {!play_file} converts a
    WAV file on the way.

    {[
      Sound.tone 440 200;                       (* a beep *)
      Sound.play_file "/disk/music.wav"         (* returns when played *)
    ]} *)

type _ request =
  | Info : (int * int) request          (** the rate and the channels *)
  | Open : int request                  (** a stream: its number *)
  | Write : int * string -> unit request
      (** samples for a stream; waits while it holds more than a second *)
  | Close : int -> unit request         (** it ends once played; waits until then *)
  | Stop : int -> unit request          (** it ends at once *)
  | Tone : int * int -> unit request    (** [(hz, ms)]: a square wave *)
  | Volume : int -> int request         (** 0 to 100, -1 unchanged: the volume *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : unit -> t
(** The sound service; [Mynos.Error] if there is none (no sound card). *)

val call : t -> 'a request -> 'a

val rate : int
(** 22050 *)

val tone : ?sound:t -> int -> int -> unit
(** [tone hz ms]. *)

val volume : ?sound:t -> int -> int
(** [volume level] (0 to 100; -1 asks): the volume in use. *)

(** {2 Streams} *)

type stream

val open_stream : ?sound:t -> unit -> stream
val write : stream -> string -> unit
(** Samples, as the output takes them; waits while the stream is full. *)

val close : stream -> unit
(** The stream ends once what it holds has played: returns then. *)

val stop : stream -> unit

(** {2 WAV files} *)

type wav = { channels : int; wav_rate : int; bits : int; data : string }
(** PCM (format 1), 8 or 16 bits, mono or stereo: [data] is its samples. *)

val read_wav : string -> wav
(** The contents of a WAV file; [Failure] if it is not one this reads. *)

val convert : wav -> int -> int -> string
(** [convert w first count]: [count] output frames from frame [first] (at
    {!rate}) of [w], as the output takes them; fewer at its end. *)

val frames : wav -> int
(** Its length, in output frames. *)

val play_file : ?sound:t -> string -> unit
(** Play a WAV file, a second at a time; returns when it has played. *)

(** The agent: a task in natural language, carried out by a language model
    (module {!Llm}) with tools, step by step (doc/decisions/llm.md, section
    9). The [agent] command and the agent window use it.

    Its tools: [run_command] (a line of sh), [run_ocaml] (a program,
    type-checked by ocamlc against MyNOS's libraries before it runs),
    [ocaml_signature], [read_file], [write_file], [list_directory], and
    every request of the typed services given, from their descriptions
    (module {!Tools}). What changes things (commands, writes, programs,
    requests not marked safe) is done only once [confirm] agrees. The
    event recorder runs during each task (its file: [trace calls FILE]). *)

type event =
  | Task of string                 (** the user's request *)
  | Said of string                 (** the model's text *)
  | Action of string               (** what a tool does: "read /disk/a",
                                       "run: ls" (once allowed)... *)
  | Result of { text : string; error : bool }   (** a tool's result *)
  | Note of string                 (** the recording, a stop *)

type answer = Yes | No | All       (** [All]: yes, and to everything after *)

type t
(** A session: the model, the tools, the conversation so far. *)

val create :
  ?profile:string -> ?services:string list -> ?max_turns:int -> ?trace_file:string ->
  ?yes_to_all:bool -> ?warn:(string -> unit) -> unit -> t
(** [services]: the typed services it may use (["net"]); [max_turns]: model
    calls per task (20); [trace_file]: [/tmp/agent.trc]. @raise Failure
    without the language model service. *)

val run : t -> emit:(event -> unit) -> confirm:(string -> answer) -> string -> int
(** [run a ~emit ~confirm task]: carries the task out, in the conversation
    so far (a follow-up can say "and now..."), telling [emit] what happens
    and asking [confirm] (the action, shown) before what changes things.
    0 once the model answered, 1 if it stopped (an error, a refusal, too
    many calls). *)

val ocamlc_libraries : string -> string list
(** The arguments that give ocamlc, inside MyNOS, the libraries a
    program's source names: [-noautolink], [mynos.cma], then [unix.cma],
    [threads.cma], [str.cma], [nums.cma], [graphics.cma] when it mentions
    their modules ([Unix], [Thread], [Str], [Num] or [Big_int],
    [Graphics]). The run_ocaml and build_ocaml tools and {!Shell.compile}
    use it. *)

val tokens : t -> int * int
(** In and out, since the session started. *)

val trace_file : t -> string
(** Where each task's recording is saved. *)

val set_yes_to_all : t -> bool -> unit
val forget : t -> unit
(** A new conversation. *)

(** MyNOS's voice: the agent (module {!Agent}) told to be MyNOS itself,
    speaking in the first person about what it is and what it is doing,
    from what it checks (the "Ask MyNOS" window, and its service mynos).

    Its tools, beside the agent's own, observe the running system: its
    state (processes, threads, memory, the services each registered), its
    log, the services and their descriptions, a request of a service (the
    ones marked safe at once, the others only once confirmed), a short
    recording of what is happening now (the event recorder), and the
    manual (the package manual, if installed: searched, then read by
    section). *)

val tools : Agent.extra list

val system_prompt : unit -> string

val create : ?warn:(string -> unit) -> unit -> Agent.t
(** A session: {!Agent.create} with this prompt and these tools, its
    tasks not recorded (so that it can record the system). @raise
    Failure without the language model service. *)

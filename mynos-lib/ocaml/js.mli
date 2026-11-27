(** JavaScript, over typed IPC with the service [js] (jsd, services/js, in
    C with QuickJS-ng): contexts of their own (a page's), code run in
    them, what [console] printed. Protocol ["js/1"].

    {[
      let c = Js.create () in
      let r = Js.eval c "console.log('hi'); 6 * 7" in
      r.Js.value;                         (* "42" *)
      r.console;                          (* "hi\n" *)
      Js.destroy c
    ]}

    A context's memory is limited (64 MB), its stack too, and a run stops
    after 5 s with an exception. *)

type _ request =
  | Create : string -> int request              (** a new context, the DOM's service (or ""): its number *)
  | Eval : int * string * string -> (bool * string * string) request
      (** [(context, code, name)]: ended without an exception, the value
          (or the exception and its stack), what console printed *)
  | Destroy : int -> unit request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : unit -> t
(** The JavaScript service; [Mynos.Error] if there is none. *)

val call : t -> 'a request -> 'a

type context = { js : t; id : int }

val create : ?js:t -> ?dom:string -> unit -> context
(** A context; with [dom], the name of a service of protocol ["dom/1"]
    (one request, [call (op, args)] to a list of strings): its global
    [__dom(op, ...args)] calls it, and throws its errors. *)

type result = {
  ok : bool;             (** no exception *)
  value : string;        (** the value (a string as it is, an object as JSON), or the exception *)
  console : string;      (** what console printed, a line each call *)
}

val eval : ?name:string -> context -> string -> result
(** Run a script in the context ([name]: its file, for the stack). *)

val destroy : context -> unit

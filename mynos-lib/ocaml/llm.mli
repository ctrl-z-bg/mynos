(** Language models, over typed IPC with the service [llm] (llmd,
    services/llm). Protocol ["llm/1"]; doc/decisions/llm.md.

    {[
      let l = Llm.connect ();;
      Llm.call l Llm.Profiles;;            (* [("claude", "anthropic", ...)] *)
      Llm.ask l "Which year was OCaml born?";;
      let a = Llm.call l (Llm.Chat { Llm.chat with
                                     messages = [ Llm.user "Hello" ] });;
      Llm.text a;;
    ]}

    The models are configured in [/disk/llm.env] (profiles: an API, a
    model, a key); without it, every call fails with ["no model
    configured: ..."]. A provider's error (a bad key, a rate limit) is the
    call's {!Ipc.Remote_error}. *)

type block =
  | Text of string
  | Tool_call of { id : string; name : string; input : string }
      (** the model calls a tool: [input] is a JSON object *)
  | Tool_result of { id : string; content : string; error : bool }
      (** the result of the call [id], sent back in a [User] message *)
  | Opaque of string
      (** a block of the provider's own (Claude's thinking), as JSON: give
          it back unchanged in the next request of a conversation *)

type role = User | Assistant

type message = { role : role; content : block list }

type tool = {
  name : string;
  description : string;
  schema : string;     (** a JSON Schema of its input (an object) *)
}

type chat = {
  profile : string;    (** [""]: the default one *)
  system : string;     (** [""]: none *)
  messages : message list;
  tools : tool list;
  max_tokens : int;    (** 0: the profile's (16000 unless set) *)
}

type stop =
  | End                (** the model finished its answer *)
  | Tool_use           (** it waits for the results of its tool calls *)
  | Max_tokens         (** cut at [max_tokens] *)
  | Refusal            (** it declined *)
  | Other of string

type answer = {
  content : block list;
  stop : stop;
  model : string;      (** the model that answered *)
  input_tokens : int;
  output_tokens : int;
}

type _ request =
  | Profiles : (string * string * string) list request
      (** [(name, api, model)] of each profile, the default first *)
  | Chat : chat -> answer request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : ?service:string -> unit -> t
(** Waits up to 5 s for the service to be registered. *)

val call : t -> 'a request -> 'a

val chat : chat
(** An empty chat, to fill: [{ Llm.chat with messages = [...] }]. *)

val user : string -> message
(** A [User] message of one [Text]. *)

val text : answer -> string
(** The [Text] blocks of an answer, joined. *)

val ask : ?profile:string -> ?system:string -> t -> string -> string
(** One question, one answer's text. *)

type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }

val answer : ?caller:Ipc.caller -> handler -> string -> string
(** The service's side: the reply to a request message (see llmd). *)

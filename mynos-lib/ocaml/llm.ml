(* Language models over typed IPC: see llm.mli. The service is llmd
   (services/llm/llmd.ml). *)

type block =
  | Text of string
  | Tool_call of { id : string; name : string; input : string }
  | Tool_result of { id : string; content : string; error : bool }
  | Opaque of string

type role = User | Assistant

type message = { role : role; content : block list }

type tool = { name : string; description : string; schema : string }

type chat = {
  profile : string;
  system : string;
  messages : message list;
  tools : tool list;
  max_tokens : int;
}

type stop = End | Tool_use | Max_tokens | Refusal | Other of string

type answer = {
  content : block list;
  stop : stop;
  model : string;
  input_tokens : int;
  output_tokens : int;
}

type _ request =
  | Profiles : (string * string * string) list request
  | Chat : chat -> answer request

let block_codec =
  Wire.(variant [
      case 0 string (fun s -> Text s) (function Text s -> Some s | _ -> None);
      case 1 (triple string string string)
        (fun (id, name, input) -> Tool_call { id; name; input })
        (function Tool_call { id; name; input } -> Some (id, name, input) | _ -> None);
      case 2 (triple string string bool)
        (fun (id, content, error) -> Tool_result { id; content; error })
        (function Tool_result { id; content; error } -> Some (id, content, error)
                | _ -> None);
      case 3 string (fun s -> Opaque s) (function Opaque s -> Some s | _ -> None) ])

let message_codec =
  Wire.(conv (fun m -> (m.role = Assistant, m.content))
          (fun (a, content) -> { role = (if a then Assistant else User); content })
          (pair bool (list block_codec)))

let tool_codec =
  Wire.(conv (fun (t : tool) -> (t.name, t.description, t.schema))
          (fun (name, description, schema) -> { name; description; schema })
          (triple string string string))

let chat_codec =
  Wire.(conv
          (fun c -> ((c.profile, c.system, c.max_tokens), (c.messages, c.tools)))
          (fun ((profile, system, max_tokens), (messages, tools)) ->
             { profile; system; max_tokens; messages; tools })
          (pair (triple string string int)
             (pair (list message_codec) (list tool_codec))))

let stop_codec =
  Wire.(variant [
      case 0 unit (fun () -> End) (function End -> Some () | _ -> None);
      case 1 unit (fun () -> Tool_use) (function Tool_use -> Some () | _ -> None);
      case 2 unit (fun () -> Max_tokens) (function Max_tokens -> Some () | _ -> None);
      case 3 unit (fun () -> Refusal) (function Refusal -> Some () | _ -> None);
      case 4 string (fun s -> Other s) (function Other s -> Some s | _ -> None) ])

let answer_codec =
  Wire.(conv
          (fun a -> ((a.content, a.stop, a.model), (a.input_tokens, a.output_tokens)))
          (fun ((content, stop, model), (input_tokens, output_tokens)) ->
             { content; stop; model; input_tokens; output_tokens })
          (pair (triple (list block_codec) stop_codec string) (pair int int)))

module Protocol = struct
  let id = "llm/1"
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Profiles -> Wire.write w Wire.int 0
    | Chat c -> Wire.write w Wire.int 1; Wire.write w chat_codec c

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Profiles
    | 1 -> Request (Chat (Wire.read r chat_codec))
    | n -> raise (Wire.Error (Printf.sprintf "llm: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Profiles -> Wire.(list (triple string string string))
    | Chat _ -> answer_codec
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect ?(service = "llm") () =
  let rec go tries =
    match I.connect service with
    | c -> c
    | exception Mynos.Error _ when tries > 0 -> Mynos.sleep 0.1; go (tries - 1) in
  go 50

let call = I.call

let chat = { profile = ""; system = ""; messages = []; tools = []; max_tokens = 0 }

let user s = { role = User; content = [ Text s ] }

let text (a : answer) =
  String.concat "" (List.filter_map (function Text s -> Some s | _ -> None) a.content)

let ask ?(profile = "") ?(system = "") l q =
  text (call l (Chat { chat with profile; system; messages = [ user q ] }))

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }

let answer = I.answer

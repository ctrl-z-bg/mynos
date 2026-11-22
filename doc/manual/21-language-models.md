# 21. Language models

A program in MyNOS asks a language model a question the way it asks for a
file: with a typed request to a service. This chapter shows how: one
question (21.2), a conversation (21.3), tools that the model may call
(21.4), the requests of any typed service turned into tools with no glue
code (21.5), and the agent, which does all of it for a task (21.6). The
service is described in appendix E.13; the design, and why it is so, in
`doc/decisions/llm.md`.

## 21.1 Models are a service

```
   your program                 llmd ("llm", OCaml, no privilege)
  ┌───────────────┐  llm/1    ┌──────────────────────────┐  net/1   ┌──────┐
  │ Llm.ask l "?" │ ────────► │ profiles: /disk/llm.env  │ ───────► │ netd │──► HTTPS
  │               │ ◄──────── │ Claude's Messages API,   │ ◄─────── │      │   to the
  └───────────────┘  answer   │ or Chat Completions      │          └──────┘   provider
                              └──────────────────────────┘
```

`llmd` registers `llm` and speaks **llm/1** (module `Llm`,
`mynos-lib/ocaml/llm.mli`). It knows two HTTP APIs: `anthropic`
(Claude's Messages API) and `openai` (Chat Completions, also spoken by
vLLM, Ollama and llama.cpp). A **profile** is a name for an API, a model,
a URL and a key, written in the configuration file `/disk/llm.env` as
`LLM_<NAME>_API`, `LLM_<NAME>_MODEL` and so on, with `LLM_DEFAULT`
naming the default profile; `llm.env.example` in the source tree lists
the fields. `llmd` reads the file again at every request, so it can be
edited while the system runs. The keys never leave `llmd`: a program sees
profile names and model names, nothing else.

Without the file, or without the service, there is no model; programs
should say so and go on. MyNOS works the same without one.

## 21.2 One question

```ocaml
let l = Llm.connect () in
print_endline (Llm.ask l "Which year was OCaml born?")
```

`Llm.connect ()` finds the service (waiting up to 5 s for it to be
registered; `Mynos.Error` without it). `Llm.ask ?profile ?system l
question` sends one user message, with an optional system prompt, to a
profile (the default if `profile` is `""` or absent), and returns the
text of the answer. `Llm.call l Llm.Profiles` lists the profiles, the
default first, as `(name, api, model)`:

```ocaml
List.iter (fun (name, api, model) -> Printf.printf "%s: %s, %s\n" name api model)
  (Llm.call l Llm.Profiles)
```

Every failure is an `Ipc.Remote_error (service, message)`, and the
message says what happened:

| Message (start) | When |
|---|---|
| `no model configured: write /disk/llm.env ...` | no configuration, or no profile in it |
| `no profile "nope" (there are: claude, local)` | an unknown profile |
| `claude: 401 authentication_error: ...` | the provider's own error, prefixed by the profile: a bad key, a rate limit, an overloaded server |
| `host not found`, `TLS: ...`, `timeout` | the network (chapter 19) |

An answer takes seconds; `llmd` serves four requests at once, each in a
domain of its own, so one slow model does not hold the others.

## 21.3 Conversations

`Llm.ask` is a shorthand for the request `Chat`:

```ocaml
type chat = {
  profile : string;          (* "": the default *)
  system : string;           (* "": none *)
  messages : message list;
  tools : tool list;
  max_tokens : int;          (* 0: the profile's (16000 unless set) *)
}
```

`Llm.chat` is an empty one to fill with `{ Llm.chat with ... }`. A
message is a role, `User` or `Assistant`, and a list of blocks: `Text`,
`Tool_call`, `Tool_result`, or `Opaque`, a block of the provider's own
(Claude's thinking) kept as JSON. `Llm.user s` is a user message of one
text. The reply is an `answer`:

| Field | |
|---|---|
| `content` | the model's blocks |
| `stop` | `End` (finished), `Tool_use` (waits for tool results), `Max_tokens` (cut), `Refusal`, `Other s` |
| `model` | the model that answered |
| `input_tokens`, `output_tokens` | what the call cost |

`Llm.text a` joins its text blocks. A model keeps no memory between
calls: a conversation is the whole list of messages, sent again each
time, with the model's own answers in it:

```ocaml
let c = { Llm.chat with system = "Be brief."; messages = [ Llm.user "Hello" ] } in
let a = Llm.call l (Llm.Chat c) in
let c = { c with messages = c.messages @ [ { Llm.role = Assistant; content = a.content };
                                           Llm.user "And in Italian?" ] } in
let b = Llm.call l (Llm.Chat c) in
print_endline (Llm.text b)
```

Give back the answer's `content` whole, `Opaque` blocks included: the
provider may refuse a conversation in which they are missing or changed.

## 21.4 Tools

A **tool** is something the model may ask the program to do. The program
describes it, with a JSON Schema of its input:

```ocaml
let shout = { Llm.name = "shout"; description = "Says a text in capitals";
              schema = {|{"type":"object","properties":{"text":{"type":"string"}},
                         "required":["text"]}|} }
```

When the model wants it, the answer stops with `Tool_use`, and its
content holds one or more `Tool_call { id; name; input }`, `input` being
a JSON object. The program runs them, sends their results back as
`Tool_result { id; content; error }` blocks in a `User` message, after
the model's own message, and calls again. The model then answers, or
calls more tools:

```
  program                                     model
     │ Chat: user "quiet", tools [shout] ───────►│
     │◄──── Tool_use: Tool_call {id; "shout";    │
     │                {"text":"quiet"}}          │
     │ (runs it: "QUIET")                        │
     │ Chat: ..., assistant [the call],          │
     │       user [Tool_result {id; "QUIET"}] ──►│
     │◄──── End: Text "tool said: QUIET"         │
```

`error = true` tells the model that the tool failed and `content` is the
error's message; it usually tries something else. The program decides
what a tool may do: nothing runs unless the program's own code runs it.

## 21.5 A service's requests as tools: module `Tools`

Every service made with `Ipc.Make` describes its protocol when asked
(`Ipc.describe name`): a summary, and for each request its number, name,
documentation, the shapes of its arguments and reply (`Wire.shape`), and
whether it is **safe** (it only reads). netd answers the same
description, from a table in C. Module `Tools` (`tools.mli`) turns a
description into tools:

```ocaml
let ts = Tools.of_service "net" in
let names = List.map (fun t -> t.Tools.tool.Llm.name) ts in
  (* ["net_config"; "net_ping"; "net_resolve"; "net_connect"; ...] *)
let ip = Tools.call (Tools.find ts "net_resolve") {|{"name": "example.com"}|} in
  (* "\"172.66.147.243\"": a JSON string *)
...
```

A tool is named `SERVICE_REQUEST`; its description is the request's,
followed by the service's summary and, for an unsafe request, "It
changes things."; its schema comes from the arguments' shape. For
`net_ping`:

```
{"type":"object","properties":{"address":{"type":"string"},
 "timeout_ms":{"type":"integer"}},"required":["address","timeout_ms"]}
```

`Tools.call t input` writes the JSON `input` as the protocol's bytes,
sends the request to the service, and reads the reply back as JSON: no
code of the service's own is needed. Values map as follows:

| Wire | JSON |
|---|---|
| unit / bool, int, float, string | `null` / JSON's own (strings are bytes) |
| option | `null` or the value |
| list, array | an array |
| a tuple of named components (`Wire.field`) | an object |
| another tuple | an array |
| a variant | the case's name, or `{"name": value}` if it carries one |

Input that does not fit the shape raises `Failure` (`expected
{"type":"string"}, not 5`); the service's refusal raises
`Ipc.Remote_error`. `Tools.call` sends whatever it is given: checking
`t.request.safe`, and asking before an unsafe request, is the caller's
work.

**A complete example: netask.** A question about the machine's network,
answered by a model that may use netd's safe requests:

```ocaml
(* netask: a question to a model that may use the network's safe
   requests (config, ping, resolve) as tools.  netask QUESTION *)

let tool_result tools = function
  | Llm.Tool_call { id; name; input } ->
    let content, error =
      match Tools.call (Tools.find tools name) input with
      | json -> (json, false)
      | exception Not_found -> ("no tool " ^ name, true)
      | exception (Ipc.Remote_error (_, m) | Failure m) -> (m, true) in
    Printf.printf "  [%s %s -> %s]\n%!" name input content;
    Some (Llm.Tool_result { id; content; error })
  | _ -> None

let () =
  let question = String.concat " " (List.tl (Array.to_list Sys.argv)) in
  let l = Llm.connect () in
  (* only what changes nothing: the requests marked safe *)
  let tools = List.filter (fun t -> t.Tools.request.Ipc.safe) (Tools.of_service "net") in
  let chat = { Llm.chat with
               system = "You answer questions about this machine's network.";
               tools = List.map (fun t -> t.Tools.tool) tools } in
  let rec turn n messages =
    let a = Llm.call l (Llm.Chat { chat with messages }) in
    let messages = messages @ [ { Llm.role = Assistant; content = a.content } ] in
    match a.stop with
    | Llm.Tool_use when n < 10 ->
      let results = List.filter_map (tool_result tools) a.content in
      turn (n + 1) (messages @ [ { Llm.role = User; content = results } ])
    | Llm.End | Llm.Tool_use -> print_endline (Llm.text a)
    | Llm.Max_tokens -> print_endline (Llm.text a ^ " [cut]")
    | Llm.Refusal -> print_endline "(the model declined)"
    | Llm.Other s -> Printf.printf "(stopped: %s)\n" s in
  match turn 1 [ Llm.user question ] with
  | () -> ()
  | exception Ipc.Remote_error (_, m) -> prerr_endline ("netask: " ^ m); exit 1
```

The loop is 21.4's, with at most ten model calls. The tools are only
the three safe requests of `net/1` (`config`, `ping`, `resolve`), so the
model can look but not connect anywhere. Run against the fake provider
of the tests (21.7), which calls the first tool it is given:

```
$ netask.byte What is my address?
  [net_config {} -> {"mac":"52:54:00:12:34:56","address":"10.0.2.15",
   "netmask":"255.255.255.0","gateway":"10.0.2.2","dns":"10.0.2.3"}]
tool said: {"mac":"52:54:00:12:34:56","address":"10.0.2.15", ...}
```

A real model answers in words, after the same tool call.

> **THE MyNOS FACTOR — A service's description is its tool.**
> Because protocols describe themselves, a model can use any typed
> service of the system, the network, the disk driver, the display, the
> language model service itself, without a line of code written for it:
> `Tools.of_service "ata0"` gives `ata0_info`, `ata0_read` and
> `ata0_write`, the last marked as changing things. The type checker
> keeps the OCaml side honest; the description keeps the model's.

## 21.6 The agent: module `Agent`

`Agent` (`agent.mli`) is the loop of 21.4 made into a component: the
`agent` command and the agent window use it. Its tools are its own
(`run_command`, a line of `sh`; `run_ocaml`, a program type-checked by
`ocamlc` before it runs; `build_ocaml`; `ocaml_signature`; `read_file`,
`write_file`, `list_directory`) and the requests of the typed services
it is given, through `Tools`. A program gives it two functions: `emit`,
told what happens, and `confirm`, asked before anything that changes
things (a command, a write, a program, an unsafe request):

```ocaml
(* agentdemo: a task for the agent, at the console.  agentdemo TASK *)
let () =
  let task = String.concat " " (List.tl (Array.to_list Sys.argv)) in
  let a = Agent.create ~services:[ "net" ] () in
  let emit = function
    | Agent.Task t -> Printf.printf "> %s\n%!" t
    | Said s -> Printf.printf "%s\n%!" s
    | Action a -> Printf.printf "  [%s]\n%!" a
    | Result { text; error } ->
      Printf.printf "  %s%s\n%!" (if error then "error: " else "") text
    | Note n -> Printf.printf "  (%s)\n%!" n in
  let confirm what =
    Printf.printf "Allow %s? [y/n/a] %!" what;
    match In_channel.input_line stdin with
    | Some "y" -> Agent.Yes
    | Some "a" -> Agent.All
    | _ -> Agent.No in
  exit (Agent.run a ~emit ~confirm task)
```

`Agent.create ?profile ?services ?max_turns ?trace_file ?yes_to_all ()`
makes a session (`services`: `["net"]` by default; `max_turns`: 20 model
calls a task). `Agent.run a ~emit ~confirm task` carries out one task,
in the conversation so far, so a second task can say "and now..."; it
returns 0 once the model has answered, 1 if it stopped (an error, a
refusal, too many calls). `All` answers yes to the rest of the task;
`set_yes_to_all` and `forget` (a new conversation) act on the session,
`tokens` tells the tokens spent.

Each task is recorded by the event recorder (chapter 22): the agent
marks each model call and each tool, and saves the recording to
`/tmp/agent.trc` (`trace_file`), so what the model made the system do can
be read afterwards with `trace calls /tmp/agent.trc`. If another program
is recording, the agent says so in a `Note` and works unrecorded.

## 21.7 MyNOS's voice: module `Voice`

`Agent.create` also takes `?system` (the model's instructions, in place
of the agent's), `?record` (each task under the event recorder; true)
and `?extra` (tools of the program's: a `Llm.tool` and the function that
runs it). Module `Voice` uses them to make the agent speak as MyNOS:
its prompt says "you are MyNOS, in the first person; check what you say
about yourself with your tools, take your design from your manual, say
when you do not know", and its tools look at the running system:

| Tool | What it gives |
|---|---|
| `my_state` | version, uptime, memory, every process (threads, C or OCaml, driver) and its services |
| `my_log` | the last lines of the kernel's log |
| `my_services` | each registered name, its program, protocol and summary |
| `describe_service` | a service's description of itself, request by request |
| `ask_service` | a request of a service: at once if it only reads, else after a yes |
| `watch_me` | 1 to 5 seconds under the event recorder: who called whom, how often |
| `manual_search`, `manual_read` | the package `manual`: lines with some words, then a section |

`watch_me` needs the recorder, which is why `Voice.create` makes a
session whose tasks are not recorded. The "Ask MyNOS" window (10.12) is
the agent window started as `ask.byte`; it serves `mynos` (mynos/1,
`ask`: a question, the answer) with a session of its own that never
changes anything. The tools are checked without a model by the library
test (`tests/mynos-ocaml`).

## 21.8 Testing without a model

`tools/net-peer.py llm PORT` is a fake provider for the host: it speaks
both APIs, checks the headers and the shape of each request as the real
ones do, answers a text that echoes the last user text (`echo: hello`),
and, when it is given tools, calls one (the first, or the one named by a
leading `[name] ` in the question) with the question as its input; after
a tool result it answers `tool said: ...`. Point a profile's `URL` at it
(`http://10.0.2.2:PORT/v1`, the host as QEMU's user network shows it),
with the key that `net-peer.py` expects, and start `llmd` with that
file as its argument (`llmd.byte /test.env`): the examples of this
chapter run, and give the outputs shown, with no account and no cost.
The network test (`tests/net/net_test.ml`) does exactly this.

## 21.9 Known limits

- No streaming: an answer comes whole, after the model has finished.
- `Tools` maps strings as JSON strings: binary data (a disk sector) does
  not suit a model's tools.
- Descriptions are asked by name, and only of typed services
  (`Ipc.describe`'s documentation); nothing in the registry's list says
  which names those are.
- The configuration is a file any process can read: MyNOS has one user
  (`doc/decisions/identity-and-permissions.md`). To keep a key out of
  MyNOS, point the profile's URL at a proxy on the host that adds it.

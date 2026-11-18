# Decision: language models as a service

- **Issue:** mynos-wsd (an "AI-OS" direction, from Alessandro's idea)
- **Date:** 2026-11-17
- **Status:** accepted (2026-11-17); all four steps implemented the same
  day: `llmd`, `llm/1` and `llm`; `ask`; descriptions and `Tools`; `agent`.

## The idea

MyNOS has a high-level language (OCaml), typed services, and an event
recorder that shows every message between processes. Language models are
becoming a commodity, called like any other service; the interesting part
is what sits above them: agents that use the system's own services as their
tools, with the recorder showing what they did. The plan, in order:

1. **`llmd`**, a service with the protocol `llm/1`: one way for any program
   to ask a model, whichever provider runs it;
2. **`ask` in `sh`**: a request in natural language; the system proposes a
   command, and runs it only once confirmed;
3. **protocols that describe themselves**: a typed service answers a
   `Describe` request with its requests and their types, from which a
   model's tools are made;
4. **an agent loop in OCaml**, with the recorder on.

Then the GUI. This note is about step 1, and what all four rely on.

## Choices

### 1. Optional

Nothing in MyNOS depends on a model. `llmd` starts from `init.rc` like the
other services; without a configuration it answers every request with "no
model configured: see /disk/llm.env", and `ask` and the agent say so. The
system boots and works the same with or without it.

### 2. Configuration: a `.env` file

`/disk/llm.env`, with the syntax of a `.env` file (`NAME=value`, `#`
comments, optional quotes): what one keeps API keys in elsewhere. `/disk`
is the only place that survives a reboot, where `ca.pem` already is. `llmd`
reads it at every request, so an edit takes effect at once.

On the host, `llm.env` at the root of the repository (ignored by git;
`llm.env.example` is the reference) is copied into the demo's disk image by
`tools/run-demo.sh` each time it starts: the keys are kept where they are
kept for any other project, and MyNOS gets them.

Several **profiles**, each a name (lower case in requests):

```
LLM_DEFAULT=claude
LLM_CLAUDE_API=anthropic          # anthropic | openai
LLM_CLAUDE_MODEL=claude-opus-5-5
LLM_CLAUDE_KEY=sk-ant-...
LLM_CLAUDE_URL=...                # optional: the API's base, with /v1
LLM_CLAUDE_MAX_TOKENS=16000       # optional
LLM_CLAUDE_EFFORT=high            # optional (anthropic)
LLM_CLAUDE_FALLBACKS=default      # optional (anthropic)
```

**The key in MyNOS.** MyNOS has no users and its file services do not check
who reads what: any program in MyNOS can read `/disk/llm.env`. For a
development system that is acceptable, and said. Who does not want the key
inside MyNOS points `URL` at a proxy on the host (`http://10.0.2.2:PORT/v1`)
that adds it, and leaves `KEY` empty. When MyNOS has users (identity is
there since `identity-and-permissions.md`), the file becomes `llmd`'s.

### 3. Providers: two APIs cover them

Most providers speak one of two HTTP APIs:

- **`anthropic`**: Claude's Messages API (`POST {URL}/messages`, headers
  `x-api-key` and `anthropic-version`), default URL
  `https://api.anthropic.com/v1`;
- **`openai`**: the Chat Completions API (`POST {URL}/chat/completions`,
  `Authorization: Bearer`), default URL `https://api.openai.com/v1`. Spoken
  by OpenAI (ChatGPT's models), and by the servers one runs oneself:
  **vLLM** (`http://HOST:8000/v1`), **Ollama** (`http://HOST:11434/v1`),
  llama.cpp's server, LM Studio; and by routers such as OpenRouter.

So `llmd` has two adapters, not one per provider. A model "on the host"
(Ollama, vLLM, reached at 10.0.2.2) is the local model worth having; one
running inside MyNOS (i386, one CPU, no vector unit to speak of) would be
a toy.

Requests are not streamed: an answer comes whole (`max_tokens` defaults to
16000, and `llmd` waits up to 5 minutes for it). Streaming can come with
the GUI, where text appearing as it is written matters.

For Claude: thinking is left to the model's default (adaptive on current
models); `EFFORT` sets `output_config.effort`; `FALLBACKS=default` turns on
the server-side fallback when a model declines a request (beta
`server-side-fallback-2026-07-01`), and is on in the example. For OpenAI's
own API the token limit is sent as `max_completion_tokens` (its newer
models refuse `max_tokens`); other `openai` servers get `max_tokens`.

### 4. The protocol `llm/1`

Typed IPC (`typed-ipc.md`), the same for every provider:

```ocaml
type block =
  | Text of string
  | Tool_call of { id : string; name : string; input : string }  (* JSON *)
  | Tool_result of { id : string; content : string; error : bool }
  | Opaque of string     (* a provider's block, as JSON, given back as is *)

type message = { role : [ `User | `Assistant ]; content : block list }
type tool = { name : string; description : string; schema : string }

type chat = {
  profile : string;          (* "" : the default *)
  system : string;
  messages : message list;
  tools : tool list;
  max_tokens : int;          (* 0 : the profile's *)
}

type stop = End | Tool_use | Max_tokens | Refusal | Other of string
type answer = {
  content : block list; stop : stop; model : string;
  input_tokens : int; output_tokens : int;
}

type _ request =
  | Profiles : (string * string * string) list request  (* name, api, model *)
  | Chat : chat -> answer request
```

- **Tools from the start**: steps 3 and 4 need them, and both APIs have
  them, in different shapes; `llmd` translates (Claude's `tool_use` and
  `tool_result` blocks, OpenAI's `tool_calls` and `tool` messages).
- **`Opaque`**: what a provider returns that the other cannot read (Claude's
  thinking blocks, which must be given back unchanged in a tool loop) is
  kept as its JSON, sent back to the same API and dropped for the other.
- **Keys and URLs never leave `llmd`**: `Profiles` names models, nothing
  else. A provider's error (a bad key, a rate limit) is the call's error,
  with the provider's message.

### 5. `llmd`

In OCaml (`services/llm/llmd.ml`), on the modules `Http`, `Json`, `Net`
and `Ipc`. An answer takes seconds, so requests are served by a few
domains at once (as `httpd`): the main domain accepts connections and
queues them; workers read, call the provider, answer. It needs no
privilege. Argument: the configuration's path (`/disk/llm.env` by
default; the tests give another).

`llm`, a command, to use it by hand: `llm "question"`, `llm -p local
"question"`, `llm -l` (the profiles).

### 6. Tests without keys

`tools/net-peer.py llm PORT` is a fake provider on the host: it speaks both
APIs, checks the headers and the shape of each request (a 400 otherwise,
as the real ones), answers with a text built from the request, and with a
tool call when tools are given. The network test starts `llmd` with a
configuration of two profiles, one per API, on that server, and runs a
tool loop through each. A real provider is tried by hand, with a key.

### 7. `ask` in `sh`

A built-in, since what it proposes must run in the shell itself (`cd`,
variables): `ask [-p PROFILE] REQUEST...`. The model gets, as its system
prompt, what the shell is (its syntax and what it lacks: no arithmetic,
no loops), its commands (the built-ins and the programs in `PATH`), the
current directory and its files; and one tool, `propose_command`
(`command`, `explanation`). `sh` shows the explanation and the command and
asks "Run it? [y/N]": a key on the console, or a line when its input is a
file. Nothing runs without a yes, in a script either. A model that
answers in text (a question needing no command) has its text shown. The
proposals are commands of `sh`, not OCaml for the toplevel: `ocaml` is
one of the commands it may propose.

### 8. Protocols that describe themselves

Every `Wire` codec carries its **shape** (`Wire.shape`): unit, bool, int,
float, string, options, lists, tuples, named components (`Wire.field`),
variants with named cases, recursive types. A protocol lists its requests
(`Ipc.request_doc`: case number, name, documentation, the shapes of its
arguments and reply, and `safe`: whether it only reads), and a summary.
Every service made with `Ipc.Make` answers a request of protocol
`"describe"` with that description, with no code of its own. netd, in C,
answers it too, from a table written in a compact notation
(`wire_put_shape`: `"(socket:I,max:I)"`); the network test checks that it
is `net.ml`'s.

Descriptions are asked by name (`Ipc.describe`, with a timeout): the
registry cannot list its names, and the services of 2004 (memrofs, the
console) expect C structures, not typed messages.

From a description alone, module **`Tools`** makes each request a model's
tool: its name (`net_ping`), its documentation, and a JSON Schema of its
arguments; and calls it with JSON, written as the protocol's bytes by
shape, the reply read back as JSON. A program, or a model, can use a
service it was not compiled against: `llm_chat` itself is callable from
JSON. `safe` is for the agent: what changes things is confirmed first.

### 9. The agent

`agent TASK...` (`agent/agent_main.ml`) runs the loop, which is the
library module `Agent` (`mynos-lib/ocaml/agent.ml`, shared with the
agent window, `doc/decisions/gui.md`): the model answers,
its tool calls are carried out, their results sent back, until it answers
with no tool call (or after 20 model calls, `-n`). Its tools:

- its own: `run_command` (one line of `sh`, run by a new `sh -c` with its
  input from an empty file and its output, and its programs' output,
  into a file of `/tmp`, sent back with the exit status), `read_file`,
  `write_file`, `list_directory`;
- OCaml (mynos-vdj): `run_ocaml` compiles a program with `ocamlc` inside
  MyNOS, against its libraries (`Mynos`, `Net`, `Http`, `Json`, `Llm`,
  `Tools`...). The type checker speaks first: a program that does not
  type-check comes back with the compiler's errors, and nothing runs; one
  that does is shown, confirmed, run. `ocaml_signature` gives a module's
  interface (the toplevel's `#show_module`), so the model looks before it
  writes. The type checker is the contract between the model and the
  system's interfaces;
- every request of the typed services it is given (`-s net,llm`; `net` by
  default), from their descriptions (`Tools`).

What changes things (a command, a write, a request not `safe`) is shown
and done only once confirmed: y, n, or a (yes to all for this run); `-y`
confirms everything. A refusal goes back to the model as the tool's
error. The process has no privilege: it reaches what the user's programs
reach, and the services know it as itself (`Ipc.caller`).

The event recorder runs meanwhile, and its file (`/tmp/agent.trc`, `-t`)
shows, with `trace calls`, the agent's calls to llmd, llmd's to netd (the
TLS connection to the provider), and the commands' own calls, nested.
llmd asks Claude to cache the prompt (`cache_control`, automatic): in a
loop, each request repeats the previous one and adds to it.

`Agent` tells what happens through events (`Task`, `Said`, `Action`,
`Result`, `Note`) and asks through a function (`Yes`, `No`, `All`): the
command prints them and reads a key, the window draws them and waits
for a button. A session keeps its conversation: the next task is a
follow-up ("and now...").

## Not now

- **Streaming**, images, documents.
- **Costs**: `answer` reports tokens, and `agent` their sum; no budget
  yet beyond the number of model calls.
- **Who may ask**: every process may use `llmd`. With users, a profile can
  be restricted to some.

#!/usr/bin/env python3
"""The host's side of the network test (tools/run-tests.sh).

  net-peer.py echo PORT          answer each connection's first line in
                                 capitals, then close (until killed)
  net-peer.py fetch PORT FILE    connect to localhost:PORT (QEMU forwards it
                                 to MyNOS) until it answers, send an HTTP
                                 request, write the answer to FILE
  net-peer.py udpecho PORT       answer each UDP datagram with its bytes in
                                 capitals (until killed)
  net-peer.py https PORT CERT KEY
                                 an HTTPS server with that certificate:
                                 answers each request with "METHOD PATH
                                 BODY-IN-CAPITALS", chunked (until killed)
  net-peer.py llm PORT           a fake language model provider over HTTP
                                 (llmd's tests, doc/decisions/llm.md): both
                                 Claude's Messages API (POST /v1/messages)
                                 and Chat Completions (POST
                                 /v1/chat/completions), with their headers
                                 and request shapes checked
"""
import json
import socket
import ssl
import sys
import time


def echo(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        with conn:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            conn.sendall(data.upper())


def fetch(port, out, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
                s.sendall(b"GET / HTTP/1.0\r\n\r\n")
                answer = b""
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    answer += chunk
                if answer:
                    open(out, "wb").write(answer)
                    return
        except OSError:
            pass
        time.sleep(0.5)


def https(port, cert, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        raw, _ = srv.accept()
        raw.settimeout(20)
        try:
            with ctx.wrap_socket(raw, server_side=True) as conn:
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                head, _, body = data.partition(b"\r\n\r\n")
                lines = head.decode("latin-1").split("\r\n")
                length = 0
                for line in lines[1:]:
                    name, _, value = line.partition(":")
                    if name.strip().lower() == "content-length":
                        length = int(value)
                while len(body) < length:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    body += chunk
                method, path = (lines[0].split(" ") + ["", ""])[:2]
                answer = ("%s %s " % (method, path)).encode() + body.upper()
                half = len(answer) // 2
                out = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" \
                      b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                for part in (answer[:half], answer[half:]):
                    out += b"%x\r\n%s\r\n" % (len(part), part)
                conn.sendall(out + b"0\r\n\r\n")
        except (OSError, ssl.SSLError):
            pass                        # a refused handshake: the next one


def udpecho(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", port))
    while True:
        data, peer = srv.recvfrom(65536)
        srv.sendto(data.upper(), peer)


KEY = "test-key"


class Bad(Exception):
    """a request a real provider would refuse: (status, kind, message)"""


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            raise OSError("closed")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    while len(body) < length:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    method, path = (lines[0].split(" ") + ["", ""])[:2]
    return method, path, headers, body


def need(cond, message, status=400, kind="invalid_request_error"):
    if not cond:
        raise Bad(status, kind, message)


def fill(schema, text):
    """a tool's input: each property of its schema set to the request's text"""
    return {k: text for k in schema.get("properties", {})}


def last_text(blocks):
    return "".join(b["text"] for b in blocks if b.get("type") == "text")


def anthropic(headers, req):
    """Claude's Messages API: a text that echoes the last user text (and
    the system prompt); with tools, a call of the first one (each
    property of its input set to the last user text), after a
    thinking block that must come back unchanged; after a tool result, a
    text that quotes it"""
    need(headers.get("x-api-key") == KEY, "invalid x-api-key", 401,
         "authentication_error")
    need(headers.get("anthropic-version") == "2026-10-21",
         "anthropic-version missing or unknown")
    need(isinstance(req.get("model"), str), "model: a string")
    need(isinstance(req.get("max_tokens"), int) and req["max_tokens"] > 0,
         "max_tokens: a positive integer")
    if "cache_control" in req:
        need(req["cache_control"] == {"type": "ephemeral"}, "cache_control")
    if "fallbacks" in req:
        need("server-side-fallback-2026-07-01" in headers.get("anthropic-beta", ""),
             "fallbacks needs its beta header")
    msgs = req.get("messages")
    need(isinstance(msgs, list) and msgs, "messages: a non-empty list")
    for m in msgs:
        need(m.get("role") in ("user", "assistant"), "role: user or assistant")
        need(isinstance(m.get("content"), list), "content: a list of blocks")
        for b in m["content"]:
            t = b.get("type")
            need(t in ("text", "tool_use", "tool_result", "thinking"),
                 "unknown block type %r" % t)
            if t == "text":
                need(b.get("text"), "text blocks must be non-empty")
            if t == "tool_use":
                need(isinstance(b.get("input"), dict), "tool_use input: an object")
    for t in req.get("tools", []):
        need(set(t) == {"name", "description", "input_schema"}, "tool fields")
        need(t["input_schema"].get("type") == "object", "input_schema: an object")
    last = msgs[-1]
    need(last["role"] == "user", "the last message must be the user's")
    results = [b for b in last["content"] if b["type"] == "tool_result"]
    if results:
        before = msgs[-2]["content"]
        need({"type": "thinking", "thinking": "", "signature": "sig-1"} in before,
             "thinking blocks must be passed back unchanged")
        uses = [b["id"] for b in before if b["type"] == "tool_use"]
        need(results[0]["tool_use_id"] in uses, "tool_result for an unknown tool_use")
        content = [{"type": "text", "text": "tool said: " + results[0]["content"]}]
        stop = "end_turn"
    elif req.get("tools"):
        content = [{"type": "thinking", "thinking": "", "signature": "sig-1"},
                   {"type": "tool_use", "id": "toolu_1",
                    "name": req["tools"][0]["name"],
                    "input": fill(req["tools"][0]["input_schema"],
                                  last_text(last["content"]))}]
        stop = "tool_use"
    else:
        text = "echo: " + last_text(last["content"])
        if req.get("system"):
            text += " (system: %s)" % req["system"]
        content = [{"type": "text", "text": text}]
        stop = "end_turn"
    return {"id": "msg_1", "type": "message", "role": "assistant",
            "model": req["model"], "content": content, "stop_reason": stop,
            "usage": {"input_tokens": 11, "output_tokens": 7}}


def openai(headers, req):
    """Chat Completions, the same answers"""
    auth = headers.get("authorization")
    need(auth is None or auth == "Bearer " + KEY, "Incorrect API key provided",
         401, "invalid_api_key")
    need(isinstance(req.get("model"), str), "model: a string")
    need(isinstance(req.get("max_tokens"), int), "max_tokens: an integer")
    msgs = req.get("messages")
    need(isinstance(msgs, list) and msgs, "messages: a non-empty list")
    for i, m in enumerate(msgs):
        need(m.get("role") in ("system", "user", "assistant", "tool"),
             "unknown role %r" % m.get("role"))
        if m["role"] == "tool":
            need(isinstance(m.get("tool_call_id"), str), "tool: tool_call_id")
            prev = [x for x in msgs[:i] if x["role"] != "tool"][-1]
            need(any(c["id"] == m["tool_call_id"] for c in prev.get("tool_calls", [])),
                 "a tool message must answer the assistant's tool_calls")
        if m["role"] == "assistant":
            for c in m.get("tool_calls", []):
                need(c.get("type") == "function", "tool_calls: functions")
                json.loads(c["function"]["arguments"])
    for t in req.get("tools", []):
        need(t.get("type") == "function", "tools: functions")
        need(t["function"]["parameters"].get("type") == "object", "parameters: object")
    last = msgs[-1]
    message = {"role": "assistant", "content": None}
    if last["role"] == "tool":
        message["content"] = "tool said: " + last["content"]
        finish = "stop"
    elif req.get("tools"):
        message["tool_calls"] = [{
            "id": "call_1", "type": "function",
            "function": {"name": req["tools"][0]["function"]["name"],
                         "arguments": json.dumps(fill(
                             req["tools"][0]["function"]["parameters"],
                             last["content"]))}}]
        finish = "tool_calls"
    else:
        message["content"] = "echo: " + last["content"]
        if msgs[0]["role"] == "system":
            message["content"] += " (system: %s)" % msgs[0]["content"]
        finish = "stop"
    return {"id": "chatcmpl-1", "object": "chat.completion", "model": req["model"],
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 13, "completion_tokens": 5}}


def llm(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        conn.settimeout(20)
        with conn:
            try:
                method, path, headers, body = read_request(conn)
                try:
                    need(method == "POST", "POST only", 405)
                    need(headers.get("content-type") == "application/json",
                         "content-type: application/json")
                    req = json.loads(body)
                    if path == "/v1/messages":
                        status, answer = 200, anthropic(headers, req)
                    elif path == "/v1/chat/completions":
                        status, answer = 200, openai(headers, req)
                    else:
                        raise Bad(404, "not_found_error", "no such path " + path)
                except Bad as e:
                    status, kind, message = e.args
                    answer = {"type": "error",
                              "error": {"type": kind, "message": message}}
                except (ValueError, KeyError, TypeError, IndexError) as e:
                    status = 400
                    answer = {"type": "error", "error": {
                        "type": "invalid_request_error", "message": repr(e)}}
                out = json.dumps(answer).encode()
                conn.sendall(b"HTTP/1.1 %d X\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\nConnection: close\r\n\r\n"
                             % (status, len(out)) + out)
            except OSError:
                pass


if __name__ == "__main__":
    if sys.argv[1] == "echo":
        echo(int(sys.argv[2]))
    elif sys.argv[1] == "udpecho":
        udpecho(int(sys.argv[2]))
    elif sys.argv[1] == "llm":
        llm(int(sys.argv[2]))
    elif sys.argv[1] == "https":
        https(int(sys.argv[2]), sys.argv[3], sys.argv[4])
    else:
        fetch(int(sys.argv[2]), sys.argv[3])

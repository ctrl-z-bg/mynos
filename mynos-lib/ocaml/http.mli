(** HTTP/1.1 clients, over the network service ({!Net}): [http://] and
    [https://] (TLS in netd, {!Net.Connect_tls}).

    {[
      let r = Http.get "https://example.com/";;
      r.Http.status;;                         (* 200 *)
      Http.header "content-type" r;;
      let r = Http.post ~headers:[ "content-type", "application/json" ]
          ~body:{|{"q": 1}|} "https://httpbin.org/post";;
    ]}

    A connection is kept open after an answer whose end was known, and the
    next request to the same server (scheme, host, port) uses it: a TLS
    handshake costs about a second in netd, which makes them one at a
    time. Per server, at most 2 connections and one handshake at a time: a
    request waits for a free connection rather than open a third. At most
    8 are kept idle, shared by the program's threads; one the server had
    closed is replaced, the request sent again on a new one. [Connection: close] in [headers]
    asks for one connection for the request. The body of the answer is
    decoded from chunked transfer, not decompressed (the request asks for
    none). *)

type response = {
  status : int;                         (** 200, 404... *)
  reason : string;                      (** ["OK"] *)
  headers : (string * string) list;     (** names in lower case *)
  body : string;
}

exception Error of string
(** A bad URL, the network's error (["host not found"], ["TLS: bad
    certificate: ..."], ["timeout"]...), or an answer that is not HTTP. *)

val request :
  ?net:Net.t -> ?meth:string -> ?headers:(string * string) list ->
  ?body:string -> ?timeout:int -> string -> response
(** [request url]: [meth] is ["GET"] by default, or ["POST"] with a
    [body]. [timeout] (ms, default 30000) bounds each wait for the server;
    the connection, with its TLS handshake, waits at most 20 s (netd).
    [Host], [User-Agent] and [Content-Length] are added unless given in
    [headers]. *)

val get : ?net:Net.t -> ?headers:(string * string) list -> ?timeout:int ->
  string -> response

val post : ?net:Net.t -> ?headers:(string * string) list -> ?timeout:int ->
  body:string -> string -> response

val header : string -> response -> string option
(** A header of the answer (the name in any case). *)

val parse_url : string -> bool * string * int * string
(** [(tls, host, port, path)]. @raise Error for another scheme. *)

val parse_response : string -> response
(** The bytes of a whole answer. @raise Error if they are not HTTP. *)

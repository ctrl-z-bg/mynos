(* ariadne --check-js: jsd (services/js) checked from MyNOS, for
   tools/run-tests.sh: its description against module Js', values, console,
   exceptions, contexts apart, an endless loop stopped. *)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let run () =
  let ok = ref true in
  let check name cond =
    Printf.printf "ariadne: jsd: %-40s %s\n%!" name (if cond then "ok" else "FAIL");
    if not cond then ok := false in
  let shape (rs : Ipc.request_doc list) =
    List.map (fun (r : Ipc.request_doc) -> (r.case, r.name, r.args, r.reply, r.safe)) rs in
  let d = Ipc.describe "js" in
  check "described as js.ml says"
    (d.Ipc.protocol = Js.Protocol.id && shape d.requests = shape Js.Protocol.requests);
  let js = Js.connect () in
  let a = Js.create ~js () and b = Js.create ~js () in
  let r = Js.eval a "console.log('hi', 1 + 1); 6 * 7" in
  check "a value, and console" (r.ok && r.value = "42" && r.console = "hi 2\n");
  let r = Js.eval a "({a: [1, 'two'], b: null})" in
  check "an object, as JSON" (r.ok && r.value = {|{"a":[1,"two"],"b":null}|});
  let r = Js.eval ~name:"t.js" a "function f() { throw new TypeError('no ' + 'way') }\nf()" in
  check "an exception, its message and stack"
    ((not r.ok) && String.starts_with ~prefix:"TypeError: no way" r.value
     && contains r.value "t.js");
  ignore (Js.eval a "var shared = 'a'");
  let r = Js.eval b "typeof shared" in
  check "two contexts, apart" (r.ok && r.value = "undefined");
  let t0 = Unix.gettimeofday () in
  let r = Js.eval b "for (;;) {}" in
  let took = Unix.gettimeofday () -. t0 in
  check "an endless loop, stopped" ((not r.ok) && took < 8.);
  let r = Js.eval b "1 + 1" in
  check "and the context goes on" (r.ok && r.value = "2");
  Js.destroy a;
  check "a context destroyed is gone"
    (match Js.eval a "1" with _ -> false | exception Ipc.Remote_error _ -> true);
  Js.destroy b;
  print_endline (if !ok then "ariadne: jsd: all checks passed" else "ariadne: jsd: FAIL");
  if not !ok then exit 1

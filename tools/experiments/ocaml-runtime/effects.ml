(* Lightweight cooperative threads with effect handlers: no kernel support *)
open Effect
open Effect.Deep
type _ Effect.t += Yield : unit Effect.t
let run tasks =
  let q = Queue.create () in
  let spawn f = Queue.push (fun () ->
    match_with f () { retc = (fun () -> ()); exnc = raise;
      effc = fun (type a) (e : a Effect.t) -> match e with
        | Yield -> Some (fun (k : (a, _) continuation) -> Queue.push (fun () -> continue k ()) q)
        | _ -> None }) q in
  List.iter spawn tasks;
  while not (Queue.is_empty q) do (Queue.pop q) () done
let task name n () = for i = 1 to n do Printf.printf "%s %d\n" name i; perform Yield done
let () = run [task "ping" 3; task "pong" 3]; print_endline "effects ok"

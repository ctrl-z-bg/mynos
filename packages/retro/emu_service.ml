(* The service of an emulator (emu_service.mli; doc/decisions/
   retro-emulators.md, section 6): a thread listens, decodes and queues;
   the emulation loop takes the queue between frames and answers on the
   channels, at once or later (wait, keys). As Studio's runner does:
   Ipc.Make's decode and reply, not its serve, which answers one request
   before taking the next. *)

type reply_to = int                     (* the request's channel *)

type job = Job : reply_to * 'a Emu_proto.request -> job

type t = {
  name : string;
  lock : Mutex.t;
  queue : job Queue.t;
  any : bool Atomic.t;                  (* the queue is not empty *)
}

let send ch msg =
  (try Mynos.send ch msg with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let answer ch r v = send ch (Emu_proto.I.reply r v)
let fail ch msg = send ch (Emu_proto.I.error_reply msg)

let start prefix =
  let name = Printf.sprintf "%s%d" prefix (Mynos.getpid ()) in
  let port = Mynos.register name in
  let t = { name; lock = Mutex.create (); queue = Queue.create (); any = Atomic.make false } in
  ignore (Thread.create (fun () ->
      while true do
        match Mynos.listen port with
        | ch ->
          (match Mynos.recv ~timeout:1.0 ch with
           | msg ->
             (match Emu_proto.I.decode msg with
              | Error reply -> send ch reply            (* the description, or an error *)
              | Ok (Emu_proto.Protocol.Request r) ->
                Mutex.protect t.lock (fun () ->
                    Queue.push (Job (ch, r)) t.queue;
                    Atomic.set t.any true))
           | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ()))
        | exception Mynos.Error _ -> Thread.yield ()
      done) ());
  t

let none () =
  { name = "none"; lock = Mutex.create (); queue = Queue.create (); any = Atomic.make false }

let name t = t.name
let pending t = Atomic.get t.any

let take t =
  Mutex.protect t.lock (fun () ->
      let jobs = List.of_seq (Queue.to_seq t.queue) in
      Queue.clear t.queue;
      Atomic.set t.any false;
      jobs)

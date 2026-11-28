(* The cryptography against vectors made by OpenSSL 4.0 (throwaway keys)
   and RFC 8439's: `ssh-keygen --selftest` in MyNOS (31-bit ints on
   i386), tests/nettools/cryptotest.ml on the host. *)

let hex = Ssh_wire.hex
let unhex h = String.init (String.length h / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

let msg = unhex "54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672c20616e64207468656e20736f6d65206d6f7265207465787420746f2063726f7373206120626c6f636b20626f756e6461727920666f7220737572653a20303132333435363738396162636465663031323334353637383961626364656630313233343536373839616263646566"
let xa = unhex "a832b5077d1d2e244f2cd0f23f76a24b62e5157bbe49d67c86b7bcc1cefd0044"
let seed = unhex "f199385f7ac7dce72fe34914a69cc1eae46cc458f4a5765cba18a461e5eccbcf"
let pub = unhex "9288169987024dc3cb1a5c74d482344f8d08acf1e728fb620bcf1613bd5adbbe"
let signature = "5e1ae84127a6c4974fef7194ab6701cb25cc5e880edb2795a410de91319154875f205fed4bbeabedb8576fa620b8259e0045841eea799de2e500d3610f8eeb0a"
let pk = unhex "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"

(* (name, got, wanted) *)
let checks () = [
  "sha256", (fun () -> hex (Sha2.sha256 msg)), "f59da04f900fb6891f892653963a9a7dfb3a1a3c7186ebbc7a1a7d97470154dc";
  "sha256 empty", (fun () -> hex (Sha2.sha256 "")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  "sha512", (fun () -> hex (Sha2.sha512 msg)),
  "e5533bc02e697a7d9dfd24be4f99214cc6c05cb21a701d442abe55a065cf36f0f2bf0a345073e3c839c1d2abcc5f8768b9144fd54bf611d6d2bc832b421093fa";
  "hmac-sha256", (fun () -> hex (Sha2.hmac_sha256 ~key:(unhex "0102030405") msg)),
  "ea2b82b08048ebc8055afad0a57ba1840bada2347ac6c4d5602cfd0e5a097cb0";
  "chacha20", (fun () ->
      hex (Chacha20.xor (Chacha20.create ~key:(unhex "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
                           ~iv:(unhex "01000000000000000000004a00000000")) msg)),
  "762734d3316eb08244fe451dd71473cdea7c67a257596b920d6fa59afb81ef0ce25e2acf131a73b2d11613e1cd4afd505938d225a81e47a287440c219f0f24971dc30ceb1f17606141b8915b9f6da55e44b85b0e1b99ee1c8687a15bb675792356f94ea96ff149b3e157dbffa3294b1dc45b4d6211437ec4eecb8dda0aa5f1dbffd53f2d0cf0f9255745dfd37464c6d39e96b227a32ec92ff0";
  "chacha20 carry", (fun () ->
      let c = Chacha20.create ~key:(String.make 32 '\001') ~iv:(unhex "ffffffff000000000000000000000000") in
      hex (String.sub (Chacha20.stream c 128) 64 64)),
  hex (Chacha20.stream (Chacha20.create ~key:(String.make 32 '\001') ~iv:(unhex "00000000010000000000000000000000")) 64);
  "poly1305", (fun () -> hex (Poly1305.mac ~key:pk msg)), "548a79af28bb57723a6b6158f18e7354";
  "poly1305 rfc8439", (fun () -> hex (Poly1305.mac ~key:pk "Cryptographic Forum Research Group")),
  "a8061dc1305136c6c22b8baf0c0127a9";
  "x25519 public", (fun () -> hex (Curve25519.x25519_public xa)),
  "55026bed7aaa75017d5b31546bfd657fe2b685aa4eb38b1d76bbcbce9b81d511";
  "x25519 shared", (fun () ->
      hex (Curve25519.x25519 xa (unhex "1291df8117ae0d512f702bceb4b742a393e37b2af17ee8effdd363247fd85a23"))),
  "84723095cfe5bb63e7e41fb4354285cba5184de8fbf2e53a5f8af6950c5b1e62";
  "ed25519 public", (fun () -> hex (Curve25519.ed25519_public seed)), hex pub;
  "ed25519 sign", (fun () -> hex (Curve25519.sign ~seed msg)), signature;
  "ed25519 verify", (fun () -> string_of_bool (Curve25519.verify ~pub msg (unhex signature))), "true";
  "ed25519 verify, another message",
  (fun () -> string_of_bool (Curve25519.verify ~pub (msg ^ "!") (unhex signature))), "false";
  "random bytes", (fun () -> let a = Ssh_wire.random 32 and b = Ssh_wire.random 32 in
                     string_of_bool (a <> b && String.length a = 32)), "true";
]

(* the checks, printed; whether all passed *)
let run ~now ~timings =
  let fails = ref 0 in
  List.iter (fun (name, f, want) ->
      match f () with
      | got when got = want -> Printf.printf "ok   %s\n%!" name
      | got -> incr fails; Printf.printf "FAIL %s\n  got  %s\n  want %s\n%!" name got want
      | exception e -> incr fails; Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string e))
    (checks ());
  if timings then begin
    let time name n f =
      let t = now () in
      for _ = 1 to n do ignore (Sys.opaque_identity (f ())) done;
      Printf.printf "     %s: %.1f ms\n%!" name ((now () -. t) *. 1000. /. float n) in
    time "x25519" 3 (fun () -> Curve25519.x25519_public xa);
    time "ed25519 sign" 3 (fun () -> Curve25519.sign ~seed msg);
    time "ed25519 verify" 3 (fun () -> Curve25519.verify ~pub msg (unhex signature));
    let k = String.make 32 'k' and mb = String.make 65536 'x' in
    time "chacha20, 64 KB" 3 (fun () -> Chacha20.xor (Chacha20.create ~key:k ~iv:(String.make 16 '\000')) mb);
    time "poly1305, 64 KB" 3 (fun () -> Poly1305.mac ~key:k mb)
  end;
  !fails = 0

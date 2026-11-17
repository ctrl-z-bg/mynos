# Test certificates (mynos-dhp)

Made once with openssl on 2026-11-17, valid 20 years; for tests only (the
private keys are public). The test authority's own key was not kept.

- `ca.pem`: the test authority, which netd trusts in the network test (it
  is `cacert.pem` on the test RAM disk);
- `good.pem`/`.key`: RSA, for `IP:10.0.2.2` (the host, from QEMU), from
  the test authority: accepted;
- `untrusted.pem`/`.key`: for `IP:10.0.2.2`, from another authority:
  refused;
- `wrongname.pem`/`.key`: for `DNS:other.example`, from the test
  authority: refused for 10.0.2.2.

`tools/net-peer.py https PORT CERT KEY` serves HTTPS with them.

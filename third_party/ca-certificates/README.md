# Certificate authorities

`cacert.pem`: the certificate authorities that Mozilla trusts for web
sites, as extracted by curl's project from Mozilla's `certdata.txt`
(<https://curl.se/docs/caextract.html>), data as of 2026-11-05, downloaded
on 2026-11-17 (SHA-256 `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`,
as published in `cacert.pem.sha256`). Mozilla's data is under the MPL 2.0 (its text: `MPL-2.0.txt`).

It goes on the system RAM disk as `/cacert.pem`, where netd reads it for
TLS (mynos-dhp); users add their own authorities in `/disk/ca.pem`. To
update it: download <https://curl.se/ca/cacert.pem> again.

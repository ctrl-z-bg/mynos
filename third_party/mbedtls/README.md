# Mbed TLS

[Mbed TLS](https://github.com/Mbed-TLS/mbedtls) 3.6.8 (LTS), the TLS and
cryptography library, from its release archive
(`mbedtls-3.6.8.tar.bz2`, SHA-256 `bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b`),
taken on 2026-11-17. Licensed under Apache-2.0 OR GPL-2.0-or-later (see
`LICENSE`); MyNOS uses it under GPL-2.0-or-later.

Only `include/` and `library/` are kept, unchanged. netd links all of it
(`services/net/Makefile`); its configuration is the default one with the
changes in `services/net/mbedtls_mynos.h` (no BSD sockets, no files, no
DTLS). lwIP's adapter, `third_party/lwip/src/apps/altcp_tls/`, was written
for 2.x and adapted to 3.6 (see `third_party/lwip/README.md`).

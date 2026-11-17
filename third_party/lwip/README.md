# lwIP

[lwIP](https://savannah.nongnu.org/projects/lwip/) 2.2.1, the TCP/IP
stack, from `lwip-2.2.1.zip`, BSD license (see `COPYING`). netd
(`services/net/`) uses its core, IPv4, Ethernet, and the `altcp` layer
with its TLS adapter for Mbed TLS (`src/apps/altcp_tls/`); configuration
in `services/net/lwipopts.h`.

MyNOS changes, all in `src/apps/altcp_tls/altcp_tls_mbedtls.c` (marked
"MyNOS"), which lwIP wrote for Mbed TLS 2.x:
- adapted to Mbed TLS 3.6: private fields of `mbedtls_ssl_context`
  (`MBEDTLS_ALLOW_PRIVATE_ACCESS`), `mbedtls_ssl_flush_output` declared
  here, `mbedtls_pk_parse_key` with a random number generator,
  `mbedtls_ssl_get_max_out_record_payload`, the includes;
- a failed handshake leaves the Mbed TLS error and the certificate
  check's flags in `altcp_mbedtls_handshake_error` and
  `altcp_mbedtls_verify_result`, for netd's error messages;
- a list of authorities is used even if some of its certificates cannot
  be parsed.

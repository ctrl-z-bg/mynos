/* mbedTLS's configuration for netd (mynos-dhp): the default one
   (TLS 1.2 and 1.3, clients and servers, X.509), minus what MyNOS cannot
   use. mbedTLS reads it after its defaults (MBEDTLS_USER_CONFIG_FILE). */
#ifndef MBEDTLS_MYNOS_H
#define MBEDTLS_MYNOS_H

/* no BSD sockets (lwIP carries the bytes), no files (netd reads the
   certificates itself), no keys kept in files by PSA */
#undef MBEDTLS_NET_C
#undef MBEDTLS_TIMING_C
#undef MBEDTLS_FS_IO
#undef MBEDTLS_PSA_ITS_FILE_C
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C

/* no datagram TLS */
#undef MBEDTLS_SSL_PROTO_DTLS
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID
#undef MBEDTLS_SSL_COOKIE_C

/* entropy: the platform's source is Linux's getrandom (355), which MyNOS's
   kernel serves (mynos-core/kernel/random.c) */

#endif

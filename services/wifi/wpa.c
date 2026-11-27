/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * WPA2-PSK on the host (btq.9, doc/decisions/wifi.md): the Pi's Wi-Fi
 * firmware associates, but the keys are agreed by the host, as Linux's
 * wpa_supplicant does (802.11-2016, 12.7):
 *
 *   - the PMK: PBKDF2-HMAC-SHA1 of the passphrase, the network's name as
 *     the salt, 4096 rounds, 32 bytes;
 *   - the 4-way handshake, EAPOL-Key frames (key descriptor 2, RSN; key
 *     information's version 2: HMAC-SHA1 MICs, AES key wrap):
 *       1. the AP's nonce (ANonce): ours (SNonce) chosen, the PTK derived
 *          (PRF-384 of the PMK, "Pairwise key expansion", both addresses
 *          and nonces, the smaller first): KCK (the MICs), KEK (the key
 *          data's wrap), TK (the frames' key, CCMP);
 *       2. our nonce and our RSN element, its MIC;
 *       3. the AP's, its MIC checked, its key data unwrapped: the group
 *          key (GTK, in its KDE);
 *       4. our acknowledgement, its MIC: the keys are then installed;
 *   - the group key handshake (the AP's new GTK, now and then): its
 *     message 1 checked and unwrapped, our message 2.
 * SHA-1 and AES are mbedTLS's (third_party/mbedtls); HMAC, PBKDF2, the
 * PRF and the key unwrap (RFC 3394) are here.
 */

#include <string.h>
#include <sys/random.h>
#include <mynos.h>
#include "mbedtls/sha1.h"
#include "mbedtls/aes.h"
#include "wpa.h"

static unsigned char pmk[32], kck[16], kek[16], tk[16], own[6], ap[6];
static unsigned char anonce[32], snonce[32];
static unsigned char ie[22] = {
  0x30, 20, 1, 0,                      /* RSN, version 1 */
  0x00, 0x0F, 0xAC, 4,                 /* group cipher: CCMP (or the network's) */
  1, 0, 0x00, 0x0F, 0xAC, 4,           /* one pairwise cipher: CCMP */
  1, 0, 0x00, 0x0F, 0xAC, 2,           /* one AKM: PSK */
  0, 0                                 /* capabilities */
};
static int have_ptk;

/* ---- HMAC-SHA1, PBKDF2, the PRF ---- */

static void hmac_sha1(const unsigned char * key, int keylen,
                      const unsigned char * d1, int n1, const unsigned char * d2, int n2,
                      const unsigned char * d3, int n3, unsigned char out[20])
{
  unsigned char k[64], pad[64], inner[20];
  mbedtls_sha1_context c;
  int i;
  memset(k, 0, sizeof k);
  if (keylen > 64) mbedtls_sha1(key, (size_t)keylen, k);
  else memcpy(k, key, (size_t)keylen);
  mbedtls_sha1_init(&c);
  for (i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
  mbedtls_sha1_starts(&c);
  mbedtls_sha1_update(&c, pad, 64);
  if (n1) mbedtls_sha1_update(&c, d1, (size_t)n1);
  if (n2) mbedtls_sha1_update(&c, d2, (size_t)n2);
  if (n3) mbedtls_sha1_update(&c, d3, (size_t)n3);
  mbedtls_sha1_finish(&c, inner);
  for (i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5C;
  mbedtls_sha1_starts(&c);
  mbedtls_sha1_update(&c, pad, 64);
  mbedtls_sha1_update(&c, inner, 20);
  mbedtls_sha1_finish(&c, out);
  mbedtls_sha1_free(&c);
}

static void pbkdf2_sha1(const char * pass, const unsigned char * salt, int saltlen,
                        unsigned char out[32])
{
  unsigned char u[20], t[20], cnt[4];
  int block, i, j, plen = (int)strlen(pass);
  for (block = 1; block <= 2; block++) {
    cnt[0] = 0; cnt[1] = 0; cnt[2] = 0; cnt[3] = (unsigned char)block;
    hmac_sha1((const unsigned char *)pass, plen, salt, saltlen, cnt, 4, NULL, 0, u);
    memcpy(t, u, 20);
    for (i = 1; i < 4096; i++) {
      hmac_sha1((const unsigned char *)pass, plen, u, 20, NULL, 0, NULL, 0, u);
      for (j = 0; j < 20; j++) t[j] ^= u[j];
    }
    memcpy(out + (block - 1) * 20, t, block == 1 ? 20 : 12);
  }
}

/* PRF-384: 48 bytes of HMAC-SHA1(PMK, label 0 data i), i = 0, 1, 2 */
static void prf384(const unsigned char * data, int n, unsigned char out[48])
{
  static const char label[] = "Pairwise key expansion";   /* (its 0 sent too) */
  unsigned char r[60], i;
  for (i = 0; i < 3; i++)
    hmac_sha1(pmk, 32, (const unsigned char *)label, sizeof label, data, n, &i, 1, r + 20 * i);
  memcpy(out, r, 48);
}

/* RFC 3394's unwrap with the KEK: len - 8 bytes into out; 0, or -1 */
static int unwrap(const unsigned char * in, int len, unsigned char * out)
{
  mbedtls_aes_context c;
  unsigned char a[8], b[16];
  int n = len / 8 - 1, i, j, k;
  if (len < 16 || len % 8 || len > 256) return -1;
  memcpy(a, in, 8);
  memcpy(out, in + 8, (size_t)(len - 8));
  mbedtls_aes_init(&c);
  mbedtls_aes_setkey_dec(&c, kek, 128);
  for (j = 5; j >= 0; j--)
    for (i = n; i >= 1; i--) {
      unsigned long t = (unsigned long)(n * j + i);
      for (k = 7; k >= 0; k--, t >>= 8) a[k] ^= (unsigned char)t;
      memcpy(b, a, 8);
      memcpy(b + 8, out + (i - 1) * 8, 8);
      mbedtls_aes_crypt_ecb(&c, MBEDTLS_AES_DECRYPT, b, b);
      memcpy(a, b, 8);
      memcpy(out + (i - 1) * 8, b + 8, 8);
    }
  mbedtls_aes_free(&c);
  for (i = 0; i < 8; i++) if (a[i] != 0xA6) return -1;
  return 0;
}

/* ---- the handshakes ---- */

void wpa_start(const char * ssid, const char * pass, const unsigned char me[6], int group)
{
  pbkdf2_sha1(pass, (const unsigned char *)ssid, (int)strlen(ssid), pmk);
  memcpy(own, me, 6);
  ie[7] = (unsigned char)(group == 2 ? 2 : 4);
  have_ptk = 0;
}

const unsigned char * wpa_ie(int * len)
{
  *len = sizeof ie;
  return ie;
}

/* EAPOL-Key's fields, from the frame's start (after its Ethernet header) */
#define K_DESC    4
#define K_INFO    5
#define K_KEYLEN  7
#define K_REPLAY  9
#define K_NONCE   17
#define K_MIC     81
#define K_DATALEN 97
#define K_DATA    99

#define KI_VERSION  0x0007
#define KI_PAIRWISE 0x0008
#define KI_INSTALL  0x0040
#define KI_ACK      0x0080
#define KI_MIC      0x0100
#define KI_SECURE   0x0200
#define KI_ENCRYPTED 0x1000

/* our EAPOL-Key frame (an Ethernet frame to the AP): its length */
static int build(unsigned char * f, unsigned int info, const unsigned char * replay,
                 const unsigned char * nonce, const unsigned char * data, int datalen)
{
  unsigned char * e = f + 14, mic[20];
  int body = 95 + datalen;
  memcpy(f, ap, 6);
  memcpy(f + 6, own, 6);
  f[12] = 0x88; f[13] = 0x8E;
  memset(e, 0, (size_t)(4 + body));
  e[0] = 1;                            /* 802.1X-2001 */
  e[1] = 3;                            /* EAPOL-Key */
  e[2] = (unsigned char)(body >> 8); e[3] = (unsigned char)body;
  e[K_DESC] = 2;                       /* RSN */
  e[K_INFO] = (unsigned char)(info >> 8); e[K_INFO + 1] = (unsigned char)info;
  memcpy(e + K_REPLAY, replay, 8);
  if (nonce) memcpy(e + K_NONCE, nonce, 32);
  e[K_DATALEN] = (unsigned char)(datalen >> 8); e[K_DATALEN + 1] = (unsigned char)datalen;
  if (datalen) memcpy(e + K_DATA, data, (size_t)datalen);
  hmac_sha1(kck, 16, e, 4 + body, NULL, 0, NULL, 0, mic);
  memcpy(e + K_MIC, mic, 16);
  return 14 + 4 + body;
}

/* the frame's MIC, with the KCK: 0 if right */
static int check_mic(const unsigned char * e, int n)
{
  unsigned char copy[1024], mic[20];
  if (n > (int)sizeof copy) return -1;
  memcpy(copy, e, (size_t)n);
  memset(copy + K_MIC, 0, 16);
  hmac_sha1(kck, 16, copy, n, NULL, 0, NULL, 0, mic);
  return memcmp(mic, e + K_MIC, 16) ? -1 : 0;
}

/* the GTK's KDE in the unwrapped key data: 0, or -1 */
static int find_gtk(const unsigned char * d, int n, struct wpa_keys * k)
{
  int i = 0;
  while (i + 2 <= n) {
    int t = d[i], l = d[i + 1];
    if (t == 0xDD && l == 0 && i + 2 == n) break;   /* (padding) */
    if (i + 2 + l > n) break;
    if (t == 0xDD && l >= 6 + 16 && d[i + 2] == 0x00 && d[i + 3] == 0x0F &&
        d[i + 4] == 0xAC && d[i + 5] == 1) {
      k->gtk_idx = d[i + 6] & 3;
      k->gtk_len = l - 6 > 32 ? 32 : l - 6;
      memcpy(k->gtk, d + i + 8, (size_t)k->gtk_len);
      return 0;
    }
    i += 2 + l;
  }
  return -1;
}

int wpa_eapol(const unsigned char * eth, int len, unsigned char * reply, int * reply_len,
              struct wpa_keys * k)
{
  const unsigned char * e = eth + 14;
  unsigned int info;
  int body, n, datalen;
  unsigned char data[256];
  if (len < 14 + K_DATA || eth[12] != 0x88 || eth[13] != 0x8E || e[1] != 3 || e[K_DESC] != 2)
    return 0;
  body = e[2] << 8 | e[3];
  n = 4 + body;
  if (14 + n > len) return 0;
  info = (unsigned int)(e[K_INFO] << 8 | e[K_INFO + 1]);
  datalen = e[K_DATALEN] << 8 | e[K_DATALEN + 1];
  if (K_DATA + datalen > n) return 0;
  if ((info & KI_VERSION) != 2) {
    mynos_log("wifid: WPA: key descriptor version %u, not 2 (not WPA2-PSK with AES)\n",
              info & KI_VERSION);
    return 0;
  }
  if ((info & KI_PAIRWISE) && (info & KI_ACK) && !(info & KI_MIC)) {
    /* message 1: the PTK; message 2 */
    unsigned char d[76], ptk[48];
    int lo;
    memcpy(ap, eth + 6, 6);
    memcpy(anonce, e + K_NONCE, 32);
    if (getrandom(snonce, 32, 0) != 32) return 0;
    lo = memcmp(own, ap, 6) < 0;
    memcpy(d, lo ? own : ap, 6);
    memcpy(d + 6, lo ? ap : own, 6);
    lo = memcmp(snonce, anonce, 32) < 0;
    memcpy(d + 12, lo ? snonce : anonce, 32);
    memcpy(d + 44, lo ? anonce : snonce, 32);
    prf384(d, sizeof d, ptk);
    memcpy(kck, ptk, 16);
    memcpy(kek, ptk + 16, 16);
    memcpy(tk, ptk + 32, 16);
    have_ptk = 1;
    *reply_len = build(reply, 2 | KI_PAIRWISE | KI_MIC, e + K_REPLAY, snonce, ie, sizeof ie);
    mynos_log("wifid: WPA: message 1 of 4, message 2 sent\n");
    return WPA_REPLY;
  }
  if (!have_ptk || !(info & KI_MIC)) return 0;
  if (check_mic(e, n) < 0) {
    mynos_log("wifid: WPA: a wrong MIC (the passphrase?)\n");
    return 0;
  }
  if ((info & KI_ENCRYPTED) && datalen &&
      (unwrap(e + K_DATA, datalen, data) < 0 || find_gtk(data, datalen - 8, k) < 0)) {
    mynos_log("wifid: WPA: the key data not understood\n");
    return 0;
  }
  memcpy(k->ap, ap, 6);
  if (info & KI_PAIRWISE) {
    /* message 3: message 4, the keys */
    if (memcmp(anonce, e + K_NONCE, 32)) { mynos_log("wifid: WPA: message 3's ANonce differs\n"); return 0; }
    memcpy(k->tk, tk, 16);
    *reply_len = build(reply, 2 | KI_PAIRWISE | KI_MIC | KI_SECURE, e + K_REPLAY, NULL, NULL, 0);
    mynos_log("wifid: WPA: message 3 of 4, message 4 sent\n");
    return WPA_REPLY | WPA_PTK | ((info & KI_ENCRYPTED) && datalen ? WPA_GTK : 0);
  }
  /* the group key handshake's message 1: its message 2 */
  *reply_len = build(reply, 2 | KI_MIC | KI_SECURE, e + K_REPLAY, NULL, NULL, 0);
  mynos_log("wifid: WPA: a new group key\n");
  return WPA_REPLY | WPA_GTK;
}

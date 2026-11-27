/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* WPA2-PSK's handshakes on the host (wpa.c): the Pi's firmware has no
   supplicant of its own ("sup_wpa" unsupported). */

#ifndef __WPA_H__
#define __WPA_H__

/* the PMK from the passphrase and the network's name (PBKDF2, 4096
   rounds); our MAC address; the RSN element we associate with (its group
   cipher the network's: 4 CCMP, 2 TKIP) */
void wpa_start(const char * ssid, const char * pass, const unsigned char own[6], int group);

/* our RSN element (given to the firmware as "wpaie" and sent in message
   2) */
const unsigned char * wpa_ie(int * len);

/* the keys, once known */
struct wpa_keys {
  unsigned char ap[6];                 /* the access point's address */
  unsigned char tk[16];                /* the pairwise key (CCMP) */
  unsigned char gtk[32];               /* the group key */
  int gtk_len, gtk_idx;
};

#define WPA_REPLY 1                    /* *reply: an EAPOL frame to send */
#define WPA_PTK   2                    /* the pairwise key to install */
#define WPA_GTK   4                    /* the group key to install */

/* an EAPOL frame received (an Ethernet frame, type 0x888E): what to do
   (WPA_* bits), the frame to send in reply (up to 256 bytes), the keys;
   0: nothing (or not ours, or its MIC wrong: logged) */
int wpa_eapol(const unsigned char * eth, int len, unsigned char * reply, int * reply_len,
              struct wpa_keys * k);

#endif

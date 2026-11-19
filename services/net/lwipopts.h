/* lwIP's configuration for netd: one thread calls lwIP (NO_SYS, the raw
   API); TCP, UDP (for DNS and DHCP), ICMP, raw sockets for ping. */
#ifndef __LWIPOPTS_H__
#define __LWIPOPTS_H__

#define NO_SYS                  1
#define LWIP_SOCKET             0
#define LWIP_NETCONN            0
#define SYS_LIGHTWEIGHT_PROT    0

#define LWIP_IPV4               1
#define LWIP_IPV6               0
#define LWIP_ARP                1
#define LWIP_ETHERNET           1
#define LWIP_ICMP               1
#define LWIP_RAW                1
#define LWIP_UDP                1
#define LWIP_TCP                1
#define LWIP_DHCP               1
#define LWIP_DHCP_DOES_ACD_CHECK 0
#define LWIP_DNS                1
#define LWIP_NETIF_STATUS_CALLBACK 1

/* memory: lwIP's heap from malloc, its pools static */
#define MEM_LIBC_MALLOC         1
#define MEM_ALIGNMENT           4
#define MEM_SIZE                (64 * 1024)
#define MEMP_NUM_PBUF           32
#define MEMP_NUM_RAW_PCB        4
#define MEMP_NUM_UDP_PCB        8
#define MEMP_NUM_TCP_PCB        32
#define MEMP_NUM_TCP_PCB_LISTEN 8
#define MEMP_NUM_TCP_SEG        64
#define PBUF_POOL_SIZE          64

#define TCP_MSS                 1460
#define TCP_WND                 (16 * TCP_MSS)  /* more than a TLS record */
#define TCP_SND_BUF             (8 * TCP_MSS)
#define TCP_SND_QUEUELEN        (4 * TCP_SND_BUF / TCP_MSS)
#define TCP_LISTEN_BACKLOG      1

/* TLS: altcp (TCP, or TLS over TCP) with mbedTLS; mbedTLS's memory from
   malloc */
#define LWIP_ALTCP              1
#define LWIP_ALTCP_TLS          1
#define LWIP_ALTCP_TLS_MBEDTLS  1
#define ALTCP_MBEDTLS_AUTHMODE  MBEDTLS_SSL_VERIFY_REQUIRED

/* packets to the card's own address go back in through a queue, which
   the main loop empties (netif_poll): a program can reach a server of its
   own machine (httpd) by its address */
#define LWIP_NETIF_LOOPBACK     1

#define LWIP_STATS              0
#define LWIP_DEBUG              0
#define LWIP_CHECKSUM_CTRL_PER_NETIF 0

#endif

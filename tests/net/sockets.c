/* BSD sockets in libmynos (mynos-t9l): a C program on the network, run by
   the network test (net_test.ml) with the host's servers of
   tools/run-tests.sh: 47001 answers a line in capitals (TCP), 47053 a
   datagram (UDP). Prints one line per check; exits 0 if all passed. */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static int failures;

static void check(const char * what, int ok)
{
  printf("sockets: %-44s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

static struct sockaddr_in addr(const char * dotted, int port)
{
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  inet_pton(AF_INET, dotted, &a.sin_addr);
  return a;
}

/* all that comes until the peer closes */
static int read_all(int fd, char * buf, int max)
{
  int n = 0, k;
  while (n < max - 1 && (k = read(fd, buf + n, max - 1 - n)) > 0) n += k;
  buf[n] = 0;
  return n;
}

/* the server end of the local check: one connection, its line back
   reversed */
static int server_fd;
static void * server(void * unused)
{
  struct sockaddr_in peer;
  socklen_t len = sizeof peer;
  char line[64];
  int c, n, i;
  (void)unused;
  if ((c = accept(server_fd, (struct sockaddr *)&peer, &len)) < 0) return NULL;
  n = recv(c, line, sizeof line, 0);
  for (i = 0; i < n / 2; i++) {
    char t = line[i]; line[i] = line[n - 1 - i]; line[n - 1 - i] = t;
  }
  if (n > 0) send(c, line, n, 0);
  close(c);
  return NULL;
}

int main(void)
{
  struct addrinfo hints, * res = NULL;
  struct sockaddr_in a;
  struct stat st;
  struct timeval tv;
  char buf[256];
  int s, r, e;

  /* getaddrinfo: a dotted address, a service by number and by name */
  memset(&hints, 0, sizeof hints);
  hints.ai_socktype = SOCK_STREAM;
  r = getaddrinfo("10.0.2.2", "47001", &hints, &res);
  check("getaddrinfo: an address and a port",
        r == 0 && res && res->ai_family == AF_INET &&
        ntohs(((struct sockaddr_in *)res->ai_addr)->sin_port) == 47001);
  {
    struct addrinfo * h = NULL;
    int ok = getaddrinfo("localhost", "http", &hints, &h) == 0 &&
             ((struct sockaddr_in *)h->ai_addr)->sin_addr.s_addr == htonl(INADDR_LOOPBACK) &&
             ntohs(((struct sockaddr_in *)h->ai_addr)->sin_port) == 80;
    if (h) freeaddrinfo(h);
    check("getaddrinfo: localhost, http", ok);
  }

  /* TCP out: a line to the host, its answer until it closes */
  s = socket(AF_INET, SOCK_STREAM, 0);
  r = res ? connect(s, res->ai_addr, res->ai_addrlen) : -1;
  check("socket, connect", s >= 0 && r == 0);
  check("fstat: a socket", fstat(s, &st) == 0 && S_ISSOCK(st.st_mode));
  r = write(s, "hello sockets\n", 14);
  r = r == 14 ? read_all(s, buf, sizeof buf) : -1;
  printf("sockets: the host says: %s", r > 0 ? buf : "(nothing)\n");
  check("write, read: the host answers", r == 14 && !strcmp(buf, "HELLO SOCKETS\n"));
  check("close", close(s) == 0);
  check("a closed socket is gone", write(s, "x", 1) < 0 && errno == EBADF);
  if (res) freeaddrinfo(res);

  /* a receive timeout: the host waits for a whole line */
  s = socket(AF_INET, SOCK_STREAM, 0);
  a = addr("10.0.2.2", 47001);
  tv.tv_sec = 0; tv.tv_usec = 300000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  connect(s, (struct sockaddr *)&a, sizeof a);
  r = recv(s, buf, sizeof buf, 0);
  e = errno;
  check("SO_RCVTIMEO: recv gives EAGAIN", r < 0 && e == EAGAIN);
  close(s);

  /* refused */
  s = socket(AF_INET, SOCK_STREAM, 0);
  a = addr("10.0.2.2", 47002);
  r = connect(s, (struct sockaddr *)&a, sizeof a);
  e = errno;
  check("a refused connection: ECONNREFUSED", r < 0 && e == ECONNREFUSED);
  close(s);

  /* UDP: a datagram to the host and its answer */
  s = socket(AF_INET, SOCK_DGRAM, 0);
  tv.tv_sec = 3; tv.tv_usec = 0;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  a = addr("10.0.2.2", 47053);
  r = sendto(s, "hello udp", 9, 0, (struct sockaddr *)&a, sizeof a);
  {
    struct sockaddr_in from;
    socklen_t len = sizeof from;
    int n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &len);
    if (n >= 0) buf[n] = 0;
    check("UDP: sendto, recvfrom",
          r == 9 && n == 9 && !strcmp(buf, "HELLO UDP") &&
          ntohs(from.sin_port) == 47053);
  }
  close(s);

  /* a server here and a client of it: bind, listen, accept, our own
     address (lwIP's loopback) */
  server_fd = socket(AF_INET, SOCK_STREAM, 0);
  {
    int one = 1;
    pthread_t t;
    struct sockaddr_in peer;
    socklen_t len = sizeof peer;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    a = addr("0.0.0.0", 8091);
    r = bind(server_fd, (struct sockaddr *)&a, sizeof a);
    check("bind, listen", r == 0 && listen(server_fd, 4) == 0);
    pthread_create(&t, NULL, server, NULL);
    s = socket(AF_INET, SOCK_STREAM, 0);
    a = addr("10.0.2.15", 8091);
    r = connect(s, (struct sockaddr *)&a, sizeof a);
    send(s, "stressed", 8, 0);
    r = r == 0 ? recv(s, buf, sizeof buf, MSG_PEEK) : -1;
    r = r > 0 ? read_all(s, buf, sizeof buf) : -1;
    check("accept: our own server answers", r == 8 && !strcmp(buf, "desserts"));
    check("getpeername", getpeername(s, (struct sockaddr *)&peer, &len) == 0 &&
          ntohs(peer.sin_port) == 8091);
    close(s);
    pthread_join(t, NULL);
    close(server_fd);
  }

  printf(failures ? "sockets: FAIL\n" : "sockets: all checks passed\n");
  return failures ? 1 : 0;
}

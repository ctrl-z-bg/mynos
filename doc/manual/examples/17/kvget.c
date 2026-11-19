/* kvget.c: a C client of kv/1, with mynos_wire.h */
#include <stdio.h>
#include <mynos.h>
#include <mynos_wire.h>

int main(int argc, char ** argv)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  const char * s;
  unsigned int len;
  int port, ch;

  if (argc != 2 || (port = mynos_registryLookUp("kv")) < 0) return 2;
  wire_writer_init(&w);                   /* the request: */
  wire_put_cstring(&w, "kv/1");           /*   the protocol */
  wire_put_int(&w, 1);                    /*   case 1, Get */
  wire_put_cstring(&w, argv[1]);          /*   its argument, the key */
  if (w.error || (ch = mynos_connectToPort(port)) < 0) return 1;
  mynos_send(ch, w.buf, w.len, 0);
  wire_writer_free(&w);
  if (mynos_recv(ch, &msg, 0, 2000) < 0) { mynos_freeChannel(ch); return 1; }
  mynos_freeChannel(ch);

  wire_reader_init(&r, msg->start, msg->size);   /* the reply: */
  if (wire_get_int(&r) != 0) {                   /*   case 1: Error */
    s = wire_get_string(&r, &len);
    printf("kvget: error: %.*s\n", (int)len, s);
  } else if (!wire_get_bool(&r))                 /*   Ok None */
    printf("kvget: %s has no value\n", argv[1]);
  else {                                         /*   Ok (Some v) */
    s = wire_get_string(&r, &len);
    if (!r.error && wire_at_end(&r)) printf("kvget: %s = %.*s\n", argv[1], (int)len, s);
  }
  if (r.error) printf("kvget: a malformed reply\n");
  mynos_freeMsg(&msg);
  return 0;
}

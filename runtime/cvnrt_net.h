/* Сетевые сокеты Convulsions: value-сокет, TCP IPv4, fibers. */
#ifndef CVNRT_NET_H
#define CVNRT_NET_H

#include "cvnrt.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { CVN_SOCK_INVALID = 0, CVN_SOCK_LISTENER = 1, CVN_SOCK_CONN = 2 };

typedef struct cvn_socket {
  int64_t fd;
  int32_t kind;
  int32_t _pad;
} cvn_socket;

/* cgen ожидает именно это имя для !Socket (opaque object result). */
typedef struct cvn_result_obj_cvn_socket {
  uint32_t tag;
  uint32_t _pad;
  union {
    cvn_socket ok;
    cvn_error err;
  } u;
} cvn_result_obj_cvn_socket;

cvn_result_obj_cvn_socket cvn_net_listen(cvn_string host, int64_t port);
cvn_result_obj_cvn_socket cvn_net_accept(cvn_socket s);
cvn_result_obj_cvn_socket cvn_net_connect(cvn_string host, int64_t port);

cvn_result_string cvn_net_read(cvn_socket s, cvn_allocator a,
                               int64_t max_bytes);
cvn_result_i64    cvn_net_read_into(cvn_socket s, void *buf,
                                    int64_t max_bytes);
cvn_error         cvn_net_write(cvn_socket s, cvn_string data);
cvn_error         cvn_net_write_bytes(cvn_socket s, void *buf, int64_t n);

void              cvn_net_close(cvn_socket s);
int64_t           cvn_net_local_port(cvn_socket s);

#ifdef __cplusplus
}
#endif

#endif

/* C-юнит TCP-сокетов поверх fiber executor. */
#include "cvnrt_net.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (!(cond)) {                                                          \
      fprintf(stderr, "FAIL: %s\n", msg);                                   \
      failures++;                                                           \
    }                                                                       \
  } while (0)

static cvn_string lit(const char *s) {
  cvn_string r;
  r.ptr = (char *)s;
  r.len = (int64_t)strlen(s);
  r.cap = r.len + 1;
  memset(&r.alloc, 0, sizeof r.alloc);
  return r;
}

typedef struct {
  cvn_socket listener;
  int result;
} server_env;

static void serve_echo(void *p) {
  server_env *e = (server_env *)p;
  cvn_result_obj_cvn_socket ar = cvn_net_accept(e->listener);
  cvn_socket c;
  char buf[64];
  int total = 0;
  int ok = 0;
  if (ar.tag != 0u) {
    cvn_task_finish_current(&ok, (int64_t)sizeof ok);
    return;
  }
  c = ar.u.ok;
  while (total < 4) {
    cvn_result_i64 rr = cvn_net_read_into(c, buf + total, 4 - total);
    if (rr.tag != 0u || rr.u.ok <= 0)
      break;
    total += (int)rr.u.ok;
  }
  if (total == 4) {
    cvn_error we = cvn_net_write_bytes(c, buf, total);
    if (we.code == 0 && memcmp(buf, "ping", 4) == 0)
      ok = 1;
  }
  cvn_net_shutdown_write(c);
  cvn_net_close(c);
  cvn_task_finish_current(&ok, (int64_t)sizeof ok);
}

static cvn_socket open_server(int64_t *port) {
  cvn_result_obj_cvn_socket lr = cvn_net_listen(lit("127.0.0.1"), 0);
  if (lr.tag != 0u) {
    cvn_socket bad;
    bad.fd = -1;
    bad.kind = CVN_SOCK_INVALID;
    bad._pad = 0;
    return bad;
  }
  *port = cvn_net_local_port(lr.u.ok);
  return lr.u.ok;
}

static int test_echo(void) {
  int64_t port = 0;
  cvn_socket listener = open_server(&port);
  server_env env;
  cvn_task *srv;
  cvn_result_obj_cvn_socket cr;
  cvn_socket client;
  cvn_string data;
  cvn_result_string rr;
  int *ok;
  if (listener.fd < 0 || port <= 0)
    return -1;
  env.listener = listener;
  env.result = 0;
  srv = cvn_task_spawn(serve_echo, &env, (int64_t)sizeof env,
                       (int64_t)sizeof(int));
  cr = cvn_net_connect(lit("127.0.0.1"), port);
  CHECK(cr.tag == 0u, "connect echo");
  if (cr.tag != 0u)
    return -1;
  client = cr.u.ok;
  data = lit("ping");
  CHECK(cvn_net_write(client, data).code == 0, "write ping");
  rr = cvn_net_read(client, cvn_c_allocator(), 64);
  CHECK(rr.tag == 0u, "read echo");
  if (rr.tag == 0u) {
    CHECK(cvn_str_equal(rr.u.ok, lit("ping")), "echo payload");
    cvn_str_deinit(&rr.u.ok);
  }
  cvn_net_close(client);
  ok = (int *)cvn_task_await(srv);
  CHECK(ok != NULL && *ok == 1, "server task ok");
  cvn_net_close(listener);
  return 0;
}

static void serve_close(void *p) {
  server_env *e = (server_env *)p;
  cvn_result_obj_cvn_socket ar = cvn_net_accept(e->listener);
  int ok = 0;
  if (ar.tag == 0u) {
    cvn_socket c = ar.u.ok;
    if (cvn_net_write(c, lit("bye")).code == 0)
      ok = 1;
    cvn_net_shutdown_write(c);
    cvn_net_close(c);
  }
  cvn_task_finish_current(&ok, (int64_t)sizeof ok);
}

static int test_eof(void) {
  int64_t port = 0;
  cvn_socket listener = open_server(&port);
  server_env env;
  cvn_task *srv;
  cvn_result_obj_cvn_socket cr;
  cvn_socket client;
  cvn_result_string first;
  cvn_result_string second;
  if (listener.fd < 0 || port <= 0)
    return -1;
  env.listener = listener;
  env.result = 0;
  srv = cvn_task_spawn(serve_close, &env, (int64_t)sizeof env,
                       (int64_t)sizeof(int));
  cr = cvn_net_connect(lit("127.0.0.1"), port);
  CHECK(cr.tag == 0u, "connect eof");
  if (cr.tag != 0u)
    return -1;
  client = cr.u.ok;
  first = cvn_net_read(client, cvn_c_allocator(), 64);
  CHECK(first.tag == 0u && cvn_str_equal(first.u.ok, lit("bye")),
        "read bye");
  if (first.tag == 0u)
    cvn_str_deinit(&first.u.ok);
  second = cvn_net_read(client, cvn_c_allocator(), 64);
  CHECK(second.tag == 1u && second.u.err.code == CVN_ERR_CLOSED,
        "eof closed error");
  if (second.tag == 0u)
    cvn_str_deinit(&second.u.ok);
  CHECK(cvn_task_await(srv) != NULL, "eof server await");
  cvn_net_close(client);
  cvn_net_close(listener);
  return 0;
}

static int test_errors(void) {
  int64_t port = 0;
  cvn_socket listener = open_server(&port);
  cvn_result_obj_cvn_socket bad;
  cvn_result_obj_cvn_socket refused;
  cvn_result_obj_cvn_socket wrong_kind;
  CHECK(listener.fd >= 0, "listen for errors");
  if (listener.fd < 0)
    return -1;
  bad = cvn_net_listen(lit("not-an-ip"), 0);
  CHECK(bad.tag == 1u && bad.u.err.code == CVN_ERR_INVALID,
        "invalid host");
  bad = cvn_net_listen(lit("127.0.0.1"), 70000);
  CHECK(bad.tag == 1u && bad.u.err.code == CVN_ERR_INVALID,
        "invalid port");
  {
    cvn_socket invalid;
    invalid.fd = -1;
    invalid.kind = CVN_SOCK_INVALID;
    invalid._pad = 0;
    wrong_kind = cvn_net_accept(invalid);
    CHECK(wrong_kind.tag == 1u && wrong_kind.u.err.code == CVN_ERR_INVALID,
          "invalid kind");
  }
  (void)wrong_kind;
  cvn_net_close(listener);
  refused = cvn_net_connect(lit("127.0.0.1"), port);
  CHECK(refused.tag == 1u && refused.u.err.code == CVN_ERR_IO,
        "connection refused");
  return 0;
}

static cvn_error run_tests(void) {
  test_echo();
  test_eof();
  test_errors();
  return cvn_error_make(failures == 0 ? CVN_OK : CVN_ERR_TASK);
}

int main(void) {
  cvn_error e;
  cvn_rt_init();
  e = cvn_exec_run(run_tests, 4, 256);
  if (e.code != 0 || failures != 0) {
    fprintf(stderr, "c-net-fail code=%d failures=%d\n", (int)e.code,
            failures);
    return 1;
  }
  printf("c-net-ok\n");
  return 0;
}


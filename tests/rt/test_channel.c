/* C-юнит fiber-aware channel: backpressure, close, errors. */
#include "cvnrt.h"

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
  void *ch;
} producer_env;

static void producer(void *p) {
  producer_env *e = (producer_env *)p;
  int ok = 1;
  if (cvn_channel_send(e->ch, lit("alpha")).code != 0)
    ok = 0;
  if (cvn_channel_send(e->ch, lit("beta")).code != 0)
    ok = 0;
  if (cvn_channel_send(e->ch, lit("gamma")).code != 0)
    ok = 0;
  cvn_channel_close(e->ch);
  cvn_task_finish_current(&ok, (int64_t)sizeof ok);
}

typedef struct {
  void *ch;
  int total;
} consumer_env;

static void consumer(void *p) {
  consumer_env *e = (consumer_env *)p;
  int total = 0;
  for (;;) {
    cvn_result_string r = cvn_channel_recv(e->ch);
    if (r.tag != 0u) {
      if (r.u.err.code != CVN_ERR_CLOSED)
        total = -1;
      break;
    }
    total += (int)r.u.ok.len;
    cvn_str_deinit(&r.u.ok);
  }
  e->total = total;
  cvn_task_finish_current(&total, (int64_t)sizeof total);
}

static cvn_error run_tests(void) {
  cvn_result_ptr cr = cvn_channel_new(cvn_c_allocator(), 1);
  producer_env pe;
  consumer_env ce;
  cvn_task *pt;
  cvn_task *ct;
  int *pr;
  int *crv;
  cvn_error e;
  if (cr.tag != 0u) {
    fprintf(stderr, "channel-new failed %d\n", (int)cr.u.err.code);
    return cvn_error_make(CVN_ERR_TASK);
  }
  pe.ch = cr.u.ok;
  ce.ch = cr.u.ok;
  ce.total = 0;
  pt = cvn_task_spawn(producer, &pe, (int64_t)sizeof pe,
                      (int64_t)sizeof(int));
  ct = cvn_task_spawn(consumer, &ce, (int64_t)sizeof ce,
                      (int64_t)sizeof(int));
  pr = (int *)cvn_task_await(pt);
  crv = (int *)cvn_task_await(ct);
  CHECK(pr != NULL && *pr == 1, "producer ok");
  CHECK(crv != NULL && *crv == 14, "consumer total");
  e = cvn_channel_send(cr.u.ok, lit("late"));
  CHECK(e.code == CVN_ERR_CLOSED, "send after close");
  e = cvn_channel_recv(cr.u.ok).u.err;
  CHECK(e.code == CVN_ERR_CLOSED, "recv closed empty");
  cvn_channel_free(cr.u.ok);

  cr = cvn_channel_new(cvn_c_allocator(), 0);
  CHECK(cr.tag == 1u && cr.u.err.code == CVN_ERR_INVALID,
        "invalid capacity");
  return cvn_error_make(failures == 0 ? CVN_OK : CVN_ERR_TASK);
}

int main(void) {
  cvn_error e;
  cvn_rt_init();
  e = cvn_exec_run(run_tests, 1, 256);
  if (e.code != 0 || failures != 0) {
    fprintf(stderr, "c-channel-fail code=%d failures=%d\n", (int)e.code,
            failures);
    return 1;
  }
  printf("c-channel-ok\n");
  return 0;
}

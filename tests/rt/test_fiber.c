/* C-юнит fiber-executor: задачи, воркеры, таймеры, fd-readiness. */
#include "cvnrt.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define TEST_SLEEP_MS(ms) Sleep((DWORD)(ms))
#else
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#define TEST_SLEEP_MS(ms) usleep((useconds_t)(ms) * 1000)
#endif

static int failures = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (!(cond)) {                                                          \
      fprintf(stderr, "FAIL: %s\n", msg);                                   \
      failures++;                                                           \
    }                                                                       \
  } while (0)

typedef struct {
  int id;
  volatile long *count;
  volatile long *ids;
  int total;
} barrier_env;

static void barrier_task(void *p) {
  barrier_env *e = (barrier_env *)p;
  int r;
#ifdef _WIN32
  InterlockedIncrement(e->count);
  while (*(volatile long *)e->count < e->total)
    SwitchToThread();
  InterlockedExchange(e->ids + e->id, (long)cvn_worker_id() + 1);
#else
  __sync_add_and_fetch(e->count, 1);
  while (*(volatile long *)e->count < e->total)
    sched_yield();
  e->ids[e->id] = cvn_worker_id() + 1;
#endif
  r = e->id;
  cvn_task_finish_current(&r, (int64_t)sizeof r);
}

typedef struct {
  int ms;
  int *order;
  volatile long *counter;
} timer_env;

static void timer_task(void *p) {
  timer_env *e = (timer_env *)p;
  int pos;
  int r = e->ms;
  cvn_sleep_ms(e->ms);
#ifdef _WIN32
  pos = (int)InterlockedIncrement(e->counter) - 1;
#else
  pos = (int)__sync_add_and_fetch(e->counter, 1) - 1;
#endif
  e->order[pos] = e->ms;
  cvn_task_finish_current(&r, (int64_t)sizeof r);
}

typedef struct {
  int fd;
  int saw_read;
} fd_env;

static void fd_reader(void *p) {
  fd_env *e = (fd_env *)p;
  char c = 0;
  int events = cvn_task_wait_fd(e->fd, CVN_IO_READ);
  if (events & CVN_IO_READ) {
    (void)recv(e->fd, &c, 1, 0);
  }
  e->saw_read = (events & CVN_IO_READ) && c == 'x';
  {
    int r = e->saw_read ? 1 : 0;
    cvn_task_finish_current(&r, (int64_t)sizeof r);
  }
}

typedef struct {
  int fd;
  int delay_ms;
} writer_env;

static void fd_writer(void *p) {
  writer_env *e = (writer_env *)p;
  char c = 'x';
  cvn_sleep_ms(e->delay_ms);
  (void)send(e->fd, &c, 1, 0);
  {
    int r = 1;
    cvn_task_finish_current(&r, (int64_t)sizeof r);
  }
}

static void nested_inner(void *p) {
  int r = 7;
  (void)p;
  cvn_sleep_ms(5);
  cvn_task_finish_current(&r, (int64_t)sizeof r);
}

static void nested_outer(void *p) {
  cvn_task *inner;
  int *v;
  (void)p;
  inner = cvn_task_spawn(nested_inner, NULL, 0, (int64_t)sizeof(int));
  v = (int *)cvn_task_await(inner);
  {
    int r = (v != NULL && *v == 7) ? 1 : 0;
    cvn_task_finish_current(&r, (int64_t)sizeof r);
  }
}

static int test_barrier_and_workers(void) {
  enum { N = 4 };
  volatile long count = 0;
  volatile long ids[N];
  barrier_env env[N];
  cvn_task *tasks[N];
  int i;
  int distinct = 0;
  int seen[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  for (i = 0; i < N; i++) {
    ids[i] = 0;
    env[i].id = i;
    env[i].count = &count;
    env[i].ids = ids;
    env[i].total = N;
    tasks[i] = cvn_task_spawn(barrier_task, &env[i],
                              (int64_t)sizeof env[i], (int64_t)sizeof(int));
  }
  for (i = 0; i < N; i++) {
    int *r = (int *)cvn_task_await(tasks[i]);
    CHECK(r != NULL && *r == i, "barrier result");
  }
  for (i = 0; i < N; i++) {
    int w = (int)ids[i];
    CHECK(w > 0, "worker id set");
    if (w > 0 && w < 8 && !seen[w]) {
      seen[w] = 1;
      distinct++;
    }
  }
  CHECK(distinct >= 2, "tasks distributed over >=2 workers");
  return count >= N ? 0 : -1;
}

static int test_timers(void) {
  int order[3] = {0, 0, 0};
  volatile long counter = 0;
  timer_env env[3];
  cvn_task *tasks[3];
  int ms[3] = {30, 120, 240};
  int i;
  for (i = 0; i < 3; i++) {
    env[i].ms = ms[i];
    env[i].order = order;
    env[i].counter = &counter;
    tasks[i] = cvn_task_spawn(timer_task, &env[i],
                              (int64_t)sizeof env[i], (int64_t)sizeof(int));
  }
  for (i = 0; i < 3; i++)
    (void)cvn_task_await(tasks[i]);
  CHECK(order[0] == 30 && order[1] == 120 && order[2] == 240,
        "timer wake order");
  return 0;
}

static int test_nested_await(void) {
  cvn_task *t = cvn_task_spawn(nested_outer, NULL, 0, (int64_t)sizeof(int));
  int *r = (int *)cvn_task_await(t);
  CHECK(r != NULL && *r == 1, "nested await");
  return 0;
}

#ifdef _WIN32
static int test_fd_readiness(void) {
  SOCKET listener = INVALID_SOCKET;
  SOCKET client = INVALID_SOCKET;
  SOCKET server = INVALID_SOCKET;
  struct sockaddr_in addr;
  int len = (int)sizeof addr;
  fd_env renv;
  writer_env wenv;
  cvn_task *rt;
  cvn_task *wt;
  int *ready;
  int ok = 0;

  listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listener == INVALID_SOCKET)
    return -1;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0)
    goto done;
  if (listen(listener, 1) != 0)
    goto done;
  if (getsockname(listener, (struct sockaddr *)&addr, &len) != 0)
    goto done;
  client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (client == INVALID_SOCKET)
    goto done;
  if (connect(client, (struct sockaddr *)&addr, sizeof addr) != 0)
    goto done;
  server = accept(listener, NULL, NULL);
  if (server == INVALID_SOCKET)
    goto done;

  renv.fd = (int)server;
  renv.saw_read = 0;
  wenv.fd = (int)client;
  wenv.delay_ms = 30;
  rt = cvn_task_spawn(fd_reader, &renv, (int64_t)sizeof renv,
                      (int64_t)sizeof(int));
  wt = cvn_task_spawn(fd_writer, &wenv, (int64_t)sizeof wenv,
                      (int64_t)sizeof(int));
  ready = (int *)cvn_task_await(rt);
  (void)cvn_task_await(wt);
  ok = ready != NULL && *ready == 1;
  CHECK(ok, "fd readiness wakes task");

done:
  if (server != INVALID_SOCKET)
    closesocket(server);
  if (client != INVALID_SOCKET)
    closesocket(client);
  if (listener != INVALID_SOCKET)
    closesocket(listener);
  return ok ? 0 : -1;
}
#else
static int test_fd_readiness(void) {
  int sv[2];
  fd_env renv;
  writer_env wenv;
  cvn_task *rt;
  cvn_task *wt;
  int *ready;
  int ok;
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
    return -1;
  renv.fd = sv[0];
  renv.saw_read = 0;
  wenv.fd = sv[1];
  wenv.delay_ms = 30;
  rt = cvn_task_spawn(fd_reader, &renv, (int64_t)sizeof renv,
                      (int64_t)sizeof(int));
  wt = cvn_task_spawn(fd_writer, &wenv, (int64_t)sizeof wenv,
                      (int64_t)sizeof(int));
  ready = (int *)cvn_task_await(rt);
  (void)cvn_task_await(wt);
  ok = ready != NULL && *ready == 1;
  CHECK(ok, "fd readiness wakes task");
  close(sv[0]);
  close(sv[1]);
  return ok ? 0 : -1;
}
#endif

static cvn_error run_tests(void) {
  test_barrier_and_workers();
  test_timers();
  test_nested_await();
  test_fd_readiness();
  return cvn_error_make(failures == 0 ? CVN_OK : CVN_ERR_TASK);
}

int main(void) {
  cvn_error e;
  cvn_rt_init();
  e = cvn_exec_run(run_tests, 4, 256);
  if (e.code != 0 || failures != 0) {
    fprintf(stderr, "c-fiber-fail code=%d failures=%d\n", (int)e.code,
            failures);
    return 1;
  }
  printf("c-fiber-ok\n");
  return 0;
}




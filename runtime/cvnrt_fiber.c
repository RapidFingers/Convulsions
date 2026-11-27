/* Fiber executor: M:N-пул воркеров, парковка/пробуждение, event loop. */
#define _WIN32_WINNT 0x0601

#include "cvnrt.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <pthread.h>
#include <ucontext.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <time.h>
#include <fcntl.h>
#include <errno.h>
#endif

#define CVN_MAX_WORKERS 64
#define CVN_DEFAULT_STACK_KB 256

typedef enum {
  CVN_TASK_READY = 0,
  CVN_TASK_RUNNING,
  CVN_TASK_WAITING,
  CVN_TASK_DONE
} cvn_task_state;

typedef struct cvn_worker cvn_worker;
typedef struct cvn_fiber cvn_fiber;

struct cvn_task {
  cvn_task_fn fn;
  void *env;
  int64_t env_size;
  void *result;
  int64_t result_size;
  int state;
  int home;
  int worker_id;
  uint32_t io_events;
  cvn_task *next;
  cvn_task *waiters;
  cvn_task *wait_next;
  cvn_task *all_next;
  cvn_fiber *fiber;
};

struct cvn_fiber {
#ifdef _WIN32
  LPVOID handle;
#else
  ucontext_t ctx;
  void *stack;
  size_t stack_size;
#endif
};

struct cvn_worker {
  int id;
  cvn_fiber *sched;
  cvn_task *local_head;
  cvn_task *local_tail;
#ifdef _WIN32
  LPVOID sched_handle;
  CONDITION_VARIABLE cv;
  HANDLE thread;
#else
  pthread_cond_t cv;
  pthread_t thread;
  ucontext_t sched_ctx;
#endif
};

/* ----------------------------------------------------------- общий lock --- */

#ifdef _WIN32
static CRITICAL_SECTION g_lock;
static void lock_init(void) {
  InitializeCriticalSection(&g_lock);
}
static void lock_enter(void) { EnterCriticalSection(&g_lock); }
static void lock_leave(void) { LeaveCriticalSection(&g_lock); }
static void cond_init(cvn_worker *w) {
  InitializeConditionVariable(&w->cv);
}
static void cond_wait(cvn_worker *w, int ms) {
  SleepConditionVariableCS(&w->cv, &g_lock, (DWORD)ms);
}
static void cond_wake(cvn_worker *w) { WakeConditionVariable(&w->cv); }
static void cond_wake_all(cvn_worker *w) { WakeAllConditionVariable(&w->cv); }
#else
static pthread_mutex_t g_lock;
static void lock_init(void) { pthread_mutex_init(&g_lock, NULL); }
static void lock_enter(void) { pthread_mutex_lock(&g_lock); }
static void lock_leave(void) { pthread_mutex_unlock(&g_lock); }
static void cond_init(cvn_worker *w) { pthread_cond_init(&w->cv, NULL); }
static void cond_wait(cvn_worker *w, int ms) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  ts.tv_sec += ms / 1000;
  ts.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (ts.tv_nsec >= 1000000000L) {
    ts.tv_sec++;
    ts.tv_nsec -= 1000000000L;
  }
  pthread_cond_timedwait(&w->cv, &g_lock, &ts);
}
static void cond_wake(cvn_worker *w) { pthread_cond_signal(&w->cv); }
static void cond_wake_all(cvn_worker *w) { pthread_cond_broadcast(&w->cv); }
#endif

static _Thread_local cvn_worker *tls_worker = NULL;
static _Thread_local cvn_task *tls_task = NULL;

static cvn_worker *g_workers = NULL;
static int g_worker_count = 0;
static int g_stop = 0;
static int g_stack_kb = CVN_DEFAULT_STACK_KB;
static cvn_task *g_ready_head = NULL;
static cvn_task *g_ready_tail = NULL;
static cvn_task *g_all_tasks = NULL;
static cvn_task *g_root = NULL;

static void fatal(const char *msg) {
  fprintf(stderr, "fiber error: %s\n", msg);
  fflush(stderr);
  exit(3);
}

static void enqueue_local_locked(cvn_worker *w, cvn_task *t) {
  t->next = NULL;
  if (w->local_tail != NULL)
    w->local_tail->next = t;
  else
    w->local_head = t;
  w->local_tail = t;
  cond_wake(w);
}

static void enqueue_global_locked(cvn_task *t) {
  int i;
  t->next = NULL;
  if (g_ready_tail != NULL)
    g_ready_tail->next = t;
  else
    g_ready_head = t;
  g_ready_tail = t;
  for (i = 0; i < g_worker_count; i++)
    cond_wake(&g_workers[i]);
}

static void enqueue_ready_locked(cvn_task *t) {
  if (t->home >= 0 && t->home < g_worker_count)
    enqueue_local_locked(&g_workers[t->home], t);
  else
    enqueue_global_locked(t);
}

static cvn_task *pop_locked(cvn_worker *w) {
  cvn_task *t;
  if (w->local_head != NULL) {
    t = w->local_head;
    w->local_head = t->next;
    if (w->local_head == NULL)
      w->local_tail = NULL;
    t->next = NULL;
    return t;
  }
  if (g_ready_head != NULL) {
    t = g_ready_head;
    g_ready_head = t->next;
    if (g_ready_head == NULL)
      g_ready_tail = NULL;
    t->next = NULL;
    return t;
  }
  return NULL;
}

/* ---------------------------------------------------------- event loop --- */

enum { CVN_LOOP_TIMER = 1, CVN_LOOP_FD = 2, CVN_LOOP_STOP = 3 };

typedef struct cvn_loop_cmd {
  int kind;
  int64_t deadline;
  cvn_task *task;
  int fd;
  uint32_t events;
  struct cvn_loop_cmd *next;
} cvn_loop_cmd;

typedef struct {
  int64_t deadline;
  cvn_task *task;
} cvn_timer;

typedef struct {
  int fd;
  uint32_t events;
  cvn_task *task;
} cvn_fdentry;

#ifdef _WIN32
static CRITICAL_SECTION g_loop_lock;
static SOCKET g_wake_recv = INVALID_SOCKET;
static SOCKET g_wake_send = INVALID_SOCKET;
static HANDLE g_loop_thread = NULL;
#else
static pthread_mutex_t g_loop_lock;
static int g_wake_pipe[2] = {-1, -1};
static pthread_t g_loop_thread;
static int g_epoll_fd = -1;
#endif

static cvn_loop_cmd *g_cmd_head = NULL;
static cvn_loop_cmd *g_cmd_tail = NULL;
static cvn_timer *g_timers = NULL;
static int g_timer_count = 0;
static int g_timer_cap = 0;
static cvn_fdentry *g_fds = NULL;
static int g_fd_count = 0;
static int g_fd_cap = 0;
static volatile int g_loop_stop = 0;

static int64_t now_ms(void) {
#ifdef _WIN32
  return (int64_t)GetTickCount64();
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static void loop_lock_enter(void) {
#ifdef _WIN32
  EnterCriticalSection(&g_loop_lock);
#else
  pthread_mutex_lock(&g_loop_lock);
#endif
}

static void loop_lock_leave(void) {
#ifdef _WIN32
  LeaveCriticalSection(&g_loop_lock);
#else
  pthread_mutex_unlock(&g_loop_lock);
#endif
}

static void loop_wake(void) {
#ifdef _WIN32
  char b = 1;
  if (g_wake_send != INVALID_SOCKET)
    (void)send(g_wake_send, &b, 1, 0);
#else
  char b = 1;
  if (g_wake_pipe[1] >= 0)
    (void)write(g_wake_pipe[1], &b, 1);
#endif
}

static void loop_submit(cvn_loop_cmd *cmd) {
  loop_lock_enter();
  cmd->next = NULL;
  if (g_cmd_tail != NULL)
    g_cmd_tail->next = cmd;
  else
    g_cmd_head = cmd;
  g_cmd_tail = cmd;
  loop_lock_leave();
  loop_wake();
}

static void timer_push(int64_t deadline, cvn_task *t) {
  int i;
  if (g_timer_count == g_timer_cap) {
    g_timer_cap = g_timer_cap == 0 ? 16 : g_timer_cap * 2;
    g_timers = (cvn_timer *)realloc(g_timers,
                                    (size_t)g_timer_cap * sizeof *g_timers);
    if (g_timers == NULL)
      fatal("timer heap allocation failed");
  }
  i = g_timer_count++;
  while (i > 0) {
    int p = (i - 1) / 2;
    if (g_timers[p].deadline <= deadline)
      break;
    g_timers[i] = g_timers[p];
    i = p;
  }
  g_timers[i].deadline = deadline;
  g_timers[i].task = t;
}

static cvn_timer timer_pop(void) {
  cvn_timer top = g_timers[0];
  int n = --g_timer_count;
  if (n > 0) {
    cvn_timer last = g_timers[n];
    int i = 0;
    for (;;) {
      int l = i * 2 + 1;
      int r = l + 1;
      int m;
      if (l >= n)
        break;
      m = l;
      if (r < n && g_timers[r].deadline < g_timers[l].deadline)
        m = r;
      if (g_timers[m].deadline >= last.deadline)
        break;
      g_timers[i] = g_timers[m];
      i = m;
    }
    g_timers[i] = last;
  }
  return top;
}

static void fd_add(int fd, uint32_t events, cvn_task *t) {
  if (g_fd_count == g_fd_cap) {
    g_fd_cap = g_fd_cap == 0 ? 16 : g_fd_cap * 2;
    g_fds = (cvn_fdentry *)realloc(g_fds,
                                   (size_t)g_fd_cap * sizeof *g_fds);
    if (g_fds == NULL)
      fatal("fd set allocation failed");
  }
  g_fds[g_fd_count].fd = fd;
  g_fds[g_fd_count].events = events;
  g_fds[g_fd_count].task = t;
  g_fd_count++;
}

static void wake_task(cvn_task *t, uint32_t events) {
  lock_enter();
  t->io_events = events;
  if (t->state == CVN_TASK_WAITING) {
    t->state = CVN_TASK_READY;
    enqueue_ready_locked(t);
  }
  lock_leave();
}

#ifdef _WIN32
static int loop_init_wake(void) {  WSADATA wsa;
  struct sockaddr_in addr;
  int len = (int)sizeof addr;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
    return -1;
  g_wake_recv = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  g_wake_send = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (g_wake_recv == INVALID_SOCKET || g_wake_send == INVALID_SOCKET)
    return -1;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(g_wake_recv, (struct sockaddr *)&addr, sizeof addr) != 0)
    return -1;
  if (getsockname(g_wake_recv, (struct sockaddr *)&addr, &len) != 0)
    return -1;
  if (connect(g_wake_send, (struct sockaddr *)&addr, sizeof addr) != 0)
    return -1;
  {
    u_long nb = 1;
    (void)ioctlsocket(g_wake_recv, FIONBIO, &nb);
    (void)ioctlsocket(g_wake_send, FIONBIO, &nb);
  }
  return 0;
}

static void loop_drain_wake(void) {
  char buf[256];
  while (recv(g_wake_recv, buf, (int)sizeof buf, 0) > 0) {
  }
}

static DWORD WINAPI loop_thread_proc(LPVOID p) {
  (void)p;
  for (;;) {
    cvn_loop_cmd *cmd;
    int stopping = 0;
    int64_t now;
    int timeout = 1000;
    WSAPOLLFD *pfds;
    int nfds;
    int i;
    int n;

    loop_lock_enter();
    cmd = g_cmd_head;
    g_cmd_head = NULL;
    g_cmd_tail = NULL;
    loop_lock_leave();
    while (cmd != NULL) {
      cvn_loop_cmd *next = cmd->next;
      if (cmd->kind == CVN_LOOP_TIMER) {
        timer_push(cmd->deadline, cmd->task);
      } else if (cmd->kind == CVN_LOOP_FD) {
        fd_add(cmd->fd, cmd->events, cmd->task);
#ifndef _WIN32
        {
          struct epoll_event ev;
          memset(&ev, 0, sizeof ev);
          if (cmd->events & CVN_IO_READ)
            ev.events |= EPOLLIN;
          if (cmd->events & CVN_IO_WRITE)
            ev.events |= EPOLLOUT;
          ev.data.fd = cmd->fd;
          (void)epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, cmd->fd, &ev);
        }
#endif
      } else if (cmd->kind == CVN_LOOP_STOP) {
        stopping = 1;
      }
      free(cmd);
      cmd = next;
    }
    if (stopping || g_loop_stop)
      break;

    now = now_ms();
    if (g_timer_count > 0) {
      int64_t d = g_timers[0].deadline - now;
      timeout = d <= 0 ? 0 : (int)(d > 1000 ? 1000 : d);
    }

    nfds = 1 + g_fd_count;
    pfds = (WSAPOLLFD *)malloc((size_t)nfds * sizeof *pfds);
    if (pfds == NULL)
      fatal("poll allocation failed");
    pfds[0].fd = g_wake_recv;
    pfds[0].events = POLLRDNORM;
    pfds[0].revents = 0;
    for (i = 0; i < g_fd_count; i++) {
      pfds[i + 1].fd = g_fds[i].fd;
      pfds[i + 1].events = 0;
      if (g_fds[i].events & CVN_IO_READ)
        pfds[i + 1].events |= POLLRDNORM;
      if (g_fds[i].events & CVN_IO_WRITE)
        pfds[i + 1].events |= POLLWRNORM;
      pfds[i + 1].revents = 0;
    }
    n = WSAPoll(pfds, (ULONG)nfds, timeout);
    if (n > 0) {
      if (pfds[0].revents != 0)
        loop_drain_wake();
      i = 0;
      while (i < g_fd_count) {
        short re = pfds[i + 1].revents;
        if (re != 0) {
          cvn_fdentry e = g_fds[i];
          uint32_t ev = 0;
          if (re & (POLLRDNORM | POLLIN))
            ev |= CVN_IO_READ;
          if (re & (POLLWRNORM | POLLOUT))
            ev |= CVN_IO_WRITE;
          if (re & (POLLERR | POLLHUP | POLLNVAL))
            ev |= CVN_IO_ERR;
          if (ev == 0)
            ev = CVN_IO_ERR;
          g_fds[i] = g_fds[g_fd_count - 1];
          g_fd_count--;
          wake_task(e.task, ev);
        } else {
          i++;
        }
      }
    }
    free(pfds);

    now = now_ms();
    while (g_timer_count > 0 && g_timers[0].deadline <= now) {
      cvn_timer t = timer_pop();
      wake_task(t.task, 0);
    }
  }
  return 0;
}

static void loop_lock_init(void);

static void loop_start(void) {
  loop_lock_init();
  if (loop_init_wake() != 0)
    fatal("event loop wake sockets failed");
  g_loop_stop = 0;
  g_loop_thread = CreateThread(NULL, 0, loop_thread_proc, NULL, 0, NULL);
  if (g_loop_thread == NULL)
    fatal("event loop thread failed");
}

static void loop_shutdown(void) {
  cvn_loop_cmd *cmd = (cvn_loop_cmd *)calloc(1, sizeof *cmd);
  if (cmd != NULL) {
    cmd->kind = CVN_LOOP_STOP;
    loop_submit(cmd);
  }
  g_loop_stop = 1;
  loop_wake();
  if (g_loop_thread != NULL) {
    WaitForSingleObject(g_loop_thread, INFINITE);
    CloseHandle(g_loop_thread);
    g_loop_thread = NULL;
  }
  if (g_wake_recv != INVALID_SOCKET)
    closesocket(g_wake_recv);
  if (g_wake_send != INVALID_SOCKET)
    closesocket(g_wake_send);
  g_wake_recv = INVALID_SOCKET;
  g_wake_send = INVALID_SOCKET;
  WSACleanup();
  DeleteCriticalSection(&g_loop_lock);
}

static void loop_lock_init(void) {
  InitializeCriticalSection(&g_loop_lock);
}
#else
/* POSIX: epoll + pipe, ucontext. */
static void loop_lock_init(void) {
  pthread_mutex_init(&g_loop_lock, NULL);
}
static void loop_wake(void) {
  char b = 1;
  if (g_wake_pipe[1] >= 0)
    (void)write(g_wake_pipe[1], &b, 1);
}
static void loop_drain_wake(void) {
  char buf[256];
  (void)read(g_wake_pipe[0], buf, sizeof buf);
}
static void *loop_thread_proc(void *p) {
  (void)p;
  struct epoll_event evs[64];
  for (;;) {
    cvn_loop_cmd *cmd;
    int stopping = 0;
    int timeout = 1000;
    loop_lock_enter();
    cmd = g_cmd_head;
    g_cmd_head = NULL;
    g_cmd_tail = NULL;
    loop_lock_leave();
    while (cmd != NULL) {
      cvn_loop_cmd *next = cmd->next;
      if (cmd->kind == CVN_LOOP_TIMER) {
        timer_push(cmd->deadline, cmd->task);
      } else if (cmd->kind == CVN_LOOP_FD) {
        fd_add(cmd->fd, cmd->events, cmd->task);
#ifndef _WIN32
        {
          struct epoll_event ev;
          memset(&ev, 0, sizeof ev);
          if (cmd->events & CVN_IO_READ)
            ev.events |= EPOLLIN;
          if (cmd->events & CVN_IO_WRITE)
            ev.events |= EPOLLOUT;
          ev.data.fd = cmd->fd;
          (void)epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, cmd->fd, &ev);
        }
#endif
      } else if (cmd->kind == CVN_LOOP_STOP) {
        stopping = 1;
      }
      free(cmd);
      cmd = next;
    }
    if (stopping || g_loop_stop)
      break;
    if (g_timer_count > 0) {
      int64_t d = g_timers[0].deadline - now_ms();
      timeout = d <= 0 ? 0 : (int)(d > 1000 ? 1000 : d);
    }
    {
      int n = epoll_wait(g_epoll_fd, evs, 64, timeout);
      int i;
      for (i = 0; i < n; i++) {
        int fd = evs[i].data.fd;
        uint32_t ev = 0;
        if (fd == g_wake_pipe[0]) {
          loop_drain_wake();
          continue;
        }
        if (evs[i].events & (EPOLLIN | EPOLLHUP))
          ev |= CVN_IO_READ;
        if (evs[i].events & EPOLLOUT)
          ev |= CVN_IO_WRITE;
#if defined(EPOLLERR)
        if (evs[i].events & EPOLLERR)
          ev |= CVN_IO_ERR;
#endif
        if (ev == 0)
          ev = CVN_IO_ERR;
        {
          int j = 0;
          while (j < g_fd_count) {
            if (g_fds[j].fd == fd) {
              cvn_fdentry e = g_fds[j];
              g_fds[j] = g_fds[g_fd_count - 1];
              g_fd_count--;
              (void)epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, fd, NULL);
              wake_task(e.task, ev);
              break;
            }
            j++;
          }
        }
      }
    }
    {
      int64_t now = now_ms();
      while (g_timer_count > 0 && g_timers[0].deadline <= now) {
        cvn_timer t = timer_pop();
        wake_task(t.task, 0);
      }
    }
  }
  return NULL;
}
static void loop_start(void) {
  struct epoll_event ev;
  loop_lock_init();
  if (pipe(g_wake_pipe) != 0)
    fatal("wake pipe failed");
  {
    int flags = fcntl(g_wake_pipe[0], F_GETFL, 0);
    (void)fcntl(g_wake_pipe[0], F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(g_wake_pipe[1], F_GETFL, 0);
    (void)fcntl(g_wake_pipe[1], F_SETFL, flags | O_NONBLOCK);
  }
  g_epoll_fd = epoll_create1(0);
  if (g_epoll_fd < 0)
    fatal("epoll_create1 failed");
  memset(&ev, 0, sizeof ev);
  ev.events = EPOLLIN;
  ev.data.fd = g_wake_pipe[0];
  (void)epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_wake_pipe[0], &ev);
  g_loop_stop = 0;
  if (pthread_create(&g_loop_thread, NULL, loop_thread_proc, NULL) != 0)
    fatal("event loop thread failed");
}
static void loop_shutdown(void) {
  cvn_loop_cmd *cmd = (cvn_loop_cmd *)calloc(1, sizeof *cmd);
  if (cmd != NULL) {
    cmd->kind = CVN_LOOP_STOP;
    loop_submit(cmd);
  }
  g_loop_stop = 1;
  loop_wake();
  pthread_join(g_loop_thread, NULL);
  if (g_epoll_fd >= 0)
    close(g_epoll_fd);
  g_epoll_fd = -1;
  if (g_wake_pipe[0] >= 0) {
    close(g_wake_pipe[0]);
    close(g_wake_pipe[1]);
    g_wake_pipe[0] = g_wake_pipe[1] = -1;
  }
  pthread_mutex_destroy(&g_loop_lock);
}
#endif

/* ------------------------------------------------------------- контекст --- */

#ifdef _WIN32
static VOID CALLBACK task_trampoline(void *p) {
  cvn_task *t = (cvn_task *)p;
  t->fn(t->env);
  {
    cvn_error e = cvn_error_make(CVN_ERR_TASK);
    cvn_task_finish_current(&e, (int64_t)sizeof e);
  }
}
#else
static void task_trampoline(void) {
  cvn_task *t = tls_task;
  t->fn(t->env);
  {
    cvn_error e = cvn_error_make(CVN_ERR_TASK);
    cvn_task_finish_current(&e, (int64_t)sizeof e);
  }
}
#endif

static cvn_fiber *make_task_fiber(cvn_task *t) {
  cvn_fiber *f = (cvn_fiber *)calloc(1, sizeof *f);
  if (f == NULL)
    fatal("fiber allocation failed");
#ifdef _WIN32
  f->handle = CreateFiberEx((SIZE_T)g_stack_kb * 1024,
                            (SIZE_T)g_stack_kb * 1024,
                            FIBER_FLAG_FLOAT_SWITCH,
                            (LPFIBER_START_ROUTINE)task_trampoline, t);
  if (f->handle == NULL)
    fatal("CreateFiberEx failed");
#else
  f->stack_size = (size_t)g_stack_kb * 1024;
  f->stack = mmap(NULL, f->stack_size, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (f->stack == MAP_FAILED)
    fatal("mmap fiber stack failed");
  if (getcontext(&f->ctx) != 0)
    fatal("getcontext failed");
  f->ctx.uc_stack.ss_sp = f->stack;
  f->ctx.uc_stack.ss_size = f->stack_size;
  f->ctx.uc_link = NULL;
  makecontext(&f->ctx, task_trampoline, 0);
#endif
  return f;
}

static void free_task_fiber(cvn_fiber *f) {
  if (f == NULL)
    return;
#ifdef _WIN32
  if (f->handle != NULL)
    DeleteFiber(f->handle);
#else
  if (f->stack != NULL && f->stack != MAP_FAILED)
    munmap(f->stack, f->stack_size);
#endif
  free(f);
}

static void switch_to_sched(void) {
#ifdef _WIN32
  SwitchToFiber(tls_worker->sched->handle);
#else
  swapcontext(&tls_task->fiber->ctx, &tls_worker->sched_ctx);
#endif
}

/* --------------------------------------------------------------- задачи --- */

static cvn_task *task_alloc(cvn_task_fn fn, const void *env, int64_t env_size,
                            int64_t result_size) {
  cvn_task *t = (cvn_task *)calloc(1, sizeof *t);
  if (t == NULL)
    fatal("task allocation failed");
  t->fn = fn;
  t->env_size = env_size;
  t->env = malloc(env_size > 0 ? (size_t)env_size : 1);
  if (t->env == NULL)
    fatal("task env allocation failed");
  if (env != NULL && env_size > 0)
    memcpy(t->env, env, (size_t)env_size);
  t->result_size = result_size;
  t->result = calloc(1, result_size > 0 ? (size_t)result_size : 1);
  if (t->result == NULL)
    fatal("task result allocation failed");
  t->state = CVN_TASK_READY;
  t->home = -1;
  t->worker_id = -1;
  return t;
}

cvn_task *cvn_task_spawn(cvn_task_fn fn, const void *env, int64_t env_size,
                         int64_t result_size) {
  cvn_task *t;
  if (fn == NULL || result_size <= 0)
    return NULL;
  t = task_alloc(fn, env, env_size, result_size);
  lock_enter();
  t->all_next = g_all_tasks;
  g_all_tasks = t;
  enqueue_global_locked(t);
  lock_leave();
  return t;
}

void cvn_task_finish_current(const void *result, int64_t result_size) {
  cvn_task *t = tls_task;
  cvn_task *w;
  if (t == NULL)
    fatal("task_finish outside task");
  lock_enter();
  if (result != NULL && result_size > 0 && t->result != NULL) {
    int64_t n = result_size < t->result_size ? result_size : t->result_size;
    memcpy(t->result, result, (size_t)n);
  }
  t->state = CVN_TASK_DONE;
  w = t->waiters;
  t->waiters = NULL;
  while (w != NULL) {
    cvn_task *next = w->wait_next;
    w->wait_next = NULL;
    if (w->state == CVN_TASK_WAITING) {
      w->state = CVN_TASK_READY;
      enqueue_ready_locked(w);
    }
    w = next;
  }
  lock_leave();
  switch_to_sched();
  for (;;) {
  }
}

void *cvn_task_await(cvn_task *t) {
  cvn_task *cur = tls_task;
  if (t == NULL)
    return NULL;
  if (cur == NULL)
    fatal("await outside task");
  if (cur == t)
    fatal("task awaits itself");
  lock_enter();
  if (t->state == CVN_TASK_DONE) {
    void *r = t->result;
    lock_leave();
    return r;
  }
  cur->state = CVN_TASK_WAITING;
  cur->wait_next = t->waiters;
  t->waiters = cur;
  lock_leave();
  switch_to_sched();
  return t->result;
}

void cvn_task_yield(void) {
  /* Кооперативная уступка через планировщик: паркуем задачу на 0 мс.
     Это надёжнее прямого enqueue при одном воркере. */
  cvn_sleep_ms(0);
}

void cvn_sleep_ms(int64_t ms) {
  cvn_task *t = tls_task;
  cvn_loop_cmd *cmd;
  if (t == NULL)
    fatal("sleep outside task");
  cmd = (cvn_loop_cmd *)calloc(1, sizeof *cmd);
  if (cmd == NULL)
    fatal("sleep command allocation failed");
  cmd->kind = CVN_LOOP_TIMER;
  cmd->deadline = now_ms() + (ms > 0 ? ms : 0);
  cmd->task = t;
  lock_enter();
  t->state = CVN_TASK_WAITING;
  lock_leave();
  loop_submit(cmd);
  switch_to_sched();
}

int cvn_task_wait_fd(int fd, uint32_t events) {
  cvn_task *t = tls_task;
  cvn_loop_cmd *cmd;
  if (t == NULL)
    fatal("wait_fd outside task");
  cmd = (cvn_loop_cmd *)calloc(1, sizeof *cmd);
  if (cmd == NULL)
    fatal("fd command allocation failed");
  cmd->kind = CVN_LOOP_FD;
  cmd->task = t;
  cmd->fd = fd;
  cmd->events = events;
  t->io_events = 0;
  lock_enter();
  t->state = CVN_TASK_WAITING;
  lock_leave();
  loop_submit(cmd);
  switch_to_sched();
  return (int)t->io_events;
}

int cvn_worker_id(void) {
  return tls_worker != NULL ? tls_worker->id : -1;
}

static void run_task(cvn_worker *w, cvn_task *t) {
  if (t == NULL || t->state == CVN_TASK_DONE)
    return;
  if (t->fiber == NULL)
    t->fiber = make_task_fiber(t);
  tls_task = t;
  t->state = CVN_TASK_RUNNING;
  t->worker_id = w->id;
#ifdef _WIN32
  SwitchToFiber(t->fiber->handle);
#else
  swapcontext(&w->sched_ctx, &t->fiber->ctx);
#endif
  tls_task = NULL;
  if (t->state == CVN_TASK_DONE) {
    free_task_fiber(t->fiber);
    t->fiber = NULL;
  } else if (t->state == CVN_TASK_READY) {
    lock_enter();
    enqueue_local_locked(w, t);
    lock_leave();
  }
}

static void worker_loop(cvn_worker *w) {
  tls_worker = w;
  for (;;) {
    cvn_task *t;
    lock_enter();
    if (g_stop) {
      lock_leave();
      break;
    }
    t = pop_locked(w);
    if (t == NULL) {
      cond_wait(w, 10);
      lock_leave();
      continue;
    }
    if (t->home < 0)
      t->home = w->id;
    lock_leave();
    run_task(w, t);
    if (w->id == 0 && g_root != NULL && g_root->state == CVN_TASK_DONE) {
      lock_enter();
      g_stop = 1;
      {
        int i;
        for (i = 0; i < g_worker_count; i++)
          cond_wake_all(&g_workers[i]);
      }
      lock_leave();
      break;
    }
  }
}

/* ---------------------------------------------------------------- поток --- */

#ifdef _WIN32
static DWORD WINAPI worker_thread_proc(LPVOID p) {
  cvn_worker *w = (cvn_worker *)p;
  tls_worker = w;
  w->sched_handle = ConvertThreadToFiberEx(NULL, FIBER_FLAG_FLOAT_SWITCH);
  if (w->sched_handle == NULL)
    fatal("ConvertThreadToFiberEx failed");
  w->sched = (cvn_fiber *)calloc(1, sizeof *w->sched);
  if (w->sched == NULL)
    fatal("sched fiber allocation failed");
  w->sched->handle = w->sched_handle;
  worker_loop(w);
  ConvertFiberToThread();
  return 0;
}
#else
static void *worker_thread_proc(void *p) {
  cvn_worker *w = (cvn_worker *)p;
  tls_worker = w;
  w->sched = (cvn_fiber *)calloc(1, sizeof *w->sched);
  if (w->sched == NULL)
    fatal("sched allocation failed");
  worker_loop(w);
  return NULL;
}
#endif

static void workers_start(int count, int stack_kb) {
  int i;
  g_worker_count = count;
  g_stack_kb = stack_kb > 0 ? stack_kb : CVN_DEFAULT_STACK_KB;
  g_workers = (cvn_worker *)calloc((size_t)count, sizeof *g_workers);
  if (g_workers == NULL)
    fatal("workers allocation failed");
  for (i = 0; i < count; i++) {
    g_workers[i].id = i;
    cond_init(&g_workers[i]);
  }
#ifdef _WIN32
  {
    cvn_worker *w = &g_workers[0];
    w->sched_handle = ConvertThreadToFiberEx(NULL, FIBER_FLAG_FLOAT_SWITCH);
    if (w->sched_handle == NULL)
      fatal("main ConvertThreadToFiberEx failed");
    w->sched = (cvn_fiber *)calloc(1, sizeof *w->sched);
    if (w->sched == NULL)
      fatal("main sched allocation failed");
    w->sched->handle = w->sched_handle;
  }
#endif
  for (i = 1; i < count; i++) {
#ifdef _WIN32
    g_workers[i].thread = CreateThread(NULL, 0, worker_thread_proc,
                                       &g_workers[i], 0, NULL);
    if (g_workers[i].thread == NULL)
      fatal("worker thread failed");
#else
    if (pthread_create(&g_workers[i].thread, NULL, worker_thread_proc,
                       &g_workers[i]) != 0)
      fatal("worker thread failed");
#endif
  }
}

/* ---------------------------------------------------------------- root ----- */

typedef struct {
  cvn_main_fn fn;
} cvn_root_env;

static void root_entry(void *p) {
  cvn_root_env *e = (cvn_root_env *)p;
  cvn_error err = e->fn();
  cvn_task_finish_current(&err, (int64_t)sizeof err);
}

cvn_error cvn_exec_run(cvn_main_fn fn, int workers, int stack_kb) {
  cvn_root_env *re;
  cvn_task *root;
  cvn_error result;
  int i;

  if (workers <= 0) {
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    workers = (int)si.dwNumberOfProcessors;
#else
    workers = (int)sysconf(_SC_NPROCESSORS_ONLN);
#endif
    if (workers < 1)
      workers = 1;
    if (workers > 4)
      workers = 4;
  }
  if (workers > CVN_MAX_WORKERS)
    workers = CVN_MAX_WORKERS;

  lock_init();
  g_stop = 0;
  g_ready_head = NULL;
  g_ready_tail = NULL;
  g_all_tasks = NULL;
  g_root = NULL;
  g_timer_count = 0;
  g_fd_count = 0;
  g_cmd_head = NULL;
  g_cmd_tail = NULL;

  workers_start(workers, stack_kb);
  loop_start();

  re = (cvn_root_env *)calloc(1, sizeof *re);
  if (re == NULL)
    fatal("root env allocation failed");
  re->fn = fn;
  root = task_alloc(root_entry, re, (int64_t)sizeof *re,
                    (int64_t)sizeof(cvn_error));
  free(re);
  root->home = 0;
  root->worker_id = 0;
  lock_enter();
  root->all_next = g_all_tasks;
  g_all_tasks = root;
  g_root = root;
  enqueue_local_locked(&g_workers[0], root);
  lock_leave();

  worker_loop(&g_workers[0]);

  lock_enter();
  g_stop = 1;
  for (i = 0; i < g_worker_count; i++)
    cond_wake_all(&g_workers[i]);
  lock_leave();
  loop_shutdown();

#ifdef _WIN32
  for (i = 1; i < g_worker_count; i++) {
    if (g_workers[i].thread != NULL) {
      WaitForSingleObject(g_workers[i].thread, INFINITE);
      CloseHandle(g_workers[i].thread);
    }
  }
#else
  for (i = 1; i < g_worker_count; i++)
    pthread_join(g_workers[i].thread, NULL);
#endif

  result = *(cvn_error *)root->result;

  /* Освобождение записей задач и фибр (MVP: только на shutdown). */
  {
    cvn_task *t = g_all_tasks;
    while (t != NULL) {
      cvn_task *next = t->all_next;
      if (t->fiber != NULL)
        free_task_fiber(t->fiber);
      free(t->env);
      free(t->result);
      free(t);
      t = next;
    }
  }
  free(g_timers);
  g_timers = NULL;
  free(g_fds);
  g_fds = NULL;

#ifdef _WIN32
  if (g_workers[0].sched != NULL)
    free(g_workers[0].sched);
  ConvertFiberToThread();
  DeleteCriticalSection(&g_lock);
#else
  if (g_workers[0].sched != NULL)
    free(g_workers[0].sched);
  pthread_mutex_destroy(&g_lock);
#endif
  free(g_workers);
  g_workers = NULL;
  g_worker_count = 0;
  tls_worker = NULL;
  tls_task = NULL;
  return result;
}

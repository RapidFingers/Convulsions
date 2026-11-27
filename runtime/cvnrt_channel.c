/* Ограниченный fiber-aware канал строк (v0.12). */
#include "cvnrt.h"

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

typedef struct cvn_channel {
  cvn_allocator alloc;
  cvn_string *slots;
  int64_t slot_bytes;
  int64_t capacity;
  int64_t head;
  int64_t count;
  bool closed;
#ifdef _WIN32
  CRITICAL_SECTION lock;
#else
  pthread_mutex_t lock;
#endif
} cvn_channel;

static cvn_result_ptr chan_ptr_ok(void *p) {
  cvn_result_ptr r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = p;
  return r;
}

static cvn_result_ptr chan_ptr_err(int32_t code) {
  cvn_result_ptr r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = cvn_error_make(code);
  return r;
}

static cvn_result_string chan_str_ok(cvn_string s) {
  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = s;
  return r;
}

static cvn_result_string chan_str_err(int32_t code) {
  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = cvn_error_make(code);
  return r;
}

static void chan_lock_init(cvn_channel *c) {
#ifdef _WIN32
  InitializeCriticalSection(&c->lock);
#else
  pthread_mutex_init(&c->lock, NULL);
#endif
}

static void chan_lock(cvn_channel *c) {
#ifdef _WIN32
  EnterCriticalSection(&c->lock);
#else
  pthread_mutex_lock(&c->lock);
#endif
}

static void chan_unlock(cvn_channel *c) {
#ifdef _WIN32
  LeaveCriticalSection(&c->lock);
#else
  pthread_mutex_unlock(&c->lock);
#endif
}

static void chan_lock_destroy(cvn_channel *c) {
#ifdef _WIN32
  DeleteCriticalSection(&c->lock);
#else
  pthread_mutex_destroy(&c->lock);
#endif
}

cvn_result_ptr cvn_channel_new(cvn_allocator a, int64_t capacity) {
  cvn_channel *c;
  cvn_result_ptr cr;
  cvn_result_ptr sr;
  int64_t slot_bytes;
  if (capacity <= 0 || capacity > 1000000)
    return chan_ptr_err(CVN_ERR_INVALID);
  if (capacity > INT64_MAX / (int64_t)sizeof(cvn_string))
    return chan_ptr_err(CVN_ERR_INVALID);
  cr = cvn_alloc_aligned(a, (int64_t)sizeof(cvn_channel),
                         (int64_t)_Alignof(cvn_channel));
  if (cr.tag != 0u)
    return chan_ptr_err(cr.u.err.code);
  c = (cvn_channel *)cr.u.ok;
  memset(c, 0, sizeof *c);
  slot_bytes = capacity * (int64_t)sizeof(cvn_string);
  sr = cvn_alloc_aligned(a, slot_bytes, (int64_t)_Alignof(cvn_string));
  if (sr.tag != 0u) {
    cvn_free_bytes(a, c, (int64_t)sizeof *c);
    return chan_ptr_err(sr.u.err.code);
  }
  c->alloc = a;
  c->slots = (cvn_string *)sr.u.ok;
  memset(c->slots, 0, (size_t)slot_bytes);
  c->slot_bytes = slot_bytes;
  c->capacity = capacity;
  c->head = 0;
  c->count = 0;
  c->closed = false;
  chan_lock_init(c);
  return chan_ptr_ok(c);
}

cvn_error cvn_channel_send(void *state, cvn_string value) {
  cvn_channel *c = (cvn_channel *)state;
  if (c == NULL || c->slots == NULL)
    return cvn_error_make(CVN_ERR_INVALID);
  for (;;) {
    int64_t tail;
    chan_lock(c);
    if (c->closed) {
      chan_unlock(c);
      return cvn_error_make(CVN_ERR_CLOSED);
    }
    if (c->count < c->capacity) {
      tail = (c->head + c->count) % c->capacity;
      c->slots[tail] = value;
      c->count++;
      chan_unlock(c);
      return cvn_error_make(CVN_OK);
    }
    chan_unlock(c);
    cvn_task_yield();
  }
}

cvn_result_string cvn_channel_recv(void *state) {
  cvn_channel *c = (cvn_channel *)state;
  if (c == NULL || c->slots == NULL)
    return chan_str_err(CVN_ERR_INVALID);
  for (;;) {
    chan_lock(c);
    if (c->count > 0) {
      cvn_string v = c->slots[c->head];
      memset(&c->slots[c->head], 0, sizeof(cvn_string));
      c->head = (c->head + 1) % c->capacity;
      c->count--;
      chan_unlock(c);
      return chan_str_ok(v);
    }
    if (c->closed) {
      chan_unlock(c);
      return chan_str_err(CVN_ERR_CLOSED);
    }
    chan_unlock(c);
    cvn_task_yield();
  }
}

void cvn_channel_close(void *state) {
  cvn_channel *c = (cvn_channel *)state;
  if (c == NULL || c->slots == NULL)
    return;
  chan_lock(c);
  c->closed = true;
  chan_unlock(c);
}

void cvn_channel_free(void *state) {
  cvn_channel *c = (cvn_channel *)state;
  int64_t i;
  if (c == NULL)
    return;
  if (c->slots != NULL) {
    for (i = 0; i < c->count; i++) {
      int64_t idx = (c->head + i) % c->capacity;
      cvn_str_deinit(&c->slots[idx]);
    }
    cvn_free_bytes(c->alloc, c->slots, c->slot_bytes);
  }
  chan_lock_destroy(c);
  cvn_free_bytes(c->alloc, c, (int64_t)sizeof *c);
}

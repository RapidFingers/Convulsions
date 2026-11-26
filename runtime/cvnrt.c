#include "cvnrt.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

_Static_assert(sizeof(cvn_allocator) == 16, "allocator ABI");
_Static_assert(sizeof(cvn_string) == 40, "string ABI");
_Static_assert(sizeof(cvn_error) == 24, "error ABI");

static void *c_alloc(void *state, size_t size, size_t align) {
  (void)state;
  (void)align;
  return malloc(size);
}

static void *c_realloc(void *state, void *oldp, size_t old_size,
                       size_t new_size, size_t align) {
  (void)state;
  (void)old_size;
  (void)align;
  return realloc(oldp, new_size);
}

static void c_free(void *state, void *p, size_t size) {
  (void)state;
  (void)size;
  free(p);
}

static const cvn_allocator_vtable c_vtable = {
    1u, 0u, "cAllocator", c_alloc, c_realloc, c_free};

cvn_allocator cvn_c_allocator(void) {
  cvn_allocator a;
  a.vtable = &c_vtable;
  a.state = NULL;
  return a;
}

static cvn_error make_error(int32_t code, uintptr_t payload) {
  cvn_error e;
  e.code = code;
  e._pad = 0;
  e.payload = payload;
  e.ctx = NULL;
  return e;
}

static cvn_result_string error_result(cvn_error e) {
  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = e;
  return r;
}

cvn_result_string cvn_str_concat(cvn_allocator a, cvn_string x, cvn_string y) {
  int64_t total, cap;
  char *p;

  if (a.vtable == NULL || a.vtable->alloc == NULL)
    return error_result(make_error(CVN_ERR_NO_ALLOC, 0));
  if (x.len < 0 || y.len < 0 || x.len > INT64_MAX - y.len - 1)
    return error_result(make_error(CVN_ERR_INVALID, 0));

  total = x.len + y.len;
  cap = total + 1;
  p = (char *)a.vtable->alloc(a.state, (size_t)cap, 1);
  if (p == NULL)
    return error_result(make_error(CVN_ERR_OOM, 0));

  if (x.len > 0)
    memcpy(p, x.ptr, (size_t)x.len);
  if (y.len > 0)
    memcpy(p + x.len, y.ptr, (size_t)y.len);
  p[total] = '\0';

  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok.ptr = p;
  r.u.ok.len = total;
  r.u.ok.cap = cap;
  r.u.ok.alloc = a;
  return r;
}

void cvn_str_deinit(cvn_string *s) {
  if (s == NULL)
    return;
  if (s->ptr != NULL && s->alloc.vtable != NULL && s->alloc.vtable->free != NULL)
    s->alloc.vtable->free(s->alloc.state, s->ptr, (size_t)s->cap);
  memset(s, 0, sizeof *s);
}

cvn_error cvn_io_println(cvn_string s) {
  if (s.len < 0)
    return make_error(CVN_ERR_INVALID, 0);
  if (s.len > 0) {
    size_t want = (size_t)s.len;
    if (fwrite(s.ptr, 1, want, stdout) != want)
      return make_error(CVN_ERR_IO, (uintptr_t)errno);
  }
  if (fputc('\n', stdout) == EOF)
    return make_error(CVN_ERR_IO, (uintptr_t)errno);
  if (fflush(stdout) != 0)
    return make_error(CVN_ERR_IO, (uintptr_t)errno);
  return make_error(CVN_OK, 0);
}

void cvn_rt_init(void) {
#ifdef _WIN32
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
}

const char *cvn_error_message(int32_t code) {
  switch (code) {
    case CVN_OK: return "ok";
    case CVN_ERR_OOM: return "out of memory";
    case CVN_ERR_NO_ALLOC: return "no allocator";
    case CVN_ERR_INVALID: return "invalid argument";
    case CVN_ERR_BAD_ALIGN: return "bad alignment";
    case CVN_ERR_BOUNDS: return "out of bounds";
    case CVN_ERR_IO: return "i/o error";
    case CVN_ERR_EOF: return "end of file";
    case CVN_ERR_CANCELLED: return "cancelled";
    default: return "error";
  }
}

void cvn_rt_report_error(cvn_error e) {
  fprintf(stderr, "error[%d]: %s\n", (int)e.code, cvn_error_message(e.code));
  if (e.code == CVN_ERR_IO && e.payload != 0)
    fprintf(stderr, "  errno: %d\n", (int)e.payload);
  fflush(stderr);
}

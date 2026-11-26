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

static char cvn_empty_buf[1] = {0};
const cvn_string cvn_str_empty = {cvn_empty_buf, 0, 1, {NULL, NULL}};

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

/* ---------------------------------------------------------------- UTF-8 --- */

static bool cvn_rune_is_scalar(uint32_t r) {
  return r <= 0x10FFFFu && !(r >= 0xD800u && r <= 0xDFFFu);
}

/* 1 — валидная последовательность; 0 — невалидная (out=U+FFFD, width=1). */
static int cvn_utf8_decode(const unsigned char *p, int64_t len, int64_t i,
                           uint32_t *out, int64_t *width) {
  unsigned char b0, b1, b2, b3;
  *out = 0xFFFDu;
  *width = 1;
  if (p == NULL || i < 0 || i >= len)
    return 0;
  b0 = p[i];
  if (b0 < 0x80u) {
    *out = b0;
    return 1;
  }
  if (b0 >= 0xC2u && b0 <= 0xDFu) {
    if (i + 1 >= len)
      return 0;
    b1 = p[i + 1];
    if ((b1 & 0xC0u) != 0x80u)
      return 0;
    *out = ((uint32_t)(b0 & 0x1Fu) << 6) | (uint32_t)(b1 & 0x3Fu);
    *width = 2;
    return 1;
  }
  if (b0 >= 0xE0u && b0 <= 0xEFu) {
    if (i + 2 >= len)
      return 0;
    b1 = p[i + 1];
    b2 = p[i + 2];
    if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u)
      return 0;
    if (b0 == 0xE0u && b1 < 0xA0u)
      return 0; /* overlong */
    if (b0 == 0xEDu && b1 >= 0xA0u)
      return 0; /* surrogate */
    *out = ((uint32_t)(b0 & 0x0Fu) << 12) |
           ((uint32_t)(b1 & 0x3Fu) << 6) | (uint32_t)(b2 & 0x3Fu);
    *width = 3;
    return 1;
  }
  if (b0 >= 0xF0u && b0 <= 0xF4u) {
    if (i + 3 >= len)
      return 0;
    b1 = p[i + 1];
    b2 = p[i + 2];
    b3 = p[i + 3];
    if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u ||
        (b3 & 0xC0u) != 0x80u)
      return 0;
    if (b0 == 0xF0u && b1 < 0x90u)
      return 0; /* overlong */
    if (b0 == 0xF4u && b1 > 0x8Fu)
      return 0; /* > U+10FFFF */
    *out = ((uint32_t)(b0 & 0x07u) << 18) |
           ((uint32_t)(b1 & 0x3Fu) << 12) |
           ((uint32_t)(b2 & 0x3Fu) << 6) | (uint32_t)(b3 & 0x3Fu);
    *width = 4;
    return 1;
  }
  return 0;
}

bool cvn_utf8_validate(cvn_string s) {
  int64_t i = 0;
  if (s.len < 0 || (s.len > 0 && s.ptr == NULL))
    return false;
  while (i < s.len) {
    uint32_t r;
    int64_t w;
    if (!cvn_utf8_decode((const unsigned char *)s.ptr, s.len, i, &r, &w))
      return false;
    i += w;
  }
  return true;
}

static cvn_result_u32 err_u32(int32_t code) {
  cvn_result_u32 res;
  memset(&res, 0, sizeof res);
  res.tag = 1u;
  res.u.err = make_error(code, 0);
  return res;
}

static cvn_result_i64 err_i64(int32_t code) {
  cvn_result_i64 res;
  memset(&res, 0, sizeof res);
  res.tag = 1u;
  res.u.err = make_error(code, 0);
  return res;
}

cvn_result_u32 cvn_str_rune_at(cvn_string s, int64_t byte_idx) {
  uint32_t r;
  int64_t w;
  cvn_result_u32 res;
  if (s.len < 0 || byte_idx < 0 || byte_idx >= s.len)
    return err_u32(CVN_ERR_BOUNDS);
  if (!cvn_utf8_decode((const unsigned char *)s.ptr, s.len, byte_idx, &r, &w))
    return err_u32(CVN_ERR_INVALID);
  memset(&res, 0, sizeof res);
  res.tag = 0u;
  res.u.ok = r;
  return res;
}

cvn_result_i64 cvn_str_rune_offset(cvn_string s, int64_t rune_idx) {
  int64_t i = 0;
  int64_t k = 0;
  cvn_result_i64 res;
  if (rune_idx < 0 || s.len < 0)
    return err_i64(CVN_ERR_BOUNDS);
  while (k < rune_idx) {
    uint32_t r;
    int64_t w;
    if (i >= s.len)
      return err_i64(CVN_ERR_BOUNDS);
    if (!cvn_utf8_decode((const unsigned char *)s.ptr, s.len, i, &r, &w))
      return err_i64(CVN_ERR_INVALID);
    i += w;
    k++;
  }
  memset(&res, 0, sizeof res);
  res.tag = 0u;
  res.u.ok = i;
  return res;
}

int64_t cvn_str_rune_len(cvn_string s) {
  int64_t i = 0;
  int64_t n = 0;
  if (s.len < 0)
    return 0;
  while (i < s.len) {
    uint32_t r;
    int64_t w;
    (void)cvn_utf8_decode((const unsigned char *)s.ptr, s.len, i, &r, &w);
    i += w;
    n++;
  }
  return n;
}

cvn_result_u32 cvn_rune_checked(int64_t x) {
  cvn_result_u32 res;
  if (x < 0 || x > 0x10FFFF)
    return err_u32(CVN_ERR_INVALID);
  if (!cvn_rune_is_scalar((uint32_t)x))
    return err_u32(CVN_ERR_INVALID);
  memset(&res, 0, sizeof res);
  res.tag = 0u;
  res.u.ok = (uint32_t)x;
  return res;
}

cvn_result_string cvn_str_from_rune(cvn_allocator a, uint32_t r) {
  unsigned char buf[4];
  int n;
  char *p;
  cvn_result_string res;
  if (!cvn_rune_is_scalar(r))
    return error_result(make_error(CVN_ERR_INVALID, 0));
  if (r < 0x80u) {
    buf[0] = (unsigned char)r;
    n = 1;
  } else if (r < 0x800u) {
    buf[0] = (unsigned char)(0xC0u | (r >> 6));
    buf[1] = (unsigned char)(0x80u | (r & 0x3Fu));
    n = 2;
  } else if (r < 0x10000u) {
    buf[0] = (unsigned char)(0xE0u | (r >> 12));
    buf[1] = (unsigned char)(0x80u | ((r >> 6) & 0x3Fu));
    buf[2] = (unsigned char)(0x80u | (r & 0x3Fu));
    n = 3;
  } else {
    buf[0] = (unsigned char)(0xF0u | (r >> 18));
    buf[1] = (unsigned char)(0x80u | ((r >> 12) & 0x3Fu));
    buf[2] = (unsigned char)(0x80u | ((r >> 6) & 0x3Fu));
    buf[3] = (unsigned char)(0x80u | (r & 0x3Fu));
    n = 4;
  }
  if (a.vtable == NULL || a.vtable->alloc == NULL)
    return error_result(make_error(CVN_ERR_NO_ALLOC, 0));
  p = (char *)a.vtable->alloc(a.state, (size_t)n + 1, 1);
  if (p == NULL)
    return error_result(make_error(CVN_ERR_OOM, 0));
  memcpy(p, buf, (size_t)n);
  p[n] = '\0';
  memset(&res, 0, sizeof res);
  res.tag = 0u;
  res.u.ok.ptr = p;
  res.u.ok.len = n;
  res.u.ok.cap = n + 1;
  res.u.ok.alloc = a;
  return res;
}

void cvn_rt_assert_fail(const char *where, const char *msg) {
  fprintf(stderr, "assertion failed: %s", where != NULL ? where : "?");
  if (msg != NULL && msg[0] != '\0')
    fprintf(stderr, ": %s", msg);
  fputc('\n', stderr);
  fflush(stderr);
  exit(2);
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

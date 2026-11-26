/*
 * cvnrt.h — минимальный рантайм Convulsions (kernel MVP).
 *
 * ABI зафиксирован README §3.4/§5.1/§8.2:
 *   cvn_allocator : 16 байт  {vtable, state}
 *   cvn_string    : 40 байт  {ptr, len, cap, alloc}
 *   cvn_error     : 24 байта {code, pad, payload, ctx}
 */
#ifndef CVNRT_H
#define CVNRT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Коды ошибок; порядок совпадает с README §5.1. */
enum {
  CVN_OK             = 0,
  CVN_ERR_OOM        = 1,
  CVN_ERR_NO_ALLOC   = 2,
  CVN_ERR_INVALID    = 3,
  CVN_ERR_BAD_ALIGN  = 4,
  CVN_ERR_BOUNDS     = 5,
  CVN_ERR_IO         = 6,
  CVN_ERR_EOF        = 7,
  CVN_ERR_CANCELLED  = 8,
  CVN_ERR_CUSTOM     = 0x1000
};

typedef struct cvn_allocator_vtable cvn_allocator_vtable;

typedef struct cvn_allocator {
  const cvn_allocator_vtable *vtable;
  void *state;
} cvn_allocator;

struct cvn_allocator_vtable {
  uint32_t abi_version;
  uint32_t flags; /* bit0: alloc зануляет; bit2: потокобезопасен */
  const char *name;
  void *(*alloc)(void *state, size_t size, size_t align);
  void *(*realloc)(void *state, void *oldp, size_t old_size,
                   size_t new_size, size_t align);
  void  (*free)(void *state, void *p, size_t size);
};

/* NUL-инвариант: ptr[len] == '\0', cap >= len + 1. */
typedef struct cvn_string {
  char *ptr;
  int64_t len;
  int64_t cap;
  cvn_allocator alloc;
} cvn_string;

typedef struct cvn_error {
  int32_t code;
  int32_t _pad;
  uintptr_t payload;
  void *ctx;
} cvn_error;

/* !string */
typedef struct cvn_result_string {
  uint32_t tag;
  uint32_t _pad;
  union {
    cvn_string ok;
    cvn_error err;
  } u;
} cvn_result_string;

cvn_allocator     cvn_c_allocator(void);
cvn_result_string cvn_str_concat(cvn_allocator a, cvn_string x, cvn_string y);
void              cvn_str_deinit(cvn_string *s);
cvn_error         cvn_io_println(cvn_string s);
void              cvn_rt_init(void);
void              cvn_rt_report_error(cvn_error e);
const char       *cvn_error_message(int32_t code);

#ifdef __cplusplus
}
#endif

#endif /* CVNRT_H */

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
  CVN_ERR_TASK       = 9,
  CVN_ERR_CLOSED     = 10,
  CVN_ERR_WOULD_BLOCK = 11,
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

/* Валидная пустая строка: ptr[len] == '\0', cap = 1, аллокатор нулевой. */
extern const cvn_string cvn_str_empty;

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

/* !Rune (uint32_t) и !int — канонические типы: cgen их не дублирует. */
typedef struct cvn_result_u32 {
  uint32_t tag;
  uint32_t _pad;
  union {
    uint32_t ok;
    cvn_error err;
  } u;
} cvn_result_u32;

typedef struct cvn_result_i64 {
  uint32_t tag;
  uint32_t _pad;
  union {
    int64_t ok;
    cvn_error err;
  } u;
} cvn_result_i64;

/* !ptr T — указатель (в C хранится как void*, конверсия в T* неявная). */
typedef struct cvn_result_ptr {
  uint32_t tag;
  uint32_t _pad;
  union {
    void *ok;
    cvn_error err;
  } u;
} cvn_result_ptr;

cvn_allocator     cvn_null_allocator(void);
cvn_allocator     cvn_c_allocator(void);
cvn_allocator     cvn_page_allocator(void);
cvn_allocator     cvn_fixed_allocator(void *buf, int64_t size);
cvn_allocator     cvn_arena_allocator(cvn_allocator backing, int64_t chunk);
cvn_allocator     cvn_stack_allocator(cvn_allocator backing, int64_t size);
cvn_allocator     cvn_debug_allocator(cvn_allocator backing);
cvn_allocator     cvn_task_allocator(void);

cvn_result_ptr    cvn_alloc_bytes(cvn_allocator a, int64_t n);
cvn_result_ptr    cvn_alloc_aligned(cvn_allocator a, int64_t n, int64_t align);
cvn_result_ptr    cvn_alloc_tagged(cvn_allocator a, int64_t n, int64_t align,
                                   const char *tag, const char *where);
cvn_result_ptr    cvn_alloc_zeroed(cvn_allocator a, int64_t n);
cvn_result_ptr    cvn_realloc_bytes(cvn_allocator a, void *p, int64_t oldn,
                                    int64_t newn);
cvn_result_ptr    cvn_realloc_aligned(cvn_allocator a, void *p, int64_t oldn,
                                      int64_t newn, int64_t align);
void              cvn_free_bytes(cvn_allocator a, void *p, int64_t n);

void              cvn_fixed_reset(cvn_allocator a);
void              cvn_fixed_deinit(cvn_allocator a);
void              cvn_arena_reset(cvn_allocator a);
void              cvn_arena_deinit(cvn_allocator a);
int64_t           cvn_stack_mark(cvn_allocator a);
void              cvn_stack_reset(cvn_allocator a, int64_t mark);
void              cvn_stack_deinit(cvn_allocator a);
bool              cvn_debug_check(cvn_allocator a);
int64_t           cvn_debug_report(cvn_allocator a);
void              cvn_debug_fail_on_leak(cvn_allocator a);
void              cvn_debug_deinit(cvn_allocator a);

bool              cvn_is_aligned(void *p, int64_t align);
bool              cvn_is_null_ptr(void *p);
int64_t           cvn_ptr_addr(void *p);
void              cvn_mem_fill(void *p, uint8_t v, int64_t n);
void              cvn_mem_copy(void *dst, void *src, int64_t n);
uint8_t           cvn_mem_byte(void *p, int64_t i);
void              cvn_mem_set_byte(void *p, int64_t i, uint8_t v);

/* --- Fiber executor: задачи, пул воркеров, event loop ------------------ */

typedef struct cvn_task cvn_task;
typedef void (*cvn_task_fn)(void *env);
typedef cvn_error (*cvn_main_fn)(void);

enum { CVN_IO_READ = 1, CVN_IO_WRITE = 2, CVN_IO_ERR = 4 };

cvn_task *cvn_task_spawn(cvn_task_fn fn, const void *env,
                         int64_t env_size, int64_t result_size);
void      cvn_task_finish_current(const void *result, int64_t result_size);
void     *cvn_task_await(cvn_task *t);
void      cvn_sleep_ms(int64_t ms);
void      cvn_task_yield(void);

/* Fiber-aware строковый канал (v0.12). */
cvn_result_ptr    cvn_channel_new(cvn_allocator a, int64_t capacity);
cvn_error         cvn_channel_send(void *state, cvn_string value);
cvn_result_string cvn_channel_recv(void *state);
void              cvn_channel_close(void *state);
void              cvn_channel_free(void *state);
int       cvn_worker_id(void);
cvn_error cvn_error_make(int32_t code);
int       cvn_task_wait_fd(int fd, uint32_t events);

cvn_error cvn_exec_run(cvn_main_fn fn, int workers, int stack_kb);

cvn_result_string cvn_str_concat(cvn_allocator a, cvn_string x, cvn_string y);
void              cvn_str_deinit(cvn_string *s);
bool              cvn_str_equal(cvn_string x, cvn_string y);
cvn_error         cvn_io_println(cvn_string s);

/* UTF-8: декодирование, проверка, обратное кодирование. */
bool              cvn_utf8_validate(cvn_string s);
cvn_result_u32    cvn_str_rune_at(cvn_string s, int64_t byte_idx);
cvn_result_i64    cvn_str_rune_offset(cvn_string s, int64_t rune_idx);
int64_t           cvn_str_rune_len(cvn_string s);
cvn_result_u32    cvn_rune_checked(int64_t x);
cvn_result_string cvn_str_from_rune(cvn_allocator a, uint32_t r);

void              cvn_rt_init(void);
void              cvn_rt_report_error(cvn_error e);
void              cvn_rt_assert_fail(const char *where, const char *msg);
void              cvn_panic(cvn_string msg);
const char       *cvn_error_message(int32_t code);

#ifdef __cplusplus
}
#endif

#endif /* CVNRT_H */

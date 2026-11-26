/* C-юниты аллокаторов: контракт cvnrt.h (без фатальных путей). */
#include "cvnrt.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_null(void) {
  cvn_allocator a = cvn_null_allocator();
  cvn_result_ptr r = cvn_alloc_bytes(a, 8);
  assert(r.tag == 1u && r.u.err.code == CVN_ERR_NO_ALLOC);
  cvn_free_bytes(a, NULL, 8);
}

static void test_c(void) {
  cvn_allocator a = cvn_c_allocator();
  cvn_result_ptr r = cvn_alloc_bytes(a, 64);
  cvn_result_ptr q;
  int64_t i;
  assert(r.tag == 0u && r.u.ok != NULL);
  memset(r.u.ok, 7, 64);
  q = cvn_realloc_bytes(a, r.u.ok, 64, 128);
  assert(q.tag == 0u && q.u.ok != NULL);
  assert(((unsigned char *)q.u.ok)[0] == 7);
  cvn_free_bytes(a, q.u.ok, 128);

  r = cvn_alloc_zeroed(a, 32);
  assert(r.tag == 0u);
  for (i = 0; i < 32; i++)
    assert(((unsigned char *)r.u.ok)[i] == 0);
  cvn_free_bytes(a, r.u.ok, 32);

  r = cvn_alloc_aligned(a, 8, 3);
  assert(r.tag == 1u && r.u.err.code == CVN_ERR_BAD_ALIGN);
  r = cvn_alloc_bytes(a, 0);
  assert(r.tag == 1u && r.u.err.code == CVN_ERR_INVALID);
}

static void test_fixed(void) {
  char buf[128];
  cvn_allocator fx = cvn_fixed_allocator(buf, 128);
  cvn_result_ptr r;
  assert(fx.vtable != NULL);
  r = cvn_alloc_bytes(fx, 32);
  assert(r.tag == 0u);
  r = cvn_alloc_bytes(fx, 32);
  assert(r.tag == 0u);
  r = cvn_alloc_bytes(fx, 80);
  assert(r.tag == 1u && r.u.err.code == CVN_ERR_OOM);
  cvn_fixed_reset(fx);
  r = cvn_alloc_bytes(fx, 64);
  assert(r.tag == 0u);
  cvn_fixed_deinit(fx);
}

static void test_page(void) {
  cvn_allocator a = cvn_page_allocator();
  cvn_result_ptr r = cvn_alloc_aligned(a, 100, 4096);
  assert(r.tag == 0u && r.u.ok != NULL);
  assert(cvn_is_aligned(r.u.ok, 65536));
  assert(cvn_is_aligned(r.u.ok, 4096));
  cvn_free_bytes(a, r.u.ok, 100);
}

static void test_arena(void) {
  cvn_allocator a = cvn_arena_allocator(cvn_c_allocator(), 64);
  cvn_result_ptr r1 = cvn_alloc_bytes(a, 10);
  cvn_result_ptr r2 = cvn_alloc_bytes(a, 300);
  assert(r1.tag == 0u && r2.tag == 0u);
  cvn_mem_fill(r1.u.ok, 0xAB, 10);
  assert(cvn_mem_byte(r1.u.ok, 9) == 0xAB);
  cvn_arena_reset(a);
  r1 = cvn_alloc_bytes(a, 10);
  assert(r1.tag == 0u);
  cvn_arena_deinit(a);
}

static void test_stack(void) {
  cvn_allocator a = cvn_stack_allocator(cvn_c_allocator(), 256);
  int64_t mark = cvn_stack_mark(a);
  cvn_result_ptr p = cvn_alloc_bytes(a, 16);
  cvn_result_ptr q = cvn_alloc_bytes(a, 16);
  assert(p.tag == 0u && q.tag == 0u);
  cvn_free_bytes(a, q.u.ok, 16);
  cvn_stack_reset(a, mark);
  p = cvn_alloc_bytes(a, 32);
  assert(p.tag == 0u);
  cvn_stack_deinit(a);
}

static void test_debug(void) {
  cvn_allocator d = cvn_debug_allocator(cvn_c_allocator());
  cvn_result_ptr p = cvn_alloc_bytes(d, 32);
  cvn_result_ptr leak;
  assert(p.tag == 0u && p.u.ok != NULL);
  assert(cvn_debug_check(d));
  ((unsigned char *)p.u.ok)[32] = 0x00; /* испортить tail-redzone */
  assert(!cvn_debug_check(d));
  ((unsigned char *)p.u.ok)[32] = 0xFD;
  assert(cvn_debug_check(d));

  leak = cvn_alloc_bytes(d, 8);
  assert(leak.tag == 0u);
  assert(cvn_debug_report(d) == 2);
  cvn_free_bytes(d, leak.u.ok, 8);
  assert(cvn_debug_report(d) == 1);
  cvn_free_bytes(d, p.u.ok, 32);
  assert(cvn_debug_report(d) == 0);
  cvn_debug_deinit(d);
}

static void test_tagged(void) {
  cvn_allocator d = cvn_debug_allocator(cvn_c_allocator());
  cvn_result_ptr p = cvn_alloc_tagged(d, 16, 8, "TagC", "test_alloc.c:42");
  assert(p.tag == 0u && p.u.ok != NULL);
  assert(cvn_debug_report(d) == 1);
  cvn_free_bytes(d, p.u.ok, 16);
  assert(cvn_debug_report(d) == 0);
  cvn_debug_deinit(d);
}

static void test_helpers(void) {
  char a[8];
  char b[8];
  int64_t i;
  cvn_mem_fill(a, 0x11, 8);
  for (i = 0; i < 8; i++)
    assert(cvn_mem_byte(a, i) == 0x11);
  cvn_mem_copy(b, a, 8);
  assert(cvn_mem_byte(b, 0) == 0x11);
  cvn_mem_set_byte(b, 0, 0x22);
  assert(cvn_mem_byte(b, 0) == 0x22);
  assert(cvn_ptr_addr(a) != 0);
  assert(cvn_is_null_ptr(NULL));
  assert(!cvn_is_null_ptr(a));
  assert(cvn_is_aligned(a, 1));
}

int main(void) {
  test_null();
  test_c();
  test_fixed();
  test_page();
  test_arena();
  test_stack();
  test_debug();
  test_tagged();
  test_helpers();
  printf("c-alloc-ok\n");
  return 0;
}

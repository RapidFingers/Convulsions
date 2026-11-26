/* C-юнит-тесты UTF-8 рантайма: контракт cvnrt.h. */
#include "cvnrt.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static cvn_string mk(const char *p, int64_t len) {
  cvn_string s;
  memset(&s, 0, sizeof s);
  s.ptr = (char *)p;
  s.len = len;
  s.cap = len + 1;
  return s;
}

static void test_validate(void) {
  assert(cvn_utf8_validate(mk("", 0)));
  assert(cvn_utf8_validate(mk("A", 1)));
  assert(cvn_utf8_validate(mk("\xC2\xA2", 2)));
  assert(cvn_utf8_validate(mk("\xE2\x82\xAC", 3)));
  assert(cvn_utf8_validate(mk("\xF0\x9F\x99\x82", 4)));
  assert(cvn_utf8_validate(mk("a\0b", 3)));

  assert(!cvn_utf8_validate(mk("\x80", 1)));
  assert(!cvn_utf8_validate(mk("\xC0\x80", 2)));        /* overlong */
  assert(!cvn_utf8_validate(mk("\xC1\xBF", 2)));        /* overlong */
  assert(!cvn_utf8_validate(mk("\xE0\x80\x80", 3)));    /* overlong */
  assert(!cvn_utf8_validate(mk("\xED\xA0\x80", 3)));    /* surrogate */
  assert(!cvn_utf8_validate(mk("\xF4\x90\x80\x80", 4)));/* > U+10FFFF */
  assert(!cvn_utf8_validate(mk("\xF5\x80\x80\x80", 4)));/* bad lead */
  assert(!cvn_utf8_validate(mk("\xE2\x82", 2)));        /* truncated */
  assert(!cvn_utf8_validate(mk("\xC2", 1)));            /* truncated */
  assert(!cvn_utf8_validate(mk("\xFF", 1)));
}

static void test_rune_at(void) {
  cvn_string s = mk("a\xC2\xA2\xE2\x82\xAC", 6);
  cvn_result_u32 r;

  r = cvn_str_rune_at(s, 0);
  assert(r.tag == 0 && r.u.ok == 0x61u);
  r = cvn_str_rune_at(s, 1);
  assert(r.tag == 0 && r.u.ok == 0xA2u);
  r = cvn_str_rune_at(s, 3);
  assert(r.tag == 0 && r.u.ok == 0x20ACu);

  r = cvn_str_rune_at(s, 2); /* continuation */
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
  r = cvn_str_rune_at(s, -1);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_BOUNDS);
  r = cvn_str_rune_at(s, 6);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_BOUNDS);
  r = cvn_str_rune_at(mk("\xE2\x82", 2), 0);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
  r = cvn_str_rune_at(mk("", 0), 0);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_BOUNDS);
}

static void test_rune_offset(void) {
  cvn_string s = mk("a\xC2\xA2\xE2\x82\xAC", 6);
  cvn_result_i64 r;

  r = cvn_str_rune_offset(s, 0);
  assert(r.tag == 0 && r.u.ok == 0);
  r = cvn_str_rune_offset(s, 1);
  assert(r.tag == 0 && r.u.ok == 1);
  r = cvn_str_rune_offset(s, 2);
  assert(r.tag == 0 && r.u.ok == 3);
  r = cvn_str_rune_offset(s, 3);
  assert(r.tag == 0 && r.u.ok == 6);

  r = cvn_str_rune_offset(s, 4);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_BOUNDS);
  r = cvn_str_rune_offset(s, -1);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_BOUNDS);
  r = cvn_str_rune_offset(mk("\xC0\x80", 2), 0);
  assert(r.tag == 0 && r.u.ok == 0);
  r = cvn_str_rune_offset(mk("\xC0\x80", 2), 1);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
}

static void test_rune_len(void) {
  assert(cvn_str_rune_len(mk("", 0)) == 0);
  assert(cvn_str_rune_len(mk("abc", 3)) == 3);
  assert(cvn_str_rune_len(mk("\xE2\x82\xAC", 3)) == 1);
  assert(cvn_str_rune_len(mk("a\0b", 3)) == 3);
  assert(cvn_str_rune_len(mk("\xE2\x82", 2)) == 2);
  assert(cvn_str_rune_len(mk("a\xFF", 2)) == 2);
}

static void test_rune_checked(void) {
  cvn_result_u32 r;
  r = cvn_rune_checked(0x41);
  assert(r.tag == 0 && r.u.ok == 0x41u);
  r = cvn_rune_checked(0x10FFFF);
  assert(r.tag == 0 && r.u.ok == 0x10FFFFu);
  r = cvn_rune_checked(0xD800);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
  r = cvn_rune_checked(0x110000);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
  r = cvn_rune_checked(-1);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
}

static void test_from_rune(void) {
  cvn_allocator a = cvn_c_allocator();
  cvn_result_string r;
  cvn_string s;

  r = cvn_str_from_rune(a, 0x41);
  assert(r.tag == 0 && r.u.ok.len == 1 && r.u.ok.ptr[0] == 'A');
  s = r.u.ok;
  cvn_str_deinit(&s);

  r = cvn_str_from_rune(a, 0x20AC);
  assert(r.tag == 0 && r.u.ok.len == 3);
  s = r.u.ok;
  assert(cvn_utf8_validate(s));
  assert(cvn_str_rune_len(s) == 1);
  cvn_str_deinit(&s);

  r = cvn_str_from_rune(a, 0x1F600);
  assert(r.tag == 0 && r.u.ok.len == 4);
  s = r.u.ok;
  assert((unsigned char)s.ptr[0] == 0xF0u);
  cvn_str_deinit(&s);

  r = cvn_str_from_rune(a, 0xD800);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
  r = cvn_str_from_rune(a, 0x110000u);
  assert(r.tag == 1 && r.u.err.code == CVN_ERR_INVALID);
}

int main(void) {
  test_validate();
  test_rune_at();
  test_rune_offset();
  test_rune_len();
  test_rune_checked();
  test_from_rune();
  printf("c-utf-ok\n");
  return 0;
}

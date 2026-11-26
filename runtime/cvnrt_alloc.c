/* Аллокаторы Convulsions: vtable-значения, byte-API, debug-обёртка. */
#include "cvnrt.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

#define CVN_PAGE_SIZE 65536

#define CVN_FIXED_MAGIC 0x46584D31u
#define CVN_ARENA_MAGIC 0x41524D31u
#define CVN_STACK_MAGIC 0x53544B31u
#define CVN_DEBUG_MAGIC 0x44424731u

#define CVN_DBG_MAGIC 0x44564731u
#define CVN_DBG_DEAD 0x44564700u
#define CVN_DBG_HDR 64
#define CVN_DBG_TAIL 16
#define CVN_DBG_TAIL_FILL 0xFDu

static void alloc_fatal(const char *msg) {
  fprintf(stderr, "allocator error: %s\n", msg);
  fflush(stderr);
  exit(3);
}

static int is_pow2(int64_t x) { return x > 0 && (x & (x - 1)) == 0; }

static int64_t align_up(int64_t v, int64_t a) {
  if (a <= 1)
    return v;
  return (v + a - 1) & ~(a - 1);
}

/* --------------------------------------------------------------- null --- */

static void *null_alloc(void *s, size_t n, size_t a) {
  (void)s; (void)n; (void)a;
  return NULL;
}
static void *null_realloc(void *s, void *p, size_t o, size_t n, size_t a) {
  (void)s; (void)p; (void)o; (void)n; (void)a;
  return NULL;
}
static void null_free(void *s, void *p, size_t n) {
  (void)s; (void)p; (void)n;
}

static const cvn_allocator_vtable null_vtable = {
    1u, 0u, "nullAllocator", null_alloc, null_realloc, null_free};

cvn_allocator cvn_null_allocator(void) {
  cvn_allocator a;
  a.vtable = &null_vtable;
  a.state = NULL;
  return a;
}

/* ----------------------------------------------------------------- c --- */

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
    1u, 4u, "cAllocator", c_alloc, c_realloc, c_free};

cvn_allocator cvn_c_allocator(void) {
  cvn_allocator a;
  a.vtable = &c_vtable;
  a.state = NULL;
  return a;
}

/* -------------------------------------------------------------- page --- */

static void *page_alloc(void *state, size_t size, size_t align) {
  size_t rounded;
  (void)state;
  (void)align;
  if (size == 0 || size > (size_t)INT64_MAX - CVN_PAGE_SIZE)
    return NULL;
  rounded = (size + CVN_PAGE_SIZE - 1) & ~((size_t)CVN_PAGE_SIZE - 1);
#ifdef _WIN32
  return VirtualAlloc(NULL, rounded, MEM_COMMIT | MEM_RESERVE,
                      PAGE_READWRITE);
#else
  {
    void *p = mmap(NULL, rounded, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
  }
#endif
}

static void page_free(void *state, void *p, size_t size) {
  size_t rounded;
  (void)state;
  if (p == NULL)
    return;
  rounded = (size + CVN_PAGE_SIZE - 1) & ~((size_t)CVN_PAGE_SIZE - 1);
#ifdef _WIN32
  (void)rounded;
  VirtualFree(p, 0, MEM_RELEASE);
#else
  munmap(p, rounded);
#endif
}

static void *page_realloc(void *state, void *oldp, size_t old_size,
                          size_t new_size, size_t align) {
  void *p = page_alloc(state, new_size, align);
  if (p == NULL)
    return NULL;
  if (oldp != NULL) {
    size_t n = old_size < new_size ? old_size : new_size;
    memcpy(p, oldp, n);
    page_free(state, oldp, old_size);
  }
  return p;
}

static const cvn_allocator_vtable page_vtable = {
    1u, 4u, "pageAllocator", page_alloc, page_realloc, page_free};

cvn_allocator cvn_page_allocator(void) {
  cvn_allocator a;
  a.vtable = &page_vtable;
  a.state = NULL;
  return a;
}

/* ------------------------------------------------------------- fixed --- */

typedef struct {
  uint32_t magic;
  char *buf;
  int64_t size;
  int64_t used;
} fixed_state;

static void *fixed_alloc(void *st, size_t size, size_t align) {
  fixed_state *s = (fixed_state *)st;
  int64_t a = (int64_t)align;
  int64_t off;
  if (s == NULL || s->magic != CVN_FIXED_MAGIC || size == 0 || !is_pow2(a))
    return NULL;
  off = align_up(s->used, a);
  if (off < 0 || off + (int64_t)size > s->size)
    return NULL;
  s->used = off + (int64_t)size;
  return s->buf + off;
}

static void *fixed_realloc(void *st, void *oldp, size_t old_size,
                           size_t new_size, size_t align) {
  void *p;
  size_t n;
  if (oldp == NULL)
    return fixed_alloc(st, new_size, align);
  p = fixed_alloc(st, new_size, align);
  if (p == NULL)
    return NULL;
  n = old_size < new_size ? old_size : new_size;
  memcpy(p, oldp, n);
  return p;
}

static void fixed_free(void *st, void *p, size_t size) {
  (void)st; (void)p; (void)size;
}

static const cvn_allocator_vtable fixed_vtable = {
    1u, 0u, "fixedAllocator", fixed_alloc, fixed_realloc, fixed_free};

cvn_allocator cvn_fixed_allocator(void *buf, int64_t size) {
  fixed_state *s;
  cvn_allocator a;
  if (buf == NULL || size <= 0)
    return cvn_null_allocator();
  s = (fixed_state *)malloc(sizeof *s);
  if (s == NULL)
    return cvn_null_allocator();
  s->magic = CVN_FIXED_MAGIC;
  s->buf = (char *)buf;
  s->size = size;
  s->used = 0;
  a.vtable = &fixed_vtable;
  a.state = s;
  return a;
}

void cvn_fixed_reset(cvn_allocator a) {
  fixed_state *s = (fixed_state *)a.state;
  if (s != NULL && s->magic == CVN_FIXED_MAGIC)
    s->used = 0;
}

void cvn_fixed_deinit(cvn_allocator a) {
  fixed_state *s = (fixed_state *)a.state;
  if (s != NULL && s->magic == CVN_FIXED_MAGIC) {
    s->magic = 0;
    free(s);
  }
}

/* ------------------------------------------------------------- arena --- */

typedef struct arena_chunk {
  struct arena_chunk *next;
  char *data;
  int64_t cap;
  int64_t used;
} arena_chunk;

typedef struct {
  uint32_t magic;
  cvn_allocator backing;
  int64_t chunk_size;
  arena_chunk *head;
} arena_state;

static void arena_free_chunks(arena_state *s) {
  arena_chunk *c = s->head;
  while (c != NULL) {
    arena_chunk *next = c->next;
    if (c->data != NULL && s->backing.vtable != NULL &&
        s->backing.vtable->free != NULL)
      s->backing.vtable->free(s->backing.state, c->data, (size_t)c->cap);
    free(c);
    c = next;
  }
  s->head = NULL;
}

static void *arena_alloc(void *st, size_t size, size_t align) {
  arena_state *s = (arena_state *)st;
  int64_t a = (int64_t)align;
  int64_t need = (int64_t)size;
  int64_t off;
  if (s == NULL || s->magic != CVN_ARENA_MAGIC || need <= 0 || !is_pow2(a))
    return NULL;
  if (s->head == NULL || align_up(s->head->used, a) + need > s->head->cap) {
    int64_t cap = s->chunk_size > need + a ? s->chunk_size : need + a;
    arena_chunk *c = (arena_chunk *)malloc(sizeof *c);
    if (c == NULL)
      return NULL;
    c->data = NULL;
    c->cap = cap;
    c->used = 0;
    if (s->backing.vtable == NULL || s->backing.vtable->alloc == NULL) {
      free(c);
      return NULL;
    }
    c->data = (char *)s->backing.vtable->alloc(s->backing.state,
                                               (size_t)cap, 16);
    if (c->data == NULL) {
      free(c);
      return NULL;
    }
    c->next = s->head;
    s->head = c;
  }
  off = align_up(s->head->used, a);
  if (off + need > s->head->cap)
    return NULL;
  s->head->used = off + need;
  return s->head->data + off;
}

static void *arena_realloc(void *st, void *oldp, size_t old_size,
                           size_t new_size, size_t align) {
  void *p;
  size_t n;
  if (oldp == NULL)
    return arena_alloc(st, new_size, align);
  p = arena_alloc(st, new_size, align);
  if (p == NULL)
    return NULL;
  n = old_size < new_size ? old_size : new_size;
  memcpy(p, oldp, n);
  return p;
}

static void arena_free(void *st, void *p, size_t size) {
  (void)st; (void)p; (void)size;
}

static const cvn_allocator_vtable arena_vtable = {
    1u, 0u, "arenaAllocator", arena_alloc, arena_realloc, arena_free};

cvn_allocator cvn_arena_allocator(cvn_allocator backing, int64_t chunk) {
  arena_state *s;
  cvn_allocator a;
  if (chunk <= 0)
    return cvn_null_allocator();
  s = (arena_state *)malloc(sizeof *s);
  if (s == NULL)
    return cvn_null_allocator();
  s->magic = CVN_ARENA_MAGIC;
  s->backing = backing;
  s->chunk_size = chunk;
  s->head = NULL;
  a.vtable = &arena_vtable;
  a.state = s;
  return a;
}

void cvn_arena_reset(cvn_allocator a) {
  arena_state *s = (arena_state *)a.state;
  if (s != NULL && s->magic == CVN_ARENA_MAGIC)
    arena_free_chunks(s);
}

void cvn_arena_deinit(cvn_allocator a) {
  arena_state *s = (arena_state *)a.state;
  if (s != NULL && s->magic == CVN_ARENA_MAGIC) {
    arena_free_chunks(s);
    s->magic = 0;
    free(s);
  }
}

/* ------------------------------------------------------------- stack --- */

typedef struct {
  uint32_t magic;
  cvn_allocator backing;
  char *buf;
  int64_t cap;
  int64_t off;
} stack_state;

static void *stack_alloc(void *st, size_t size, size_t align) {
  stack_state *s = (stack_state *)st;
  int64_t a = (int64_t)align;
  int64_t off;
  if (s == NULL || s->magic != CVN_STACK_MAGIC || size == 0 || !is_pow2(a))
    return NULL;
  off = align_up(s->off, a);
  if (off < 0 || off + (int64_t)size > s->cap)
    return NULL;
  s->off = off + (int64_t)size;
  return s->buf + off;
}

static void *stack_realloc(void *st, void *oldp, size_t old_size,
                           size_t new_size, size_t align) {
  stack_state *s = (stack_state *)st;
  char *p = (char *)oldp;
  if (s == NULL || s->magic != CVN_STACK_MAGIC)
    return NULL;
  if (oldp == NULL)
    return stack_alloc(st, new_size, align);
  if (p + old_size == s->buf + s->off) {
    int64_t base = (int64_t)(p - s->buf);
    int64_t a = (int64_t)align;
    if (base + (int64_t)new_size <= s->cap && align_up(base, a) == base) {
      s->off = base + (int64_t)new_size;
      return oldp;
    }
  }
  return NULL;
}

static void stack_free(void *st, void *p, size_t size) {
  stack_state *s = (stack_state *)st;
  char *cp = (char *)p;
  if (s == NULL || s->magic != CVN_STACK_MAGIC || p == NULL)
    return;
  if (cp + size != s->buf + s->off)
    alloc_fatal("stack free out of order");
  s->off = (int64_t)(cp - s->buf);
}

static const cvn_allocator_vtable stack_vtable = {
    1u, 0u, "stackAllocator", stack_alloc, stack_realloc, stack_free};

cvn_allocator cvn_stack_allocator(cvn_allocator backing, int64_t size) {
  stack_state *s;
  cvn_allocator a;
  char *buf;
  if (size <= 0 || backing.vtable == NULL || backing.vtable->alloc == NULL)
    return cvn_null_allocator();
  s = (stack_state *)malloc(sizeof *s);
  if (s == NULL)
    return cvn_null_allocator();
  buf = (char *)backing.vtable->alloc(backing.state, (size_t)size, 16);
  if (buf == NULL) {
    free(s);
    return cvn_null_allocator();
  }
  s->magic = CVN_STACK_MAGIC;
  s->backing = backing;
  s->buf = buf;
  s->cap = size;
  s->off = 0;
  a.vtable = &stack_vtable;
  a.state = s;
  return a;
}

int64_t cvn_stack_mark(cvn_allocator a) {
  stack_state *s = (stack_state *)a.state;
  if (s != NULL && s->magic == CVN_STACK_MAGIC)
    return s->off;
  return 0;
}

void cvn_stack_reset(cvn_allocator a, int64_t mark) {
  stack_state *s = (stack_state *)a.state;
  if (s != NULL && s->magic == CVN_STACK_MAGIC) {
    if (mark < 0 || mark > s->off)
      alloc_fatal("stack reset invalid mark");
    s->off = mark;
  }
}

void cvn_stack_deinit(cvn_allocator a) {
  stack_state *s = (stack_state *)a.state;
  if (s != NULL && s->magic == CVN_STACK_MAGIC) {
    if (s->buf != NULL && s->backing.vtable != NULL &&
        s->backing.vtable->free != NULL)
      s->backing.vtable->free(s->backing.state, s->buf, (size_t)s->cap);
    s->magic = 0;
    free(s);
  }
}

/* ------------------------------------------------------------- debug --- */

typedef struct dbg_node {
  struct dbg_node *next;
  void *user;
} dbg_node;

typedef struct {
  uint32_t magic;
  cvn_allocator backing;
  dbg_node *live;
  dbg_node *freed;
} dbg_state;

typedef struct {
  uint32_t magic;
  uint32_t align;
  int64_t size;
  void *base;
  int64_t total;
  void *owner;
  dbg_node *node;
  char pad[CVN_DBG_HDR - 48];
} dbg_hdr;

_Static_assert(sizeof(dbg_hdr) == CVN_DBG_HDR, "debug header size");

static dbg_hdr *hdr_of(void *p) {
  return (dbg_hdr *)((char *)p - CVN_DBG_HDR);
}

static int dbg_state_ok(dbg_state *s) {
  return s != NULL && s->magic == CVN_DEBUG_MAGIC;
}

static void dbg_unlink(dbg_state *s, dbg_node *node) {
  dbg_node **cur = &s->live;
  while (*cur != NULL) {
    if (*cur == node) {
      *cur = node->next;
      return;
    }
    cur = &(*cur)->next;
  }
}

static dbg_node *dbg_take_freed(dbg_state *s, void *user) {
  dbg_node **cur = &s->freed;
  while (*cur != NULL) {
    if ((*cur)->user == user) {
      dbg_node *n = *cur;
      *cur = n->next;
      n->next = NULL;
      return n;
    }
    cur = &(*cur)->next;
  }
  return NULL;
}

static void *dbg_alloc(void *st, size_t size, size_t align) {
  dbg_state *s = (dbg_state *)st;
  int64_t a = (int64_t)align;
  int64_t alloc_align;
  int64_t total;
  char *base;
  char *user;
  dbg_hdr *h;
  dbg_node *node;
  if (!dbg_state_ok(s) || size == 0 || size > (size_t)INT64_MAX / 2 ||
      !is_pow2(a) || a > 4096)
    return NULL;
  alloc_align = a > CVN_DBG_HDR ? a : CVN_DBG_HDR;
  total = alloc_align + (int64_t)size + CVN_DBG_TAIL;
  if (s->backing.vtable == NULL || s->backing.vtable->alloc == NULL)
    return NULL;
  base = (char *)s->backing.vtable->alloc(s->backing.state, (size_t)total,
                                          (size_t)alloc_align);
  if (base == NULL)
    return NULL;
  user = base + alloc_align;
  h = hdr_of(user);
  memset(h, 0, sizeof *h);
  h->magic = CVN_DBG_MAGIC;
  h->align = (uint32_t)a;
  h->size = (int64_t)size;
  h->base = base;
  h->total = total;
  h->owner = s;
  memset(user + size, CVN_DBG_TAIL_FILL, CVN_DBG_TAIL);
  node = dbg_take_freed(s, user);
  if (node == NULL) {
    node = (dbg_node *)malloc(sizeof *node);
    if (node == NULL) {
      s->backing.vtable->free(s->backing.state, base, (size_t)total);
      return NULL;
    }
    node->user = user;
  }
  node->next = s->live;
  s->live = node;
  h->node = node;
  return user;
}

static void dbg_free(void *st, void *p, size_t size) {
  dbg_state *s = (dbg_state *)st;
  dbg_hdr *h;
  dbg_node *cur;
  int64_t i;
  if (p == NULL)
    return;
  if (!dbg_state_ok(s))
    alloc_fatal("debug free with wrong allocator");
  for (cur = s->freed; cur != NULL; cur = cur->next)
    if (cur->user == p)
      alloc_fatal("double free");
  h = hdr_of(p);
  if (h->magic != CVN_DBG_MAGIC || h->owner != s)
    alloc_fatal("invalid free");
  if (h->size != (int64_t)size)
    alloc_fatal("wrong size");
  for (i = 0; i < CVN_DBG_TAIL; i++)
    if ((unsigned char)((char *)p)[h->size + i] != CVN_DBG_TAIL_FILL)
      alloc_fatal("redzone corrupted");
  dbg_unlink(s, h->node);
  h->magic = CVN_DBG_DEAD;
  h->node->next = s->freed;
  s->freed = h->node;
  if (s->backing.vtable != NULL && s->backing.vtable->free != NULL)
    s->backing.vtable->free(s->backing.state, h->base, (size_t)h->total);
}

static void *dbg_realloc(void *st, void *oldp, size_t old_size,
                         size_t new_size, size_t align) {
  void *p;
  size_t n;
  if (oldp == NULL)
    return dbg_alloc(st, new_size, align);
  p = dbg_alloc(st, new_size, align);
  if (p == NULL)
    return NULL;
  n = old_size < new_size ? old_size : new_size;
  memcpy(p, oldp, n);
  dbg_free(st, oldp, old_size);
  return p;
}

static const cvn_allocator_vtable debug_vtable = {
    1u, 0u, "debugAllocator", dbg_alloc, dbg_realloc, dbg_free};

cvn_allocator cvn_debug_allocator(cvn_allocator backing) {
  dbg_state *s;
  cvn_allocator a;
  s = (dbg_state *)malloc(sizeof *s);
  if (s == NULL)
    return cvn_null_allocator();
  s->magic = CVN_DEBUG_MAGIC;
  s->backing = backing;
  s->live = NULL;
  s->freed = NULL;
  a.vtable = &debug_vtable;
  a.state = s;
  return a;
}

bool cvn_debug_check(cvn_allocator a) {
  dbg_state *s = (dbg_state *)a.state;
  dbg_node *cur;
  if (!dbg_state_ok(s))
    return false;
  for (cur = s->live; cur != NULL; cur = cur->next) {
    dbg_hdr *h = hdr_of(cur->user);
    int64_t i;
    if (h->magic != CVN_DBG_MAGIC || h->owner != s)
      return false;
    for (i = 0; i < CVN_DBG_TAIL; i++)
      if ((unsigned char)((char *)cur->user)[h->size + i] !=
          CVN_DBG_TAIL_FILL)
        return false;
  }
  return true;
}

int64_t cvn_debug_report(cvn_allocator a) {
  dbg_state *s = (dbg_state *)a.state;
  dbg_node *cur;
  int64_t n = 0;
  if (!dbg_state_ok(s))
    return 0;
  for (cur = s->live; cur != NULL; cur = cur->next)
    n++;
  if (n > 0) {
    fprintf(stderr, "[debug allocator] leaked %lld block(s)\n",
            (long long)n);
    for (cur = s->live; cur != NULL; cur = cur->next) {
      dbg_hdr *h = hdr_of(cur->user);
      fprintf(stderr, "  %p: %lld byte(s)\n", cur->user,
              (long long)h->size);
    }
    fflush(stderr);
  }
  return n;
}

void cvn_debug_fail_on_leak(cvn_allocator a) {
  int64_t n = cvn_debug_report(a);
  if (n > 0) {
    fprintf(stderr, "allocator error: leaked %lld block(s)\n",
            (long long)n);
    fflush(stderr);
    exit(3);
  }
}

void cvn_debug_deinit(cvn_allocator a) {
  dbg_state *s = (dbg_state *)a.state;
  dbg_node *cur;
  if (!dbg_state_ok(s))
    return;
  if (s->live != NULL)
    (void)cvn_debug_report(a);
  cur = s->live;
  while (cur != NULL) {
    dbg_node *next = cur->next;
    free(cur);
    cur = next;
  }
  cur = s->freed;
  while (cur != NULL) {
    dbg_node *next = cur->next;
    free(cur);
    cur = next;
  }
  s->magic = 0;
  free(s);
}

/* ------------------------------------------------------------ task --- */

cvn_allocator cvn_task_allocator(void) {
  /* В v0.4 нет исполнителей: аллокатор корневой задачи — cAllocator. */
  return cvn_c_allocator();
}

/* --------------------------------------------------------- wrappers --- */

static cvn_result_ptr ptr_ok(void *p) {
  cvn_result_ptr r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = p;
  return r;
}

static cvn_result_ptr ptr_err(int32_t code) {
  cvn_result_ptr r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = (cvn_error){code, 0, 0, NULL};
  return r;
}

cvn_result_ptr cvn_alloc_aligned(cvn_allocator a, int64_t n, int64_t align) {
  void *p;
  if (n <= 0)
    return ptr_err(CVN_ERR_INVALID);
  if (align <= 0 || !is_pow2(align) || align > (1 << 20))
    return ptr_err(CVN_ERR_BAD_ALIGN);
  if (a.vtable == NULL || a.vtable == &null_vtable ||
      a.vtable->alloc == NULL)
    return ptr_err(CVN_ERR_NO_ALLOC);
  p = a.vtable->alloc(a.state, (size_t)n, (size_t)align);
  if (p == NULL)
    return ptr_err(CVN_ERR_OOM);
  if (((uintptr_t)p & (uintptr_t)(align - 1)) != 0) {
    if (a.vtable->free != NULL)
      a.vtable->free(a.state, p, (size_t)n);
    return ptr_err(CVN_ERR_BAD_ALIGN);
  }
  return ptr_ok(p);
}

cvn_result_ptr cvn_alloc_bytes(cvn_allocator a, int64_t n) {
  return cvn_alloc_aligned(a, n, 8);
}

cvn_result_ptr cvn_alloc_zeroed(cvn_allocator a, int64_t n) {
  cvn_result_ptr r = cvn_alloc_aligned(a, n, 8);
  if (r.tag == 0u)
    memset(r.u.ok, 0, (size_t)n);
  return r;
}

cvn_result_ptr cvn_realloc_aligned(cvn_allocator a, void *p, int64_t oldn,
                                   int64_t newn, int64_t align) {
  void *q;
  if (newn <= 0)
    return ptr_err(CVN_ERR_INVALID);
  if (align <= 0 || !is_pow2(align) || align > (1 << 20))
    return ptr_err(CVN_ERR_BAD_ALIGN);
  if (a.vtable == NULL || a.vtable == &null_vtable ||
      a.vtable->realloc == NULL)
    return ptr_err(CVN_ERR_NO_ALLOC);
  if (p == NULL)
    return cvn_alloc_aligned(a, newn, align);
  q = a.vtable->realloc(a.state, p, (size_t)oldn, (size_t)newn,
                        (size_t)align);
  if (q == NULL)
    return ptr_err(CVN_ERR_OOM);
  if (((uintptr_t)q & (uintptr_t)(align - 1)) != 0)
    return ptr_err(CVN_ERR_BAD_ALIGN);
  return ptr_ok(q);
}

cvn_result_ptr cvn_realloc_bytes(cvn_allocator a, void *p, int64_t oldn,
                                 int64_t newn) {
  return cvn_realloc_aligned(a, p, oldn, newn, 8);
}

void cvn_free_bytes(cvn_allocator a, void *p, int64_t n) {
  if (p == NULL || n < 0)
    return;
  if (a.vtable == NULL || a.vtable->free == NULL)
    return;
  a.vtable->free(a.state, p, (size_t)n);
}

/* ---------------------------------------------------------- helpers --- */

bool cvn_is_aligned(void *p, int64_t align) {
  if (p == NULL || align <= 0)
    return false;
  return ((uintptr_t)p % (uintptr_t)align) == 0;
}

bool cvn_is_null_ptr(void *p) { return p == NULL; }

int64_t cvn_ptr_addr(void *p) { return (int64_t)(uintptr_t)p; }

void cvn_mem_fill(void *p, uint8_t v, int64_t n) {
  if (p != NULL && n > 0)
    memset(p, v, (size_t)n);
}

void cvn_mem_copy(void *dst, void *src, int64_t n) {
  if (dst != NULL && src != NULL && n > 0)
    memcpy(dst, src, (size_t)n);
}

uint8_t cvn_mem_byte(void *p, int64_t i) {
  return ((uint8_t *)p)[i];
}

void cvn_mem_set_byte(void *p, int64_t i, uint8_t v) {
  ((uint8_t *)p)[i] = v;
}

# Convulsions MVP (v0.6): kernel, UTF-8, объекты, аллокаторы, отладка утечек

Минимальный компилятор языка Convulsions: профиль `kernel`, бэкенд `native`
(HIR → C11 → gcc). Реализует hello world, UTF-8-модель `string` (README §6.7),
value-объекты и их аллокацию в куче (§6.2, §3.6), аллокаторы (§3.2–3.8)
и отчёт об утечках с типом и `file:line`.
Спецификация языка — [../README.md](../README.md).

## Сборка и запуск

```console
$ nimble build                      # -> bin/cvn.exe
$ bin/cvn run examples/hello.conv
hello, convulsions
$ bin/cvn run examples/objects.conv
objects ok
$ bin/cvn run examples/objects_alloc.conv
objects-alloc ok
$ bin/cvn run examples/allocators.conv
allocators ok
$ bin/cvn run examples/leak_debug.conv
leak-debug ok
```

`stdlib` и `runtime` ищутся рядом с бинарником (`bin/../stdlib`,
`bin/../runtime`); из другого каталога задайте `--path` и `--runtime-path`.

## Поддерживаемое подмножество

| Область | Что работает |
|---|---|
| Модули | `{.profile: kernel.}`, `{.header.}`, `from m/path import a, b`, `*`-экспорт, запрет циклов |
| Типы | `void`, `int`, `bool`, `char`, `string`, `Rune`, `pointer`, `ptr T`, `!T`, `object` с полями, непрозрачный `{.importc.}`-`object` |
| Литералы | целые, строковые `"..."`, байтовые `b"..."`, char `'a'`/`'\xFF'` |
| Объекты | `T(f: v, ...)`, `T()`, `p.x`, `p.a.b`, `p = q`, копии, вложенность, `ptr`-поля |
| Аллокация объектов | `a.create(T)`, `a.create(T, value)`, `a.destroy(p)`, `p.x` через `ptr`, `p[]` |
| Отладка утечек | тип и `file:line` для `create`, `debugReport`, автоотчёт на exit, `CVN_DEBUG_FAIL_ON_LEAK=1` |
| Аллокаторы | `null/c/page/fixed/arena/stack/task`, `initDebug`, байтовые `alloc/free/realloc`, `memFill/memByte/...` |
| Выражения | имена, вызовы, UFCS, `try`, `-`, `not`, арифметика, сравнения скаляров, `s.len`, `sizeof/alignof/offsetof`, `T(x)` |
| Операторы | `let`, `var`, `return`, `discard`, `defer:`, `try`, `assert(cond[, "msg"])`, присваивание `lhs = expr` |
| UTF-8 | `runeAt`, `runeOffset`, `runeLen`, `validate`, `rune(x)`, `fromRune`, `Rune(char)`, `int(char/Rune)` |
| FFI | `{.importc, cdecl.}`, `{.header.}`, возврат `!T` |

Не поддерживается (ошибка `E-UNSUPPORTED` с версией): `if/while/for`,
`catch:`/`errdefer`, `seq`, `union`/`enum`/`distinct`, `class`/`interface`,
`spawn`, `runes`, срезы строк, `addr`/`p[i]`, `nil`, `alloc[T]` для массивов,
`{.packed.}`/`{.align.}`, сравнение объектов и строк, `user`-профиль, VM.

## Аллокаторы

`Allocator` — значение 16 байт `{vtable, state}`; операции — функции.

```console
$ bin/cvn run examples/allocators.conv
allocators ok
```

```conv
let page = pageAllocator()
let buf = try allocBytes(page, 1024)      # align 8
defer: freeBytes(page, buf, 1024)

let fx = fixedAllocator(buf, 1024)
let p = try allocBytes(fx, 64)
fixedReset(fx)
fixedDeinit(fx)

let ar = arenaAllocator(cAllocator(), 256)
let a = try allocBytes(ar, 100)
arenaReset(ar)                              # все чанки освобождены
arenaDeinit(ar)

let st = stackAllocator(cAllocator(), 4096)
let mark = stackMark(st)
let s1 = try allocBytes(st, 32)
let s2 = try allocBytes(st, 32)
freeBytes(st, s2, 32)                       # только LIFO
freeBytes(st, s1, 32)
stackDeinit(st)

let dbg = initDebug(cAllocator())
let d = try allocZeroedBytes(dbg, 16)
assert(debugCheck(dbg))
freeBytes(dbg, d, 16)
assert(debugReport(dbg) == 0)
debugDeinit(dbg)
```

Свойства: `alloc*` возвращают `!ptr char` (`outOfMemory`, `badAlignment`,
`noAllocator`, `invalidArgument`); `align` — степень двойки; `page` выравнивает
на 64 КиБ; `fixed/arena/stack` не потокобезопасны; `arena/fixed` игнорируют
индивидуальный `free`; `stack` требует LIFO (нарушение — `allocator error`,
exit 3); `debug` ловит double free, неверный размер, redzone и утечки
(`debugReport`/`debugFailOnLeak`); `taskAllocator()` пока возвращает
`cAllocator()` — аллокатор корневой задачи.

До появления `seq[T]`/дженериков `alloc[T]` для массивов, `free(Slice)` и `dupe`
не реализованы. Для одиночных объектов уже работают `create`/`destroy`
(см. «Аллокация объектов»); байтовый API остаётся для остального.

## Объекты

```conv
type
  Point* = object
    x*, y*: int

proc shift(p: Point, dx: int): !Point =
  var q = p
  q.x = q.x + dx
  return q
```

`object` — значение; копии поверхностные (строки/`ptr` делят ресурс);
опущенные поля — zero, строковые — пустая строка с NUL-инвариантом;
`let`/value-параметры неизменяемы, `var`-параметры — мутабельные ссылки; поля
видны по `*`; циклы по значению запрещены, через `ptr T` — разрешены;
`sizeof/alignof/offsetof` вычисляются C-компилятором.

## Аллокация объектов

```conv
type
  Node* = object
    id*: int
    name*: string
    next*: ptr Node

let a = pageAllocator()
let p = try a.create(Node)                  # zero/empty
defer: a.destroy(p)
p.id = 1
p.name = try concat(cAllocator(), "root", "")
defer: p.name.deinit()                      # deinit полей — вручную

let q = try a.create(Node, Node(id: 2))     # копия значения
p.next = q
assert(p.next.id == 2)
let v = p[]                                 # копия значения из указателя
```

`create` выделяет `sizeof(T)` с `_Alignof(T)` и заполняет `cvn_new_T()`
(строки — `cvn_str_empty`) либо копирует `value`; `destroy` только освобождает
память, не вызывая `deinit` полей. `p.x`/`p.x = v` авто-разыменовывают `ptr T`;
`p[]` читает/пишет значение цели; `let p` не мешает менять поля через указатель,
но запрещает `p = q`. `p[i]`, `nil`, `addr`, массивы объектов в куче — позже.

## Отладка утечек

`create` в debug-аллокаторе запоминает тип и место:

```console
$ bin/cvn run examples/leak_debug.conv
leak-debug ok
[debug allocator] leaked 1 block(s), 16 byte(s)
  #1 Node (16 byte(s)) at .../examples/leak_debug.conv:14 ptr=000001...
  by type:
    Node x1, 16 byte(s)
```

- `debugReport(a)` печатает детали и сводку по типам, возвращает число блоков.
- `debugCheck(a)` проверяет заголовки и tail-redzone.
- `debugFailOnLeak(a)` печатает отчёт и завершает процесс с кодом 3.
- Без `debugDeinit`/освобождения блоков отчёт печатается автоматически на
  выходе (atexit). `CVN_DEBUG_FAIL_ON_LEAK=1` в окружении делает это exit 3 —
  удобно для CI.
- Double free, неверный размер и повреждение redzone сообщают тип и исходное
  `file:line` из места `create`.
- Байтовые `allocBytes` попадают в отчёт как `bytes` с местом `?`.

Ограничения: это не stack trace и не heap-профилировщик; строки/`concat`
не тегируются, пока не появится единый учёт `string`.

## UTF-8

`len` — байты, `s[i]` — байт, NUL в конце; `validate` — строгая проверка;
`runeLen` считает невалидный байт за один; `runeAt`/`runeOffset` на невалидном
байте — `error.invalidArgument`, вне диапазона — `error.bounds`;
`runeOffset(s, runeLen(s)) == s.len`.

## Устройство

```
src/cvn.nim             CLI
src/cvnc/lexer.nim      UTF-8 исходника, INDENT/DEDENT, литералы
src/cvnc/parser.nim     рекурсивный спуск по подмножеству
src/cvnc/sema.nim       типы/поля/видимость, Rune, конструкторы, мутабельность
src/cvnc/lower.nim      AST -> HIR (try, defer, объекты, пути, by-ref)
src/cvnc/cgen.nim       HIR -> C11 (структуры, zero/new, путёвая запись)
src/cvnc/driver.nim     пайплайн, поиск cc, временный каталог
stdlib/core/*.conv      importc-объявления поверх cvnrt
runtime/cvnrt.h         ABI: allocator/string/error/result
runtime/cvnrt.c         string, UTF-8, I/O, assert
runtime/cvnrt_alloc.c   аллокаторы, byte-API, debug, память
```

### Отличия MVP от полной спецификации

- Stdlib — не реализация на Convulsions, а `importc`-объявления над `cvnrt`.
- Одна единица трансляции (`main.c`), без инкрементальной сборки.
- HIR без оптимизаций; `defer`-очистки дублируются на каждом выходе.
- `deinit` и `assert` встроены в компилятор.
- Нет классов/методов: аллокаторы и `deinit` — функции/встроенные операции.
- Нет `seq`/`Slice`/дженериков: байтовый API и `create/destroy` одиночных
  объектов; массивов объектов в куче нет.
- Отладка утечек даёт тип/`file:line` и автоотчёт, но не stack trace,
  не символизацию и не heap-профилирование; строки/`concat` не тегируются.
- `runes`/`for`, срезы, `union`/`enum`, `addr`/`p[i]`, `nil`, `{.packed.}`,
  сравнение объектов и строк, debug-аллокатор по умолчанию не реализованы.

## Тесты

```console
$ nimble test
```

- unit: лексер, парсер, sema/lower/cgen;
- C-юниты: `tests/rt/test_utf.c` (декодер), `tests/rt/test_alloc.c`
  (c/page/fixed/arena/stack/debug, выравнивание, redzone, отчёты);
- e2e: hello, defer-LIFO, UTF-8, объекты, аллокация объектов
  (`examples/objects_alloc.conv`), отладка утечек
  (`examples/leak_debug.conv`, `obj_leak_auto.conv`), `examples/allocators.conv`,
  `--emit-c` (детерминизм);
- негативы: ошибки компилятора, OOM fixed, bad align, null allocator,
  stack LIFO, double free, неверный размер, redzone, утечка.

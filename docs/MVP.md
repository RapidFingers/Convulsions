# Convulsions MVP (v0.4): kernel, UTF-8, объекты, аллокаторы

Минимальный компилятор языка Convulsions: профиль `kernel`, бэкенд `native`
(HIR → C11 → gcc). Реализует hello world, UTF-8-модель `string` (README §6.7),
value-объекты (§6.2) и аллокаторы (§3.2–3.8).
Спецификация языка — [../README.md](../README.md).

## Сборка и запуск

```console
$ nimble build                      # -> bin/cvn.exe
$ bin/cvn run examples/hello.conv
hello, convulsions
$ bin/cvn run examples/objects.conv
objects ok
$ bin/cvn run examples/allocators.conv
allocators ok
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
| Аллокаторы | `null/c/page/fixed/arena/stack/task`, `initDebug`, байтовые `alloc/free/realloc`, `memFill/memByte/...` |
| Выражения | имена, вызовы, UFCS, `try`, `-`, `not`, арифметика, сравнения скаляров, `s.len`, `sizeof/alignof/offsetof`, `T(x)` |
| Операторы | `let`, `var`, `return`, `discard`, `defer:`, `try`, `assert(cond[, "msg"])`, присваивание `lhs = expr` |
| UTF-8 | `runeAt`, `runeOffset`, `runeLen`, `validate`, `rune(x)`, `fromRune`, `Rune(char)`, `int(char/Rune)` |
| FFI | `{.importc, cdecl.}`, `{.header.}`, возврат `!T` |

Не поддерживается (ошибка `E-UNSUPPORTED` с версией): `if/while/for`,
`catch:`/`errdefer`, `seq`, `union`/`enum`/`distinct`, `class`/`interface`,
`spawn`, `runes`, срезы строк, `addr`/`[]`, `nil`, `{.packed.}`/`{.align.}`,
сравнение объектов и строк, `user`-профиль, VM.

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

До появления `seq[T]`/дженериков типизированные `alloc[T]`/`create(T)`/`destroy(p)`
не реализованы — только байтовый API.

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
- Нет `seq`/`Slice`/дженериков: только байтовый API аллокаторов.
- `runes`/`for`, срезы, `union`/`enum`, `addr`/`[]`, `{.packed.}`, сравнение
  объектов и строк, debug-аллокатор по умолчанию не реализованы.

## Тесты

```console
$ nimble test
```

- unit: лексер, парсер, sema/lower/cgen;
- C-юниты: `tests/rt/test_utf.c` (декодер), `tests/rt/test_alloc.c`
  (c/page/fixed/arena/stack/debug, выравнивание, redzone, отчёты);
- e2e: hello, defer-LIFO, UTF-8, объекты, `examples/allocators.conv`,
  `--emit-c` (детерминизм);
- негативы: ошибки компилятора, OOM fixed, bad align, null allocator,
  stack LIFO, double free, неверный размер, redzone, утечка.

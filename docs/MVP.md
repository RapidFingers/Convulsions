# Convulsions MVP (v0.3): kernel, UTF-8 и объекты

Минимальный компилятор языка Convulsions: профиль `kernel`, бэкенд `native`
(HIR → C11 → gcc). Реализует hello world, UTF-8-модель `string` (README §6.7)
и value-объекты (README §6.2).
Спецификация языка — [../README.md](../README.md).

## Сборка и запуск

```console
$ nimble build                      # -> bin/cvn.exe
$ bin/cvn build examples/hello.conv -o build/hello
$ build/hello
hello, convulsions

$ bin/cvn run examples/objects.conv
objects ok
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
| Выражения | имена, вызовы, UFCS, `try`, `-`, `not`, арифметика, сравнения скаляров, `s.len`, `sizeof/alignof/offsetof`, `T(x)` |
| Операторы | `let`, `var`, `return`, `discard`, `defer:`, `try`, `assert(cond[, "msg"])`, присваивание `lhs = expr` |
| UTF-8 | `runeAt`, `runeOffset`, `runeLen`, `validate`, `rune(x)`, `fromRune`, `Rune(char)`, `int(char/Rune)` |
| FFI | `{.importc, cdecl.}`, `{.header.}`, возврат `!T` |

Не поддерживается (ошибка `E-UNSUPPORTED` с версией): `if/while/for`,
`catch:`/`errdefer`, `seq`, `union`/`enum`/`distinct`, `class`/`interface`,
`spawn`, `runes`, срезы строк, `addr`/`[]`, `nil`, `{.packed.}`/`{.align.}`,
сравнение объектов и строк, `user`-профиль, VM.

## Объекты

```conv
type
  Point* = object
    x*, y*: int

proc shift(p: Point, dx: int): !Point =
  var q = p
  q.x = q.x + dx
  return q

proc bump(v: var int): void =
  v = v + 1

proc main(): !void =
  var p = Point(x: 1, y: 2)
  bump(p.x)
  let q = try shift(p, 10)
  assert(q.x == 12)
  assert(sizeof(Point) == 16)
  assert(offsetof(Point, y) == 8)
```

Семантика: `object` — значение; копирование и присваивание копируют структуру
(строки/`ptr` — поверхностно, без автоосвобождения); опущенные поля
инициализируются нулём, строковые — пустой строкой с NUL-инвариантом;
`let` и value-параметры неизменяемы, `var`-параметры — мутабельные ссылки;
поля видны по `*`; циклы по значению запрещены, через `ptr T` — разрешены;
`sizeof/alignof/offsetof` вычисляются C-компилятором.

## UTF-8

```conv
let s = "привет🙂"
assert(validate(s))
assert(s.len == 16)
assert(runeLen(s) == 7)
assert(int(try runeAt(s, 12)) == 0x1F642)
assert((try runeOffset(s, 6)) == 12)
```

Инварианты: `len` — байты, `s[i]` — байт, NUL в конце; `validate` — строгая
проверка; `runeLen` считает невалидный байт за один; `runeAt`/`runeOffset`
на невалидном байте — `error.invalidArgument`, вне диапазона — `error.bounds`;
`runeOffset(s, runeLen(s)) == s.len`.

## Устройство

```
src/cvn.nim            CLI
src/cvnc/lexer.nim     UTF-8 исходника, INDENT/DEDENT, литералы
src/cvnc/parser.nim    рекурсивный спуск по подмножеству
src/cvnc/sema.nim      типы/поля/видимость, Rune, конструкторы, мутабельность
src/cvnc/lower.nim     AST -> HIR (try, defer, объекты, пути, by-ref)
src/cvnc/cgen.nim      HIR -> C11 (структуры, zero/new, путёвая запись)
src/cvnc/driver.nim    пайплайн, поиск cc, временный каталог
stdlib/core/*.conv     тонкие importc-объявления поверх cvnrt
runtime/cvnrt.{h,c}    аллокатор, string, UTF-8, println, error, assert
```

### Отличия MVP от полной спецификации

- Stdlib — не реализация на Convulsions, а `importc`-объявления над `cvnrt`.
- Одна единица трансляции (`main.c`), без инкрементальной сборки.
- HIR без оптимизаций; `defer`-очистки дублируются на каждом выходе.
- `deinit` и `assert` встроены в компилятор.
- `runes`/`for`, срезы, `union`/`enum`, указательная арифметика, `{.packed.}`,
  сравнение объектов и строк, debug-аллокатор не реализованы.

## Тесты

```console
$ nimble test
```

- unit: лексер (char/b-string/UTF-8), парсер, sema/lower/cgen;
- C-юниты `tests/rt/test_utf.c`: декодер на edge-cases;
- e2e: hello, defer-LIFO, UTF-8, объекты (копии, вложенность, строки,
  `var`-параметры, возврат, модули, layout), `--emit-c` (детерминизм);
- негативы в `tests/fixtures/` — по одному на диагностический код.

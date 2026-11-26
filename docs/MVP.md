# Convulsions MVP (v0.1): kernel + hello world

Минимальный компилятор языка Convulsions: профиль `kernel`, бэкенд `native`
(HIR → C11 → gcc). Реализует ровно то, что нужно для `examples/hello.conv`,
и ничего сверх этого. Спецификация языка — [../README.md](../README.md).

## Сборка и запуск

```console
$ nimble build                      # -> bin/cvn.exe
$ bin/cvn build examples/hello.conv -o build/hello
$ build/hello
hello, convulsions

$ bin/cvn run examples/hello.conv
hello, convulsions
```

По умолчанию `stdlib` и `runtime` ищутся рядом с бинарником (`bin/../stdlib`,
`bin/../runtime`); из другого каталога задайте `--path` и `--runtime-path`.

## Поддерживаемое подмножество

| Область | Что работает |
|---|---|
| Модули | `{.profile: kernel.}`, `{.header.}`, `from m/path import a, b`, `*`-экспорт, запрет циклов |
| Типы | `void`, `int`, `bool`, `char`, `string`, `pointer`, `ptr T`, `!T`, непрозрачный `{.importc.}`-`object` |
| Выражения | литералы, имена, вызовы, `x.f(y)` (UFCS), `try`, `-`, `not`, арифметика и сравнения |
| Операторы | `let`, `var`, `return`, `discard`, `defer:`, `try` |
| Builtin | `deinit` для `string` (без импорта) |
| FFI | `{.importc, cdecl.}`, `{.header.}`, возврат `!T` |

Всё остальное (`if`, `while`, `catch:`, `errdefer`, `seq`, `class`, `spawn`,
`user`-профиль, VM) отклоняется с `E-UNSUPPORTED` и указанием версии, в которой
появится.

## Устройство

```
src/cvn.nim            CLI
src/cvnc/lexer.nim     INDENT/DEDENT, литералы, комментарии
src/cvnc/parser.nim    рекурсивный спуск по подмножеству
src/cvnc/sema.nim      имена, типы, импорты, builtin deinit
src/cvnc/lower.nim     AST -> HIR (try, defer, литералы)
src/cvnc/cgen.nim      HIR -> C11 (одна единица трансляции)
src/cvnc/driver.nim    пайплайн, поиск cc, временный каталог
stdlib/core/*.conv     тонкие importc-объявления поверх cvnrt
runtime/cvnrt.{h,c}    аллокатор, string, println, error
```

### Отличия MVP от полной спецификации

- Stdlib — не реализация на Convulsions, а `importc`-объявления над `cvnrt`.
- Одна единица трансляции (`main.c`), без инкрементальной сборки.
- HIR без оптимизаций и без Φ-узлов; `defer`-очистки дублируются на каждом выходе.
- `deinit` встроен в компилятор (иначе hello не собрался бы без импорта).
- Проверки границ/`nil` и debug-аллокатор не реализованы.

## Тесты

```console
$ nimble test
```

- unit: лексер, парсер, sema/lower/cgen-интеграция;
- e2e: сборка и запуск hello, `cvn run`, `--emit-c` (включая детерминизм);
- 19 негативных фикстур в `tests/fixtures/` — по одной на диагностический код.

# Convulsions — дизайн языка

Статус: **v0.14.0, kernel MVP**. Реализация — компилятор на Nim, бэкенд
`native`: HIR → C11 → gcc. Спецификация ниже описывает то, что действительно
поддерживается в этой версии; подробности и тесты — в [MVP](MVP.md).

## 1. Цели и границы

- Статическая типизация, значения и явное владение памятью; GC нет.
- `kernel`-профиль: ошибки — значения `!T`, без исключений и раскрутки стека.
- Один C11-файл на программу, линковка с `cvnrt`.
- Исполнение — `fiber` с пулом воркеров и event loop.
- Бинарные данные — `Slice[byte]`/`Buffer`, без `string` и `ptr char` в API.
- `user`-профиль, VM, `thread`-исполнитель и GC в этой версии не реализованы.

## 2. Лексика и синтаксис

- Исходник — UTF-8; отступы пробелами, табы запрещены; точка с запятой
  запрещена; комментарии `#`.
- Блоки задаются отступом; `if`/`while`/`proc`/`type` — двоеточием.
- Ключевые слова: `proc`, `type`, `let`, `var`, `return`, `discard`, `defer`,
  `errdefer`, `try`, `catch`, `spawn`, `await`, `if`, `elif`, `else`, `while`,
  `break`, `continue`, `import`, `from`, `object`, `ptr`, `true`, `false`,
  `not`, `and`, `or`.
- Импорты — до объявлений; `import m` вносит все `*`-экспорты, `from m import a,b` — выборочно.
- Прагмы: `{.profile: kernel.}`, `{.header. "...".}`, `{.importc.}`,
  `{.cdecl.}`, `{.propagate.}`.

```conv
{.profile: kernel.}
import core/io

proc add(a: int, b: int): int =
  return a + b

proc main(): !void =
  let x = add(2, 3)
  assert(x == 5)
  try println("ok")
```

## 3. Типы

| Тип | Представление / смысл |
|---|---|
| `int` | `int64_t` |
| `bool` | `bool` |
| `char`, `byte` | `uint8_t`; `byte` — алиас `char` |
| `string` | `cvn_string` (40 байт), UTF-8, NUL в конце |
| `Rune` | `uint32_t`; скаляр Unicode |
| `pointer` | `void *` |
| `ptr T` | `T *`; `p[]`, `p.x` |
| `T` (`object`) | значение; копия поверхностная |
| `proc` | функция/импорт |
| `!T` | результат: `T` или `cvn_error` |
| `Task[T]` | задача `fiber` |
| `Slice[T]` | `{ data: ptr T, len: int }`, невладеющий |
| `Buffer` | владеющий байтовый буфер |
| `Channel` | ограниченный канал строк |
| `ErrorCode` | compile-time коды ошибок |

- Объекты: поля, `T(f: v)` (именованные поля), `a.create(T)`, `a.destroy(p)`,
  `p[]`.
- Дженерики: `Box[T]`, `proc f[T](x: T): T`; инстанцирование
  мономорфизируется, глубина — 64.
- Приведения — только явные для скаляров (`int(x)`, `Rune(c)`, `char`).
- `nil`/`null`-литерала нет; нулевой `ptr` получается из zero-инициализации.

## 4. Память

Владение не отслеживается компилятором. Аллокатор — значение 16 байт
(`vtable + state`):

- `nullAllocator`, `cAllocator`, `pageAllocator`, `fixedAllocator`,
  `arenaAllocator`, `stackAllocator`, `taskAllocator`;
- `initDebug(backing)` — redzone, теги типа/места, отчёт об утечках;
- `allocBytes`, `allocAligned`, `reallocBytes`, `freeBytes`, `memCopy`,
  `memFill`, `memByte`.

Правила:

- `defer` — LIFO при выходе из функции; `errdefer` — только при ошибке.
- `defer`/`errdefer` внутри `if`/`while` запрещены; внутри `try:` — function-level.
- Строка владеет памятью, `deinit()` освобождает; копия строки поверхностная.
- `Slice[T]` не владеет; `Buffer` владеет и освобождается `deinitBuffer`.
- `create` только выделяет объект; `destroy` не вызывает `deinit` полей.
- Debug-аллокатор не потокобезопасен.

```conv
let a = taskAllocator()
let p = try a.create(Point)
defer: a.destroy(p)

let buf = try newBuffer(a, 4096)
defer: deinitBuffer(buf)
```

## 5. Ошибки

`!T` — значение; ошибка не покидает программу сама.

- `try expr` разворачивает один `!T`.
- `try:` — блок-выражение: все `!T` внутри разворачиваются; требует `!T`-функцию.
- `{.propagate.}` — всё тело функции как `try:`.
- `catch:` — обработка выбранных кодов:
  ```conv
  let n = readInto(c, buf.slice()) catch:
    error.Closed => break
    error.WouldBlock => continue
    else => propagate
  ```
- В `!T`-функции непокрытые коды уходят наверх; в `void`-функции обязателен
  `else => panic(...)`.
- `panic("...")` завершает процесс с кодом 2.
- `errdefer` выполняется при ошибочном выходе, LIFO вместе с `defer`.
- Auto-try в `try:`/`.propagate` не разворачивает операнды `try`/`catch`,
  значение `return` и цель `spawn`.

Коды: `OutOfMemory`, `NoAllocator`, `Invalid`, `BadAlignment`, `Bounds`, `Io`,
`Eof`, `Cancelled`, `Task`, `Closed`, `WouldBlock` (`error.Closed` или
`error.closed`).

## 6. Память: строки и срезы

- `string` — UTF-8, NUL-инвариант, длина в байтах; `runes`, `runeAt`,
  `runeLen`, `validate`, `fromRune`.
- `"text".bytes()` — невладеющий `Slice[byte]` без копирования.
- `Slice[T].sub(start,count)`, `.at(i)` проверяют границы через `assert`.
- `Buffer`: `newBuffer(a, capacity)`, `.slice()`, `.view(n)`, `deinitBuffer`.
- `Slice` не продлевает жизнь backing storage; `Buffer` нельзя копировать
  как владельца.

## 7. Конкурентность

- `spawn f(args)` создаёт `Task[T]`; `await` ждёт результат; `sleep(ms)`.
- Пул воркеров, event loop; задача привязана к воркеру, миграции нет.
- Аргументы/результат задачи копируются поверхностно; захвата замыканий нет.
- `Channel` — bounded, строковый: `newChannel(a, cap)`, `send`, `recv`,
  `closeChannel`, `freeChannel`. При заполнении/опустошении фибра уступает
  планировщику; EOF/закрытие — `error.Closed`.
- Сокеты — TCP IPv4, nonblocking, `readInto(Slice[byte])`,
  `write(Slice[byte])`, `close`, `shutdownWrite`, `localPort`.
  Одна незавершённая операция на сокет; `close` во время ожидания не поддержан.
- Нет DNS/IPv6/UDP/TLS, отмены, `select`, fan-in, миграции задач.

## 8. Модули и FFI

- Модуль — файл с `{.profile: kernel.}`; циклические импорты запрещены.
- `import core/io` — все экспорты; `from core/mem import Allocator` — выборочно.
- `*` — экспорт; конфликт имён — `E-DUP-SYMBOL`.
- `{.importc: "name", header: "<h.h>", cdecl.}` — C-функция/тип.
- Внешние типы непрозрачны; поля недоступны.
- `core/net`, `core/slice`, `core/mem`, `core/string`, `core/concurrency`,
  `core/io` — стандартные модули.

## 9. ABI и рантайм

- `cvn_allocator` — 16 байт (`vtable`, `state`).
- `cvn_string` — 40 байт (`ptr`, `len`, `cap`, `alloc`), NUL-инвариант.
- `cvn_error` — 24 байта (`code`, `payload`, `ctx`).
- `!T` — тегированный union (`tag 0/1`); `!void` — `cvn_error`.
- `cvn_socket` — value-структура (`fd`, `kind`); C-API принимает
  `pointer + length`.
- `Channel` — непрозрачное состояние; C-API `cvn_channel_*`.
- Один `main.c` на программу + `cvnrt.c`, `cvnrt_alloc.c`,
  `cvnrt_fiber.c`, `cvnrt_net.c`, `cvnrt_channel.c`.

## 10. Инструменты

```text
cvn build <entry.conv> [-o <bin>] [--emit-c=DIR]
cvn run <entry.conv> [-- args]
cvn version
```

- `--cc`, `--cflags`, `--path`, `--runtime-path`, `--workers`, `--stack-size`.
- `--dump-ast`, `--dump-hir`, `--keep-temp`.
- `-q`/`--quiet` — без прогресса; `--verbose` — подробно; `-v` — версия.
- Прогресс идёт в stderr; stdout — программа и дампы.
- Стадии: импорт → семантика → HIR → C → подготовка → cc.

## 11. Ограничения v0.14

- Только `kernel`; `user`, VM, GC нет.
- Нет `seq`, `for`, `union`/`enum`/`distinct`, `class`, массивов, `nil`,
  срезов строк, `addr`/`cast`, `p[i]`.
- Нет `catch e:`-формы из старой спецификации; используется `catch:` с кодами.
- `Slice[T]` невладеющий и без lifetime-проверок; `Buffer` только байтовый.
- `Channel` только строковый, bounded; busy-yield вместо wait queue.
- Сокеты: только TCP IPv4 numeric/`localhost`; нет DNS/IPv6/UDP/TLS.
- Нет preemption, миграции задач, отмены, `select`, per-task арен.
- Debug-аллокатор не потокобезопасен.

## 12. Дальше

1. Generic `Channel[T]`, per-task арены, освобождение записей задач.
2. `seq`/`for`/срезы, `user`-профиль, VM.
3. Отмена/таймауты, `Scope`, `select`.
4. DNS/IPv6/TLS, промышленный event loop.
5. Preemption и `thread`-исполнитель.

## 13. Тесты

`nimble test` покрывает: лексер/парсер, типы/объекты, строки/UTF-8,
аллокаторы/утечки, generics, модули/FFI, ошибки, control flow, fibers,
Channel, сокеты, Slice/Buffer, примеры и C-юниты рантайма. Подробности —
[MVP](MVP.md).

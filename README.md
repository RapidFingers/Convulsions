## Эксперимент. Попытка навайбкодить язык программирования

# Convulsions

**Компилируемый язык для kernel-кода: значения, явная память, ошибки как
значения и fibers без скрытого GC.**

Convulsions компилируется в C11 и работает поверх небольшого C-рантайма. Вы
управляете памятью через аллокатор-значение, ошибки возвращаются как `!T`, а
конкурентность строится на `spawn`/`await` и event loop.

```console
$ nimble build
$ bin/cvn run examples/hello.conv
hello, convulsions
```

## Почему Convulsions

- **Память видна.** Нет сборщика мусора и скрытых аллокаций в пользовательском
  коде: `Allocator` передаётся как значение, `create`/`destroy`,
  `defer`/`errdefer` — явные.
- **Ошибки — значения.** `!T` нельзя молча проигнорировать; `try`,
  `try:`-блок, `{.propagate.}` и частичный `catch:` убирают шум, не скрывая
  ошибки.
- **Fibers с автораспределением.** `spawn` кладёт задачу на пул воркеров,
  сокеты и каналы паркуют фибру в event loop, а не блокируют поток.
- **Один C11-файл.** Прозрачный бэкенд, простой дебаг, линковка с C и
  `{.importc.}` без FFI-магии.
- **Данные без копий.** `Slice[T]`/`Slice[byte]` и `Buffer` заменяют
  `string`/`ptr char` в бинарных API.
- **UTF-8 и generics.** Строки с NUL-инвариантом, `Rune`; дженерики
  мономорфизируются.

## Быстрый старт

```console
$ nimble build
$ bin/cvn run examples/hello.conv
$ bin/cvn run examples/objects_alloc.conv
$ bin/cvn run examples/allocators.conv
$ bin/cvn run examples/generics.conv
$ bin/cvn run examples/fibers.conv
$ bin/cvn run examples/producer_consumer.conv
$ bin/cvn run examples/error_levels.conv
$ bin/cvn run examples/echo_client.conv   # нужен запущенный echo_server
```

Компилятор показывает стадии сборки в stderr; `--quiet` отключает прогресс,
`--verbose` добавляет детали.

## Hello

```conv
{.profile: kernel.}
import core/io

proc main(): !void =
  try println("hello, convulsions")
```

## Объекты и явная память

```conv
{.profile: kernel.}
import core/mem
import core/io

type
  Point = object
    x: int
    y: int

proc main(): !void =
  let a = taskAllocator()
  let p = try a.create(Point)
  defer: a.destroy(p)

  p.x = 3
  p.y = 4
  assert(p.x + p.y == 7)
  try println("point ok")
```

Владение не отслеживается компилятором: освобождает тот, кто выделил.
`defer` выполняет очистку при выходе, `errdefer` — только при ошибке.

## Ошибки без исключений

```conv
import core/string
import core/io

proc readCode(): !int {.propagate.} =
  let r = rune(65)      # !Rune
  return int(r)         # ошибка уходит наверх

proc main(): !void {.propagate.} =
  let n = readCode()
  assert(n == 65)
  println("errors ok")
```

Частичная обработка:

```conv
let n = readInto(c, buf.slice()) catch:
  error.Closed => break
  error.WouldBlock => continue
  else => propagate
```

В `!T`-функции непокрытые коды уходят наверх. В `void`-функции нужен
`else => panic(...)`: потерять ошибку молча нельзя.

## Fibers и producer–consumer

```conv
import core/concurrency
import core/mem
import core/io

proc producer(ch: Channel): !void {.propagate.} =
  ch.send("alpha")
  ch.send("beta")
  ch.send("gamma")
  ch.closeChannel()

proc consumer(ch: Channel): !int =
  var total = 0
  while true:
    let item = ch.recv() catch:
      error.Closed => break
      else => propagate
    total = total + item.len
    item.deinit()
  return total

proc main(): !void {.propagate.} =
  let ch = newChannel(taskAllocator(), 1)
  defer: ch.freeChannel()

  let p = spawn producer(ch)
  let c = spawn consumer(ch)
  discard await p
  let total = await c
  assert(total == 14)
  println("producer-consumer-ok")
```

`Channel` ограниченный; `send`/`recv` уступают планировщику при заполнении и
опустошении. Работает и с `--workers=1`.

## Сокеты на `Slice[byte]`

```conv
import core/net
import core/slice
import core/mem
import core/io

proc handle(c: Socket): !void {.propagate.} =
  defer: c.close()
  let buf = newBuffer(taskAllocator(), 4096)
  defer: deinitBuffer(buf)

  while true:
    let n = readInto(c, buf.slice()) catch:
      error.Closed => break
      error.WouldBlock => continue
    write(c, buf.view(n))

proc main(): !void {.propagate.} =
  let l = listen("0.0.0.0", 7700)
  println("echo server on 127.0.0.1:7700")
  while true:
    let c = l.accept()
    discard spawn handle(c)
```

`readInto` и `write` принимают `Slice[byte]`; `Buffer` — владелец памяти.
EOF/закрытие — `error.Closed`. DNS, IPv6, UDP и TLS пока нет.

## Generics

```conv
type
  Box*[T] = object
    value*: T

proc get*[T](b: Box[T]): T =
  return b.value

proc main(): !void =
  let b = Box[int](value: 42)
  assert(get(b) == 42)
  try println("generic ok")
```

Инстанцирование мономорфное: каждый `Box[int]`/`Box[string]` — отдельный
C-тип, без runtime-стирания.

## UTF-8

```conv
import core/string
import core/io

proc main(): !void =
  let s = "привет🙂"
  assert(runeLen(s) == 7)
  try println(s)
```

`string` хранит UTF-8, NUL-инвариант и длину в байтах; `runeAt`,
`runeOffset`, `validate` и `fromRune` работают с Unicode.

## Что уже работает

| Возможность | Статус |
|---|---|
| `kernel`, C11, gcc, один translation unit | да |
| Объекты, `ptr T`, `create`/`destroy` | да |
| Аллокаторы и debug-утечки | да |
| Дженерики | да |
| UTF-8-строки | да |
| `!T`, `try:`, `{.propagate.}`, `catch:` | да |
| Fibers, `spawn`/`await`, `sleep` | да |
| `Channel` (bounded, строки) | да |
| TCP IPv4-сокеты | да |
| `Slice[T]`, `Slice[byte]`, `Buffer` | да |
| `user`-профиль, VM, GC | нет |
| `seq`, `for`, `class`, `union`/`enum` | нет |
| `thread`-исполнитель, TLS/DNS | нет |

## CLI

```text
cvn build <entry.conv> [-o <bin>]
cvn run <entry.conv> [-- args]
cvn version
```

Полезные флаги: `--emit-c=DIR`, `--cc`, `--cflags`, `--path`, `--runtime-path`,
`--workers`, `--stack-size`, `--dump-ast`, `--dump-hir`, `--keep-temp`,
`--quiet`, `--verbose`.

## Документация

- [Дизайн языка](docs/DESIGN.md) — типы, память, ошибки, ABI.
- [MVP и ограничения](docs/MVP.md) — что реализовано, примеры, тесты.
- [Примеры](examples) — hello, объекты, аллокаторы, generics, fibers,
  producer–consumer, сокеты, ошибки, Slice.

## Лицензия

См. файл `LICENSE` в корне репозитория, если он присутствует.

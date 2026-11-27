# Convulsions MVP (v0.12): kernel, UTF-8, объекты, аллокаторы, generics, fibers, sockets, ошибки, Channel

Минимальный компилятор языка Convulsions: профиль `kernel`, бэкенд `native`
(HIR → C11 → gcc). Реализует hello world, UTF-8-модель `string` (README §6.7),
value-объекты и их аллокацию в куче (§6.2, §3.6), аллокаторы (§3.2–3.8),
отчёт об утечках с типом и `file:line`, мономорфизируемые дженерики (§6.3),
`spawn`/`await` под исполнителем `fiber` с пулом воркеров и event loop (§4),
TCP-сокеты поверх фибр, уровни обработки ошибок `try:`/`{.propagate.}`/
частичный `catch:`/`errdefer` и fiber-aware `Channel` для producer–consumer.
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
$ bin/cvn run examples/generics.conv
generics ok
$ bin/cvn run examples/error_levels.conv
error-levels-ok
$ bin/cvn run examples/producer_consumer.conv
producer-consumer-ok
$ bin/cvn run examples/fibers.conv
fibers ok
$ bin/cvn build examples/fibers.conv --workers=1 -o build/fibers1

$ bin/cvn build examples/echo_server.conv -o build/echo_server
$ build/echo_server        # слушает 127.0.0.1:7700
$ bin/cvn run examples/echo_client.conv
hello
```

`stdlib` и `runtime` ищутся рядом с бинарником (`bin/../stdlib`,
`bin/../runtime`); из другого каталога задайте `--path` и `--runtime-path`.

## Поддерживаемое подмножество

| Область | Что работает |
|---|---|
| Модули | `{.profile: kernel.}`, `{.header.}`, `import m/path` (все экспорты), `from m/path import a, b`, `*`-экспорт, запрет циклов |
| Типы | `void`, `int`, `bool`, `char`, `string`, `Rune`, `pointer`, `ptr T`, `!T`, `object` с полями, непрозрачный `{.importc.}`-`object` |
| Литералы | целые, строковые `"..."`, байтовые `b"..."`, char `'a'`/`'\xFF'` |
| Объекты | `T(f: v, ...)`, `T()`, `p.x`, `p.a.b`, `p = q`, копии, вложенность, `ptr`-поля |
| Аллокация объектов | `a.create(T)`, `a.create(T, value)`, `a.destroy(p)`, `p.x` через `ptr`, `p[]` |
| Отладка утечек | тип и `file:line` для `create`, `debugReport`, автоотчёт на exit, `CVN_DEBUG_FAIL_ON_LEAK=1` |
| Дженерики | `[T]` у типов/процедур, `Box[int]`, вывод и явная конкретизация, вложенность, `create(Box[int])` |
| Fibers | `spawn f(args)`, `await t`, `sleep(ms)`, пул воркеров, event loop, `--workers`, `--stack-size` |
| Channel | `newChannel(a, capacity)`, `send`, `recv`, `closeChannel`, `freeChannel`; bounded строковый канал на fibers |
| Control flow | `if/elif/else`, `while`, `break`, `continue`, `true/false` |
| Ошибки | `try expr`, `try:`-блок, `{.propagate.}`, частичный `catch:` с `error.<Code>`, `errdefer:`, `panic` |
| Сокеты | `core/net`: `Socket`, `listen/accept/connect/read/readInto/write/writeBytes/close/shutdownWrite/localPort`, TCP IPv4 |
| Аллокаторы | `null/c/page/fixed/arena/stack/task`, `initDebug`, байтовые `alloc/free/realloc`, `memFill/memByte/...` |
| Выражения | имена, вызовы, UFCS, `try`, `-`, `not`, арифметика, сравнения скаляров, `s.len`, `sizeof/alignof/offsetof`, `T(x)` |
| Операторы | `let`, `var`, `return`, `discard`, `defer:`, `try`, `assert(cond[, "msg"])`, присваивание `lhs = expr` |
| UTF-8 | `runeAt`, `runeOffset`, `runeLen`, `validate`, `rune(x)`, `fromRune`, `Rune(char)`, `int(char/Rune)` |
| FFI | `{.importc, cdecl.}`, `{.header.}`, возврат `!T` |

`import core/mem` вносит все `*`-экспорты модуля; `from core/mem import a, b` —
только перечисленные. Конфликт имени с уже импортированным/объявленным —
`E-DUP-SYMBOL`; приватные имена не импортируются. Все примеры используют
`import`.

Не поддерживается (ошибка `E-UNSUPPORTED` с версией): `for`,
`catch e:`-форма из спецификации, исключения/`throw`, `seq`,
`union`/`enum`/`distinct`, `class`/`interface`,
`runes`, срезы строк, `addr`/`p[i]`, `nil`, `alloc[T]` для массивов,
constraints/`static`-параметры, UDP/IPv6/DNS/TLS, `{.packed.}`/`{.align.}`,
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

## Дженерики

```conv
type
  Box*[T] = object
    value*: T
  Pair*[T] = object
    first*: T
    second*: T

proc identity[T](x: T): T =
  return x

proc swap[T](p: Pair[T]): Pair[T] =
  return Pair[T](first: p.second, second: p.first)

let b = Box[int](value: 7)        # явная конкретизация
let p = Pair(first: 1, second: 2) # вывод T=int из полей
let q = swap(p)                   # вывод T из аргумента
assert(identity(5) == 5)
assert(Pair[int](first: 1, second: 2).first == 1)
```

Мономорфизация: каждое сочетание типов даёт отдельные C-структуру/функцию
(имена с `_g_`); кэш переиспользует инстанцирования, глубина ограничена 64
(`E-MONO-DEPTH`). Работают `Box[Pair[int]]`, `ptr Node[T]`, `!Box[T]`,
`a.create(Node[int])`, generic-процедуры в UFCS и `var`-параметрах.

Ограничения: нет constraints/concepts (`[T: Numeric]`), `static`-параметров,
частичного вывода, generic-процедуры как значения; `from m import *` не нужен —
есть `import m`.

## Fibers, воркеры и event loop

```conv
import core/concurrency
import core/io

proc work(x: int): !int =
  sleep(20)
  return x * 2

proc main(): !void =
  let a = spawn work(1)
  let b = spawn work(2)
  let ra = try await a
  let rb = try await b
  assert(ra == 2)
  assert(rb == 4)
  try println("fibers ok")
```

`spawn f(args)` создаёт задачу `Task[U]` для `f: !U`; аргументы копируются в
env задачи. Готовые задачи берут воркеры из общей очереди (автоматическое
распределение по потокам); `await` паркует текущую фибру и возобновляет её при
завершении задачи. `sleep(ms)` паркует фибру через таймер event loop; event loop
также умеет будить задачи по готовности fd (`cvn_task_wait_fd`, внутренний API
для будущих сокетов). `--workers=N` задаёт число потоков (0 = auto),
`--stack-size=KB` — стек фибры (по умолчанию 256). `--workers=1` — один поток.

Ограничения MVP: только прямой вызов процедуры и только её аргументы (нет
замыканий/захвата локальных), задачи с `var`-параметрами запрещены, нет
preemption, `thread`-исполнителя, каналов/мьютексов/отмены и per-task арен;
`string`/объекты в аргументах копируются поверхностно; записи задач живут до
завершения программы. Программы без `spawn`/`await` не запускают потоки.
Сетевые сокеты — следующий милстоун поверх event loop.

## Сокеты

TCP IPv4 поверх `fiber`: все ожидания (`accept`, `connect`, `read`, `write`)
паркуют текущую фибру; event loop пробуждает её по готовности fd. Сервер
принимает соединения в цикле и делает `spawn` на каждое — клиенты
обрабатываются параллельно на пуле воркеров.

```conv
# сервер
proc handle(c: Socket): !void {.propagate.} =
  defer: c.close()
  let a = taskAllocator()
  let buf = allocBytes(a, 4096)
  defer: freeBytes(a, buf, 4096)
  while true:
    let n = readInto(c, buf, 4096) catch:
      error.Closed => break
      error.WouldBlock => continue
    writeBytes(c, buf, n)

let l = try listen("0.0.0.0", 7700)
while true:
  let c = try l.accept()
  discard spawn handle(c)

# клиент
let a = taskAllocator()
let s = try connect("127.0.0.1", 7700)
defer: s.close()
try write(s, "hello")
let got = try read(s, a, 4096)
defer: got.deinit()
```

API: `listen(host, port)`, `accept`, `connect`, `read(s,a,max)`, `readInto`,
`write`, `writeBytes`, `close`, `shutdownWrite`, `localPort`;
`core/string.equal` сравнивает содержимое. IPv4 numeric и `localhost`;
DNS/IPv6/UDP/TLS нет. `read` аллоцирует строку (нужен `deinit`), `readInto`
пишет в буфер. EOF/закрытие — `error.Closed`, а не `0`/пустая строка.
Одна незавершённая операция на сокет; `close` во время ожидания не поддержан.
В `if`/`while` нельзя `defer` (`E-DEFER-CONTROL`); в сервере defer — на
уровне `handle`.

## Producer–consumer на fibers

`Channel` — ограниченный канал строк. `send` при заполнении и `recv` при
опустошении уступают планировщику; это работает и с одним воркером.

```conv
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

- `send` передаёт владение строкой; `recv` возвращает владение; потребитель
  обязан `deinit`.
- `closeChannel` запрещает новые `send`, но позволяет дочитать очередь;
  после опустошения `recv` даёт `error.Closed`.
- `freeChannel` — только после завершения всех задач; пример делает это в
  `defer` после `await`.
- MVP: строковый payload и фиксированная ёмкость; generic `Channel[T]`,
  unbounded, `select`/fan-in — позже. Ожидание — cooperative yield, не
  wait queue.

## Ошибки: `try:`, `{.propagate.}`, `catch:`, `errdefer`

Три уровня разворачивания `!T`:

```conv
# один вызов
let x = try call()

# регион-выражение: все !T внутри разворачиваются
let cfg = try:
  let raw = readFile(a, path)
  parseConfig(a, raw)

# вся функция
proc main(): !void {.propagate.} =
  let l = listen("0.0.0.0", 7700)
  while true:
    let c = l.accept()
    discard spawn handle(c)
```

В propagating-контексте (`try:`/`{.propagate.}`) auto-try применяется к
выражению `!T` в позиции значения: инициализатор, RHS, аргумент, условие,
результат блока. Исключения: операнд явного `try`/`catch`, `return`
(сохраняет `!T`) и цель `spawn`.

Частичный `catch:`:

```conv
let n = readInto(c, buf, 4096) catch:
  error.Closed => break
  error.WouldBlock => continue
  else => propagate
```

- В `!T`-функции непокрытые коды уходят наверх; `else` необязателен.
- В `void`-функции `else` обязателен и должен быть `panic(...)`/дивергентным.
- `else => propagate` допустим только в `!T`-функции.
- Ошибка не глотается: либо явная ветка, либо propagate/panic.

`errdefer:` выполняется только при ошибочном выходе, LIFO вместе с `defer`.
`error.*` — compile-time коды: `Closed`, `WouldBlock`, `Io`, `Eof`,
`Invalid`, `OutOfMemory`, `NoAllocator`, `BadAlignment`, `Bounds`,
`Cancelled`, `Task`; принимаются и спецификационные написания
`closed`, `wouldBlock`, `io`, `eof`, `invalidArgument`, `outOfMemory`,
`noAllocator`, `badAlignment`, `bounds`, `cancelled`, `task`.
`panic(msg)` завершает процесс с кодом 2.

Сокеты: EOF/закрытие соединения — `error.Closed` (не `0`/пустая строка).
`defer`/`errdefer` остаются function-level; block-scope cleanup — позже.

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
- Дженерики: мономорфизация без constraints/`static`/частичного вывода;
  generic-процедура не является значением; перегрузки по типам нет.
- Fibers: нет замыканий/захвата, preemption, `thread`-исполнителя, отмены и
  per-task арен; задачa не мигрирует между воркерами; записи задач
  освобождаются только на shutdown.
- Channel: только строковый payload и фиксированная ёмкость; нет generic
  `Channel[T]`, unbounded, `select`/fan-in, отмены; ожидание — cooperative
  yield (busy-переключения), а не wait queue; `freeChannel` только после
  завершения всех задач.
- Сокеты: только TCP IPv4 (numeric/`localhost`), без DNS/IPv6/UDP/TLS; одна
  незавершённая операция на сокет; `close` во время ожидания не поддержан;
  EOF — `error.Closed`. `defer`/`errdefer` внутри `if`/`while` запрещены
  (`E-DEFER-CONTROL`); block-scope cleanup внутри `try:` не реализован.
- Ошибки: спецификационная форма `catch e:` не реализована (MVP — `catch:` с
  `error.<Code>`); нет guards/`_`/payload; `WouldBlock` не выходит из сокетов;
  auto-try не разворачивает `return`/`spawn`/`try`/`catch`.
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
  import-all (`import m`), дженерики (`examples/generics.conv`,
  `generics_*.conv`), fibers (`examples/fibers.conv`, `fiber_*.conv`),
  producer/consumer (`examples/producer_consumer.conv`,
  `producer_consumer.conv` с `--workers=1` и обычным пулом),
  control flow (`flow_*.conv`), сокеты (`sockets_*.conv`,
  `examples/echo_server.conv`, `examples/echo_client.conv`),
  ошибки (`err_*.conv`, `examples/error_levels.conv`), `--emit-c`
  (детерминизм);
- C-fiber: барьер автораспределения, вложенный await, таймеры, fd-readiness.
- C-net: listen/accept/connect/read/write, EOF, connection refused, invalid
  host/port/kind.
- C-channel: bounded ring, backpressure на одном воркере, close/Closed,
  invalid capacity.
- негативы: ошибки компилятора, OOM fixed, bad align, null allocator,
  stack LIFO, double free, неверный размер, redzone, утечка.

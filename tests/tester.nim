## Тестовый раннер MVP: unit-проверки + e2e (сборка/запуск hello + негативы).

import std/[os, osproc, streams, strutils]
import cvnc/[diag, token, lexer, parser, ast, options, modules, sema, lower,
             cgen, hir, types]

var failures = 0

const ExeSuffix = when defined(windows): ".exe" else: ""

template check(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "FAIL: ", msg

template checkEq(a, b: untyped; msg: string) =
  if a != b:
    inc failures
    echo "FAIL: ", msg, " (got ", a, ", want ", b, ")"

proc run(cmd: string; args: seq[string]): tuple[code: int, output: string] =
  let p = startProcess(cmd, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()

proc expectCvnError(code: string; body: proc () {.closure.}) =
  try:
    body()
    inc failures
    echo "FAIL: ожидалась ошибка ", code, ", но её нет"
  except CvnError as e:
    checkEq e.code, code, "код ошибки"

let root = parentDir(parentDir(currentSourcePath()))
let stdlib = root / "stdlib"
let runtime = root / "runtime"
let fixtures = root / "tests" / "fixtures"
let tmp = root / "tests" / "tmp"
let cvn = root / "bin" / ("cvn" & ExeSuffix)

if not fileExists(cvn):
  echo "FAIL: нет ", cvn, "; сначала соберите компилятор (nimble build)"
  quit 1
createDir(tmp)

# ---------------------------------------------------------- e2e: --profile=user
block:
  let r = run(cvn, @["build", root / "examples" / "hello.conv",
                     "-o", tmp / "u",
                     "--profile=user",
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq r.code, 1, "profile: user запрещён"
  check "E-PROFILE-CONFLICT" in r.output, "profile: код ошибки"

# ---------------------------------------------------------------- unit: lexer
block:
  let toks = lex("a\nb\n", "t.conv")
  var kinds: seq[TokenKind]
  for t in toks:
    kinds.add t.kind
  check tkIdent in kinds, "lexer: идентификаторы"
  check tkNewline in kinds, "lexer: перевод строки"
  check kinds[^1] == tkEof, "lexer: eof"

block:
  let toks = lex("proc f(): void =\n  discard 1\n", "t.conv")
  var kinds: seq[TokenKind]
  for t in toks:
    kinds.add t.kind
  check tkIndent in kinds, "lexer: INDENT"
  check tkDedent in kinds, "lexer: DEDENT"

block:
  let toks = lex("x = \"a\\n\\x41\"\n", "t.conv")
  var found = ""
  for t in toks:
    if t.kind == tkStringLit:
      found = t.text
  checkEq found, "a\nA", "lexer: escape-последовательности"

block:
  expectCvnError("E-TAB", proc () =
    discard lex("proc f(): void =\n\tx\n", "t.conv"))

block:
  expectCvnError("E-LEX-STRING", proc () =
    discard lex("let s = \"abc\n", "t.conv"))

# --------------------------------------------------------------- unit: parser
block:
  let src = "{.profile: kernel.}\nfrom core/mem import cAllocator\n\n" &
            "proc main(): !void =\n  let a = cAllocator()\n  defer: a.deinit()\n"
  let m = parseModule(lex(src, "t.conv"), "t.conv")
  check m.kind == nkModule, "parser: модуль"
  var procs = 0
  for s in m.stmts:
    if s.kind == nkProcDecl:
      inc procs
  checkEq procs, 1, "parser: одна процедура"
  check m.stmts.len == 3, "parser: pragma + import + proc"

block:
  expectCvnError("E-NO-RETTYPE", proc () =
    discard parseModule(lex("proc f()\n  discard 1\n", "t.conv"), "t.conv"))

# ------------------------------------------------------ integration: sema/lower
proc helloOpts(): BuildOptions =
  BuildOptions(entry: root / "examples" / "hello.conv", profile: "kernel",
               searchPaths: @[stdlib], runtimePath: runtime)

block:
  let mods = loadProgram((root / "examples" / "hello.conv"), helloOpts())
  let prog = analyze(mods, helloOpts())
  checkEq prog.entryMain.name, "main", "sema: точка входа"
  checkEq prog.entryMain.typ.ret.kind, tyResult, "sema: main возвращает !T"
  checkEq prog.entryMain.typ.ret.elem.kind, tyVoid, "sema: main это !void"
  check prog.procs.len == 4, "sema: 4 процедуры (main + 3 stdlib)"
  let hirs = lowerProgram(prog)
  check hirs.len == 1, "lower: одна не-external процедура"
  var hasDeinit = false
  for ins in hirs[0].instrs:
    if ins.op == hiDeinit:
      hasDeinit = true
  check hasDeinit, "lower: deinit понижен"
  checkEq prog.strings.len, 2, "lower: два строковых литерала"
  let csrc = emitC(prog, hirs)
  check "cvn_str_concat" in csrc, "cgen: вызов concat"
  check "cvn_io_println" in csrc, "cgen: вызов println"
  check "cvn_str_deinit" in csrc, "cgen: deinit"
  check "int main(void)" in csrc, "cgen: wrapper main"

# ------------------------------------------------------------------- e2e: hello
let helloExe = tmp / "hello"
block:
  let b = run(cvn, @["build", root / "examples" / "hello.conv",
                     "-o", helloExe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "e2e: hello собирается (" & b.output & ")"
  var exe = helloExe
  if not fileExists(exe) and fileExists(helloExe & ExeSuffix):
    exe = helloExe & ExeSuffix
  check fileExists(exe), "e2e: бинарник создан"
  if fileExists(exe):
    let r = run(exe, @[])
    checkEq r.code, 0, "e2e: hello exit code"
    checkEq r.output, "hello, convulsions\n", "e2e: hello stdout"

block:
  let r = run(cvn, @["run", root / "examples" / "hello.conv",
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq r.code, 0, "e2e: cvn run exit code"
  check r.output.endsWith("hello, convulsions\n"), "e2e: cvn run stdout"

# ------------------------------------------------------------ e2e: --emit-c
block:
  let c1 = tmp / "c1"
  let c2 = tmp / "c2"
  let r1 = run(cvn, @["build", root / "examples" / "hello.conv",
                      "-o", tmp / "h1", "--emit-c=" & c1,
                      "--path=" & stdlib, "--runtime-path=" & runtime])
  let r2 = run(cvn, @["build", root / "examples" / "hello.conv",
                      "-o", tmp / "h2", "--emit-c=" & c2,
                      "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq r1.code, 0, "emit-c: первая сборка"
  checkEq r2.code, 0, "emit-c: вторая сборка"
  check fileExists(c1 / "main.c"), "emit-c: main.c создан"
  if fileExists(c1 / "main.c") and fileExists(c2 / "main.c"):
    checkEq readFile(c1 / "main.c"), readFile(c2 / "main.c"),
            "emit-c: детерминизм"

# ------------------------------------------------------------- e2e: отрицательные
let negatives = [
  ("bad_tab.conv", "E-TAB"),
  ("bad_indent.conv", "E-INDENT"),
  ("bad_string.conv", "E-LEX-STRING"),
  ("bad_unsupported.conv", "E-UNSUPPORTED"),
  ("bad_import.conv", "E-IMPORT-NOT-FOUND"),
  ("bad_private.conv", "E-PRIVATE"),
  ("cycle_a.conv", "E-IMPORT-CYCLE"),
  ("bad_type.conv", "E-TYPE"),
  ("bad_arity.conv", "E-ARG-COUNT"),
  ("bad_undef.conv", "E-UNDEF"),
  ("bad_try.conv", "E-TYPE"),
  ("bad_unhandled.conv", "E-UNHANDLED-RESULT"),
  ("bad_discard.conv", "E-DISCARD-REQUIRED"),
  ("bad_user.conv", "E-PROFILE-CONFLICT"),
  ("bad_no_main.conv", "E-MAIN-MISSING"),
  ("bad_importc_body.conv", "E-UNSUPPORTED"),
  ("bad_defer_return.conv", "E-DEFER-CTRL"),
  ("bad_dup.conv", "E-DUP-SYMBOL"),
  ("bad_no_rettype.conv", "E-NO-RETTYPE"),
]

for item in negatives:
  let file = item[0]
  let code = item[1]
  let r = run(cvn, @["build", fixtures / file, "-o", tmp / "neg",
                     "--path=" & fixtures, "--path=" & stdlib,
                     "--runtime-path=" & runtime])
  checkEq r.code, 1, "neg " & file & ": exit code"
  check code in r.output, "neg " & file & ": ожидался " & code &
        ", вывод: " & r.output.strip

# ------------------------------------------------------- e2e: два defer (LIFO)
block:
  let exe = tmp / "defers"
  let b = run(cvn, @["build", fixtures / "pos_defers.conv", "-o", exe,
                     "--path=" & fixtures, "--path=" & stdlib,
                     "--runtime-path=" & runtime])
  checkEq b.code, 0, "defers: собирается (" & b.output & ")"
  var e = exe
  if not fileExists(e) and fileExists(exe & ExeSuffix):
    e = exe & ExeSuffix
  if fileExists(e):
    let r = run(e, @[])
    checkEq r.code, 0, "defers: exit code"
    checkEq r.output, "x\n", "defers: stdout"

# ---------------------------------------------------------------- e2e: version
block:
  let r = run(cvn, @["version"])
  checkEq r.code, 0, "version: exit code"
  check "0.1.0" in r.output, "version: номер версии"

if failures > 0:
  echo "\n", failures, " проверок провалено"
  quit 1
else:
  echo "все проверки пройдены"

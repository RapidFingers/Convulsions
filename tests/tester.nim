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
  var s = ""
  var buf = newString(4096)
  while true:
    let n = p.outputStream.readData(addr buf[0], buf.len)
    if n <= 0:
      break
    s.add buf[0 ..< n]
  result.output = s
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

proc buildFixture(file, exeName: string): tuple[code: int, output: string,
                                                exe: string] =
  let exe = tmp / exeName
  let b = run(cvn, @["build", fixtures / file, "-o", exe,
                     "--path=" & fixtures, "--path=" & stdlib,
                     "--runtime-path=" & runtime])
  result.code = b.code
  result.output = b.output
  result.exe = exe
  if b.code == 0 and not fileExists(result.exe) and
     fileExists(result.exe & ExeSuffix):
    result.exe.add ExeSuffix

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

block:
  let toks = lex("x = 'a'\n", "t.conv")
  var ch = ""
  for t in toks:
    if t.kind == tkCharLit:
      ch = t.text
  checkEq ch, "97", "lexer: char-литерал"

block:
  let toks = lex("x = '\\xFF'\n", "t.conv")
  var ch = ""
  for t in toks:
    if t.kind == tkCharLit:
      ch = t.text
  checkEq ch, "255", "lexer: char-escape \\xNN"

block:
  let toks = lex("x = b\"\\xFF\"\n", "t.conv")
  var found = ""
  for t in toks:
    if t.kind == tkStringLit:
      found = t.text
  checkEq found, "\xFF", "lexer: b-строка"

block:
  expectCvnError("E-LEX-ESCAPE", proc () =
    discard lex("let c = '\\u{41}'\n", "t.conv"))

block:
  expectCvnError("E-LEX-CHAR", proc () =
    discard lex("let c = 'ä'\n", "t.conv"))

block:
  expectCvnError("E-LEX-UTF8", proc () =
    discard lex("\xFF\n", "t.conv"))

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
  check prog.procs.len >= 4, "sema: stdlib-процедуры собраны"
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
  ("utf_char_escape_bad.conv", "E-LEX-ESCAPE"),
  ("utf_char_multibyte_bad.conv", "E-LEX-CHAR"),
  ("utf_rune_conv_bad.conv", "E-UNSUPPORTED"),
  ("utf_assert_type_bad.conv", "E-TYPE"),
  ("obj_private_read.conv", "E-PRIVATE"),
  ("obj_private_ctor.conv", "E-PRIVATE"),
  ("obj_let_mut.conv", "E-IMMUTABLE"),
  ("obj_valueparam_mut.conv", "E-IMMUTABLE"),
  ("obj_let_vararg.conv", "E-IMMUTABLE"),
  ("obj_dup_field.conv", "E-DUP-FIELD"),
  ("obj_unknown_field.conv", "E-FIELD"),
  ("obj_posargs.conv", "E-UNSUPPORTED"),
  ("obj_empty.conv", "E-TYPE"),
  ("obj_cycle.conv", "E-TYPE"),
  ("obj_objcmp.conv", "E-UNSUPPORTED"),
  ("obj_type_mismatch.conv", "E-TYPE"),
  ("obj_sizeof_bad.conv", "E-TYPE"),
  ("obj_opaque_ctor.conv", "E-UNSUPPORTED"),
  ("obj_ufcs_field_call.conv", "E-TYPE"),
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

# ----------------------------------------------------------- C-юниты UTF-8
block:
  let ctest = tmp / ("test_utf" & ExeSuffix)
  let b = run("gcc", @["-std=c11", "-Wall", "-Wextra", "-Werror",
                       "-I", runtime, "-o", ctest,
                       root / "tests" / "rt" / "test_utf.c",
                       runtime / "cvnrt.c"])
  checkEq b.code, 0, "c-unit: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-unit: запуск (" & r.output & ")"
    check "c-utf-ok" in r.output, "c-unit: маркер"

# ------------------------------------------------------------------ e2e: UTF-8
block:
  let b = buildFixture("utf_ok.conv", "utf_ok")
  checkEq b.code, 0, "utf: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "utf: exit code"
    checkEq r.output, "привет🙂\n😀\n", "utf: stdout"

block:
  let b = buildFixture("utf_validate_false.conv", "utf_vf")
  checkEq b.code, 0, "utf-validate: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "utf-validate: exit code"
    checkEq r.output, "ok\n", "utf-validate: stdout"

let utfNegatives = [
  ("utf_rune_bad.conv", "utf_rune_bad", "error[3]"),
  ("utf_rune_bounds.conv", "utf_rune_bounds", "error[5]"),
  ("utf_offset_bad.conv", "utf_offset_bad", "error[3]"),
  ("utf_offset_bounds.conv", "utf_offset_bounds", "error[5]"),
  ("utf_rune_ctor_bad.conv", "utf_rune_ctor_bad", "error[3]"),
]

for item in utfNegatives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 1, item[0] & ": exit code"
    check item[2] in r.output, item[0] & ": ожидался " & item[2]

block:
  let b = buildFixture("utf_assert_fail.conv", "utf_assert_fail")
  checkEq b.code, 0, "assert-fail: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 2, "assert-fail: exit code"
    check "assertion failed" in r.output, "assert-fail: сообщение"

block:
  let badPath = tmp / "bad_source.conv"
  writeFile(badPath, "{.profile: kernel.}\n\xFF\n")
  let r = run(cvn, @["build", badPath, "-o", tmp / "bs",
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq r.code, 1, "utf-source: exit code"
  check "E-LEX-UTF8" in r.output, "utf-source: код ошибки"

# ---------------------------------------------------------------- e2e: объекты
let objPositives = [
  ("obj_basic.conv", "obj_basic", "obj-ok\n"),
  ("obj_nested.conv", "obj_nested", "nested-ok\n"),
  ("obj_string.conv", "obj_string", "svc!\n"),
  ("obj_return.conv", "obj_return", "return-ok\n"),
  ("obj_ptr.conv", "obj_ptr", "ptr-ok\n"),
  ("obj_imported.conv", "obj_imported", "alloc-ok\n"),
  ("obj_module.conv", "obj_module", "module-ok\n"),
]

for item in objPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

# ---------------------------------------------------------------- e2e: version
block:
  let r = run(cvn, @["version"])
  checkEq r.code, 0, "version: exit code"
  check "0.3.0" in r.output, "version: номер версии"

if failures > 0:
  echo "\n", failures, " проверок провалено"
  quit 1
else:
  echo "все проверки пройдены"

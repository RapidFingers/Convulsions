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
  let src = "type Box[T] = object\n  value: T\n\n" &
            "proc id[T](x: T): T =\n  return x\n\n" &
            "proc main(): !void =\n" &
            "  let b: Box[int] = Box[int](value: 1)\n" &
            "  discard id[int](1)\n"
  let m = parseModule(lex(src, "t.conv"), "t.conv")
  var genericTypes = 0
  var genericProcs = 0
  var mainNode: AstNode = nil
  for s in m.stmts:
    if s.kind == nkTypeDecl and s.genericParams == @["T"]:
      inc genericTypes
    if s.kind == nkProcDecl:
      if s.genericParams.len > 0:
        inc genericProcs
      elif s.procName == "main":
        mainNode = s
  checkEq genericTypes, 1, "parser: generic-тип"
  checkEq genericProcs, 1, "parser: generic-процедура"
  var hasTypeApply = false
  for st in mainNode.body.stmts:
    if st.kind == nkLet and st.varTypeNode != nil and
       st.varTypeNode.kind == nkTypeApply:
      hasTypeApply = true
  check hasTypeApply, "parser: Box[int] в позиции типа"

block:
  let entry = fixtures / "generics_basic.conv"
  let opts = BuildOptions(entry: entry, profile: "kernel",
                          searchPaths: @[fixtures, stdlib],
                          runtimePath: runtime)
  let prog = analyze(loadProgram(entry, opts), opts)
  var hasBox = false
  var hasPair = false
  for t in prog.objectTypes:
    if t.name == "Box[int]": hasBox = true
    if t.name == "Pair[int]": hasPair = true
  check hasBox, "sema: инстанцирован Box[int]"
  check hasPair, "sema: инстанцирован Pair[int]"
  var mono = 0
  for p in prog.procs:
    if "_g_" in p.cname: inc mono
  check mono >= 2, "sema: generic-процедуры мономорфизированы"

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
    if ins.op in {hiDeinit, hiPathDeinit}:
      hasDeinit = true
  check hasDeinit, "lower: deinit понижен"
  checkEq prog.strings.len, 2, "lower: два строковых литерала"
  let csrc = emitC(prog, hirs)
  check "cvn_str_concat" in csrc, "cgen: вызов concat"
  check "cvn_io_println" in csrc, "cgen: вызов println"
  check "cvn_str_deinit" in csrc, "cgen: deinit"
  check "int main(void)" in csrc, "cgen: wrapper main"
  check "cvn_exec_run" notin csrc, "cgen: hello без executor"

block:
  let entry = root / "examples" / "fibers.conv"
  let opts = BuildOptions(entry: entry, profile: "kernel",
                          searchPaths: @[stdlib], runtimePath: runtime)
  let mods = loadProgram(entry, opts)
  let prog = analyze(mods, opts)
  let hirs = lowerProgram(prog)
  var hasSpawn = false
  for hp in hirs:
    for ins in hp.instrs:
      if ins.op == hiSpawn:
        hasSpawn = true
  check hasSpawn, "lower: spawn понижен"
  let csrc = emitC(prog, hirs)
  check "cvn_exec_run" in csrc, "cgen: исполнитель в main"
  check "cvn_spawn_entry_" in csrc, "cgen: spawn-thunk"
  check "cvn_task_await" in csrc, "cgen: await"

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
  ("obj_create_int.conv", "E-UNSUPPORTED"),
  ("obj_create_value_type.conv", "E-TYPE"),
  ("obj_destroy_value.conv", "E-TYPE"),
  ("obj_destroy_nonalloc.conv", "E-UNDEF"),
  ("obj_ptr_rebind_let.conv", "E-IMMUTABLE"),
  ("obj_deref_nonptr.conv", "E-TYPE"),
  ("obj_index_unsupported.conv", "E-UNSUPPORTED"),
  ("import_all_private.conv", "E-UNDEF"),
  ("import_conflict.conv", "E-DUP-SYMBOL"),
  ("import_local_conflict.conv", "E-DUP-SYMBOL"),
  ("gen_bare_type.conv", "E-GENERIC-NEEDS-ARGS"),
  ("gen_arg_count.conv", "E-GENERIC-ARG-COUNT"),
  ("gen_partial.conv", "E-GENERIC-ARG-COUNT"),
  ("gen_cannot_infer.conv", "E-GENERIC-CANNOT-INFER"),
  ("gen_value.conv", "E-GENERIC-VALUE"),
  ("gen_type_value.conv", "E-GENERIC-VALUE"),
  ("gen_not_generic.conv", "E-GENERIC-NOT-GENERIC"),
  ("gen_constraint.conv", "E-UNSUPPORTED"),
  ("gen_static.conv", "E-UNSUPPORTED"),
  ("gen_value_cycle.conv", "E-TYPE"),
  ("gen_private_field.conv", "E-PRIVATE"),
  ("gen_index.conv", "E-UNSUPPORTED"),
  ("gen_depth.conv", "E-MONO-DEPTH"),
  ("fiber_spawn_noncall.conv", "E-SPAWN-CALL"),
  ("fiber_spawn_ctor.conv", "E-SPAWN-CALL"),
  ("fiber_spawn_builtin.conv", "E-SPAWN-CALL"),
  ("fiber_spawn_plain.conv", "E-SPAWN-RET"),
  ("fiber_spawn_var.conv", "E-SPAWN-VAR"),
  ("fiber_await_nontask.conv", "E-TYPE"),
  ("flow_bad_break.conv", "E-LOOP-CONTROL"),
  ("flow_bad_defer.conv", "E-DEFER-CONTROL"),
  ("flow_bad_cond.conv", "E-TYPE"),
  ("err_bad_coverage.conv", "E-CATCH-COVERAGE"),
  ("err_bad_try_void.conv", "E-TRY-NO-RESULT"),
  ("err_bad_propagate_void.conv", "E-PROPAGATE-RET"),
  ("err_bad_propagate_catch.conv", "E-CATCH-PROPAGATE"),
  ("err_catch_duplicate.conv", "E-DUP-CATCH"),
  ("err_catch_unknown.conv", "E-ERROR-CODE"),
  ("err_catch_else.conv", "E-CATCH-ELSE"),
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
                       runtime / "cvnrt.c", runtime / "cvnrt_alloc.c"])
  checkEq b.code, 0, "c-unit: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-unit: запуск (" & r.output & ")"
    check "c-utf-ok" in r.output, "c-unit: маркер"

# ------------------------------------------------------- C-юниты аллокаторов
block:
  let ctest = tmp / ("test_alloc" & ExeSuffix)
  let b = run("gcc", @["-std=c11", "-Wall", "-Wextra", "-Werror",
                       "-I", runtime, "-o", ctest,
                       root / "tests" / "rt" / "test_alloc.c",
                       runtime / "cvnrt.c", runtime / "cvnrt_alloc.c"])
  checkEq b.code, 0, "c-alloc: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-alloc: запуск (" & r.output & ")"
    check "c-alloc-ok" in r.output, "c-alloc: маркер"

# ---------------------------------------------------------- C-юниты fiber
block:
  let ctest = tmp / ("test_fiber" & ExeSuffix)
  var args = @["-std=c11", "-Wall", "-Wextra", "-Werror",
               "-I", runtime, "-o", ctest,
               root / "tests" / "rt" / "test_fiber.c",
               runtime / "cvnrt.c", runtime / "cvnrt_alloc.c",
               runtime / "cvnrt_fiber.c"]
  when defined(windows):
    args.add "-lws2_32"
  else:
    args.add "-pthread"
  let b = run("gcc", args)
  checkEq b.code, 0, "c-fiber: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-fiber: запуск (" & r.output & ")"
    check "c-fiber-ok" in r.output, "c-fiber: маркер"

# ---------------------------------------------------------- C-юниты sockets
block:
  let ctest = tmp / ("test_net" & ExeSuffix)
  var args = @["-std=c11", "-Wall", "-Wextra", "-Werror",
               "-I", runtime, "-o", ctest,
               root / "tests" / "rt" / "test_net.c",
               runtime / "cvnrt.c", runtime / "cvnrt_alloc.c",
               runtime / "cvnrt_fiber.c", runtime / "cvnrt_net.c"]
  when defined(windows):
    args.add "-lws2_32"
  else:
    args.add "-pthread"
  let b = run("gcc", args)
  checkEq b.code, 0, "c-net: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-net: запуск (" & r.output & ")"
    check "c-net-ok" in r.output, "c-net: маркер"

# ---------------------------------------------------------- C-юнит channel
block:
  let ctest = tmp / ("test_channel" & ExeSuffix)
  var args = @["-std=c11", "-Wall", "-Wextra", "-Werror",
               "-I", runtime, "-o", ctest,
               root / "tests" / "rt" / "test_channel.c",
               runtime / "cvnrt.c", runtime / "cvnrt_alloc.c",
               runtime / "cvnrt_fiber.c", runtime / "cvnrt_net.c",
               runtime / "cvnrt_channel.c"]
  when defined(windows):
    args.add "-lws2_32"
  else:
    args.add "-pthread"
  let b = run("gcc", args)
  checkEq b.code, 0, "c-channel: сборка (" & b.output & ")"
  if b.code == 0:
    let r = run(ctest, @[])
    checkEq r.code, 0, "c-channel: запуск (" & r.output & ")"
    check "c-channel-ok" in r.output, "c-channel: маркер"

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

# ------------------------------------------------------------ e2e: аллокаторы
block:
  let exe = tmp / "allocators"
  let b = run(cvn, @["build", root / "examples" / "allocators.conv",
                     "-o", exe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "alloc: пример собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "alloc: exit code"
    checkEq r.output, "allocators ok\n", "alloc: stdout"

let allocPositives = [
  ("alloc_debug_check_false.conv", "alloc_dbg_check", "debug-check-ok\n"),
  ("alloc_arena_debug.conv", "alloc_arena_dbg", "arena-debug-ok\n"),
]

for item in allocPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

let allocNegatives = [
  ("alloc_fixed_oom.conv", "alloc_fixed_oom", 1, "error[1]"),
  ("alloc_bad_align.conv", "alloc_bad_align", 1, "error[4]"),
  ("alloc_null.conv", "alloc_null", 1, "error[2]"),
  ("alloc_zero_size.conv", "alloc_zero_size", 1, "error[3]"),
  ("alloc_stack_lifo.conv", "alloc_stack_lifo", 3, "stack free out of order"),
  ("alloc_debug_double_free.conv", "alloc_double_free", 3, "double free"),
  ("alloc_debug_bad_size.conv", "alloc_bad_size", 3, "wrong size"),
  ("alloc_debug_redzone.conv", "alloc_redzone", 3, "redzone corrupted"),
  ("alloc_debug_leak.conv", "alloc_leak", 3, "leaked"),
]

for item in allocNegatives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, item[2], item[0] & ": exit code"
    check item[3] in r.output, item[0] & ": ожидался " & item[3]

# ------------------------------------------------- e2e: аллокация объектов
block:
  let exe = tmp / "objects_alloc"
  let b = run(cvn, @["build", root / "examples" / "objects_alloc.conv",
                     "-o", exe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "objalloc: пример собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "objalloc: exit code"
    checkEq r.output, "objects-alloc ok\n", "objalloc: stdout"

let objAllocPositives = [
  ("obj_create_zero.conv", "obj_create_zero", "create-zero-ok\n"),
  ("obj_create_value.conv", "obj_create_value", "create-value-ok\n"),
  ("obj_ptr_mut.conv", "obj_ptr_mut", "ptr-mut-ok\n"),
  ("obj_fixed_create.conv", "obj_fixed_create", "fixed-create-ok\n"),
]

for item in objAllocPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

let objAllocNegatives = [
  ("obj_fixed_create_oom.conv", "obj_fixed_create_oom", 1, "error[1]"),
  ("obj_destroy_twice.conv", "obj_destroy_twice", 3, "double free"),
  ("obj_create_leak.conv", "obj_create_leak", 3, "leaked"),
]

for item in objAllocNegatives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, item[2], item[0] & ": exit code"
    check item[3] in r.output, item[0] & ": ожидался " & item[3]

# -------------------------------------------------------- e2e: отладка утечек
block:
  let exe = tmp / "leak_debug"
  let b = run(cvn, @["build", root / "examples" / "leak_debug.conv",
                     "-o", exe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "leak-debug: пример собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "leak-debug: exit code"
    check "leak-debug ok" in r.output, "leak-debug: stdout"
    check "Node" in r.output, "leak-debug: тип в отчёте"
    check "leak_debug.conv" in r.output, "leak-debug: место в отчёте"
    check "leaked 1 block" in r.output, "leak-debug: счётчик"

block:
  let b = buildFixture("obj_leak_auto.conv", "obj_leak_auto")
  checkEq b.code, 0, "leak-auto: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "leak-auto: exit code"
    check "leaked 1 block" in r.output, "leak-auto: автоотчёт"
    check "Node" in r.output, "leak-auto: тип"
    check "obj_leak_auto.conv" in r.output, "leak-auto: место"

# ---------------------------------------------------------------- e2e: import
block:
  let b = buildFixture("import_all_ok.conv", "import_all_ok")
  checkEq b.code, 0, "import-all: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "import-all: exit code"
    checkEq r.output, "import-all-ok\n", "import-all: stdout"

# ---------------------------------------------------------------- e2e: generics
block:
  let exe = tmp / "generics"
  let b = run(cvn, @["build", root / "examples" / "generics.conv",
                     "-o", exe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "generics: пример собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "generics: exit code"
    checkEq r.output, "generics ok\n", "generics: stdout"

let genericPositives = [
  ("generics_basic.conv", "gen_basic", "gen-basic-ok\n"),
  ("generics_nested.conv", "gen_nested", "gen-nested-ok\n"),
  ("generics_return.conv", "gen_return", "gen-return-ok\n"),
  ("generics_varparam.conv", "gen_varparam", "gen-varparam-ok\n"),
  ("generics_ufcs.conv", "gen_ufcs", "gen-ufcs-ok\n"),
  ("generics_string.conv", "gen_string", "gen-string-ok\n"),
  ("generics_field.conv", "gen_field", "gen-field-ok\n"),
  ("generics_module.conv", "gen_module", "gen-module-ok\n"),
  ("generics_recursive.conv", "gen_recursive", "gen-recursive-ok\n"),
]

for item in genericPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

block:
  let c1 = tmp / "genc1"
  let c2 = tmp / "genc2"
  let r1 = run(cvn, @["build", root / "examples" / "generics.conv",
                      "-o", tmp / "g1", "--emit-c=" & c1,
                      "--path=" & stdlib, "--runtime-path=" & runtime])
  let r2 = run(cvn, @["build", root / "examples" / "generics.conv",
                      "-o", tmp / "g2", "--emit-c=" & c2,
                      "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq r1.code, 0, "generics emit-c: первая сборка"
  checkEq r2.code, 0, "generics emit-c: вторая сборка"
  if fileExists(c1 / "main.c") and fileExists(c2 / "main.c"):
    checkEq readFile(c1 / "main.c"), readFile(c2 / "main.c"),
            "generics emit-c: детерминизм"

# ------------------------------------------------------------------ e2e: fiber
block:
  let exe = tmp / "fibers"
  let b = run(cvn, @["build", root / "examples" / "fibers.conv",
                     "-o", exe,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "fiber: пример собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "fiber: exit code"
    checkEq r.output, "fibers ok\n", "fiber: stdout"

block:
  let exe = tmp / "fibers1"
  let b = run(cvn, @["build", root / "examples" / "fibers.conv",
                     "-o", exe, "--workers=1",
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "fiber workers=1: собирается (" & b.output & ")"
  if b.code == 0:
    var e = exe
    if not fileExists(e) and fileExists(exe & ExeSuffix):
      e = exe & ExeSuffix
    let r = run(e, @[])
    checkEq r.code, 0, "fiber workers=1: exit code"
    checkEq r.output, "fibers ok\n", "fiber workers=1: stdout"

let fiberPositives = [
  ("fiber_void.conv", "fiber_void", "task-note\nfiber-void-ok\n"),
  ("fiber_many.conv", "fiber_many", "fiber-many-ok\n"),
  ("fiber_generic.conv", "fiber_generic", "fiber-generic-ok\n"),
  ("fiber_external.conv", "fiber_external", "from-task\nfiber-external-ok\n"),
  ("fiber_object.conv", "fiber_object", "fiber-object-ok\n"),
]

for item in fiberPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

block:
  let b = buildFixture("fiber_error.conv", "fiber_error")
  checkEq b.code, 0, "fiber_error: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 1, "fiber_error: exit code"
    check "error[3]" in r.output, "fiber_error: ошибка задачи"

# ---------------------------------------------------------------- e2e: control flow
block:
  let b = buildFixture("flow_test.conv", "flow_test")
  checkEq b.code, 0, "flow: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "flow: exit code"

block:
  let b = buildFixture("flow_elif.conv", "flow_elif")
  checkEq b.code, 0, "flow elif: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "flow elif: exit code"

# ---------------------------------------------------------------- e2e: sockets
let socketPositives = [
  ("sockets_echo.conv", "sockets_echo", "sockets-echo-ok\n"),
  ("sockets_multi.conv", "sockets_multi", "sockets-multi-ok\n"),
  ("sockets_eof.conv", "sockets_eof", "sockets-eof-ok\n"),
  ("sockets_listen.conv", "sockets_listen", "sockets-listen-ok\n"),
]

for item in socketPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    checkEq r.output, item[2], item[0] & ": stdout"

let socketNegatives = [
  ("sockets_refused.conv", "sockets_refused", 1, "error[6]"),
  ("sockets_bad_host.conv", "sockets_bad_host", 1, "error[3]"),
]

for item in socketNegatives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, item[2], item[0] & ": exit code"
    check item[3] in r.output, item[0] & ": ожидался " & item[3]

for ex in ["echo_server.conv", "echo_client.conv"]:
  let b = run(cvn, @["build", root / "examples" / ex,
                     "-o", tmp / ex.splitFile.name,
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "sockets: пример " & ex & " собирается (" & b.output & ")"

# ---------------------------------------------------------------- e2e: ошибки
let errorPositives = [
  ("err_try_value.conv", "err_try_value", ""),
  ("err_try_last_call.conv", "err_try_last_call", ""),
  ("err_try_arg.conv", "err_try_arg", ""),
  ("err_propagate.conv", "err_propagate", "propagate-ok\n"),
  ("err_propagate_spawn.conv", "err_propagate_spawn",
   "spawn-propagate-ok\n"),
  ("err_catch_partial.conv", "err_catch_partial", "catch-ok\n"),
  ("err_catch_continue.conv", "err_catch_continue",
   "catch-continue-ok\n"),
]

for item in errorPositives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, item[0] & ": exit code"
    if item[2].len > 0:
      checkEq r.output, item[2], item[0] & ": stdout"

block:
  let b = buildFixture("err_errdefer.conv", "err_errdefer")
  checkEq b.code, 0, "errdefer: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 2, "errdefer: assert только на ошибке"
    check "bad-errdefer" in r.output, "errdefer: успешный путь не должен срабатывать"

block:
  let b = buildFixture("err_errdefer_try.conv", "err_errdefer_try")
  checkEq b.code, 0, "errdefer try: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 2, "errdefer try: exit code"
    check "try-errdefer" in r.output, "errdefer try: сообщение"

block:
  let b = buildFixture("err_errdefer_return.conv", "err_errdefer_return")
  checkEq b.code, 0, "errdefer return: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 2, "errdefer return: exit code"
    check "forward-errdefer" in r.output, "errdefer return: сообщение"

block:
  let b = buildFixture("err_catch_panic.conv", "err_catch_panic")
  checkEq b.code, 0, "catch panic: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 2, "catch panic: exit code"
    check "panic: boom" in r.output, "catch panic: сообщение"

let errorRuntimeNegatives = [
  ("err_try_region.conv", "err_try_region", "error[3]"),
  ("err_propagate_forward.conv", "err_propagate_forward", "error[3]"),
  ("err_catch_unmatched.conv", "err_catch_unmatched", "error[3]"),
  ("channel_bad_capacity.conv", "channel_bad_capacity", "error[3]"),
]

for item in errorRuntimeNegatives:
  let b = buildFixture(item[0], item[1])
  checkEq b.code, 0, item[0] & ": собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 1, item[0] & ": exit code"
    check item[2] in r.output, item[0] & ": ожидался " & item[2]

block:
  let b = run(cvn, @["run", root / "examples" / "error_levels.conv",
                     "--path=" & stdlib, "--runtime-path=" & runtime])
  checkEq b.code, 0, "error_levels: запуск (" & b.output & ")"
  checkEq b.output, "error-levels-ok\n", "error_levels: stdout"

# ---------------------------------------------------------- e2e: producer/consumer
for workers in [0, 1]:
  var args = @["build", root / "tests" / "fixtures" / "producer_consumer.conv",
               "-o", tmp / ("producer_consumer_" & $workers),
               "--path=" & fixtures, "--path=" & stdlib,
               "--runtime-path=" & runtime]
  if workers > 0:
    args.add "--workers=" & $workers
  let b = run(cvn, args)
  checkEq b.code, 0, "producer-consumer: сборка workers=" & $workers &
            " (" & b.output & ")"
  if b.code == 0:
    let r = run(tmp / ("producer_consumer_" & $workers), @[])
    checkEq r.code, 0, "producer-consumer: exit workers=" & $workers
    checkEq r.output, "producer-consumer-ok\n",
            "producer-consumer: stdout workers=" & $workers

block:
  let b = buildFixture("slice_basic.conv", "slice_basic")
  checkEq b.code, 0, "slice: собирается (" & b.output & ")"
  if b.code == 0:
    let r = run(b.exe, @[])
    checkEq r.code, 0, "slice: exit code"
    checkEq r.output, "slice-ok\n", "slice: stdout"

block:
  for f in ["slice_bounds.conv", "slice_buffer_bounds.conv"]:
    let b = buildFixture(f, f.splitFile.name)
    checkEq b.code, 0, f & ": собирается (" & b.output & ")"
    if b.code == 0:
      let r = run(b.exe, @[])
      checkEq r.code, 2, f & ": assert вне границ"

# ---------------------------------------------------------------- e2e: version
block:
  let r = run(cvn, @["version"])
  checkEq r.code, 0, "version: exit code"
  check "0.13.0" in r.output, "version: номер версии"

if failures > 0:
  echo "\n", failures, " проверок провалено"
  quit 1
else:
  echo "все проверки пройдены"

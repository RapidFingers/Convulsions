## Семантический анализ: имена, типы, импорты, профиль, builtin deinit.

import std/[tables, strutils]
import diag, ast, types, symbols, options

type
  Program* = ref object
    modules*: seq[ModuleInfo]
    entry*: ModuleInfo
    syms*: seq[Symbol]
    procs*: seq[Symbol]
    entryMain*: Symbol
    strings*: seq[string]
    opts*: BuildOptions

  Sema = ref object
    prog: Program
    curMod: ModuleInfo
    procSym: Symbol
    scopes: seq[Scope]
    inDefer: int
    builtins: Table[string, Type]
    builtinDeinit: Symbol

proc addSym(s: Sema; sym: Symbol): int =
  sym.id = s.prog.syms.len
  s.prog.syms.add sym
  sym.id

proc makeBuiltins(): Table[string, Type] =
  result = initTable[string, Type]()
  result["void"] = newType(tyVoid, "void")
  result["int"] = newType(tyInt, "int")
  result["bool"] = newType(tyBool, "bool")
  result["char"] = newType(tyChar, "char")
  result["string"] = newType(tyString, "string")
  result["pointer"] = newType(tyPointer, "pointer")

proc push(s: Sema) =
  s.scopes.add newScope(s.scopes[^1])

proc pop(s: Sema) =
  s.scopes.setLen(s.scopes.len - 1)

proc define(s: Sema; sym: Symbol) =
  s.scopes[^1].define(sym)

proc lookup(s: Sema; name: string): Symbol =
  for i in countdown(s.scopes.len - 1, 0):
    let sym = s.scopes[i].lookup(name)
    if sym != nil:
      return sym
  nil

proc sanitizeIdent(s: string): string =
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      result.add c
    else:
      result.add '_'

proc procCName(m: ModuleInfo; name: string): string =
  "cvn_m_" & sanitizeIdent(m.path) & "_" & sanitizeIdent(name)

proc pragmaVal(pragmas: seq[AstNode]; name: string): string =
  for p in pragmas:
    if p.pragmaName == name:
      return p.pragmaValue

proc addHeader(m: ModuleInfo; value: string) =
  if value.len > 0 and value notin m.headers:
    m.headers.add value

proc validatePragmas(s: Sema; pragmas: seq[AstNode]; allowed: seq[string];
                     where: string) =
  for p in pragmas:
    if p.pragmaName notin allowed:
      fail("E-PRAGMA-UNSUPPORTED", s.curMod.file, p.line, p.col,
           "прагма '{" & p.pragmaName & ".}' у " & where &
           " не поддерживается в v0.1",
           "допустимы: " & allowed.join(", "))

proc typeFromNode(s: Sema; n: AstNode): Type =
  case n.kind
  of nkTypeName:
    if s.builtins.hasKey(n.typeName):
      return s.builtins[n.typeName]
    let sym = s.curMod.scope.lookup(n.typeName)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.line, n.col,
           "неизвестный тип: " & n.typeName)
    if sym.kind != skType:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "'" & n.typeName & "' не является типом")
    sym.typ
  of nkPtrType:
    let inner = s.typeFromNode(n.elemType)
    let t = newType(tyPtr)
    t.elem = inner
    t
  of nkResultType:
    let inner = s.typeFromNode(n.elemType)
    let t = newType(tyResult)
    t.elem = inner
    t
  else:
    fail("E-PARSE", s.curMod.file, n.line, n.col, "ожидался тип")

proc declareType(s: Sema; n: AstNode) =
  if s.curMod.scope.hasOwn(n.declName):
    fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
         "повторное объявление: " & n.declName)
  s.validatePragmas(n.declPragmas, @["importc", "header"], "типа")
  let cname = pragmaVal(n.declPragmas, "importc")
  if cname.len == 0:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "object-типы с полями не поддерживаются в v0.1 (будут в v0.2)",
         "в v0.1 допустим только непрозрачный {.importc.}-тип")
  let t = newType(tyObject, n.declName)
  t.cname = cname
  t.opaque = true
  let sym = Symbol(kind: skType, name: n.declName, typ: t, node: n,
                   exported: n.exportedDecl, modulePath: s.curMod.path)
  discard s.addSym(sym)
  s.curMod.scope.define(sym)
  if n.exportedDecl:
    s.curMod.addExport(sym)
  n.symId = sym.id
  n.importedDecl = true
  n.cNameDecl = cname
  s.curMod.addHeader(pragmaVal(n.declPragmas, "header"))

proc declareProc(s: Sema; n: AstNode) =
  if s.curMod.scope.hasOwn(n.procName):
    fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
         "повторное объявление: " & n.procName)
  s.validatePragmas(n.procPragmas, @["importc", "cdecl", "header"], "процедуры")
  var params: seq[Type]
  var pnames: seq[string]
  var pvars: seq[bool]
  for p in n.params:
    let pt = s.typeFromNode(p.paramTypeNode)
    params.add pt
    pnames.add p.paramName
    pvars.add p.paramVar
  let ret = s.typeFromNode(n.retTypeNode)
  let ptype = newType(tyProc)
  ptype.params = params
  ptype.ret = ret

  let importName = pragmaVal(n.procPragmas, "importc")
  let isExternal = importName.len > 0
  if isExternal and n.body != nil:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "importc-процедура не может иметь тело")
  if not isExternal and n.body == nil:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "процедура без тела требует {.importc.}",
         "импорт C-функции помечается {.importc: \"name\", cdecl.}")

  let sym = Symbol(kind: skProc, name: n.procName, typ: ptype, node: n,
                   exported: n.exportedProc, external: isExternal,
                   modulePath: s.curMod.path,
                   cname: (if isExternal: importName
                           else: procCName(s.curMod, n.procName)))
  sym.paramNames = pnames
  sym.paramVars = pvars
  discard s.addSym(sym)
  n.symId = sym.id
  s.curMod.scope.define(sym)
  if n.exportedProc:
    s.curMod.addExport(sym)
  s.prog.procs.add sym
  s.curMod.addHeader(pragmaVal(n.procPragmas, "header"))

  var seen = initTable[string, bool]()
  for p in n.params:
    if seen.hasKey(p.paramName):
      fail("E-DUP-SYMBOL", s.curMod.file, p.line, p.col,
           "повторяющийся параметр: " & p.paramName)
    seen[p.paramName] = true
    let psym = Symbol(kind: skParam, name: p.paramName,
                      typ: s.typeFromNode(p.paramTypeNode), node: p)
    discard s.addSym(psym)
    p.symId = psym.id
    sym.paramSyms.add psym

proc setupModule(s: Sema; m: ModuleInfo) =
  s.curMod = m
  m.scope = newScope(nil)
  for imp in m.importNodes:
    let child = m.imported[imp.modulePath]
    for name in imp.names:
      if child.exports.hasKey(name):
        let sym = child.exports[name]
        if m.scope.hasOwn(name):
          fail("E-DUP-SYMBOL", m.file, imp.line, imp.col,
               "имя '" & name & "' уже импортировано")
        m.scope.define(sym)
      elif child.scope != nil and child.scope.hasOwn(name):
        fail("E-PRIVATE", m.file, imp.line, imp.col,
             "имя '" & name & "' не экспортируется модулем " & imp.modulePath,
             "экспорт помечается '*' в объявлении")
      else:
        fail("E-UNDEF", m.file, imp.line, imp.col,
             "модуль '" & imp.modulePath & "' не экспортирует '" & name & "'")
  for stmt in m.ast.stmts:
    if stmt.kind == nkTypeDecl:
      s.declareType(stmt)
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl:
      s.declareProc(stmt)

proc addressable(n: AstNode): bool =
  if n.isNil:
    return false
  case n.kind
  of nkIdent: true
  of nkField: addressable(n.obj)
  else: false

proc sameOrCoerce(a, b: Type): bool =
  if sameType(a, b):
    return true
  if b.kind == tyString and a.kind == tyString:
    return true
  false

proc analExpr(s: Sema; n: AstNode): Type

proc checkCall(s: Sema; sym: Symbol; args: seq[AstNode]; n: AstNode) =
  let ptype = sym.typ
  if args.len != ptype.params.len:
    fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
         "процедура '" & sym.name & "' ожидает " & $ptype.params.len &
         " аргументов, а получила " & $args.len)
  for i in 0 ..< args.len:
    let at = s.analExpr(args[i])
    if not sameOrCoerce(at, ptype.params[i]):
      fail("E-TYPE", s.curMod.file, args[i].line, args[i].col,
           "аргумент " & $(i + 1) & " для '" & sym.name & "': ожидался " &
           typeName(ptype.params[i]) & ", получен " & typeName(at))
    if sym.paramVars.len > i and sym.paramVars[i] and not addressable(args[i]):
      fail("E-NOT-ADDRESSABLE", s.curMod.file, args[i].line, args[i].col,
           "var-параметр требует адресуемое выражение")

proc analCall(s: Sema; n: AstNode): Type =
  if n.callee.kind == nkField:
    let fld = n.callee
    let objType = s.analExpr(fld.obj)
    if fld.fieldName == "deinit":
      if objType.kind != tyString:
        fail("E-UNSUPPORTED", s.curMod.file, fld.line, fld.col,
             "deinit в v0.1 поддерживается только для string",
             "seq и пользовательские типы — в v0.2")
      if not addressable(fld.obj):
        fail("E-NOT-ADDRESSABLE", s.curMod.file, fld.line, fld.col,
             "deinit требует адресуемое значение")
      n.args = @[fld.obj]
      n.symId = s.builtinDeinit.id
      n.typ = s.builtins["void"]
      return n.typ
    let sym = s.lookup(fld.fieldName)
    if sym == nil or sym.kind != skProc:
      fail("E-UNDEF", s.curMod.file, fld.line, fld.col,
           "нет процедуры '" & fld.fieldName & "' для UFCS-вызова")
    var args = @[fld.obj]
    for a in n.args:
      args.add a
    n.args = args
    n.symId = sym.id
    s.checkCall(sym, n.args, n)
    n.typ = sym.typ.ret
    return n.typ
  elif n.callee.kind == nkIdent:
    let sym = s.lookup(n.callee.name)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.callee.line, n.callee.col,
           "неизвестная процедура: " & n.callee.name)
    if sym.kind == skBuiltin:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "builtin можно вызывать только методом (x.deinit())")
    if sym.kind != skProc:
      fail("E-TYPE", s.curMod.file, n.callee.line, n.callee.col,
           "'" & n.callee.name & "' не является процедурой")
    n.symId = sym.id
    s.checkCall(sym, n.args, n)
    n.typ = sym.typ.ret
    return n.typ
  else:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "вызов произвольного выражения не поддерживается в v0.1 (v0.2)")

proc analExpr(s: Sema; n: AstNode): Type =
  case n.kind
  of nkIntLit:
    n.typ = s.builtins["int"]
  of nkStrLit:
    n.typ = s.builtins["string"]
  of nkIdent:
    let sym = s.lookup(n.name)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.line, n.col, "неизвестное имя: " & n.name)
    if sym.kind in {skProc, skBuiltin}:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "процедура как значение не поддерживается в v0.1 (v0.3)")
    if sym.kind == skType:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "тип '" & n.name & "' использован как значение")
    n.symId = sym.id
    n.typ = sym.typ
  of nkUnary:
    let t = s.analExpr(n.a)
    case n.op
    of "-", "+":
      if t.kind != tyInt:
        fail("E-TYPE", s.curMod.file, n.line, n.col, "унарный '-' требует int")
      n.typ = t
    of "not":
      if t.kind != tyBool:
        fail("E-TYPE", s.curMod.file, n.line, n.col, "'not' требует bool")
      n.typ = t
    else:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "унарный оператор '" & n.op & "' не поддерживается в v0.1")
  of nkBinary:
    let ta = s.analExpr(n.a)
    let tb = s.analExpr(n.b)
    case n.op
    of "+", "-", "*", "/", "%":
      if ta.kind != tyInt or tb.kind != tyInt:
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "арифметика требует int, получено " & typeName(ta) & " и " &
             typeName(tb))
      n.typ = ta
    of "==", "!=", "<", "<=", ">", ">=":
      if not sameType(ta, tb):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "сравнение разных типов: " & typeName(ta) & " и " & typeName(tb))
      n.typ = s.builtins["bool"]
    of "and", "or":
      if ta.kind != tyBool or tb.kind != tyBool:
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "'" & n.op & "' требует bool")
      n.typ = s.builtins["bool"]
    else:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "оператор '" & n.op & "' не поддерживается в v0.1")
  of nkTry:
    let t = s.analExpr(n.operand)
    if t.kind != tyResult:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "try применяется только к !T, получен " & typeName(t))
    if s.procSym.isNil or s.procSym.typ.ret.kind != tyResult:
      fail("E-TRY-NO-RESULT", s.curMod.file, n.line, n.col,
           "try требует, чтобы процедура возвращала !T")
    n.typ = t.elem
  of nkCall:
    discard s.analCall(n)
  of nkField:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "доступ к полю вне вызова метода не поддерживается в v0.1 (v0.2)")
  else:
    fail("E-PARSE", s.curMod.file, n.line, n.col, "неожиданный узел выражения")
  n.typ

proc analStmt(s: Sema; n: AstNode) =
  case n.kind
  of nkBlock:
    s.push()
    for st in n.stmts:
      s.analStmt(st)
    s.pop()
  of nkLet, nkVar:
    let initType = s.analExpr(n.init)
    var typ = initType
    if n.varTypeNode != nil:
      typ = s.typeFromNode(n.varTypeNode)
      if not sameType(initType, typ):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "инициализатор типа " & typeName(initType) & " не совпадает с " &
             typeName(typ))
    if typ.kind == tyVoid:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "нельзя объявить переменную типа void")
    let kind = if n.kind == nkLet: skLet else: skVar
    let sym = Symbol(kind: kind, name: n.varName, typ: typ, node: n)
    discard s.addSym(sym)
    if s.scopes[^1].hasOwn(n.varName):
      fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
           "повторное объявление: " & n.varName)
    s.define(sym)
    n.symId = sym.id
    n.typ = typ
  of nkDefer:
    inc s.inDefer
    s.analStmt(n.deferBody)
    dec s.inDefer
    n.typ = s.builtins["void"]
  of nkReturn:
    if s.inDefer > 0:
      fail("E-DEFER-CTRL", s.curMod.file, n.line, n.col,
           "return внутри defer запрещён")
    let ret = s.procSym.typ.ret
    if ret.kind == tyResult:
      if ret.elem.kind == tyVoid:
        if n.value != nil:
          fail("E-TYPE", s.curMod.file, n.line, n.col,
               "функция !void не возвращает значение")
      else:
        if n.value == nil:
          fail("E-MISSING-RETURN", s.curMod.file, n.line, n.col,
               "нужно вернуть значение типа " & typeName(ret.elem))
        let vt = s.analExpr(n.value)
        if not sameType(vt, ret.elem):
          fail("E-TYPE", s.curMod.file, n.line, n.col,
               "возвращается " & typeName(vt) & ", ожидался " &
               typeName(ret.elem))
    else:
      if n.value == nil:
        fail("E-MISSING-RETURN", s.curMod.file, n.line, n.col,
             "нужно вернуть значение типа " & typeName(ret))
      let vt = s.analExpr(n.value)
      if not sameType(vt, ret):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "возвращается " & typeName(vt) & ", ожидался " & typeName(ret))
    n.typ = s.builtins["void"]
  of nkDiscard:
    let t = s.analExpr(n.value)
    if t.kind == tyResult:
      fail("E-UNHANDLED-RESULT", s.curMod.file, n.line, n.col,
           "discard не обрабатывает !T; используйте try или catch:",
           "catch: будет в v0.2")
    n.typ = s.builtins["void"]
  else:
    let t = s.analExpr(n)
    if t.kind == tyResult:
      fail("E-UNHANDLED-RESULT", s.curMod.file, n.line, n.col,
           "результат !T не обработан: используйте try")
    if t.kind != tyVoid:
      fail("E-DISCARD-REQUIRED", s.curMod.file, n.line, n.col,
           "значение типа " & typeName(t) & " не использовано; нужен discard")

proc analyzeModuleBodies(s: Sema; m: ModuleInfo) =
  s.curMod = m
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl and stmt.body != nil:
      let sym = s.prog.syms[stmt.symId]
      s.procSym = sym
      s.scopes = @[newScope(m.scope)]
      for i, p in stmt.params:
        let ps = sym.paramSyms[i]
        if s.scopes[^1].hasOwn(ps.name):
          fail("E-DUP-SYMBOL", m.file, p.line, p.col,
               "повторяющийся параметр: " & ps.name)
        s.scopes[^1].define(ps)
      s.inDefer = 0
      s.analStmt(stmt.body)

proc findMain(s: Sema) =
  let m = s.prog.entry
  var sym: Symbol = nil
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl and stmt.procName == "main":
      sym = s.prog.syms[stmt.symId]
  if sym.isNil:
    fail("E-MAIN-MISSING", m.file, 1, 1,
         "во входном модуле нет 'proc main'")
  if sym.typ.params.len != 0:
    fail("E-MAIN-MISSING", m.file, sym.node.line, sym.node.col,
         "main не должен принимать параметры")
  if sym.typ.ret.kind != tyResult or sym.typ.ret.elem.kind != tyVoid:
    fail("E-MAIN-MISSING", m.file, sym.node.line, sym.node.col,
         "main должен иметь тип '!void'")
  s.prog.entryMain = sym

proc analyze*(modules: seq[ModuleInfo]; opts: BuildOptions): Program =
  let prog = Program(modules: modules, opts: opts, syms: @[], procs: @[],
                     strings: @[])
  var s = Sema(prog: prog, builtins: makeBuiltins())
  let deinitType = newType(tyProc)
  deinitType.params = @[s.builtins["string"]]
  deinitType.ret = s.builtins["void"]
  let deinitSym = Symbol(kind: skBuiltin, name: "deinit", cname: "cvn_str_deinit",
                         typ: deinitType, builtin: "deinit")
  s.builtinDeinit = deinitSym
  discard s.addSym(deinitSym)

  for m in modules:
    if m.isEntry:
      prog.entry = m
    s.setupModule(m)
  for m in modules:
    s.analyzeModuleBodies(m)
  s.findMain()
  prog
